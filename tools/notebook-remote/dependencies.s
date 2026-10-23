package notebook.remote.dependencies

from notebook.remote.common import fail, decode, identifier, command_at
from notebook.remote.host import environment_log

export Dependencies, installed_packages

# Read indexes, never evaluate a package or a gemspec while showing inventory.
def installed_packages(directory):
  result = []
  return result unless fs.exists?(directory)
  scan_packages(directory, result, 0)
  result

def scan_packages(directory, result, depth):
  return null if depth > 4
  index = directory.to_str + "/modules.index"
  if fs.exists?(index):
    lines = fs.read_text(index, limit: 1048576).split("\n")
    if lines.count >= 4 and ["sputnik.package.index.v1", "sputnik.package.index.v2"].include?(lines[0]):
      item = {name: lines[1], version: lines[2], digest: lines[3]}
      item[:variant] = lines[4] if lines[0] == "sputnik.package.index.v2" and lines.count >= 5
      result.push!(item)
    return null
  # fs.Path values have no implicit ordering; compare their textual paths.
  paths = fs.entries(directory).map: $it.to_str
  paths.sorted.each |name|:
    path = fs.Path(name)
    scan_packages(path, result, depth + 1) if fs.dir?(path) and not fs.metadata(path).symlink? and not path.basename.starts_with?(".")

