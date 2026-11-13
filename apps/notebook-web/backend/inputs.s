package inputs

from notebook.core.common import decode
from sources import command_id, revision_id, check_guest_base64
from models import WebError, InvalidInput, NotFound

export Inputs, MediaInputs

class Inputs:
  def init(@catalog, @notebooks)

  def definitions(document, cell):
    return document[?:inputs] or [] if cell == null
    selected = null
    (document[:sheets] or []).each |sheet|:
      found = sheet[:cells].find: $it[:id] == cell and $it[:kind] == "code"
      selected = found if found
    raise NotFound() unless selected
    (selected[?:cell_ui] or {})[?:inputs] or []

  def read(current, id, cell):
    project = @catalog.require_project(current, id)
    source = @notebooks.call("project.get", {project_id: project[:core_project_id]})
    inputs = definitions(decode(source[:document]), cell)
    state = @notebooks.call("project.inputs", {project_id: project[:core_project_id]})
    values = {}
    size = 0
    inputs.each |input|:
      key = (if cell then cell else "project") + ":" + input[:id]
      value = state[:values][?key]
      if value != null:
        values[input[:id]] = value
        size += value.bytes.count
    raise WebError(413, "inputs_too_large", "These parameter values exceed the supported 8 MiB preview limit.") if size > 8388608
    {revision: source[:head], version: state[:version], values: values, can_apply: @catalog.permissions(@catalog.role(current, project))[:execute]}

  def accepted(project, response):
    return {state: "unknown"} unless Str === response[?:version] and Map === response[?:values]
    runs = response[?:run_ids] or []
    runs = [response[:run_id]] if response[?:run_id]
    runs.each |id|:
      record = @notebooks.call("run.get", {run_id: id}, execution: true)
      raise NotFound() unless record[:project] == project[:core_project_id] and record[:action] == "inputs"
    {state: "accepted", version: response[:version], run_ids: runs}

  def change(current, id, cell, command, revision, version, values):
    project = @catalog.require_project(current, id, capability: :execute)
    command_id(command)
    revision_id(revision)
    command_id(cell) if cell
    raise InvalidInput("Invalid accepted parameter version.") unless Str === version and version.length > 0 and version.length <= 128
    raise InvalidInput("Apply at most 128 parameter values together.") unless Map === values and values.count <= 128
    size = 0
    values.each |name, value|:
      raise InvalidInput("Parameter values must be exact JSON strings.") unless Str === name and name.bytes.count > 0 and name.bytes.count <= 256 and not name.contains?("\u{0}") and Str === value and value.bytes.count <= 524288
      size += value.bytes.count
    raise WebError(413, "inputs_too_large", "Apply up to 8 MiB of parameter data at a time.") if size > 8388608
    params = {project_id: project[:core_project_id], command_id: command, revision: revision, base_version: version, values: values}
    params[:cell_id] = cell if cell
    response = @notebooks.call(if cell then "cell.inputs.set" else "project.inputs.set", params, execution: true)
    {command: accepted(project, response)}

  def receipt(current, id, command):
    project = @catalog.require_project(current, id)
    response = null
    try:
      response = @notebooks.call("receipt.get", {project_id: project[:core_project_id], command_id: command_id(command)}, execution: true)[:response]
    rescue WebError |error|: raise error unless error.status == 404
    {command: if response then accepted(project, response) else {state: "unknown"}}

class MediaInputs:
  def init(@catalog, @notebooks)

  def source(current, id, revision, board, component):
    project = @catalog.require_project(current, id)
    @notebooks.call("media.source", {project_id: project[:core_project_id], revision: revision_id(revision), board_id: command_id(board), component_id: command_id(component)}, execution: true)

  def change(current, id, params):
    project = @catalog.require_project(current, id, capability: :execute)
    command_id(params[:command_id])
    revision_id(params[:revision])
    command_id(params[:board_id])
    command_id(params[:component_id])
    name = params[:name]
    raise InvalidInput("Use a file name without control characters, up to 1024 UTF-8 bytes.") if name.bytes.count > 1024 or name.contains?("\u{0}") or name.chars.any? |c|: c.bytes[0] < 32 or c.bytes[0] == 127
    check_guest_base64(params[:data]) if @catalog.guest?(current)
    response = @notebooks.call("media.accept", params.merge({project_id: project[:core_project_id]}), execution: true)
    {command: {state: "accepted", revision: response[:revision]}}

  def receipt(current, id, command):
    project = @catalog.require_project(current, id)
    response = null
    try:
      response = @notebooks.call("receipt.get", {project_id: project[:core_project_id], command_id: command_id(command)}, execution: true)[:response]
    rescue WebError |error|: raise error unless error.status == 404
    {command: if response and response[?:media_accepted] == true then {state: "accepted", revision: response[:revision]} else {state: "unknown"}}
