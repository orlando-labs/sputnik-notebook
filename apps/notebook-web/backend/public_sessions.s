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

# Orbit supplies the peer or a validated address from the trusted proxy. Convert
# it to a single representation, including IPv4-mapped IPv6, before hashing.
def ipv4(address):
  octets = address.split(".")
  return null unless octets.count == 4
  values = []
  octets.each |part|:
    return null if part.empty? or part.length > 3 or not part.contains_only?("0123456789")
    value = part.to_int
    return null if value > 255 or value.to_str != part
    values.push!(value)
  values

def ipv6_groups(side):
  return [] if side.empty?
  groups = []
  side.split(":").each |part|:
    if part.contains?("."):
      octets = ipv4(part)
      return null unless octets
      groups.push!(octets[0] * 256 + octets[1])
      groups.push!(octets[2] * 256 + octets[3])
    else:
      return null if part.empty? or part.length > 4 or not part.contains_only?("0123456789abcdef")
      value = 0
      part.chars.each |digit|:
        value = value * 16 + "0123456789abcdef".index(digit)
      groups.push!(value)
  groups

def canonical_address(address):
  return null unless Str === address and address.length <= 45
  unless address.contains?(":"):
    octets = ipv4(address)
    return octets.join(".") if octets
    return null
  sides = address.downcase.split("::")
  return null if sides.count > 2
  left = ipv6_groups(sides[0])
  right = if sides.count == 2 then ipv6_groups(sides[1]) else []
  return null unless left and right
  padding = 8 - left.count - right.count
  return null unless (sides.count == 2 and padding > 0) or (sides.count == 1 and padding == 0)
  padding.times: left.push!(0)
  groups = left + right
  if groups.take(6) == [0, 0, 0, 0, 0, 65535]:
    return [groups[6] // 256, groups[6] % 256, groups[7] // 256, groups[7] % 256].join(".")
  groups.join(":")

class PublicSessions < PreviewSessions:
  def init(catalog, notebooks, database, templates, session_secret):
    super(catalog, notebooks, database)
    @ip_secret = Digest.hmac_sha256(session_secret.bytes, "sputnik-notebook-public-ip".bytes)
    raise ArgumentError("public templates must be a list of at most 16 entries") unless Array === templates and templates.count <= 16
    @templates = {}
    templates.each |item|:
      raise ArgumentError("invalid public template") unless Map === item
      keys = item.keys.map: _1.to_str
      raise ArgumentError("invalid public template fields") unless keys.sorted == ["id", "revision", "source_project", "title"]
      raise ArgumentError("invalid public template id") unless Str === item[:id] and item[:id].length <= 64 and item[:id].length > 0 and item[:id].chars.all? |c|: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-".contains?(c)
      raise ArgumentError("duplicate public template id") if @templates.has_key?(item[:id])
      raise ArgumentError("invalid public template title") unless Str === item[:title] and item[:title].length > 0 and item[:title].length <= 200 and not item[:title].contains?("\u{0}")
      command_id(item[:source_project])
      revision_id(item[:revision])
      @templates[item[:id]] = item

  def enabled?(): not @templates.empty?

  def listing():
    @templates.values.map |item|: {id: item[:id], title: item[:title]}

  def aggregate_user?(): true

  def read(visitor, token):
    result = super(visitor, token)
    {notebook: result[:notebook], runs: result[:runs], resources: result[:resources]}

  def principal(value):
    raise NotFound() unless Str === value and value.length == 64 and value.chars.all? |c|: "0123456789abcdef".contains?(c)
    "anonymous_" + value

  def ip_key(address):
    normalized = canonical_address(address)
    raise WebError(503, "public_address_unavailable", "The public service could not determine your network address.") unless normalized
    Digest.hmac_sha256(@ip_secret, normalized.bytes).hex()

  def require_ip(row, key):
    raise WebError(410, "public_expired", "This public copy belongs to a previous network session. Open a fresh copy.") unless row[:ip_key] == key

  def open(visitor, template, command, address):
    user = principal(visitor)
    key = ip_key(address)
    command_id(command)
    item = @templates[?template]
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
          require_ip(existing, key)
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
          db.execute("INSERT INTO public_sessions(id,principal,command_id,template_id,fingerprint,core_project_id,created,expires,ip_key) VALUES(?,?,?,?,?,?,?,?,?)", params: [token, user, command, template, fingerprint, core_id, stamp, stamp + 15000, key])
          db.query("SELECT * FROM public_sessions WHERE id=?", params: [token])[0]
    accepted = @notebooks.call("session.open", {source_project: item[:source_project], source_revision: item[:revision], session_project: row[:core_project_id], user_id: user, profile: "public", public_ip: key}, execution: true)
    network = accepted[:policy][:scopes].find: $it[:kind] == "public_ip"
    raise WebError(503, "public_budget_unavailable", "The public execution budget is unavailable. Try again later.") unless network
    {session_id: row[:id], revision: accepted[:revision], resources: resources(accepted[:policy]), lease_seconds: accepted[:policy][:effective][:lease_seconds]}

  def workspace(visitor, id, address):
    row = owned(visitor, id.slice(6...id.length))
    require_ip(row, ip_key(address))
    {guest_project: {id: id, core_project_id: row[:core_project_id]}}

  def start(visitor, token, params, address):
    row = owned(visitor, token)
    require_ip(row, ip_key(address))
    start_owned(row, params)

  def owned(visitor, token):
    user = principal(visitor)
    raise NotFound() unless Str === token and token.length == 64 and token.chars.all? |c|: "0123456789abcdef".contains?(c)
    row = @database.with_connection |db|:
      found = db.query("SELECT * FROM public_sessions WHERE id=? AND principal=? AND closed=0 AND expires>?", params: [token, user, Time.now.unix_milliseconds])
      if found.empty? then null else found[0]
    raise NotFound() unless row
    # Removal or publication changes revoke old copies, not just future opens.
    item = @templates[?row[:template_id]]
    raise NotFound() unless item and digest(item) == row[:fingerprint]
    row

  def renew_expiry(token, expires):
    @database.with_connection |db|:
      db.execute("UPDATE public_sessions SET expires=? WHERE id=?", params: [expires, token])

  def close(visitor, token):
    row = owned(visitor, token)
    result = {closed: true}
    try: result = @notebooks.call("session.close", {project_id: row[:core_project_id]}, execution: true)
    rescue WebError |error|: raise error unless [404, 410].include?(error.status)
    @database.with_connection |db|: db.execute("UPDATE public_sessions SET closed=1 WHERE id=?", params: [token])
    result
