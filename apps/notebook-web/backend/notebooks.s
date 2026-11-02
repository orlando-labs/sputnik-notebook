package notebooks

from notebook.core.common import APIError
from models import WebError, InvalidInput
from sources import apply_changes

export Notebooks

# The web catalog authorizes every operation before the privileged core client.
# Core IDs, storage paths and file bundles never become browser authority.
class Notebooks:
  def init(@catalog, @core)

  def presentation_bytes(record, live: false): @core.presentation_bytes(record, live: live)

  def call(method, params, execution: false):
    raise WebError(503, "notebook_unavailable", "The notebook service is unavailable. Try again shortly.") unless @core
    try:
      @core.handle(method, params)
    rescue APIError |error|:
      if execution:
        code = "execution_error"
        status = if [400, 403, 404, 409, 410, 413, 422, 429, 507].include?(error.status) then error.status else 503
        message = "The execution service is unavailable. Check status before retrying the command."
        if status == 400: message = "The execution request is invalid."
        elif status == 404: message = "The run or notebook was not found."
        elif status == 409:
          code = "execution_conflict"
          message = "The runtime or notebook has changed. Refresh its status before trying again."
          if error.message == "run requires current active project revision":
            code = "execution_revision_conflict"
            message = "The saved notebook has changed. Reload it before running."
          elif error.message == "run metadata changed; reload history":
            code = "history_conflict"
            message = "Run labels changed. Your draft is kept; reload the snapshot before trying again."
          elif error.message == "current or active presentation is protected":
            message = "This run is the current retained presentation. Run again before deleting this result."
          elif error.message == "unpin the run before deleting it":
            message = "Unpin the run before deleting it."
          elif error.message == "at most ten runs can be pinned":
            message = "At most ten runs can be pinned. Unpin a run first."
          elif error.message == "runtime busy":
            code = "runtime_busy"
            message = "This sheet is already running. Wait for it or stop its current run."
          elif ["input version changed; reload inputs", "cell input version changed; reload inputs"].include?(error.message):
            code = "input_version_conflict"
            message = "Parameters changed on the server. Your draft is kept; reset to current values before applying again."
          elif error.message == "project revision conflict":
            code = "input_revision_conflict"
            message = "The saved notebook has changed. Reload it before applying parameters."
          elif error.message == "stale runtime epoch":
            code = "runtime_epoch_conflict"
            message = "The worker has changed. Refresh its status before trying again."
          elif ["worker environment changed; explicit runtime restart required", "runtime interrupted; explicit restart required", "environment changed; explicit runtime restart required"].include?(error.message):
            code = "runtime_restart_required"
            message = "Restart the worker before running this sheet again."
          elif error.message == "stop active runs before changing dependencies":
            code = "dependency_active_run"
            message = "Stop active runs before installing or removing packages."
          elif ["a dependency operation is already running", "dependencies are being changed; wait for installation to finish"].include?(error.message):
            code = "dependency_busy"
            message = "A dependency operation is running. Wait for it to finish."
        elif status == 403:
          code = "execution_budget_exhausted"
          message = "The execution time budget is exhausted. Review resource limits; owner and server budgets also apply to new temporary copies."
        elif status == 410:
          code = "execution_expired"
          message = "The temporary session or command receipt has expired. Open a fresh session; the old command will not run again."
        elif status == 507:
          code = "execution_storage_limit"
          message = "The server storage limit is reached. Remove old history or ask the operator to change its policy."
        elif status == 413: message = "The execution result exceeds the supported size limit."
        elif status == 422:
          message = if method == "media.source" then "The completed source is unavailable or exceeds its supported limit. Run the saved cell or apply an audio input first." else "The operation or parameter values are invalid. Check types, bounds, available choices and config syntax."
        elif status == 429: message = "The execution service is busy. Try again after another run finishes."
        raise WebError(status, code, message)
      messages = {
        400: "The notebook document is invalid.",
        404: "The notebook or revision was not found.",
        409: "The notebook has changed. Your draft is kept; reload the saved version before editing again.",
        413: "The notebook exceeds the supported size limit.",
        422: "This notebook operation is not supported.",
        507: "The notebook storage limit has been reached."
      }
      status = if messages[?error.status] then error.status else 503
      message = messages[?status] or "The notebook service is unavailable. Try again shortly."
      raise WebError(status, if status == 409 then "notebook_conflict" else "notebook_error", message)
    rescue Exception:
      raise WebError(503, "notebook_unavailable", "The notebook service is unavailable. Try again shortly.")

  def present(record):
    unless record[:state] == "active":
      raise WebError(409, "notebook_retired", "This notebook is no longer active.")
    {revision: record[:head], document: record[:document]}

  def read(current, id):
    project = @catalog.require_project(current, id)
    try:
      {notebook: present(call("project.get", {project_id: project[:core_project_id]}))}
    rescue WebError |error|:
      raise error unless error.status == 404
      {notebook: null}

  def create(current, id):
    project = @catalog.require_project(current, id, capability: :write)
    if @catalog.presentation(current, project)[:import_pending]:
      raise WebError(409, "import_pending", "Resume the pending import with the original notebook file.")
    core_id = project[:core_project_id]
    try:
      return {notebook: present(call("project.get", {project_id: core_id}))}
    rescue WebError |error|:
      raise error unless error.status == 404
    document = Json.generate({format: "sputnik-notebook", version: 1, title: project[:title], active_sheet: "main",
      sheets: [{id: "main", title: "Main", cells: [{id: "1", kind: "code", source: "", mode: "manual"}]}],
      modules: [], auto_imports: []})
    try:
      call("project.put", {project_id: core_id, command_id: "web-initialize", base_revision: null, document: document, files: {}})
    rescue WebError |error|:
      # Two first-open requests can race. Initialization never replaces a head.
      raise error unless error.status == 409
    {notebook: present(call("project.get", {project_id: core_id}))}

  def save(current, id, command, base, document, changes = {}):
    project = @catalog.require_project(current, id, capability: :write)
    valid_command = command.length > 0 and command.length <= 128 and command.chars.all? |c|:
      "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-".contains?(c)
    raise InvalidInput("Invalid notebook command ID.") unless valid_command
    valid_base = base.length == 64 and base.chars.all? |c|:
      "abcdef0123456789".contains?(c)
    raise InvalidInput("Invalid notebook revision.") unless valid_base
    raise WebError(413, "notebook_too_large", "The notebook exceeds the supported size limit.") if document.bytes.count > 7340032
    core_id = project[:core_project_id]
    # Merge bounded member edits into the exact base, preserving every other
    # bundled file. Core validates and commits the document and files together.
    original = call("revision.get", {project_id: core_id, revision: base})
    files = apply_changes(original[:files], changes)
    result = call("project.put", {project_id: core_id, command_id: command, base_revision: base,
      document: document, files: files})
    {notebook: {revision: result[:revision], document: document}}
