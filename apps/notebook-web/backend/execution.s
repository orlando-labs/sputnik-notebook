package execution

from notebook.core.common import decode, terminal?
from models import WebError, InvalidInput, NotFound
from results import RichResults
from resources import Resources

export Execution

def identifier(value):
  valid = value.length > 0 and value.length <= 128 and value.chars.all? |c|:
    "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-".contains?(c)
  raise InvalidInput("Invalid execution identifier.") unless valid
  value

class Execution:
  def init(@catalog, @notebooks): @results = RichResults(@notebooks)

  def call(method, params): @notebooks.call(method, params, execution: true)

  def run_summary(record):
    result = {id: record[:id], revision: record[:revision], sheet_id: record[?:controller] or record[:sheet_id],
      cell_id: record[:cell_id], action: record[:action], runtime_epoch: record[:epoch], state: record[:state],
      input_version: record[?:input_version], metadata: record[?:metadata], executing_cell: record[?:executing_cell] or ""}
    result.merge!({board_id: record[:board], component_id: record[:component]}) if record[?:board]
    result

  def registry(current, id, board_id = null):
    project = @catalog.require_project(current, id)
    source = call("run.registry", {project_id: project[:core_project_id]})
    runs = source[:runs]
    start = if runs.count > 100 then runs.count - 100 else 0
    # Keep active runs even if a long history on other sheets put them outside
    # the recent window. Never forward the raw project/runtime/service records.
    visible = []
    latest = {}
    identifier(board_id) if board_id
    runs.each |record|:
      latest[record[:component]] = record[:id] if board_id and record[?:board] == board_id
    runs.each_with_index |record, index|:
      visible.push!(run_summary(record)) if index >= start or not terminal?(record[:state]) or latest.values.include?(record[:id])
    {revision: source[:project][:head], input_version: source[:cell_inputs][:version], reset_epochs: source[:reset_epochs], dependency_busy: source[?:dependency_busy] or false, can_execute: @catalog.permissions(@catalog.role(current, project))[:execute],
      runs: visible, services: public_services(source[:services], board_id), resources: Resources(@catalog, @notebooks).summary(project[:core_project_id], aggregate_user: @catalog.guest?(current)),
      runtimes: (source[:runtimes].filter |runtime|: not runs.any? |run|: run[?:board] and run[:epoch] == runtime[:epoch]).map |runtime|:
        {sheet_id: runtime[:sheet_id], runtime_epoch: runtime[:epoch], state: runtime[:state], needs_restart: runtime[:needs_restart],
          iteration_ready: runtime[?:iteration_ready] or [], iteration_running: runtime[?:iteration_running] or false}
    }

  def history(current, id, before = null):
    project = @catalog.require_project(current, id)
    params = {project_id: project[:core_project_id], limit: 50}
    if before:
      raise InvalidInput("Invalid run history cursor.") unless before.length > 0 and before.length <= 19 and before.chars.all? |c|: "0123456789".contains?(c)
      params[:before] = before.to_int()
    page = call("run.list", params)
    values = page[:runs].map: run_summary($it)
    {runs: values, before: if page[:next] then page[:next].to_str else null}

  def owned_run(project, run_id):
    record = call("run.get", {run_id: identifier(run_id)})
    raise NotFound() unless record[:project] == project[:core_project_id]
    record

  def outputs(values):
    (values or []).map |value|:
      {stream: value[:stream], text: value[:text]}

  def cells(summary, sources, rich = [], finished: false):
    return [] unless summary
    (summary[?:cells] or []).map |cell|:
      source = sources.find: $it[:id] == cell[:id]
      media = rich.find: $it[:id] == cell[:id]
      {id: cell[:id], source: if source then source[:source] else null, ok: cell[:ok], dirty: cell[:dirty],
        result: cell[?:result] or "", error: cell[?:error] or "", output: outputs(cell[?:output]),
        result_format: if media then media[:result_format] else null,
        table: if media then media[:table] else null, displays: if media then media[:displays] else [], images: if media then media[:images] else [],
        audio: if media then media[:audio] else [], audio_controls: if media then media[:audio_controls] else [], audio_limited: if media then media[:audio_limited] else false,
        progress: if media then media[:progress] else [], stopwatches: if media then media[:stopwatches] else [], charts: if media then media[:charts] else [],
        elapsed_ms: if media then media[:elapsed_ms] else null, timing_running: if media then media[:timing_running] else false,
        environment_rebuild_ms: if media then media[?:environment_rebuild_ms] else null,
        metrics: if media then media[:metrics] else [],
        text_values: if media then media[:text_values] else [], diagnostics: if media then media[:diagnostics] else [], diagnostics_truncated: if media then media[:diagnostics_truncated] else false,
        telemetry_stale: if media then (finished and media[:dirty]) or media[:source_revision] != cell[:source_revision] else false,
        rich_stale: if media then media[:dirty] or media[:source_revision] != cell[:source_revision] or (finished and not cell[:ok]) else false,
        rich_unsupported: if media then media[:unsupported] else false}

  def presentation(record):
    document = if record[:execution_document] then decode(record[:execution_document]) else {sheets: []}
    sheet_id = record[?:controller] or record[:sheet_id]
    sheet = document[:sheets].find: $it[:id] == sheet_id
    sources = if sheet then sheet[:cells] else []
    summary = record[:result]
    live = if terminal?(record[:state]) then null else record[:live]
    boards = (document[?:boards] or []).filter: $it[:sheet] == sheet_id
    rich = @results.read(record, sources, boards)
    run_summary(record).merge({
      error: if record[:state] == "interrupted" then "The worker was interrupted. Restart it before another run." else if record[:state] == "force-stopped" then "The worker was force stopped. Restart it before another run." else "",
      environment_error: if summary and summary[:environment_error] != "" then public_environment_error(summary[:environment_error]) else "",
      environment_stale: if summary then summary[?:environment_stale] or false else false,
      task_errors: task_errors(summary),
      rich_error: rich[:error],
      text_limited: rich[:text_limited],
      task_telemetry: rich[:task_telemetry],
      executing_cell: if live then live[:executing_cell] else "",
      cells: cells(summary, sources, rich[:cells], finished: true), live_cells: cells(live, sources, rich[:cells])
    })

  def public_environment_error(message):
    return message if (message.starts_with?("Package module '") or message.starts_with?("Native dependencies require explicit trust")) and not message.contains?("/") and message.length < 1024
    "The worker environment could not be prepared. Check Dependencies and this sheet's worker permissions."

  def task_errors(summary):
    return [] unless summary
    (summary[?:unobserved_task_failures] or []).map |failure|:
      if Str === failure: failure
      else: "Task " + (failure[?:id] or "?").to_str + " · " + (failure[?:name] or "TaskError").to_str + ": " + (failure[?:message] or "Background task failed.").to_str

  def read(current, id, run_id):
    project = @catalog.require_project(current, id)
    {run: presentation(owned_run(project, run_id))}

  def start(current, id, command, revision, sheet, cell, action):
    project = @catalog.require_project(current, id, capability: :execute)
    raise InvalidInput("Action must be run or run_all.") unless ["run", "run_all"].include?(action)
    accepted = call("run.start", {project_id: project[:core_project_id], command_id: identifier(command),
      revision: identifier(revision), sheet_id: identifier(sheet), cell_id: identifier(cell), action: action})
    {run: run_summary(owned_run(project, accepted[:run_id]))}

  def invoke(current, id, command, revision, board, component):
    project = @catalog.require_project(current, id, capability: :execute)
    accepted = call("run.start", {project_id: project[:core_project_id], command_id: identifier(command),
      revision: identifier(revision), board_id: identifier(board), component_id: identifier(component), action: "action_run"})
    {run: run_summary(owned_run(project, accepted[:run_id]))}

  def service_summary(state):
    # Scheduler diagnostics may contain private worker paths. Only fixed public
    # states cross the boundary; user values/errors are bounded history below.
    known = ["Waiting on server", "Running on server", "Pausing after this run", "Paused", "Last run failed", "Agent restarted · Start to resume", "Settings or modules changed · Start to resume"]
    {board_id: state[:board], component_id: state[:component], sheet_id: state[:controller], revision: state[:revision],
      enabled: state[:enabled], running: state[:running], run_id: state[?:run_id],
      runs: state[:runs].to_str, failures: state[:failures].to_str, skipped: state[:skipped].to_str,
      history_count: (state[?:history_count] or state[:history].count).to_str,
      status: if known.include?(state[:status]) then state[:status] else "Service paused after a server error. Check its last run."}

  def public_services(states, board_id = null):
    # Bound old disabled definitions, retaining all enabled/current services.
    start = if states.count > 256 then states.count - 256 else 0
    result = []
    states.each_with_index |state, index|:
      result.push!(service_summary(state)) if index >= start or state[:enabled] or state[:running] or (board_id and state[:board] == board_id)
    result

  def services(current, id):
    project = @catalog.require_project(current, id)
    {services: public_services(call("service.list", {project_id: project[:core_project_id]})[:services])}

  def history_text(value):
    return null unless value
    if value.length > 4096 then value.slice(0...4096) else value

  def service_history(current, id, board, component, before = null):
    project = @catalog.require_project(current, id)
    identifier(board)
    identifier(component)
    states = call("service.list", {project_id: project[:core_project_id]})[:services]
    state = states.find: $it[:board] == board and $it[:component] == component
    raise NotFound() unless state
    params = {project_id: project[:core_project_id], board_id: board, component_id: component, limit: 50}
    if before:
      raise InvalidInput("Invalid service history cursor.") unless before.length > 0 and before.length <= 19 and before.chars.all? |c|: "0123456789".contains?(c)
      params[:before] = before.to_int()
    page = call("service.history", params)
    entries = page[:history]
    values = entries.map |entry|:
      value = entry[?:value]
      error = entry[?:error]
      {id: entry[:id].to_str, started: entry[:started], duration: entry[:duration], ok: entry[:ok],
        value: history_text(value), error: history_text(error),
        truncated: (value and value.length > 4096) or (error and error.length > 4096) or false}
    {service: service_summary(state), history: values, before: if page[:next] then page[:next].to_str else null}

  def configure_service(current, id, command, revision, board, component, operation):
    project = @catalog.require_project(current, id, capability: :execute)
    raise InvalidInput("Invalid service operation.") unless ["start", "pause", "once", "clear"].include?(operation)
    result = call("service.configure", {project_id: project[:core_project_id], command_id: identifier(command),
      revision: identifier(revision), board_id: identifier(board), component_id: identifier(component), operation: operation})
    {service: service_summary(result[:service])}

  def restart_invocation(current, id, run_id, command, epoch):
    project = @catalog.require_project(current, id, capability: :execute)
    record = owned_run(project, run_id)
    raise InvalidInput("Choose an invocation run.") unless record[?:board] and ["action_run", "periodic_run"].include?(record[:action])
    states = call("service.list", {project_id: project[:core_project_id]})[:services]
    state = states.find: $it[:board] == record[:board] and $it[:component] == record[:component]
    raise WebError(409, "service_active", "Pause the service and wait for its current run before restarting.") if state and (state[:enabled] or state[:running])
    call("runtime.restart", {project_id: project[:core_project_id], command_id: identifier(command), sheet_id: record[:sheet_id], runtime_epoch: identifier(epoch)})
    {state: "reset"}

  def stop(current, id, run_id, command, epoch, force):
    project = @catalog.require_project(current, id, capability: :execute)
    owned_run(project, run_id)
    call("run.stop", {run_id: run_id, command_id: identifier(command), runtime_epoch: identifier(epoch), force: force})
    {run: run_summary(owned_run(project, run_id))}

  def restart(current, id, command, sheet, epoch):
    project = @catalog.require_project(current, id, capability: :execute)
    document = decode(call("project.get", {project_id: project[:core_project_id]})[:document])
    raise NotFound() unless document[:sheets].any? |value|: value[:id] == sheet
    identifier(epoch) if epoch != null
    result = call("runtime.restart", {project_id: project[:core_project_id], command_id: identifier(command),
      sheet_id: identifier(sheet), runtime_epoch: epoch})
    {state: result[:state], sheet_id: result[:sheet_id]}

  def receipt(current, id, command):
    project = @catalog.require_project(current, id)
    record = null
    try:
      record = call("receipt.get", {project_id: project[:core_project_id], command_id: identifier(command)})[:response]
    rescue WebError |error|:
      raise error unless error.status == 404
    return {command: {state: "unknown"}} unless record
    if record[?:service]:
      return {command: {state: "accepted", service: service_summary(record[:service])}}
    if record[?:run_id]:
      return {command: {state: "accepted", run: run_summary(owned_run(project, record[:run_id]))}}
    if record[?:state] == "reset" and Str === record[?:sheet_id]:
      return {command: {state: "accepted"}}
    # A document/worker-settings receipt is not an execution receipt.
    {command: {state: "unknown"}}
