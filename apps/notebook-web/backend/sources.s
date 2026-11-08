package sources

from notebook.core.common import decode
from notebook.core.host import book_text, book_pack, book_base64?
from models import InvalidInput, NotFound, WebError

export Sources, member_path, revision_id, command_id, apply_changes, file_bytes

def command_id(value):
  raise InvalidInput("Invalid command ID.") unless Str === value and value.length > 0 and value.length <= 128 and value.chars.all? |c|:
    "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-".contains?(c)
  value

def revision_id(value):
  raise InvalidInput("Invalid notebook revision.") unless Str === value and value.length == 64 and value.chars.all? |c|: "abcdef0123456789".contains?(c)
  value

def member_path(value):
  raise InvalidInput("Invalid project file path.") unless Str === value and value.bytes.count > 0 and value.bytes.count <= 1024
  invalid = value.starts_with?("/") or value.ends_with?("/") or value.downcase == "project.json" or value.contains?("\\") or value.contains?(":")
  invalid = invalid or value.chars.any? |c|: c.bytes[0] < 32 or c.bytes[0] == 127
  invalid = invalid or value.split("/").any? |part|: ["", ".", ".."].include?(part)
  raise InvalidInput("Use a relative project file path without traversal or control characters.") if invalid
  value

def file_bytes(value):
  raise InvalidInput("Invalid file encoding.") unless Str === value and book_base64?(value)
  Base64.decode(value)

def apply_changes(original, changes):
  raise InvalidInput("Invalid project file changes.") unless Map === changes and changes.count <= 2048
  files = {}
  original.each |path, data|:
    files[path] = data
  changes.each |path, change|:
    member_path(path)
    if change == null:
      raise NotFound() unless files[?path]
      files.delete!(path)
    else:
      raise InvalidInput("Invalid file content.") unless Map === change and change.keys.all? |key|: ["encoding", "data"].include?(key.to_str)
      raise InvalidInput("Invalid file content.") unless Str === change[?:data] and ["utf8", "base64"].include?(change[?:encoding])
      bytes = null
      try: bytes = if change[:encoding] == "utf8" then change[:data].bytes else file_bytes(change[:data])
      rescue Exception: raise InvalidInput("Invalid file encoding.")
      limit = if change[:encoding] == "utf8" then 1048576 else 16777216
      raise WebError(413, "file_too_large", "Text files are limited to 1 MiB; binary members to 16 MiB.") if bytes.count > limit
      files[path] = Base64.encode(bytes)
  raise WebError(413, "bundle_too_large", "A notebook accepts up to 2048 files and 64 MiB of bundled data.") if files.count > 2048
  names = files.keys.map: $it.downcase
  raise InvalidInput("Project file paths must be unique without case differences.") unless names.uniq.count == names.count
  names.each |name|:
    parts = name.split("/")
    prefix = ""
    parts.take(parts.count - 1).each |part|:
      prefix = if prefix == "" then part else prefix + "/" + part
      raise InvalidInput("A file cannot also contain other files.") if names.include?(prefix)
  files

class Sources:
  def init(@catalog, @notebooks)

  def snapshot(current, id, revision):
    project = @catalog.require_project(current, id)
    @notebooks.call("revision.get", {project_id: project[:core_project_id], revision: revision_id(revision)})

  def index(current, id, revision):
    source = snapshot(current, id, revision)
    document = decode(source[:document])
    entries = source[:files].keys.sorted.map |path|:
      bytes = Base64.decode(source[:files][path])
      linked = (document[?:modules] or []).find: $it[:path] == path
      kind = if linked then "module" else if ["requirements.txt", "requirements.lock", "Gemfile", "Gemfile.lock"].include?(path) then "dependency" else "resource"
      {path: path, size: bytes.count, digest: Digest.sha256(bytes).hex, kind: kind, module_id: if linked then linked[:id] else null}
    {revision: revision, entries: entries}

  def read(current, id, revision, path):
    source = snapshot(current, id, revision)
    data = source[:files][?member_path(path)]
    raise NotFound() unless data
    bytes = Base64.decode(data)
    full = if bytes.count <= 1048576 then book_text(bytes) else null
    preview = full
    if preview == null:
      length = if bytes.count > 65536 then 65536 else bytes.count
      preview = book_text(bytes.slice(0, length))
      [1, 2, 3].each |tail|:
        preview = book_text(bytes.slice(0, length - tail)) if preview == null and length >= tail
    {revision: revision, path: path, size: bytes.count, text: full, preview: preview, editable: full != null,
      truncated: full == null and preview != null and bytes.count > 65536}

  def download(current, id, revision, path):
    source = snapshot(current, id, revision)
    data = source[:files][?member_path(path)]
    raise NotFound() unless data
    Base64.decode(data)

  def diagnostics(current, id, source):
    project = @catalog.require_project(current, id)
    raise InvalidInput("Module source is limited to 1 MiB.") if source.bytes.count > 1048576
    @notebooks.call("module.diagnostics", {project_id: project[:core_project_id], source: source}, execution: true)

  def archive(current, id, revision):
    source = snapshot(current, id, revision)
    entries = [["project.json", source[:document].bytes]]
    source[:files].each |path, data|: entries.push!([path, Base64.decode(data)])
    try: book_pack(entries)
    rescue Exception: raise InvalidInput("This notebook bundle cannot be exported within the supported limits.")

  def draft_archive(current, id, base, document, changes):
    source = snapshot(current, id, base)
    files = apply_changes(source[:files], changes)
    entries = [["project.json", document.bytes]]
    files.each |path, data|: entries.push!([path, Base64.decode(data)])
    try: book_pack(entries)
    rescue Exception: raise InvalidInput("This draft cannot be exported within the supported bundle limits.")

  def history(current, id, before):
    project = @catalog.require_project(current, id)
    params = {project_id: project[:core_project_id]}
    params[:before] = revision_id(before) if before
    source = @notebooks.call("revision.list", params)
    {head: source[:head], revisions: source[:revisions].map |item|: {revision: item[:revision], title: item[:title]}, next: source[:next]}
