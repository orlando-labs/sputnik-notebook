package notebook.core.dependencies

from notebook.core.common import fail, decode, identifier, command_at
from notebook.core.host import environment_log, package_home, package_link, package_adopt, package_unlink, package_reference?

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
      item = {name: lines[1], display_name: lines[1].split("/").last, version: lines[2], digest: lines[3], directory: directory.to_str}
      item[:variant] = lines[4] if lines[0] == "sputnik.package.index.v2" and lines.count >= 5
      item[:scope] = if fs.metadata(directory).symlink? then "shared" else "local"
      modules = lines[(if lines[0] == "sputnik.package.index.v2" then 5 else 4)..].filter: $it != ""
      item[:module_root] = modules.find |name|: modules.all? |other|: other == name or other.starts_with?(name + ".")
      result.push!(item)
    return null
  # fs.Path values have no implicit ordering; compare their textual paths.
  paths = fs.entries(directory).map: $it.to_str
  paths.sorted.each |name|:
    path = fs.Path(name)
    next if path.basename.starts_with?(".")
    metadata = fs.metadata(path)
    # Only core-managed links into the shared store are traversed.
    next unless metadata.dir? or (metadata.symlink? and package_reference?(name))
    scan_packages(path, result, depth + 1)

def matching_package(packages, metadata, artifact):
  packages.find |item|: item[:name] == metadata[:package_ref] and item[:version] == metadata[:version] and item[?:variant] == artifact[:variant] and item[:digest] == artifact[:sha256]

