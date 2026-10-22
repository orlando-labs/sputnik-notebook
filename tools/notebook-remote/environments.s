package notebook.remote.environments

from notebook.remote.common import fail, decode, digest, identifier, command_at
from notebook.remote.host import environment as inspect_environment, environment_candidates, remove_environment_candidate, environment_log

export Environments

# The agent owns installation tasks. Connections and worker processes are clients
# of ready, persistent generations, and never mutate an installed generation.
class Environments:
  def init(@core, @python, @ruby):
    @facts = {}
    @core.sql("CREATE TABLE IF NOT EXISTS foreign_environments(project TEXT,id TEXT,spec TEXT,state TEXT,directory TEXT,created INTEGER,error TEXT,PRIMARY KEY(project,id))")
    @core.sql("CREATE TABLE IF NOT EXISTS foreign_environment_attempts(project TEXT,id TEXT,directory TEXT PRIMARY KEY,state TEXT)")
    @core.sql("CREATE TABLE IF NOT EXISTS orphan_projects(id TEXT PRIMARY KEY,first_seen INTEGER,identity TEXT)")
    @core.sql("UPDATE foreign_environments SET state='interrupted',error='agent restarted during installation; explicit retry required' WHERE state IN ('queued','installing')")
    @core.sql("UPDATE foreign_environment_attempts SET state='interrupted' WHERE state IN ('queued','installing')")
    fs.mkdir_p(@core.root + "/projects")

  def facts(kind):
    return @facts[kind] if @facts.has_key?(kind)
    executable = if kind == "python" then @python else @ruby
    code = if kind == "python" then "import json,sys,sysconfig; print(json.dumps([sys.executable,sys.version,sys.platform,sysconfig.get_config_var('SOABI')]))" else "require 'json'; require 'rbconfig'; puts JSON.generate([RbConfig.ruby,RUBY_DESCRIPTION,RUBY_PLATFORM,RbConfig::CONFIG['ruby_version']])"
    arguments = if kind == "python" then ["-c", code] else ["-e", code]
    checked = system.command(executable, *arguments).capture(timeout: 15.0, check: false)
    fail(422, "cannot inspect " + kind + ": " + checked.stderr.to_str) unless checked.success?
    @facts[kind] = decode(checked.stdout.to_str)
    @facts[kind]

  def spec(revision):
    files = {}
    directory = revision[:directory]
    requirements = if fs.exists?(directory + "/requirements.lock") then "requirements.lock" else "requirements.txt"
    if fs.exists?(directory + "/" + requirements):
      files[requirements] = fs.read_text(directory + "/" + requirements)
    if fs.exists?(directory + "/Gemfile"):
      fail(422, "remote Ruby environments require Gemfile.lock") unless fs.exists?(directory + "/Gemfile.lock")
      files["Gemfile"] = fs.read_text(directory + "/Gemfile")
      files["Gemfile.lock"] = fs.read_text(directory + "/Gemfile.lock")
      files[".bundle/config"] = fs.read_text(directory + "/.bundle/config") if fs.exists?(directory + "/.bundle/config")
    return null if files.empty?
    python = if files.has_key?(requirements) then facts("python") else null
    ruby = if files.has_key?("Gemfile") then facts("ruby") else null
    artifacts = {}
    ["wheels", "vendor/cache"].each |prefix|:
      collect_artifacts(directory, prefix, artifacts) if fs.exists?(directory + "/" + prefix) and fs.dir?(directory + "/" + prefix)
    {format: 1, python: python, ruby: ruby, requirements: requirements, files: files, artifacts: artifacts}

  def collect_artifacts(root, prefix, artifacts):
    fs.entries(root + "/" + prefix).each |path|:
      name = prefix + "/" + path.basename
      if fs.dir?(path): collect_artifacts(root, name, artifacts)
      else: artifacts[name] = Base64.encode(fs.read_bytes(path, limit: 16777216))

  def record(project, id): @core.row("SELECT * FROM foreign_environments WHERE project=? AND id=?", [project, id])

  def ensure_project(project):
    directory = @core.root + "/projects/" + project
    fs.mkdir_p(directory)
    unless fs.exists?(directory + "/.sputnik-owner"):
      fs.atomic_write_text(directory + "/.sputnik-owner", "sputnik-notebook-project.v1\n" + project + "\n" + SecureRandom.hex(16) + "\n")
    fs.sync(directory)
    fs.sync(@core.root + "/projects")
    directory

  def request(project, revision, retry: false):
    description = spec(revision)
    return decode(inspect_environment(revision[:directory])).merge({state: "ready", id: null}) unless description
    id = digest(description)
    old = record(project, id)
    return old.merge({fingerprint: id}) if old and (not retry or ["ready", "queued", "installing"].include?(old[:state]))
    project_directory = @core.root + "/projects/" + project
    directory = project_directory + "/environments/" + id + "/" + SecureRandom.hex(16)
    @core.transaction:
      @core.sql("INSERT OR REPLACE INTO foreign_environments VALUES(?,?,?,?,?,?,?)", [project, id, Json.generate(description), "queued", directory, Time.now.unix_seconds, ""])
      @core.sql("INSERT INTO foreign_environment_attempts VALUES(?,?,?,?)", [project, id, directory, "queued"])
    # The recorded intent precedes filesystem creation, including the ownership marker.
    ensure_project(project)
    task.async: install(project, id, directory, description)
    record(project, id).merge({fingerprint: id})

  def update(project, id, directory, state, error = ""):
    @core.synchronize:
      @core.sql("UPDATE foreign_environments SET state=?,error=? WHERE project=? AND id=? AND directory=?", [state, error, project, id, directory])
      @core.sql("UPDATE foreign_environment_attempts SET state=? WHERE directory=?", [state, directory])
      @core.event(project, {type: "foreign_environment", environment_id: id, state: state, error: error})

  def command(directory, program, arguments, env = {}):
    # Stream both pipes into separate logs without buffering installer output.
    checked = command_at(directory, program, arguments, env).capture(timeout: 900.0, check: false) with:
      stdout |stream|:
        fs.File.open(directory + "/stdout.log", :append, create: true) |file|:
          stream.each_chunk |chunk|: file.write_all!(chunk)
      stderr |stream|:
        fs.File.open(directory + "/stderr.log", :append, create: true) |file|:
          stream.each_chunk |chunk|: file.write_all!(chunk)
    raise IOError("environment installer failed; see stdout.log and stderr.log") unless checked.success?

  def install(project, id, directory, description):
    try:
      update(project, id, directory, "installing")
      fs.mkdir_p(directory)
      fs.atomic_write_text(directory + "/spec.json", Json.generate(description))
      description[:files].each |name, contents|:
        path = fs.Path(directory + "/" + name)
        fs.mkdir_p(path.parent)
        fs.atomic_write_text(path, contents)
      description[:artifacts].each |name, contents|:
        path = fs.Path(directory + "/" + name)
        fs.mkdir_p(path.parent)
        fs.atomic_write_bytes(path, Base64.decode(contents))
      if description[:python]:
        command(directory, description[:python][0], ["-m", "venv", directory + "/.venv"])
        arguments = ["-m", "pip", "install", "--disable-pip-version-check", "--no-input"]
        arguments.push!("--require-hashes") if description[:requirements] == "requirements.lock"
        arguments.push!("-r")
        arguments.push!(directory + "/" + description[:requirements])
        command(directory, directory + "/.venv/bin/python", arguments)
        command(directory, directory + "/.venv/bin/python", ["-m", "pip", "check"])
        resolved = system.command(directory + "/.venv/bin/python", "-m", "pip", "freeze", "--all").output(timeout: 30.0)
        fs.atomic_write_text(directory + "/resolved-python.txt", resolved)
      if description[:ruby]:
        env = {BUNDLE_GEMFILE: directory + "/Gemfile", BUNDLE_APP_CONFIG: directory + "/.bundle", BUNDLE_FROZEN: "true"}
        command(directory, description[:ruby][0], ["-S", "bundle", "config", "set", "--local", "path", directory + "/vendor/bundle"], env)
        command(directory, description[:ruby][0], ["-S", "bundle", "install"], env)
        command(directory, description[:ruby][0], ["-S", "bundle", "check"], env)
        resolved = system.command(description[:ruby][0], "-S", "bundle", "list", env: env).output(timeout: 30.0)
        fs.atomic_write_text(directory + "/resolved-ruby.txt", resolved)
      # A venv contains absolute paths; it is created at its final location.
      fs.atomic_write_text(directory + "/ready.json", Json.generate({environment_id: id, configuration: decode(inspect_environment(directory))}))
      fs.sync(directory)
      update(project, id, directory, "ready")
    rescue Exception |error|:
      update(project, id, directory, "failed", error.message)

  def wait(project, id, directory, &stopped):
    return null unless id
    loop:
      return null if stopped()
      current = @core.synchronize: record(project, id)
      raise IOError("environment no longer exists") unless current
      raise IOError("environment installation attempt changed; explicit runtime restart required") unless current[:directory] == directory
      return null if current[:state] == "ready"
      raise IOError(current[:error]) if ["failed", "interrupted"].include?(current[:state])
      task.sleep(0.1)

  def list(project): @core.rows("SELECT * FROM foreign_environments WHERE project=? ORDER BY created,rowid", [project])

  def details(record):
    result = record.merge(decode(environment_log(record[:directory])))
    ["python", "ruby"].each |kind|:
      path = record[:directory] + "/resolved-" + kind + ".txt"
      result[kind + "_packages"] = if fs.exists?(path) then fs.read_text(path, limit: 1048576) else ""
    result

  def gc(age, dry_run: false):
    fail(400, "orphan age must be a nonnegative number of seconds") unless Int === age and age >= 0
    fail(400, "dry_run must be boolean") unless Bool === dry_run
    candidates = decode(environment_candidates(@core.root + "/projects"))
    now = Time.now.unix_seconds
    removed = []
    pending = []
    candidates.each |candidate|:
      id = candidate[:id]
      project = @core.row("SELECT state FROM projects WHERE id=?", [id])
      installing = @core.row("SELECT id FROM foreign_environment_attempts WHERE project=? AND state IN ('queued','installing','interrupted') LIMIT 1", [id])
      installing = installing or @core.row("SELECT id FROM foreign_environments WHERE project=? AND state IN ('queued','installing','interrupted') LIMIT 1", [id])
      if (project and project[:state] != "deleted") or @core.owners_pending?(id) or installing or @core.dependency_protected?(id):
        @core.sql("DELETE FROM orphan_projects WHERE id=?", [id])
      else:
        old = @core.row("SELECT identity FROM orphan_projects WHERE id=?", [id])
        @core.sql("DELETE FROM orphan_projects WHERE id=?", [id]) if old and old[:identity] != candidate[:identity]
        @core.sql("INSERT OR IGNORE INTO orphan_projects VALUES(?,?,?)", [id, now, candidate[:identity]])
        seen = @core.row("SELECT first_seen FROM orphan_projects WHERE id=?", [id])[:first_seen]
        if now - seen >= age:
          removed.push!(id)
          unless dry_run:
            fail(409, "orphan directory changed during collection") unless remove_environment_candidate(@core.root + "/projects", id, candidate[:identity])
            @core.sql("DELETE FROM orphan_projects WHERE id=?", [id])
            @core.sql("DELETE FROM foreign_environments WHERE project=?", [id])
            @core.sql("DELETE FROM foreign_environment_attempts WHERE project=?", [id])
        else: pending.push!(id)
    {removed: removed, pending: pending, dry_run: dry_run, minimum_age_seconds: age}
