package notebook.core.services

from notebook.core.common import fail, identifier, decode, digest

export Services

# The agent owns deadlines and invocation worlds. No client timer or open-book
# metadata can enable a service. Agent restart always requires an explicit Start.
class Services:
  def init(@core):
    @states = {}
    @core.sql("CREATE TABLE IF NOT EXISTS services(project TEXT,owner TEXT,state TEXT NOT NULL,PRIMARY KEY(project,owner))")
    @core.rows("SELECT project,owner,state FROM services").each |row|:
      state = decode(row[:state])
      state[:enabled] = false
      state[:running] = false
      state[:next_at] = null
      state[:status] = "Agent restarted · Start to resume"
      trim(state)
      @states[key(row[:project], row[:owner])] = state
      save(state)

  def key(project, owner): project + ":" + owner
  def owner(board, component): "service_" + digest([board, component])
  def now(): Time.monotonic.total_nanoseconds.to_float / 1000000000.0
  def save(state):
    trim(state)
    @core.sql("INSERT OR REPLACE INTO services VALUES(?,?,?)", [state[:project], state[:owner], Json.generate(state)])
  def list(project): @states.values.filter: $it[:project] == project

  def definition(project, revision, board_id, component_id):
    document = decode(revision[:document])
    board = (document[?:boards] or []).find: $it[:id] == board_id
    fail(404, "service board unavailable") unless board
    component = find_component(board[:components], component_id)
    fail(404, "Periodic Work component unavailable") unless component and component[:kind] == "periodic_work"
    {component: component, controller: board[:sheet], signature: digest([revision[:environment], board[:sheet], component])}

  def find_component(items, id):
    items.each |item|:
      return item if item[:id] == id
      (item[?:panels] or []).each |panel|:
        found = find_component(panel[:components], id)
        return found if found
    null

  def configure(params):
    project = identifier(params[?:project_id])
    command = @core.receipt(project, params, "service.configure")
    return command[2] if command[2]
    current = @core.project(project)
    fail(409, "project deleted") unless current[:state] == "active"
    board = identifier(params[?:board_id])
    component = identifier(params[?:component_id])
    operation = params[?:operation]
    fail(400, "unknown service operation") unless ["start", "pause", "once", "clear"].include?(operation)
    own = owner(board, component)
    state = @states[?key(project, own)]
    state = decode(Json.generate(state)) if state
    if ["start", "once"].include?(operation):
      fail(409, "project revision conflict") unless params[?:revision] == current[:head]
      revision = @core.revision(current[:head])
      definition = definition(project, revision, board, component)
      # Validate the exported target and complete argument snapshot before enabling.
      @core.invocation_document(revision, @core.resolve_inputs(revision, @core.cell_inputs(project)[:values])[:document], board, component)
      fail(409, "service is already running") if state and state[:running]
      fail(429, "project service limit reached (256)") if not state and list(project).count >= 256
      state = state or {project: project, owner: own, board: board, component: component, runs: 0, failures: 0, skipped: 0, history: [], enabled: false, running: false}
      state[:revision] = current[:head]
      state[:signature] = definition[:signature]
      state[:config] = definition[:component]
      state[:controller] = definition[:controller]
      state[:status] = "Waiting on server"
      state[:enabled] = operation == "start"
      state[:next_at] = now() + (if (state[:config][?:run_immediately] != false) or operation == "once" then 0.0 else period(state))
    else:
      fail(404, "service has not been started") unless state
      if operation == "pause":
        state[:enabled] = false
        state[:next_at] = null
        state[:status] = if state[:running] then "Pausing after this run" else "Paused"
      else: state[:history] = []
    return dispatch(state, command: command) if operation == "once"
    response = {service: decode(Json.generate(state))}
    @core.transaction:
      save(state)
      @core.remember(project, command, response)
    @states[key(project, own)] = state
    response

  def period(state): (state[:config][?:period_seconds] or 60.0).to_float
  def pause_owner(project, owner):
    state = @states[?key(project, owner)]
    return null unless state
    state[:enabled] = false
    state[:next_at] = null
    state[:status] = "Paused"
    save(state)
  def pause_controller(project, controller):
    list(project).filter |s|: s[:controller] == controller .each: pause_owner(project, $it[:owner])
  def pause_project(project, reason = null):
    list(project).each |state|:
      pause_owner(project, state[:owner])
      if reason:
        state[:status] = reason
        save(state)
  def forget(project):
    @states.keys.each |key|:
      @states.delete!(key) if @states[key][:project] == project

  def reconcile(project, revision_id):
    revision = @core.revision(revision_id)
    list(project).each |state|:
      try:
        definition = definition(project, revision, state[:board], state[:component])
        if definition[:signature] != state[:signature]:
          pause_owner(project, state[:owner])
          state[:status] = "Settings or modules changed · Start to resume"
          save(state)
      rescue Exception:
        pause_owner(project, state[:owner])

  def tick():
    instant = now()
    @states.values.each |state|:
      next unless state[:enabled] and not state[:running] and state[:next_at] and state[:next_at] <= instant
      try: dispatch(state)
      rescue Exception |error|:
        failed = decode(Json.generate(state))
        failed[:enabled] = false
        failed[:status] = error.message
        failed[:next_at] = null
        save(failed)
        @states[key(failed[:project], failed[:owner])] = failed

  def dispatch(state, command: null):
    # Published state must survive a failed durable Run transaction unchanged.
    state = decode(Json.generate(state))
    current = @core.project(state[:project])
    fail(409, "project deleted") unless current[:state] == "active"
    revision = @core.revision(current[:head])
    definition = definition(state[:project], revision, state[:board], state[:component])
    fail(409, "Settings or modules changed · Start to resume") unless definition[:signature] == state[:signature]
    plan = @core.prepare_run({project_id: state[:project], revision: current[:head], board_id: state[:board], component_id: state[:component], action: "periodic_run"}, internal: true)
    state[:run_id] = plan[:id]
    state[:running] = true
    state[:started] = now()
    state[:date] = Time.now.unix_milliseconds.to_float / 1000.0
    state[:next_at] = null
    state[:status] = "Running on server"
    response = {service: decode(Json.generate(state)), run_id: plan[:id]}
    @core.transaction:
      @core.persist_run(plan)
      save(state)
      @core.remember(state[:project], command, response) if command
    @states[key(state[:project], state[:owner])] = state
    @core.launch_run(plan)
    response

  def completed(runtime, outcome, summary):
    state = @states[?key(runtime.project, runtime.sheet)]
    return null unless state and state[:run_id] == runtime.active
    finished = now()
    state[:running] = false
    state[:runs] = state[:runs] + 1
    ok = outcome == "succeeded"
    state[:failures] = state[:failures] + 1 unless ok
    config = state[:config]
    if (config[?:retention] or "tail") != "none" and (if ok then config[?:store_values] != false else config[?:store_errors] != false):
      cell = if summary and not summary[:cells].empty? then summary[:cells][0] else null
      state[:history].push!({id: state[:runs], started: state[:date], duration: finished - state[:started], ok: ok, value: (if ok and cell then clipped(cell[:result]) else null), error: (if not ok then clipped(if cell and cell[:error] != "" then cell[:error] else outcome) else null)})
      if (config[?:retention] or "tail") == "tail":
        limit = config[?:tail_limit] or 100
        state[:history] = state[:history][(state[:history].count - limit)...state[:history].count] if state[:history].count > limit
    if not ok and (config[?:stop_on_error] == true or ["force-stopped", "interrupted", "cancelled"].include?(outcome)): state[:enabled] = false
    if state[:enabled]:
      if (config[?:timing] or "fixed_delay") == "fixed_rate":
        elapsed = (finished - state[:started]) / period(state)
        skipped = (elapsed - elapsed % 1.0).to_int
        state[:skipped] = state[:skipped] + skipped
        state[:next_at] = state[:started] + (skipped + 1) * period(state)
      else: state[:next_at] = finished + period(state)
    else: state[:next_at] = null
    state[:status] = if state[:enabled] then (if ok then "Waiting on server" else "Last run failed") else "Paused"
    save(state)


  def clipped(text):
    return text unless Str === text and text.bytes.count > 8192
    text.slice(0...2048) + "… [history value truncated]"

  def trim(state):
    history = state[:history]
    history.each |entry|:
      entry[:value] = clipped(entry[?:value])
      entry[:error] = clipped(entry[?:error])
    history = history[(history.count - 1000)...history.count] if history.count > 1000
    while not history.empty? and Json.generate(history).bytes.count > 1048576:
      history = if history.count == 1 then [] else history[1...history.count]
    state[:history] = history

  def snapshot(project):
    budget = 1048576
    list(project).map |state|:
      result = {}
      state.each |key, value|:
        key = key.to_str
        unless ["config", "signature", "history"].include?(key): result[key] = value
      history = state[:history]
      start = if history.count > 100 then history.count - 100 else 0
      tail = if history.empty? then [] else history[start...history.count]
      while not tail.empty? and Json.generate(tail).bytes.count > budget:
        tail = if tail.count == 1 then [] else tail[1...tail.count]
      budget -= Json.generate(tail).bytes.count
      budget = 0 if budget < 0
      result[:history] = tail
      result[:history_count] = history.count
      result[:history_truncated] = tail.count < history.count
      result[:status] = clipped(state[:status])
      result

  def history(project, params):
    board = identifier(params[?:board_id])
    component = identifier(params[?:component_id])
    state = @states[?key(project, owner(board, component))]
    fail(404, "service not found") unless state
    before = params[?:before] or 9223372036854775807
    limit = params[?:limit] or 100
    fail(400, "invalid service history page") unless Int === before and before > 0 and Int === limit and limit > 0 and limit <= 100
    entries = state[:history].reversed.filter: $it[:id] < before
    more = entries.count > limit
    entries = entries.take(limit)
    {history: entries, next: if more then entries[-1][:id] else null}
