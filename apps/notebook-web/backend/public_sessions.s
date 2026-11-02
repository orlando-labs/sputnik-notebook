package public_sessions

from notebook.core.common import decode, digest
from models import WebError, NotFound, InvalidInput
from preview import PreviewSessions
from resources import Resources
from sources import command_id, revision_id

export PublicSessions, public_templates

# Operator-only configuration. Never accept a template path/Core identity or
# billing/policy principal from an HTTP request. Publication pins a revision.
def public_templates(path):
  return [] unless path
  decode(fs.read_text(path, limit: 65536))

class PublicSessions < PreviewSessions:
  def init(catalog, notebooks, database, templates):
    super(catalog, notebooks, database)
    raise ArgumentError("public templates must be a list of at most 16 entries") unless Array === templates and templates.count <= 16
    ids = []
    templates.each |item|:
      raise ArgumentError("invalid public template") unless Map === item
      keys = item.keys.map: _1.to_str
      raise ArgumentError("invalid public template fields") unless keys.sorted == ["id", "revision", "source_project", "title"]
      raise ArgumentError("invalid public template id") unless Str === item[:id] and item[:id].length <= 64 and item[:id].length > 0 and item[:id].chars.all? |c|: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-".contains?(c)
      raise ArgumentError("duplicate public template id") if ids.include?(item[:id])
      ids.push!(item[:id])
      raise ArgumentError("invalid public template title") unless Str === item[:title] and item[:title].length > 0 and item[:title].length <= 200 and not item[:title].contains?("\u{0}")
      command_id(item[:source_project])
      revision_id(item[:revision])
    @templates = templates

  def enabled?(): not @templates.empty?

  def listing():
    @templates.map |item|: {id: item[:id], title: item[:title]}

  def summary(project): Resources(@catalog, @notebooks).summary(project, aggregate_user: true)

  def read(visitor, token):
    result = super(visitor, token)
    {notebook: result[:notebook], runs: result[:runs], resources: result[:resources]}

  def principal(value):
    raise NotFound() unless Str === value and value.length == 64 and value.chars.all? |c|: "0123456789abcdef".contains?(c)
    "anonymous_" + value

  def open(visitor, template, command):
    user = principal(visitor)
    command_id(command)
    item = @templates.find: $it[:id] == template
    raise NotFound() unless item
    fingerprint = digest(item)
    stamp = Time.now.unix_milliseconds
    # Immediate catalog transaction serializes admission across HTTP processes.
    # A reserved Core identity makes an uncertain open retry idempotent too.
    row = @database.with_lock:
      @database.with_connection |db|:
        db.execute("DELETE FROM public_sessions WHERE created<? AND expires<?", params: [stamp - 86400000, stamp])
        found = db.query("SELECT * FROM public_sessions WHERE principal=? AND command_id=?", params: [user, command])
        if found.present?:
          existing = found[0]
          raise WebError(409, "public_open_conflict", "This opening command belongs to another template or publication.") unless existing[:fingerprint] == fingerprint
          raise WebError(410, "public_expired", "This public copy expired. Open a fresh copy.") if existing[:closed] == 1 or existing[:expires] <= stamp
          existing
        else:
          active = db.query("SELECT id FROM public_sessions WHERE closed=0 AND expires>?", params: [stamp])
          own = db.query("SELECT id FROM public_sessions WHERE principal=? AND closed=0 AND expires>?", params: [user, stamp])
          recent = db.query("SELECT id FROM public_sessions WHERE created>?", params: [stamp - 3600000])
          personal = db.query("SELECT id FROM public_sessions WHERE principal=? AND created>?", params: [user, stamp - 3600000])
          raise WebError(429, "public_busy", "A public copy is already open in this browser session. Close it or wait for its lease to expire.") unless own.empty?
          raise WebError(429, "public_busy", "Public capacity is busy. Try again later.") if active.count >= 16 or recent.count >= 120 or personal.count >= 10
          token = SecureRandom.hex(32)
          core_id = "session_" + token
          db.execute("INSERT INTO public_sessions(id,principal,command_id,template_id,fingerprint,core_project_id,created,expires) VALUES(?,?,?,?,?,?,?,?)", params: [token, user, command, template, fingerprint, core_id, stamp, stamp + 15000])
          db.query("SELECT * FROM public_sessions WHERE id=?", params: [token])[0]
    accepted = @notebooks.call("session.open", {source_project: item[:source_project], source_revision: item[:revision], session_project: row[:core_project_id], user_id: user, profile: "public"}, execution: true)
    {session_id: row[:id], revision: accepted[:revision], resources: summary(row[:core_project_id])}

  def owned(visitor, token):
    user = principal(visitor)
    raise NotFound() unless Str === token and token.length == 64 and token.chars.all? |c|: "0123456789abcdef".contains?(c)
    row = @database.with_connection |db|:
      found = db.query("SELECT * FROM public_sessions WHERE id=? AND principal=? AND closed=0 AND expires>?", params: [token, user, Time.now.unix_milliseconds])
      if found.empty? then null else found[0]
    raise NotFound() unless row
    # Removal or publication changes revoke old copies, not just future opens.
    item = @templates.find: $it[:id] == row[:template_id]
    raise NotFound() unless item and digest(item) == row[:fingerprint]
    row

  def touch(visitor, token):
    row = owned(visitor, token)
    renewed = @notebooks.call("session.touch", {project_id: row[:core_project_id]}, execution: true)
    @database.with_connection |db|:
      db.execute("UPDATE public_sessions SET expires=? WHERE id=?", params: [renewed[:expires_at], token])
    {renewed: true}

  def close(visitor, token):
    row = owned(visitor, token)
    result = {closed: true}
    try: result = @notebooks.call("session.close", {project_id: row[:core_project_id]}, execution: true)
    rescue WebError |error|: raise error unless [404, 410].include?(error.status)
    @database.with_connection |db|: db.execute("UPDATE public_sessions SET closed=1 WHERE id=?", params: [token])
    result
