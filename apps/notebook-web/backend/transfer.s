package transfer

from notebook.core.common import decode, digest
from notebook.core.host import book_entries, book_read, book_text
from sources import command_id, file_bytes
from models import InvalidInput, WebError

export Transfer

class Transfer:
  def init(@catalog, @notebooks)

  def unpack(archive, members):
    raise InvalidInput("Choose one notebook ZIP or folder.") unless (archive != null) != (members != null)
    entries = null
    try:
      if archive != null:
        raise InvalidInput("Invalid ZIP payload.") unless Str === archive
        entries = book_read(file_bytes(archive))
      else:
        raise InvalidInput("Invalid notebook members.") unless Array === members and members.count <= 2049
        values = members.map |member|:
          raise InvalidInput("Invalid notebook member.") unless Map === member and member.keys.all? |key|: ["path", "data"].include?(key.to_str)
          raise InvalidInput("Invalid notebook member.") unless Str === member[?:path] and Str === member[?:data]
          [member[:path], file_bytes(member[:data])]
        entries = book_entries(values)
    rescue InvalidInput |error|: raise error
    rescue Exception: raise InvalidInput("Choose a valid notebook ZIP or folder within the supported file and size limits.")
    document = null
    files = {}
    hashes = []
    entries.each |entry|:
      if entry[0] == "project.json": document = book_text(entry[1])
      else:
        files[entry[0]] = Base64.encode(entry[1])
        hashes.push!([entry[0], Digest.sha256(entry[1]).hex])
    raise InvalidInput("project.json must be valid UTF-8 text.") unless document
    checked = @notebooks.call("project.validate", {document: document, files: files})
    parsed = decode(document)
    {document: document, files: files, fingerprint: digest({document: document, files: hashes}),
      summary: {title: parsed[:title], sheets: parsed[:sheets].count, modules: (parsed[?:modules] or []).count, files: files.count, bytes: checked[:bytes]}}

  def inspect(current, archive, members):
    @catalog.account(current[:id])
    bundle = unpack(archive, members)
    {fingerprint: bundle[:fingerprint], summary: bundle[:summary]}

  def start(current, command, title, fingerprint, archive, members):
    command_id(command)
    raise InvalidInput("Import command ID is too long.") if command.length > 80
    @catalog.account(current[:id])
    bundle = unpack(archive, members)
    raise InvalidInput("Notebook contents changed. Inspect the selected file again before importing.") unless fingerprint == bundle[:fingerprint]
    record = @catalog.begin_import(current, command, fingerprint, title)
    project = @catalog.require_project(current, record[:project_id], capability: :manage)
    if record[:state] != "complete":
      @notebooks.call("project.put", {project_id: project[:core_project_id], command_id: "web-import-" + command,
        base_revision: null, document: bundle[:document], files: bundle[:files]})
      @catalog.complete_import(current, command)
    {state: "complete", project: @catalog.presentation(current, project)}

  def status(current, command):
    command_id(command)
    record = @catalog.import_record(current, command)
    return {state: "unknown"} unless record
    project = @catalog.require_project(current, record[:project_id])
    if record[:state] == "pending":
      accepted = null
      try:
        accepted = @notebooks.call("receipt.get", {project_id: project[:core_project_id], command_id: "web-import-" + command})[:response]
      rescue WebError |error|: raise error unless error.status == 404
      if accepted and accepted[?:revision]:
        record = @catalog.complete_import(current, command)
    {state: record[:state], fingerprint: record[:fingerprint], title: record[:title], project: @catalog.presentation(current, project)}
