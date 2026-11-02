package environments

from models import WebError, InvalidInput, NotFound
from sources import command_id

export Environments, web_grants

# Only capability names can enter the web policy. Targets and server paths are
# never authored by a browser. Existing operator-only grants stay on the server.
def web_grants(text):
  values = if text == "" then [] else text.split(",").map: $it.trim
  known = ["net.connect", "net.listen", "time.now", "random.secure", "ffi.call", "ffi.load", "process.spawn", "fs.read", "fs.write", "fs.metadata"]
  raise ArgumentError("Invalid web worker grant policy") unless values.all? |item|: known.include?(item)
  values.uniq.sorted.map: $it + "=*"

class Environments:
  def init(@catalog, @notebooks, @prepare = false, @grants = [])

  def summary(record):
    state = record[:state]
    spec = Json.parse(record[:spec])
    message = "Ready for an explicit worker reset. Existing workers keep their environment until reset."
    if state == "failed": message = "Environment preparation failed. The server operator can inspect installer logs. Retry is explicit."
    elif state == "interrupted": message = "The server restarted during preparation. Retry explicitly to create a new attempt."
    elif state == "queued": message = "Preparation is queued on the server."
    elif state == "installing": message = "The server is preparing an immutable environment generation."
    {id: record[:id], state: state, created_at: record[:created], python: spec[?:python] != null, ruby: spec[?:ruby] != null, message: message}

  def state(current, id):
    project = @catalog.require_project(current, id)
    head = @notebooks.call("project.get", {project_id: project[:core_project_id]})
    records = @notebooks.call("environment.list", {project_id: project[:core_project_id]})[:environments]
    {revision: head[:head], can_manage: @catalog.role(current, project) == "owner", preparation_allowed: @prepare,
      environments: records.reversed.take(100).map: summary($it)}

  def details(current, id, environment):
    project = @catalog.require_project(current, id)
    record = @notebooks.call("environment.get", {project_id: project[:core_project_id], environment_id: command_id(environment)})
    raise NotFound() unless record[:project] == project[:core_project_id]
    # Installer output can contain credentials, URLs and absolute paths. Return
    # bounded fixed diagnostics; raw logs remain available only to the operator.
    {environment: summary(record), diagnostics: [summary(record)[:message]],
      installer_output_available: (record[?:stdout] or "") != "" or (record[?:stderr] or "") != ""}

  def prepare(current, id, command, revision, retry):
    project = @catalog.require_project(current, id, capability: :manage)
    raise WebError(403, "environment_preparation_disabled", "Environment preparation is disabled by the server operator.") unless @prepare
    result = @notebooks.call("environment.prepare", {project_id: project[:core_project_id], command_id: command_id(command), revision: revision, retry: retry}, execution: true)
    {environment: if result[?:spec] then summary(result) else {id: null, state: "ready", message: "The saved notebook has no Python or Ruby environment manifest."}}

  def settings(current, id, sheet):
    project = @catalog.require_project(current, id)
    sheet = command_id(sheet)
    head = @notebooks.call("project.get", {project_id: project[:core_project_id]})
    raise NotFound() unless Json.parse(head[:document])[:sheets].any? |item|: item[:id] == sheet
    value = @notebooks.call("worker.settings", {project_id: project[:core_project_id], sheet_id: sheet})
    records = @notebooks.call("environment.list", {project_id: project[:core_project_id]})[:environments]
    selected = records.find |record|: record[:state] == "ready" and record[:directory] == value[:environment_directory]
    editable = value[:grants].filter: @grants.include?($it)
    {revision: head[:head], sheet_id: sheet, version: value[:version], runtime_epoch: value[:runtime_epoch],
      grants: editable, preserved_grants: value[:grants].count - editable.count,
      allowed_grants: @grants, environment_id: if selected then selected[:id] else null,
      custom_environment: value[:environment_directory] != "" and selected == null,
      can_manage: @catalog.role(current, project) == "owner"}

  def configure(current, id, params):
    project = @catalog.require_project(current, id, capability: :manage)
    sheet = command_id(params[:sheet_id])
    grants = params[:grants]
    raise InvalidInput("Select only worker grants allowed by the server operator.") unless Array === grants and grants.count <= @grants.count and grants.all? |value|: Str === value and @grants.include?(value)
    previous = @notebooks.call("worker.settings", {project_id: project[:core_project_id], sheet_id: sheet})
    directory = previous[:environment_directory]
    choice = params[:environment_id]
    if choice == "default": directory = ""
    elif choice != "keep":
      record = @notebooks.call("environment.get", {project_id: project[:core_project_id], environment_id: command_id(choice)})
      raise InvalidInput("Select a ready environment from this notebook.") unless record[:project] == project[:core_project_id] and record[:state] == "ready"
      directory = record[:directory]
    preserved = previous[:grants].filter: not @grants.include?($it)
    @notebooks.call("worker.configure", {project_id: project[:core_project_id], command_id: command_id(params[:command_id]), revision: params[:revision],
      sheet_id: sheet, base_version: params[:base_version], runtime_epoch: params[:runtime_epoch], grants: (preserved + grants).uniq.sorted, environment_directory: directory}, execution: true)
    {state: "reset"}

  def receipt(current, id, command):
    project = @catalog.require_project(current, id)
    result = null
    try: result = @notebooks.call("receipt.get", {project_id: project[:core_project_id], command_id: command_id(command)}, execution: true)[:response]
    rescue WebError |error|: raise error unless error.status == 404
    kind = if result and result[?:state] == "reset" and result[?:sheet_id] then "worker" else if result and ["ready", "queued", "installing", "failed", "interrupted"].include?(result[?:state]) then "environment" else null
    {command: {state: if kind then "accepted" else "unknown", kind: kind}}
