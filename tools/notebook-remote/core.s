package notebook.remote.core

import sqlite3
from notebook.remote.common import fail, identifier, decode, digest, canonical, terminal?, project_files
from notebook.remote.host import Worker, pid, environment as inspect_environment, environment_log

from notebook.remote.environments import Environments
from notebook.remote.dependencies import Dependencies, installed_packages
from notebook.remote.services import Services

export Core

class Runtime:
  attr id
  attr epoch
  attr project
  attr sheet
  attr environment
  attr directory
  attr active
  attr worker
  attr dead
  attr retiring
  attr forced
  attr stopped
  attr grants
  attr foreign_environment
  attr environment_directory
  attr managed_environment
  attr invocation
  attr controller
  attr revision

  def init(@core, @project, @sheet, @environment, @grants, @environment_directory, @foreign_environment, @managed_environment, controller: null):
    @invocation = null
    @controller = controller or @sheet
    @revision = null
    @id = SecureRandom.hex(16)
    @epoch = SecureRandom.hex(16)
    @directory = @core.root + "/runtimes/" + @id
    fs.mkdir_p(@directory + "/work")
    @worker = null
    @active = null
    @request = 0
    @dead = false
    @retiring = false
    @forced = false
    @stopped = false
    @closing = false

  def retire!(): @retiring = true
  def release!(): @active = null
  def set_invocation(source): @invocation = source

  def prepare(run):
    @active = run
    @request = 0
    @forced = false
    @stopped = false

  def stop(force: false):
    @stopped = true
    @forced = @forced or force
    @worker.stop!(@request, @forced) if @worker

  def close!():
    return null if @closing or @dead
    @closing = true
    stop(force: true)
    unless @active:
      task.async:
        terminate()
        @core.finished(self, "force-stopped", error: "worker termination confirmed")

  def terminate():
    if @worker:
      @worker.close!()
      @worker.destroy!()
      @worker = null
    @dead = true

  def receive_result(execution: false):
    loop:
      event = @worker.poll()
      if event:
        kind = event[0]
        if kind == "error": raise IOError(event[2])
        if kind == "started" or kind == "draining":
          @core.phase(self, if kind == "started" then "running" else "draining") if execution
        elif kind == "live":
          @core.live(self, event[2], event[3]) if execution
        elif kind == "result":
          return event

  def execute(run, revision):
    try:
      @revision = run[:revision]
      if @forced:
        terminate()
        @core.finished(self, "force-stopped", error: "cancelled before worker start")
        return
      @core.await_environment(@project, @managed_environment, @environment_directory): @stopped
      if @stopped:
        terminate() if @forced
        @core.finished(self, if @forced then "force-stopped" else "cancelled", error: "cancelled while preparing environment")
        return
      unless @worker:
        @worker = Worker(@core.worker_path, @directory + "/work", @grants, @environment_directory)
        trusted = (@grants.include?("ffi.call") or @grants.include?("ffi.call=*")) and (@grants.include?("ffi.load") or @grants.include?("ffi.load=*"))
        @request = @worker.send(2, [revision[:directory], @controller, (if trusted then "1" else "0"), @core.package_directory(@project)])
        @worker.stop!(@request, true) if @forced
        receive_result()
      @request = @worker.send(14, [run[:execution_document], "0"])
      @worker.stop!(@request, true) if @forced
      receive_result()
      if @stopped:
        terminate() if @forced
        @core.finished(self, if @forced then "force-stopped" else "cancelled", error: "cancelled before dispatch")
        return
      @request = case run[:action]:
        when "inputs": @worker.send(18, [])
        when "watch": @worker.send(21, [])
        else: @worker.send(4, [run[:cell_id], (if run[:action] == "run_all" then "1" else "0")])
      @worker.stop!(@request, @forced) if @stopped
      result = receive_result(execution: true)
      if @forced:
        terminate()
        @core.finished(self, "force-stopped", error: "worker termination confirmed")
      else:
        unless @core.complete(self, decode(result[2]), result[3]):
          terminate()
          @core.finished(self, "force-stopped", error: "worker termination confirmed before publication")
    rescue Exception |error|:
      print("remote runtime interrupted: " + error.message)
      terminate()
      @core.finished(self, if @forced then "force-stopped" else "interrupted", error: error.message)