class Dependencies:
  def init(@core, @compiler):
    @core.sql("CREATE TABLE IF NOT EXISTS dependency_jobs(project TEXT,id TEXT PRIMARY KEY,action TEXT,state TEXT,directory TEXT,request TEXT,error TEXT,result TEXT)")
    @core.sql("UPDATE dependency_jobs SET state='interrupted',error='agent restarted; inspect logs before retrying' WHERE state IN ('queued','running')")

  def busy?(project): @core.row("SELECT id FROM dependency_jobs WHERE project=? AND state IN ('queued','running') LIMIT 1", [project]) != null
  def protected?(project): @core.row("SELECT id FROM dependency_jobs WHERE project=? AND state IN ('queued','running','interrupted') LIMIT 1", [project]) != null
  def list(project): @core.rows("SELECT id,action,state,error,result FROM dependency_jobs WHERE project=? ORDER BY rowid DESC LIMIT 20", [project])
  def get(project, id):
    record = @core.row("SELECT * FROM dependency_jobs WHERE project=? AND id=?", [project, id])
    fail(404, "dependency operation not found") unless record
    record.merge(decode(environment_log(record[:directory])))

  # Metadata inspection never retires workers, installs code or creates a job.
  def catalog(params):
    query = params[?:query]
    source = params[?:source]
    fail(400, "unsupported package query") unless ["versions", "variants"].include?(query)
    fail(400, "invalid package name") unless Str === source and source.bytes.count > 0 and source.bytes.count <= 257 and not source.starts_with?("-") and not source.contains?("\u{0}")
    arguments = ["pkg", query, source, "--json"]
    arguments = arguments + ["--check-host"] if query == "variants"
    checked = system.command(@compiler, *arguments).capture(timeout: 20.0, check: false)
    fail(422, checked.stderr.to_str) unless checked.success?
    decode(checked.stdout.to_str)

  def request(project, revision, params):
    action = params[?:action]
    fail(400, "unsupported dependency operation") unless ["install_sputnik", "remove_sputnik", "lock_ruby"].include?(action)
    fail(409, "a dependency operation is already running") if busy?(project)
    source = params[?:source] or ""
    version = params[?:version] or ""
    fail(400, "invalid package source or version") unless Str === source and Str === version and source.bytes.count <= 4096 and version.bytes.count <= 128 and not source.starts_with?("-") and not source.contains?("\u{0}")
    fail(400, "package source is required") if action != "lock_ruby" and source == ""
    ["variant", "backend", "bundle", "registry"].each |key|:
      value = params[?key]
      fail(400, "invalid package option") if value and (not (Str === value) or value.bytes.count > 4096 or value.contains?("\u{0}") or value.starts_with?("-"))
    ["allow_native", "build_from_source", "allow_native_large", "local_source"].each |key|:
      value = params[?key]
      fail(400, "invalid package flag") unless value == null or value == true or value == false
    fail(422, "Gemfile is missing") if action == "lock_ruby" and not fs.exists?(revision[:directory] + "/Gemfile")
    @core.retire_dependency_workers(project)
    project_directory = @core.ensure_environment_project(project)
    id = SecureRandom.hex(16)
    directory = project_directory + "/operations/" + id
    @core.sql("INSERT INTO dependency_jobs VALUES(?,?,?,?,?,?,?,?)", [project, id, action, "queued", directory, Json.generate(params), "", "{}"])
    task.async: execute(project, id, action, source, version, directory, revision, params)
    {id: id, action: action, state: "queued"}

  def update(project, id, state, error = "", result = {}):
    @core.synchronize:
      @core.sql("UPDATE dependency_jobs SET state=?,error=?,result=? WHERE id=?", [state, error, Json.generate(result), id])
      @core.event(project, {type: "dependency_operation", id: id, state: state, error: error})

  def execute(project, id, action, source, version, directory, revision, params):
    try:
      update(project, id, "running")
      fs.mkdir_p(directory)
      # Removal may unlink a loaded native library. Confirm worker termination first.
      loop:
        pending = @core.synchronize: @core.owners_pending?(project)
        if not pending: break
        task.sleep(0.05)
      home = @core.package_directory(project)
      result = {}
      if action == "lock_ruby":
        ["Gemfile", "Gemfile.lock", ".bundle/config"].each |name|:
          input = revision[:directory] + "/" + name
          if fs.exists?(input):
            fs.mkdir_p(fs.Path(directory + "/" + name).parent)
            fs.atomic_write_text(directory + "/" + name, fs.read_text(input))
        copy_gem_cache(revision[:directory], directory, "vendor/cache")
        ruby = @core.ruby_executable
        command(directory, ruby, ["-S", "bundle", "lock"], {BUNDLE_GEMFILE: directory + "/Gemfile", BUNDLE_APP_CONFIG: directory + "/.bundle", BUNDLE_FROZEN: "false"})
        result = {gemfile_lock: fs.read_text(directory + "/Gemfile.lock", limit: 1048576)}
      else:
        if action == "install_sputnik" and params[?:local_source] and source.ends_with?(".sputnikpkg") and fs.exists?(source) and not fs.dir?(source):
          # A chosen archive already identifies its build. Read its own selectors
          # instead of imposing the registry installer's CPU/none defaults.
          inspected = system.command(@compiler, "pkg", "inspect", source).capture(timeout: 120.0, check: false)
          raise IOError(inspected.stderr.to_str) unless inspected.success?
          metadata = decode(inspected.stdout.to_str)
          params[:variant] = metadata[:variant] unless params[?:variant]
          params[:bundle] = metadata[:bundle] unless params[?:bundle]
          backend = metadata[:target][:compute_backend]
          params[:backend] = backend if not params[?:backend] and ["cpu", "cuda", "mps"].include?(backend)
        arguments = ["pkg", (if action == "install_sputnik" then "install" else "uninstall"), source]
        arguments = arguments + ["--version", version] if version != ""
        arguments = arguments + ["--variant", params[:variant]] if params[?"variant"]
        if action == "install_sputnik":
          ["backend", "bundle", "registry"].each |key|:
            arguments = arguments + ["--" + key, params[key]] if params[?key]
          {allow_native: "--allow-native", build_from_source: "--build-from-source", allow_native_large: "--allow-native-large"}.each |key, flag|:
            arguments = arguments + [flag] if params[?key]
        command(directory, @compiler, arguments, {SPUTNIK_PKG_HOME: home})
      update(project, id, "succeeded", "", result)
    rescue Exception |error|:
      update(project, id, "failed", error.message)

  def copy_gem_cache(root, destination, prefix):
    return null unless fs.exists?(root + "/" + prefix)
    fs.entries(root + "/" + prefix).each |path|:
      name = prefix + "/" + path.basename
      if fs.dir?(path): copy_gem_cache(root, destination, name)
      else:
        fs.mkdir_p(fs.Path(destination + "/" + name).parent)
        fs.atomic_write_bytes(destination + "/" + name, fs.read_bytes(path, limit: 16777216))

  def command(directory, program, arguments, env):
    checked = command_at(directory, program, arguments, env).capture(timeout: 900.0, check: false) with:
      stdout |stream|:
        fs.File.open(directory + "/stdout.log", :append, create: true) |file|:
          stream.each_chunk |chunk|: file.write_all!(chunk)
      stderr |stream|:
        fs.File.open(directory + "/stderr.log", :append, create: true) |file|:
          stream.each_chunk |chunk|: file.write_all!(chunk)
    raise IOError("dependency operation failed; see installation log") unless checked.success?