def runtime_grants(capabilities, native):
  grants = capabilities.map |request|:
    target = request[?:target] or ""
    flags = request[?:flags] or 0
    request[:name] + "=" + (if target == "" or flags % 2 == 1 then "*" else target)
  grants += ["ffi.call=*", "ffi.load=*"] if native
  grants.uniq.sorted

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
    fail(400, "unsupported package query") unless ["versions", "variants", "inspect"].include?(query)
    limit = if query == "inspect" then 4096 else 257
    fail(400, "invalid package source") unless Str === source and source.bytes.count > 0 and source.bytes.count <= limit and not source.starts_with?("-") and not source.contains?("\u{0}")
    fail(400, "package inspection requires an absolute local path") if query == "inspect" and not fs.Path(source).absolute?
    arguments = ["pkg", query, source]
    arguments += ["--json"] unless query == "inspect"
    arguments = arguments + ["--check-host"] if query == "variants"
    checked = system.command(@compiler, *arguments).capture(timeout: if query == "inspect" then 120.0 else 20.0, check: false)
    unless checked.success?:
      message = checked.stderr.to_str.trim
      if query == "versions" and message.contains?("HTTP 404 NOT_FOUND for "):
        message = "Package '" + source + "' was not found in the registry."
      fail(422, message)
    metadata = decode(checked.stdout.to_str)
    if query == "inspect":
      native = (metadata[?:native_adapter] or "none") != "none" or not (metadata[?:native_extensions] or []).empty?
      return {runtime_grants: runtime_grants(metadata[?:capabilities] or [], native), install_options: metadata[?:install_options] or []}
    shared = installed_packages(package_home())
    if query == "variants":
      metadata[:artifacts].each |artifact|:
        artifact[:shared_installed] = matching_package(shared, metadata, artifact) != null
        native = artifact[?:kind] != "native" and (artifact[?:native_mode] or "none") != "none"
        artifact[:runtime_grants] = runtime_grants(metadata[?:capabilities] or [], native)
    else:
      metadata[:versions].each |release|:
        release[:shared_installed] = shared.any? |item|: item[:name] == metadata[:package_ref] and item[:version] == release[:version]
    metadata

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
    settings = params[?:install_options] or {}
    fail(400, "invalid package install options") unless Map === settings and settings.count <= 64
    settings.each |name, value|:
      fail(400, "invalid package install option") unless Str === name and name.bytes.count <= 64 and name.contains_only?("abcdefghijklmnopqrstuvwxyz0123456789-") and Str === value and value.bytes.count <= 4096 and not value.contains?("\u{0}")
    scope = params[?:scope]
    fail(400, "invalid package installation scope") unless scope == null or ["shared", "local"].include?(scope)
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
    staging = null
    try:
      update(project, id, "running")
      fs.mkdir_p(directory)
      progress(directory, "Waiting for workers to stop…")
      # Removal may unlink a loaded native library. Confirm worker termination first.
      loop:
        pending = @core.synchronize: @core.owners_pending?(project)
        if not pending: break
        task.sleep(0.05)
      home = @core.package_directory(project)
      result = {}
      if action == "lock_ruby":
        progress(directory, "Resolving Ruby dependencies…")
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
          progress(directory, "Inspecting package archive…")
          # A chosen archive already identifies its build. Read its own selectors
          # instead of imposing the registry installer's CPU/none defaults.
          inspected = system.command(@compiler, "pkg", "inspect", source).capture(timeout: 120.0, check: false)
          raise IOError(inspected.stderr.to_str) unless inspected.success?
          metadata = decode(inspected.stdout.to_str)
          params[:variant] = metadata[:variant] unless params[?:variant]
          params[:bundle] = metadata[:bundle] unless params[?:bundle]
          backend = metadata[:target][:compute_backend]
          params[:backend] = backend if not params[?:backend] and ["cpu", "cuda", "mps", "rocm"].include?(backend)
        if action == "remove_sputnik":
          progress(directory, "Removing package…")
          removed = installed_packages(home).filter |item|: item[:name] == source and (version == "" or item[:version] == version) and (not params[?:variant] or item[?:variant] == params[:variant])
          fail(422, "Package is not installed in this notebook.") if removed.empty?
          removed.each |item|:
            relative = item[:name] + "/" + item[:version] + (if item[?:variant] then "/" + item[:variant] else "")
            unless package_unlink(home, relative):
              args = ["pkg", "uninstall", item[:name], "--version", item[:version]]
              args += ["--variant", item[:variant]] if item[?:variant]
              command(directory, @compiler, args, {SPUTNIK_PKG_HOME: home})
          update_imports(home, source, null, null) unless installed_packages(home).any?: $it[:name] == source
          progress(directory, "Package removed.")
          update(project, id, "succeeded")
          return
        arguments = ["pkg", "install", source]
        (params[?:install_options] or {}).each |name, value|:
          arguments += ["--option", name + "=" + value]
        arguments = arguments + ["--version", version] if version != ""
        arguments = arguments + ["--variant", params[:variant]] if params[?"variant"]
        if action == "install_sputnik":
          ["backend", "bundle", "registry"].each |key|:
            arguments = arguments + ["--" + key, params[key]] if params[?key]
          {allow_native: "--allow-native", build_from_source: "--build-from-source", allow_native_large: "--allow-native-large"}.each |key, flag|:
            arguments = arguments + [flag] if params[?key]
        shared = package_home()
        local = params[?:scope] == "local"
        staging = directory + "/packages" if local
        destination = staging or shared
        fs.mkdir_p(destination)
        # One store lock spans verification, preparation and publishing references.
        # Other books keep their workers and references while this book changes.
        lock_home = if local then fs.Path(directory).parent.to_str else shared
        progress(directory, "Waiting for package storage…")
        fs.lock(lock_home + "/.notebook-install.lock", nonblock: false) |lease|:
          progress(directory, "Resolving package version and build…")
          metadata = null
          cached = null
          unless params[?:local_source] or params[?:registry]:
            metadata = catalog({query: "variants", source: source + (if version == "" then "" else "@" + version)}) if version != ""
            if metadata:
              artifact = metadata[:artifacts].find: $it[:variant] == params[?:variant]
              if artifact:
                fail(422, "This package build is incompatible with the execution server.") unless artifact[:host_selection][:compatible]
                fail(422, "This package requires explicit permission to install native code.") if artifact[:host_selection][:allow_native] and not params[?:allow_native]
                if not local and (params[?:install_options] or {}).empty?:
                  cached = matching_package(installed_packages(shared), metadata, artifact)
                unless cached:
                  fail(422, "This package requires explicit permission to build native code.") if artifact[:host_selection][:build_from_source] and not params[?:build_from_source]
                  fail(422, "This package exceeds 64 MiB and requires explicit size permission.") if artifact[:size] > 67108864 and not params[?:allow_native_large]
          selected = []
          if cached:
            progress(directory, "Verifying shared package…")
            archive = fs.entries(cached[:directory]).find: $it.to_str.ends_with?(".sputnikpkg")
            fail(422, "The shared package archive is missing.") unless archive
            command(directory, @compiler, ["pkg", "verify", archive.to_str], {})
            verified = decode(fs.read_text(directory + "/stdout.log", limit: 16777216))
            fail(422, "Shared package cache failed verification. Repair the shared installation before retrying.") unless verified[:sha256] == cached[:digest] and verified[:name] == cached[:name] and verified[:version] == cached[:version] and verified[:variant] == cached[?:variant]
            selected = [cached]
          else:
            progress(directory, "Installing package and dependencies…")
            command(directory, @compiler, arguments, {SPUTNIK_PKG_HOME: destination, SPUTNIK_PKG_PROGRESS: "1"})
            names = fs.read_text(directory + "/stdout.log").split("\n").filter: $it.starts_with?("Installed ") or $it.starts_with?("Already installed ")
            identities = names.map |line|:
              prefix = if line.starts_with?("Installed ") then "Installed " else "Already installed "
              line.split(" in ")[0].split(prefix)[1].split(" (")[0] + "\t" + line.split("/").last
            selected = installed_packages(destination).filter |item|: identities.include?(item[:name] + "@" + item[:version] + "\t" + (item[?:variant] or item[:version]))
          fail(422, "The installer did not publish a package.") if selected.empty?
          progress(directory, "Making package available to this notebook…")
          selected.each |item|:
            relative = item[:name] + "/" + item[:version] + (if item[?:variant] then "/" + item[:variant] else "")
            if local: package_adopt(destination, home, relative)
            else: package_link(item[:directory], home, relative)
          unless params[?:local_source]:
            root = null
            if metadata: root = selected.find: $it[:name] == metadata[:package_ref]
            else: root = selected.find |item|: item[:name] == source or item[:name].split("/").last == source
            if root and root[?:module_root]:
              alias = import_alias(source, root)
              update_imports(home, root[:name], alias, root[:module_root]) if alias
      @core.remove_tree(staging) if staging and fs.exists?(staging)
      progress(directory, "Dependency operation completed.")
      update(project, id, "succeeded", "", result)
    rescue Exception |error|:
      if staging:
        try: @core.remove_tree(staging) if fs.exists?(staging)
        rescue Exception: null
      update(project, id, "failed", error.message)

  def import_alias(source, root):
    if source.contains?("/"):
      current = null
      try:
        current = catalog({query: "versions", source: source.split("/").last})
      rescue Exception: current = null
      return null unless current and current[:package_ref] == root[:name]
    root[:module_root].split(".")[1..].join(".")

  def update_imports(home, name, alias, module_root):
    path = home + "/imports.index"
    lines = if fs.exists?(path) then fs.read_text(path).split("\n").filter |line|: line != "" and line.split("\t")[0] != name and (not alias or line.split("\t")[1] != alias) else []
    if alias:
      lines.push!(name + "\t" + alias + "\t" + module_root)
    fs.atomic_write_text(path, lines.join("\n") + "\n")

  def copy_gem_cache(root, destination, prefix):
    return null unless fs.exists?(root + "/" + prefix)
    fs.entries(root + "/" + prefix).each |path|:
      name = prefix + "/" + path.basename
      if fs.dir?(path): copy_gem_cache(root, destination, name)
      else:
        fs.mkdir_p(fs.Path(destination + "/" + name).parent)
        fs.atomic_write_bytes(destination + "/" + name, fs.read_bytes(path, limit: 16777216))

  def progress(directory, message):
    fs.File.open(directory + "/stderr.log", :append, create: true) |file|:
      file.write_all!((message + "\n").bytes)

  def command(directory, program, arguments, env):
    checked = command_at(directory, program, arguments, env).capture(timeout: 900.0, check: false) with:
      stdout |stream|:
        fs.File.open(directory + "/stdout.log", :append, create: true) |file|:
          stream.each_chunk |chunk|: file.write_all!(chunk)
      stderr |stream|:
        fs.File.open(directory + "/stderr.log", :append, create: true) |file|:
          stream.each_chunk |chunk|: file.write_all!(chunk)
    raise IOError("dependency operation failed; see installation log") unless checked.success?