class Core:
  attr root
  attr worker_path

  def init(@root, @worker_path, python: "python3", ruby: "ruby", compiler: "sputnik", package_directory: null):
    @ruby_executable = ruby
    @package_directory_override = package_directory
    created = []
    parent = fs.Path(@root)
    until fs.exists?(parent):
      created.push!(parent)
      parent = parent.parent
    fs.mkdir_p(@root)
    system.command("/bin/chmod", "700", @root).run()
    @lease = fs.lock(@root + "/agent.lock", nonblock: true)
    ["revisions", "runtimes", "runs"].each: fs.mkdir_p(@root + "/" + $it)
    unless fs.exists?(@root + "/token"):
      fs.atomic_write_text(@root + "/token", SecureRandom.hex(32) + "\n")
    @mutex = Mutex.new()
    @runtimes = {}
    @owned = {}
    @db = sqlite3.open(@root + "/metadata.sqlite", busy_timeout: 5.0)
    @db.exec("""
      PRAGMA journal_mode=WAL;
      PRAGMA synchronous=FULL;
      CREATE TABLE IF NOT EXISTS projects(id TEXT PRIMARY KEY,head TEXT,state TEXT NOT NULL);
      CREATE TABLE IF NOT EXISTS revisions(id TEXT PRIMARY KEY,project TEXT,directory TEXT,document TEXT,environment TEXT);
      CREATE TABLE IF NOT EXISTS runs(id TEXT PRIMARY KEY,project TEXT,revision TEXT,sheet_id TEXT,cell_id TEXT,action TEXT,
        runtime_id TEXT,epoch TEXT,state TEXT,error TEXT,result_json TEXT,live_json TEXT,presentation TEXT);
      CREATE TABLE IF NOT EXISTS receipts(project TEXT,command TEXT,digest TEXT,response TEXT,PRIMARY KEY(project,command));
      CREATE TABLE IF NOT EXISTS events(seq INTEGER PRIMARY KEY AUTOINCREMENT,project TEXT,payload TEXT);
      CREATE TABLE IF NOT EXISTS tombstones(project TEXT,kind TEXT,id TEXT,PRIMARY KEY(project,kind,id));
      CREATE TABLE IF NOT EXISTS runtime_records(id TEXT PRIMARY KEY,project TEXT,sheet_id TEXT,epoch TEXT,environment TEXT,state TEXT);
      CREATE TABLE IF NOT EXISTS cell_inputs(project TEXT PRIMARY KEY,version TEXT NOT NULL,values_json TEXT NOT NULL);
      CREATE TABLE IF NOT EXISTS run_targets(run TEXT PRIMARY KEY,board TEXT,component TEXT,controller TEXT);
      CREATE TABLE IF NOT EXISTS run_inputs(run TEXT PRIMARY KEY,version TEXT NOT NULL,document TEXT NOT NULL);
      CREATE TABLE IF NOT EXISTS worker_environments(project TEXT,sheet TEXT,directory TEXT NOT NULL,PRIMARY KEY(project,sheet));
      CREATE TABLE IF NOT EXISTS worker_settings(project TEXT,sheet TEXT,grants TEXT NOT NULL,PRIMARY KEY(project,sheet));
      CREATE TABLE IF NOT EXISTS dependency_resets(project TEXT,epoch TEXT,PRIMARY KEY(project,epoch));
      CREATE INDEX IF NOT EXISTS runs_registry ON runs(project,id,revision,sheet_id,cell_id,action,runtime_id,epoch,state,error,presentation);
      CREATE INDEX IF NOT EXISTS revisions_environment ON revisions(id,environment);
    """)
    @db.transaction:
      @db.query("SELECT * FROM runtime_records WHERE state NOT IN ('terminated','interrupted')").each |row|:
        sql("UPDATE runtime_records SET state='interrupted' WHERE id=?", [row[:id]])
        event(row[:project], {type: "runtime", runtime_id: row[:id], state: "interrupted"})
      @db.query("SELECT * FROM runs WHERE state NOT IN ('succeeded','failed','cancelled','force-stopped','interrupted')").each |row|:
        sql("UPDATE runs SET state='interrupted',error='execution agent restarted; code was not replayed' WHERE id=?", [row[:id]])
        event(row[:project], {type: "run", run_id: row[:id], state: "interrupted"})
    @environments = Environments(self, python, ruby)
    @dependencies = Dependencies(self, compiler)
    @services = Services(self)
    ["revisions", "runtimes", "runs"].each: fs.sync(@root + "/" + $it)
    fs.sync(@root)
    created.each: fs.sync($it.parent)

  def synchronize(&block): @mutex.synchronize: block()
  def transaction(&block): @db.transaction(mode: :immediate): block()
  def ruby_executable(): @ruby_executable
  def package_directory(project): @package_directory_override or (@root + "/projects/" + project + "/packages")
  def ensure_environment_project(project): @environments.ensure_project(project)
  def dependency_protected?(project): @dependencies.protected?(project)
  def retire_dependency_workers(project):
    owned = @owned.values.filter: $it.project == project and not $it.dead
    fail(409, "stop active runs before changing dependencies") if owned.any?: $it.active != null
    @services.pause_project(project)
    owned.each |runtime|:
      sql("INSERT OR IGNORE INTO dependency_resets VALUES(?,?)", [project, runtime.epoch])
      sql("UPDATE runtime_records SET state='terminating' WHERE id=?", [runtime.id])
      runtime.close!()
      @runtimes.delete!(key(project, runtime.sheet))
  def await_environment(project, id, directory, &stopped): @environments.wait(project, id, directory, &stopped)
  def schedule_gc(interval, age):
    return null if interval == 0
    task.async:
      loop:
        task.sleep(interval.to_float)
        try:
          @mutex.synchronize: @environments.gc(age)
        rescue Exception |error|:
          print("orphan collection failed: " + error.message)

  def sql(text, values = []): @db.execute(text, params: values)
  def row(text, values = []): @db.query_one(text, params: values)
  def rows(text, values = []): @db.query(text, params: values)
  def key(project, sheet): project + ":" + sheet
  def owners_pending?(project):
    row("SELECT id FROM runtime_records WHERE project=? AND state NOT IN ('terminated','interrupted') LIMIT 1", [project]) != null
  def event(project, value): sql("INSERT INTO events(project,payload) VALUES(?,?)", [project, Json.generate(value)])
  def remember(project, receipt, result):
    sql("INSERT INTO receipts VALUES(?,?,?,?)", [project, receipt[0], receipt[1], Json.generate(result)])

  def receipt(project, params, method):
    command = identifier(params[?:command_id])
    hash = digest({method: method, params: params})
    found = row("SELECT * FROM receipts WHERE project=? AND command=?", [project, command])
    if found:
      fail(409, "command_id already used with different content") unless found[:digest] == hash
    [command, hash, (if found then decode(found[:response]) else null)]

  def project(id):
    found = row("SELECT * FROM projects WHERE id=?", [id])
    fail(404, "project not found") unless found
    found
  def revision(id):
    found = row("SELECT * FROM revisions WHERE id=?", [id])
    fail(404, "revision not found") unless found
    found
  def run(id):
    found = row("SELECT * FROM runs WHERE id=?", [id])
    fail(404, "run not found") unless found
    result = {}
    found.each |k, v|:
      if k == "result_json" or k == "live_json":
        result[if k == "result_json" then "result" else "live"] = if v then decode(v) else null
      else: result[k] = v
    target = row("SELECT board,component,controller FROM run_targets WHERE run=?", [id])
    result = result.merge(target) if target
    inputs = row("SELECT version,document FROM run_inputs WHERE run=?", [id])
    result[:input_version] = if inputs then inputs[:version] else null
    result[:execution_document] = if inputs then inputs[:document] else null
    path = @root + "/runs/" + id + ".live.bin"
    result[:live_presentation] = if fs.exists?(path) then path else null
    result
  def cell_inputs(id):
    state = row("SELECT * FROM cell_inputs WHERE project=?", [id])
    {version: (if state then state[:version] else "0"), values: (if state then decode(state[:values_json]) else {})}

  def resolve_inputs(revision, previous, cell = null, values = null):
    parsed = decode(revision[:document])
    local = (parsed[?:sheets] or []).any? |sheet|: (sheet[?:cells] or []).any? |c|: c[?:cell_ui] != null
    return {document: revision[:document], values: {}} unless local or cell or not previous.empty? or not (parsed[?:inputs] or []).empty?
    prefix = @root + "/cell-inputs-" + SecureRandom.hex(16)
    state = prefix + ".state.json"
    edits = prefix + ".edits.json"
    try:
      fs.atomic_write_text(state, Json.generate(previous))
      checked = null
      if cell:
        fs.atomic_write_text(edits, Json.generate(values))
        checked = system.command(@worker_path, "--cell-inputs", revision[:directory] + "/project.json", state, cell, edits).capture(timeout: 15.0, check: false)
      else:
        checked = system.command(@worker_path, "--cell-inputs", revision[:directory] + "/project.json", state).capture(timeout: 15.0, check: false)
      fail(422, checked.stderr.to_str) unless checked.success?
      decode(checked.stdout.to_str)
    ensure:
      fs.remove(state) if fs.exists?(state)
      fs.remove(edits) if fs.exists?(edits)

  def store_inputs(id, state):
    sql("INSERT OR REPLACE INTO cell_inputs VALUES(?,?,?)", [id, state[:version], Json.generate(state[:values])])

  def set_cell_inputs(params):
    id = identifier(params[?:project_id])
    command = receipt(id, params, "cell.inputs")
    return command[2] if command[2]
    current = project(id)
    fail(409, "project revision conflict") unless current[:state] == "active" and params[?:revision] == current[:head]
    previous = cell_inputs(id)
    fail(409, "cell input version changed; reload inputs") unless params[?:base_version] == previous[:version]
    cell = identifier(params[?:cell_id])
    revision = revision(current[:head])
    document = decode(revision[:document])
    sheet = document[:sheets].find |s|: s[:cells].any? |c|: c[:id] == cell and c[:kind] == "code"
    fail(404, "cell not found") unless sheet
    values = params[?:values]
    fail(400, "cell inputs require at most 128 scalar JSON strings") unless Map === values and values.count <= 128 and values.values.all? |value|: Str === value
    runtime = @runtimes[?key(id, sheet[:id])]
    fail(409, "runtime busy") if runtime and runtime.active
    resolved = resolve_inputs(revision, previous[:values], cell, values)
    changed = digest(resolved[:values]) != digest(previous[:values])
    next = {version: (if changed then SecureRandom.hex(16) else previous[:version]), values: resolved[:values]}
    if changed and runtime:
      request = params.merge({sheet_id: sheet[:id], action: "inputs"})
      return start_run(request, input_state: next, input_document: resolved[:document], input_command: command)
    response = next
    @db.transaction(mode: :immediate):
      store_inputs(id, next)
      remember(id, command, response)
    response

  def set_project_inputs(params):
    id = identifier(params[?:project_id])
    command = receipt(id, params, "project.inputs")
    return command[2] if command[2]
    current = project(id)
    fail(409, "project revision conflict") unless current[:state] == "active" and params[?:revision] == current[:head]
    previous = cell_inputs(id)
    fail(409, "input version changed; reload inputs") unless params[?:base_version] == previous[:version]
    values = params[?:values]
    fail(400, "inputs require at most 128 scalar JSON strings") unless Map === values and values.count <= 128 and values.values.all? |v|: Str === v
    revision = revision(current[:head])
    resolved = resolve_inputs(revision, previous[:values], "project", values)
    changed = digest(resolved[:values]) != digest(previous[:values])
    next = {version: (if changed then SecureRandom.hex(16) else previous[:version]), values: resolved[:values]}
    plans = []
    if changed:
      @runtimes.values.filter |r|: r.project == id and r.controller == r.sheet .each |runtime|:
        sheet = decode(revision[:document])[:sheets].find: $it[:id] == runtime.sheet
        cell = if sheet then sheet[:cells].find: $it[:kind] == "code" else null
        next unless cell
        plans.push!(prepare_run({project_id: id, revision: current[:head], sheet_id: runtime.sheet, cell_id: cell[:id], action: "inputs"}, input_state: next, input_document: resolved[:document], internal: true))
    response = next.merge({run_ids: plans.map: $it[:id]})
    @db.transaction(mode: :immediate):
      store_inputs(id, next)
      plans.each: persist_run($it)
      remember(id, command, response)
    plans.each: launch_run($it)
    response

  def schedule_work():
    task.async:
      loop:
        task.sleep(100)
        try:
          @mutex.synchronize: pump_work()
        rescue Exception |error|:
          print("server work deferred: " + error.message)

  def pump_work():
    @services.tick()
    @runtimes.values.filter |r|: not r.active and not r.dead and not r.retiring and r.worker and r.controller == r.sheet .each |runtime|:
      current = project(runtime.project)
      next unless current[:state] == "active" and current[:head] == runtime.revision
      document = decode(revision(current[:head])[:document])
      sheet = document[:sheets].find: $it[:id] == runtime.sheet
      next unless sheet and sheet[:cells].any? |c|: c[:kind] == "code" and c[:mode] == "watch"
      ready = false
      try: ready = runtime.worker.activity?()
      rescue Exception |error|:
        runtime.close!()
        print("idle Watch interrupted: " + error.message)
      next unless ready
      cell = sheet[:cells].find: $it[:kind] == "code"
      # Poll only observes readiness. A storage conflict leaves the live heap
      # and pending notifications intact for the next pass.
      start_run({project_id: runtime.project, command_id: SecureRandom.hex(16), revision: current[:head], sheet_id: runtime.sheet, cell_id: cell[:id], action: "watch"}, internal: true)

  def invocation_document(revision, document, board, component):
    path = @root + "/invocation-" + SecureRandom.hex(16) + ".json"
    try:
      fs.atomic_write_text(path, document, durable: false)
      checked = system.command(@worker_path, "--action-document", path, board, component).capture(timeout: 15.0, check: false)
      fail(422, checked.stderr.to_str) unless checked.success?
      decode(checked.stdout.to_str)
    ensure:
      fs.remove(path) if fs.exists?(path)

  def ids(document):
    result = []
    (document[?:sheets] or []).each |sheet|:
      result.push!(["sheet", sheet[:id]])
      (sheet[?:cells] or []).each: result.push!(["cell", $it[:id]])
    result

  def put_project(params):
    id = identifier(params[?:project_id])
    command = receipt(id, params, "project.put")
    return command[2] if command[2]
    existing = row("SELECT * FROM projects WHERE id=?", [id])
    if existing:
      fail(409, "project revision conflict or project deleted") unless existing[:state] == "active" and params[:base_revision] == existing[:head]
    else: fail(409, "new project requires null base_revision") unless params[:base_revision] == null
    document = params[?:document]
    fail(413, "document must be a JSON string of at most 7 MiB") unless Str === document and document.bytes.count <= 7340032
    parsed = decode(document)
    fail(400, "invalid project document") unless Map === parsed
    current = ids(parsed)
    rows("SELECT kind,id FROM tombstones WHERE project=?", [id]).each |removed|:
      fail(409, "deleted entity IDs cannot be reused") if current.include?([removed[:kind], removed[:id]])
    files = params[?:files] or {}
    fail(400, "invalid file manifest") unless Map === files and files.count <= 2048
    staged = @root + "/revisions/staging-" + SecureRandom.hex(16)
    fs.mkdir(staged)
    try:
      fs.atomic_write_text(staged + "/project.json", document)
      hashes = []
      total = 0
      files.keys.sorted.each |name|:
        parts = name.split("/")
        unsafe = name == "" or name.starts_with?("/") or name.contains?("\\") or name.contains?("\u{0}") or name == "project.json"
        unsafe = unsafe or parts.any? |p|: ["", ".", ".."].include?(p)
        fail(400, "unsafe project member path") if unsafe
        data = Base64.decode(files[name])
        total += data.count
        fail(413, "project file budget exceeded") if data.count > 16777216 or total > 67108864
        path = fs.Path(staged + "/" + name)
        fs.mkdir_p(path.parent)
        fs.atomic_write_bytes(path, data)
        hashes.push!([name, Digest.sha256(data).hex])
      checked = system.command(@worker_path, "--check-project", staged).capture(timeout: 15.0, check: false)
      fail(400, checked.stderr.to_str) unless checked.success?
      revision_id = Digest.sha256(Json.generate([id, document, hashes]).bytes).hex
      environment = Digest.sha256(Json.generate([parsed[?:modules] or [], parsed[?:auto_imports] or [], parsed[?:dependencies] or [], hashes]).bytes).hex
      directory = @root + "/revisions/" + revision_id
      if fs.exists?(directory): sync_tree(directory)
      else:
        sync_tree(staged)
        fs.rename(staged, directory)
      fs.atomic_write_text(directory + ".manifest.json", Json.generate(files.keys.sorted))
      fs.sync(@root + "/revisions")
      previous = if existing then decode(revision(existing[:head])[:document]) else {sheets: []}
      previous_inputs = cell_inputs(id)
      resolved = resolve_inputs({directory: directory, document: document}, previous_inputs[:values])
      input_state = {version: (if digest(resolved[:values]) == digest(previous_inputs[:values]) then previous_inputs[:version] else SecureRandom.hex(16)), values: resolved[:values]}
      response = {project_id: id, revision: revision_id}
      stop_owners = []
      @db.transaction(mode: :immediate):
        store_inputs(id, input_state)
        sql("INSERT OR IGNORE INTO revisions VALUES(?,?,?,?,?)", [revision_id, id, directory, document, environment])
        sql("INSERT OR REPLACE INTO projects VALUES(?,?,'active')", [id, revision_id])
        remember(id, command, response)
        event(id, {type: "revision", revision: revision_id})
        ids(previous).each |deleted|:
          sql("INSERT OR IGNORE INTO tombstones VALUES(?,?,?)", [id, deleted[0], deleted[1]]) unless current.include?(deleted)
        @runtimes.values.filter |runtime|: runtime.project == id .each |runtime|:
          sheet = (parsed[?:sheets] or []).find: $it[:id] == runtime.controller
          origin = if runtime.active then run(runtime.active) else null
          removed = runtime.controller == runtime.sheet and origin and origin[:action] == "run" and not ((if sheet then sheet[:cells] else []) or []).any? |c|:
            c[:id] == origin[:cell_id] and c[:kind] == "code"
          if runtime.controller != runtime.sheet:
            target = row("SELECT t.board,t.component FROM run_targets t JOIN runs r ON r.id=t.run WHERE r.runtime_id=? ORDER BY r.rowid DESC LIMIT 1", [runtime.id])
            board = if target then (parsed[?:boards] or []).find: $it[:id] == target[:board] else null
            component = if board then @services.find_component(board[:components], target[:component]) else null
            removed = not component or not ["action", "periodic_work"].include?(component[:kind]) or board[:sheet] != runtime.controller
          if not sheet or removed:
            if origin and origin[:state] != "terminating":
              sql("UPDATE runs SET state='stopping' WHERE id=?", [origin[:id]])
              event(id, {type: "run", run_id: origin[:id], state: "stopping", reason: "owner removed"})
            sql("UPDATE runtime_records SET state=? WHERE id=?", [(if origin then "stopping" else "terminating"), runtime.id])
            stop_owners.push!([runtime, not sheet or runtime.controller != runtime.sheet])
      @services.reconcile(id, revision_id)
      stop_owners.each |entry|:
        runtime = entry[0]
        runtime.retire!() if entry[1]
        if runtime.active: runtime.stop()
        else: runtime.close!()
      response
    ensure:
      remove_tree(staged) if fs.exists?(staged)

  def sync_tree(path):
    metadata = fs.metadata(path)
    fail(400, "snapshot contains a symlink or special file") if metadata.symlink? or not (metadata.dir? or metadata.file?)
    if metadata.dir?: fs.entries(path).each: sync_tree($it)
    fs.sync(path)

  def remove_tree(path):
    if fs.dir?(path): fs.entries(path).each: remove_tree($it.to_str)
    fs.remove(path)

  def prepare_run(params, input_state: null, input_document: null, internal: false):
    id = identifier(params[?:project_id])
    current = project(id)
    fail(409, "run requires current active project revision") unless current[:state] == "active" and params[:revision] == current[:head]
    revision = revision(current[:head])
    document = decode(revision[:document])
    fail(422, "directory dependency bundles are not enabled") unless (document[?:dependencies] or []).empty?
    action = params[?:action] or "run"
    target = null
    input_state = input_state or cell_inputs(id)
    input_document = input_document or resolve_inputs(revision, input_state[:values])[:document]
    if ["action_run", "periodic_run"].include?(action):
      board = identifier(params[?:board_id])
      component = identifier(params[?:component_id])
      target = invocation_document(revision, input_document, board, component)
      fail(422, "invocation kind mismatch") unless target[:kind] == (if action == "action_run" then "action" else "periodic_work")
      input_document = target[:document]
      target = target.merge({board: board, component: component})
      params = params.merge({sheet_id: target[:sheet_id], cell_id: target[:cell_id]})
      document = decode(input_document)
    sheet = document[:sheets].find: $it[:id] == params[?:sheet_id]
    fail(404, "sheet not found") unless sheet
    fail(422, "unsupported cell semantics") if sheet[:cells].any? |c|: not ["code", "text"].include?(c[:kind])
    cell = sheet[:cells].find: $it[:id] == params[?:cell_id] and $it[:kind] == "code"
    fail(404, "code cell not found") unless cell
    fail(422, "unsupported execution action") unless ["run", "run_all", "action_run"].include?(action) or (internal and ["inputs", "watch", "periodic_run"].include?(action))
    input_state = input_state or cell_inputs(id)
    input_document = input_document or resolve_inputs(revision, input_state[:values])[:document]
    owner = if target then "service_" + digest([target[:board], target[:component]]) else sheet[:id]
    key = key(id, owner)
    runtime = @runtimes[?key]
    settings = worker_settings(id, sheet[:id])
    fail(409, "dependencies are being changed; wait for installation to finish") if @dependencies.busy?(id)
    foreign = worker_environment(id, sheet[:id], revision, prepare: true)
    replaced = null
    if runtime and target and not runtime.active and (runtime.dead or runtime.forced or runtime.environment != revision[:environment] or runtime.controller != sheet[:id] or runtime.invocation != cell[:source]):
      replaced = runtime
      runtime = null
    if runtime:
      fail(409, "worker environment changed; explicit runtime restart required") unless runtime.foreign_environment == foreign[:fingerprint] and (not runtime.managed_environment or runtime.environment_directory == foreign[:directory])
      fail(409, "runtime interrupted; explicit restart required") if runtime.dead or runtime.forced
      fail(409, "runtime busy") if runtime.active
      fail(409, "environment changed; explicit runtime restart required") unless runtime.environment == revision[:environment]
    else:
      fail(429, "runtime limit reached") if (@owned.values.filter |r|: not r.dead).count >= 8
      runtime = Runtime(self, id, owner, revision[:environment], settings[:grants], foreign[:directory], foreign[:fingerprint], foreign[?:id], controller: sheet[:id])
    {id: SecureRandom.hex(16), project: id, revision: revision, runtime: runtime, cell: cell[:id], action: action, inputs: input_state, document: input_document, target: target, source: cell[:source], replaced: replaced}

  def persist_run(plan):
    if plan[:replaced] and not plan[:replaced].dead:
      sql("UPDATE runtime_records SET state='terminating' WHERE id=?", [plan[:replaced].id])
    runtime = plan[:runtime]
    sql("INSERT INTO run_inputs VALUES(?,?,?)", [plan[:id], plan[:inputs][:version], plan[:document]])
    sql("INSERT OR REPLACE INTO runtime_records VALUES(?,?,?,?,?,?)", [runtime.id, plan[:project], runtime.sheet, runtime.epoch, runtime.environment, "preparing"])
    sql("INSERT INTO runs(id,project,revision,sheet_id,cell_id,action,runtime_id,epoch,state,error) VALUES(?,?,?,?,?,?,?,?,?,?)", [plan[:id], plan[:project], plan[:revision][:id], runtime.sheet, plan[:cell], plan[:action], runtime.id, runtime.epoch, "preparing", ""])
    if plan[:target]:
      target = plan[:target]
      sql("INSERT INTO run_targets VALUES(?,?,?,?)", [plan[:id], target[:board], target[:component], target[:sheet_id]])
    event(plan[:project], {type: "run", run_id: plan[:id], state: "preparing"})

  def launch_run(plan):
    plan[:replaced].close!() if plan[:replaced] and not plan[:replaced].dead
    runtime = plan[:runtime]
    runtime.set_invocation(plan[:source]) if plan[:target]
    @runtimes[key(plan[:project], runtime.sheet)] = runtime
    @owned[runtime.id] = runtime
    runtime.prepare(plan[:id])
    record = run(plan[:id])
    task.async: runtime.execute(record, plan[:revision])

  def start_run(params, input_state: null, input_document: null, input_command: null, internal: false):
    id = identifier(params[?:project_id])
    command = input_command or receipt(id, params, "run.start")
    return command[2] if command[2]
    plan = prepare_run(params, input_state: input_state, input_document: input_document, internal: internal or input_command != null)
    runtime = plan[:runtime]
    response = {run_id: plan[:id], runtime_id: runtime.id, runtime_epoch: runtime.epoch}
    response = response.merge(input_state) if input_command
    @db.transaction(mode: :immediate):
      store_inputs(id, input_state) if input_command
      persist_run(plan)
      remember(id, command, response)
    launch_run(plan)
    response

  def phase(runtime, state):
    @mutex.synchronize:
      return null unless runtime.active
      current = run(runtime.active)
      return null if ["stopping", "terminating"].include?(current[:state])
      @db.transaction:
        sql("UPDATE runs SET state=? WHERE id=?", [state, runtime.active])
        sql("UPDATE runtime_records SET state=? WHERE id=?", [state, runtime.id])
        event(runtime.project, {type: "run", run_id: runtime.active, state: state})

  def live(runtime, text, binary):
    @mutex.synchronize:
      if runtime.active:
        fs.atomic_write_bytes(@root + "/runs/" + runtime.active + ".live.bin", binary, durable: false)
        sql("UPDATE runs SET live_json=? WHERE id=?", [text, runtime.active])

  def complete(runtime, summary, binary):
    @mutex.synchronize:
      # Force Stop may acquire the owner lock after execute's last flag check.
      # The caller must still confirm exit and publish the terminal lifecycle.
      return false if runtime.forced
      return true unless runtime.active
      record = run(runtime.active)
      document = decode(revision(record[:revision])[:document])
      sheet = document[:sheets].find: $it[:id] == runtime.controller
      targets = [record[:cell_id]]
      if record[:action] == "run_all":
        targets = (sheet[:cells].filter |c|: c[:kind] == "code").map: $it[:id]
      bad = summary[:environment_error] != "" or not summary[:unobserved_task_failures].empty?
      if record[:action] == "inputs": bad = bad or summary[:status] == "project input evaluation failed"
      elif record[:action] == "watch": bad = bad or summary[:cells].any? |c|: not c[:ok] and not c[:dirty]
      else: bad = bad or summary[:cells].any? |c|: targets.include?(c[:id]) and not c[:ok]
      state = if summary[:cancelled] then "cancelled" else if bad then "failed" else "succeeded"
      artifact = @root + "/runs/" + record[:id] + ".bin"
      fs.atomic_write_bytes(artifact, binary)
      finish(runtime, state, summary: summary, presentation: artifact)
      true

  def finished(runtime, state, error: ""):
    @mutex.synchronize: finish(runtime, state, error: error)

  def finish(runtime, state, error: "", summary: null, presentation: null):
    @db.transaction(mode: :immediate):
      lifecycle = if runtime.dead then (if runtime.forced then "terminated" else "interrupted") else (if runtime.retiring or runtime.forced then "terminating" else "idle")
      sql("UPDATE runtime_records SET state=? WHERE id=?", [lifecycle, runtime.id])
      if runtime.active:
        id = runtime.active
        sql("UPDATE runs SET state=?,error=?,result_json=?,presentation=? WHERE id=?", [state, error, (if summary then Json.generate(summary) else null), presentation, id])
        event(runtime.project, {type: "run", run_id: id, state: state})
      deleting = project(runtime.project)[:state] == "deleting"
      if deleting and not owners_pending?(runtime.project):
        sql("UPDATE projects SET state='deleted' WHERE id=?", [runtime.project])
        event(runtime.project, {type: "project_deleted"})
    @services.completed(runtime, state, summary) if runtime.active
    runtime.release!()
    @owned.delete!(runtime.id) if runtime.dead
    runtime.close!() if runtime.retiring and not runtime.dead

  def stop_run(params):
    record = row("SELECT id,project,sheet_id,runtime_id,epoch,state FROM runs WHERE id=?", [identifier(params[?:run_id])])
    fail(404, "run not found") unless record
    command = receipt(record[:project], params, "run.stop")
    return command[2] if command[2]
    fail(409, "stale runtime epoch") unless params[:runtime_epoch] == record[:epoch]
    force = if params.has_key?(:force) then params[?:force] else false
    fail(400, "force must be a boolean") unless Bool === force
    runtime = @owned[?record[:runtime_id]]
    state = record[:state]
    unless terminal?(state):
      fail(409, "run no longer has this runtime") unless runtime and runtime.active == record[:id] and runtime.epoch == record[:epoch]
      state = if force or state == "terminating" then "terminating" else "stopping"
    response = {run_id: record[:id], state: state}
    @db.transaction(mode: :immediate):
      sql("UPDATE runs SET state=? WHERE id=?", [state, record[:id]])
      sql("UPDATE runtime_records SET state=? WHERE id=?", [state, runtime.id]) unless terminal?(state)
      remember(record[:project], command, response)
      event(record[:project], {type: "run", run_id: record[:id], state: state})
    @services.pause_owner(record[:project], record[:sheet_id]) unless terminal?(state)
    runtime.stop(force: state == "terminating") unless terminal?(state)
    response

  def restart(params):
    id = identifier(params[?:project_id])
    command = receipt(id, params, "runtime.restart")
    return command[2] if command[2]
    fail(409, "project deleted") unless project(id)[:state] == "active"
    key = key(id, identifier(params[?:sheet_id]))
    runtime = @runtimes[?key]
    if runtime:
      fail(409, "stop active run before restarting") if runtime.active
      fail(409, "stale runtime epoch") unless params[:runtime_epoch] == runtime.epoch
    response = {project_id: id, sheet_id: params[?:sheet_id], state: "reset", reset_epoch: if runtime then runtime.epoch else null}
    @db.transaction(mode: :immediate):
      remember(id, command, response)
      sql("UPDATE runtime_records SET state='terminating' WHERE id=?", [runtime.id]) if runtime and not runtime.dead
    if runtime:
      runtime.close!()
      @runtimes.delete!(key)
    response

  def worker_environment(id, sheet, revision, prepare: false):
    config = row("SELECT directory FROM worker_environments WHERE project=? AND sheet=?", [id, sheet])
    if config and config[:directory] != "": return decode(inspect_environment(config[:directory]))
    return @environments.request(id, revision) if prepare
    description = @environments.spec(revision)
    return decode(inspect_environment(revision[:directory])) unless description
    environment_id = digest(description)
    record = @environments.record(id, environment_id)
    {id: environment_id, fingerprint: environment_id, directory: if record then record[:directory] else ""}

  def worker_settings(id, sheet):
    record = row("SELECT grants FROM worker_settings WHERE project=? AND sheet=?", [id, sheet])
    grants = if record then decode(record[:grants]) else []
    config = row("SELECT directory FROM worker_environments WHERE project=? AND sheet=?", [id, sheet])
    directory = if config then config[:directory] else ""
    runtime = @runtimes[?key(id, sheet)]
    {project_id: id, sheet_id: sheet, grants: grants, environment_directory: directory, version: digest([grants, directory]), runtime_epoch: if runtime then runtime.epoch else null}

  def configure_worker(params):
    id = identifier(params[?:project_id])
    command = receipt(id, params, "worker.configure")
    return command[2] if command[2]
    current = project(id)
    fail(409, "project deleted") unless current[:state] == "active"
    sheet = identifier(params[?:sheet_id])
    fail(404, "sheet not found") unless decode(revision(current[:head])[:document])[:sheets].any? |s|: s[:id] == sheet
    settings = worker_settings(id, sheet)
    fail(409, "worker settings changed; reload settings") unless params[?:base_version] == settings[:version]
    fail(409, "stale runtime epoch; reload settings") unless params[?:runtime_epoch] == settings[:runtime_epoch]
    runtime = @runtimes[?key(id, sheet)]
    worlds = @runtimes.values.filter: $it.project == id and $it.controller == sheet
    fail(409, "stop active run before changing worker settings") if worlds.any?: $it.active != null
    directory = if params.has_key?(:environment_directory) then params[:environment_directory] else settings[:environment_directory]
    fail(400, "environment_directory must be an absolute server directory or empty") unless Str === directory and directory.bytes.count <= 4096 and not directory.contains?("\u{0}") and (directory == "" or directory.starts_with?("/"))
    if directory != "":
      try:
        inspect_environment(directory)
      rescue Exception |error|:
        fail(400, error.message)
    grants = params[?:grants]
    fail(400, "grants must be a list of at most 128 strings") unless Array === grants and grants.count <= 128 and grants.all? |g|: Str === g
    fail(400, "invalid worker grant") if grants.any? |g|: g.contains?("\n") or g.contains?("\r") or g.contains?("\u{0}")
    text = grants.join("\n")
    fail(400, "worker grants exceed 32 KiB") if text.bytes.count > 32768
    checked = system.command(@worker_path, "--check-grants", text).capture(timeout: 15.0, check: false)
    fail(400, checked.stderr.to_str) unless checked.success?
    normalized = checked.stdout.to_str
    grants = if normalized == "" then [] else normalized.split("\n")
    response = {project_id: id, sheet_id: sheet, grants: grants, environment_directory: directory, version: digest([grants, directory]), runtime_epoch: null, state: "reset", reset_epoch: if runtime then runtime.epoch else null}
    @db.transaction(mode: :immediate):
      sql("INSERT OR REPLACE INTO worker_settings VALUES(?,?,?)", [id, sheet, Json.generate(grants)])
      sql("INSERT OR REPLACE INTO worker_environments VALUES(?,?,?)", [id, sheet, directory])
      worlds.each |world|:
        sql("UPDATE runtime_records SET state='terminating' WHERE id=?", [world.id]) unless world.dead
        sql("INSERT OR IGNORE INTO dependency_resets VALUES(?,?)", [id, world.epoch])
      @services.pause_controller(id, sheet)
      remember(id, command, response)
      event(id, {type: "worker_settings", sheet_id: sheet, grants: grants})
    worlds.each |world|:
      world.close!()
      @runtimes.delete!(key(id, world.sheet))
    response

  def delete_project(params):
    id = identifier(params[?:project_id])
    command = receipt(id, params, "project.delete")
    return command[2] if command[2]
    existing = project(id)
    if ["deleting", "deleted"].include?(existing[:state]):
      response = {project_id: id, state: existing[:state]}
      @db.transaction: remember(id, command, response)
      return response
    owned = @owned.values.filter: $it.project == id
    response = {project_id: id, state: "deleting"}
    @db.transaction(mode: :immediate):
      @services.pause_project(id)
      sql("UPDATE projects SET state='deleting' WHERE id=?", [id])
      remember(id, command, response)
      event(id, {type: "project_deleting"})
      owned.each |runtime|:
        sql("UPDATE runs SET state='terminating' WHERE id=?", [runtime.active]) if runtime.active
        sql("UPDATE runtime_records SET state='terminating' WHERE id=?", [runtime.id]) unless runtime.dead
      sql("UPDATE projects SET state='deleted' WHERE id=?", [id]) unless owners_pending?(id)
    owned.each |runtime|:
      unless runtime.dead: runtime.close!()
    response

  def handle(method, params):
    if method == "dependency.catalog":
      @mutex.synchronize: project(identifier(params[?:project_id]))
      # A registry request must not hold the core lock or delay running cells.
      return @dependencies.catalog(params)
    @mutex.synchronize: dispatch(method, params)

  def environment_prepare(params):
    id = identifier(params[?:project_id])
    command = receipt(id, params, "environment.prepare")
    return command[2] if command[2]
    current = project(id)
    fail(409, "project deleted") unless current[:state] == "active"
    retry = params[?:retry] or false
    fail(400, "retry must be boolean") unless Bool === retry
    response = @environments.request(id, revision(current[:head]), retry: retry)
    @db.transaction: remember(id, command, response)
    response

  def dispatch(method, params):
    case method:
      when "environments.gc":
        command = receipt("@maintenance", params, "environments.gc")
        return command[2] if command[2]
        response = @environments.gc(params[?:minimum_age_seconds] or 604800, dry_run: params[?:dry_run] or false)
        @db.transaction: remember("@maintenance", command, response)
        return response
      when "environment.prepare": return environment_prepare(params)
      when "dependency.change":
        id = identifier(params[?:project_id])
        command = receipt(id, params, method)
        return command[2] if command[2]
        current = project(id)
        fail(409, "project deleted") unless current[:state] == "active"
        response = @dependencies.request(id, revision(current[:head]), params)
        @db.transaction: remember(id, command, response)
        return response
      when "project.put": return put_project(params)
      when "run.start": return start_run(params)
      when "cell.inputs.set": return set_cell_inputs(params)
      when "project.inputs.set": return set_project_inputs(params)
      when "service.configure": return @services.configure(params)
      when "run.stop": return stop_run(params)
      when "runtime.restart": return restart(params)
      when "worker.configure": return configure_worker(params)
      when "project.delete": return delete_project(params)
      when "health": return {protocol: 1, agent_pid: pid(), implementation: "sputnik", capabilities: ["sheet_run", "bundled_modules", "project_revisions", "reattach", "stop", "force_stop", "gui_reconnect", "live_presentation", "revision_document", "compact_registry", "worker_grants", "worker_environment", "managed_environments", "orphan_gc", "dependency_management", "package_catalog", "cell_inputs", "run_document", "project_inputs", "idle_watch", "board_actions", "server_periodic"]}
      when "project.list":
        projects = @db.query("SELECT p.*,r.document FROM projects p JOIN revisions r ON r.id=p.head ORDER BY p.id")
        projects.each |project|:
          project[:title] = decode(project[:document])[?:title] or project[:id]
          project.delete!(:document)
        return {projects: projects}
      when "run.get": return run(identifier(params[?:run_id]))
    id = identifier(params[?:project_id])
    current = project(id)
    case method:
      when "dependency.status":
        environments = @environments.list(id)
        ready = environments.reversed.find: $it[:state] == "ready"
        return {packages: installed_packages(package_directory(id)), jobs: @dependencies.list(id), environments: environments, ready: if ready then @environments.details(ready) else null}
      when "dependency.get": return @dependencies.get(id, identifier(params[?:operation_id]))
      when "environment.get":
        found = @environments.record(id, identifier(params[?:environment_id]))
        fail(404, "environment not found") unless found
        return @environments.details(found)
      when "environment.list": return {environments: @environments.list(id)}
      when ("cell.inputs" | "project.inputs"): return cell_inputs(id)
      when "service.list": return {services: @services.list(id)}
      when "worker.settings": return worker_settings(id, identifier(params[?:sheet_id]))
      when "project.get":
        current[:document] = revision(current[:head])[:document]
        current
      when ("revision.get" | "revision.document"):
        record = revision(identifier(params[?:revision]))
        fail(404, "revision not found in this project") unless record[:project] == id
        response = {project_id: id, revision: record[:id], document: record[:document]}
        response[:files] = project_files(record[:directory]) if method == "revision.get"
        response
      when "receipt.get":
        command = identifier(params[?:command_id])
        record = row("SELECT response FROM receipts WHERE project=? AND command=?", [id, command])
        fail(404, "command was not accepted") unless record
        {command_id: command, response: decode(record[:response])}
      when ("run.list" | "run.registry"):
        runs = []
        if method == "run.registry":
          runs = rows("SELECT id,project,revision,sheet_id,cell_id,action,runtime_id,epoch,state,error,presentation IS NOT NULL AS has_presentation,json_extract(live_json, '$.executing_cell') AS executing_cell,(SELECT version FROM run_inputs WHERE run=runs.id) AS input_version FROM runs WHERE project=? ORDER BY rowid", [id])
          runs.each |record|:
            record[:has_presentation] = record[:has_presentation] == 1
            record[:has_live] = not terminal?(record[:state]) and fs.exists?(@root + "/runs/" + record[:id] + ".live.bin")
        else: runs = rows("SELECT id FROM runs WHERE project=? ORDER BY rowid", [id]).map: run($it[:id])
        runs.each |record|:
          target = row("SELECT board,component,controller FROM run_targets WHERE run=?", [record[:id]])
          record.merge!(target) if target
        records = rows("SELECT * FROM runtime_records WHERE project=? ORDER BY rowid", [id])
        environment = row("SELECT environment FROM revisions WHERE id=?", [current[:head]])[:environment]
        records.each |record|:
          runtime = @owned[?record[:id]]
          record[:worker_pid] = if runtime and runtime.worker and not runtime.dead then runtime.worker.pid else null
          owner = @runtimes[?key(id, record[:sheet_id])]
          record[:needs_restart] = false
          if owner and owner.id == record[:id]:
            foreign = worker_environment(id, owner.controller, revision(current[:head]))
            record[:needs_restart] = owner.dead or owner.environment != environment or owner.foreign_environment != foreign[:fingerprint] or (owner.managed_environment != null and owner.environment_directory != foreign[:directory])
        reset_epochs = rows("SELECT DISTINCT json_extract(response, '$.reset_epoch') AS epoch FROM receipts WHERE project=? AND json_extract(response, '$.reset_epoch') IS NOT NULL", [id]).map: $it[:epoch]
        reset_epochs = reset_epochs + (rows("SELECT epoch FROM dependency_resets WHERE project=?", [id]).map: $it[:epoch])
        {services: @services.list(id), runs: runs, runtimes: records, reset_epochs: reset_epochs, cell_inputs: cell_inputs(id), event_seq: @db.scalar("SELECT COALESCE(MAX(seq),0) FROM events"), project: current}
      when "events":
        after = params[?:after] or 0
        fail(400, "invalid event cursor") unless Int === after and after >= 0
        events = rows("SELECT * FROM events WHERE project=? AND seq>? ORDER BY seq LIMIT 1000", [id, after]).map |r|: {seq: r[:seq], data: decode(r[:payload])}
        {events: events, next_seq: if events.empty? then after else events[-1][:seq]}
      else: fail(404, "unknown method")
