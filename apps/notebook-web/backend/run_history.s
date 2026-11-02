package run_history

from notebook.core.common import decode, terminal?
from sources import command_id
from models import WebError, NotFound

export RunHistory

class RunHistory:
  def init(@catalog, @notebooks, @execution)

  def scalar(input):
    if input.has_key?(:default) then Json.generate(input[:default]) else input[?:default_json] or "null"

  def asset_inputs(components):
    result = []
    (components or []).each |component|:
      result.push!(component[:input]) if component[:kind] == "file_input" and component[?:input]
      (component[?:panels] or []).each |panel|: result += asset_inputs(panel[:components])
    result

  def snapshot(current, id, run):
    project = @catalog.require_project(current, id)
    record = @execution.owned_run(project, run)
    raise WebError(409, "run_active", "Wait for this run to finish before inspecting its immutable snapshot.") unless terminal?(record[:state])
    raise WebError(410, "run_snapshot_unavailable", "This older run has no retained parameter snapshot.") unless record[:execution_document]
    document = decode(record[:execution_document])
    inputs = {}
    local = []
    sources = []
    (document[?:inputs] or []).each |input|:
      inputs[input[:id]] = scalar(input)
    document[:sheets].each |sheet|:
      sheet[:cells].each |cell|:
        sources.push!({sheet_id: sheet[:id], sheet_title: sheet[:title], cell_id: cell[:id], kind: cell[:kind], source: cell[:source]})
        values = {}
        ((cell[?:cell_ui] or {})[?:inputs] or []).each |input|:
          values[input[:id]] = scalar(input)
        local.push!({sheet_id: sheet[:id], cell_id: cell[:id], values: values}) unless values.empty?
    provenance = record[:provenance]
    environment = if provenance then {available: true, source_fingerprint: provenance[:environment], runtime_fingerprint: provenance[:foreign_environment],
      generation: provenance[:managed_generation], settings_fingerprint: provenance[:worker_settings], packages: (provenance[?:packages] or []).map |item|: {name: item[:name], version: item[:version], variant: item[?:variant], digest: item[:digest]}} else {available: false}
    assets = []
    (document[?:boards] or []).each |board|: assets += asset_inputs(board[:components])
    result = @execution.presentation(record)
    # Mutable library labels are separate from the immutable payload below.
    immutable = {schema: "notebook.web.run.v1", run: @execution.run_summary(record), created_at: if record[:created] then record[:created].to_str else null,
      source_hash: Digest.sha256(Json.generate(sources).bytes).hex, sources: sources, inputs: inputs, cell_inputs: local, asset_inputs: assets.uniq,
      modules: (document[?:modules] or []).map |item|: {id: item[:id], path: item[:path]},
      environment: environment, result: result}
    immutable[:run].delete!(:metadata)
    immutable[:result].delete!(:metadata)
    raise WebError(413, "run_snapshot_too_large", "The run snapshot exceeds the 48 MiB web inspection limit.") if Json.generate(immutable).bytes.count > 50331648
    {snapshot: immutable, metadata: record[:metadata]}

  def change(current, id, run, params):
    project = @catalog.require_project(current, id, capability: :write)
    operation = params[:operation]
    raise WebError(422, "invalid_history_operation", "Choose Update or Delete.") unless ["update", "delete"].include?(operation)
    response = @notebooks.call(if operation == "delete" then "run.delete" else "run.annotate", {
      project_id: project[:core_project_id], run_id: command_id(run), command_id: command_id(params[:command_id]),
      base_version: params[:base_version], title: params[:title], pinned: params[:pinned]}, execution: true)
    {operation: response[:operation], metadata: response[?:metadata]}

  def receipt(current, id, command):
    project = @catalog.require_project(current, id)
    response = null
    try: response = @notebooks.call("receipt.get", {project_id: project[:core_project_id], command_id: command_id(command)}, execution: true)[:response]
    rescue WebError |error|: raise error unless error.status == 404
    accepted = response and response[?:history_run] and ["updated", "deleted"].include?(response[?:operation])
    {command: {state: if accepted then "accepted" else "unknown"}}
