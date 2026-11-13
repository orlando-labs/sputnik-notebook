package notebook.core.policy

from notebook.core.common import fail, identifier, decode

export Policies

# The authenticated adapter supplies ownership; notebook JSON and unprivileged
# request bodies never select a user or raise an operator quota. Profiles are templates;
# concrete core/user/project/session scopes own aggregate execution counters.
class Policies:
  attr defaults
  attr allow_book_policy_overrides

  def init(@core, options, @allow_book_policy_overrides):
    @defaults = {run_count: 100, run_age_seconds: 2592000, revision_count: 50,
      project_bytes: 2147483648, total_bytes: 10737418240, minimum_free_bytes: 536870912,
      max_run_bytes: 134217728, receipt_age_seconds: 2592000, event_count: 10000, gc_interval_seconds: 60,
      run_seconds: null, total_run_seconds: null, persistence: "durable", lease_seconds: 15, session_seconds: 900}
    @core.schema("""
      CREATE TABLE IF NOT EXISTS policy_scopes(kind TEXT,id TEXT,limits TEXT NOT NULL,PRIMARY KEY(kind,id));
      CREATE TABLE IF NOT EXISTS policy_projects(project TEXT PRIMARY KEY,user_id TEXT,profile TEXT,session INTEGER NOT NULL DEFAULT 0,expires INTEGER,deadline INTEGER,closed INTEGER NOT NULL DEFAULT 0);
      CREATE TABLE IF NOT EXISTS policy_usage(kind TEXT,id TEXT,milliseconds INTEGER NOT NULL,PRIMARY KEY(kind,id));
      CREATE TABLE IF NOT EXISTS run_usage(run TEXT PRIMARY KEY,project TEXT,user_id TEXT,elapsed INTEGER NOT NULL,last_at INTEGER NOT NULL,active INTEGER NOT NULL,limits TEXT NOT NULL);
      CREATE INDEX IF NOT EXISTS run_usage_active_project ON run_usage(project) WHERE active=1;
    """)
    columns = @core.rows("PRAGMA table_info(policy_projects)").map: $it[:name]
    @core.schema("ALTER TABLE policy_projects ADD COLUMN public_ip TEXT") unless columns.include?("public_ip")
    @core.sql("INSERT OR IGNORE INTO policy_scopes VALUES('profile','public',?)", [Json.generate({persistence: "session", total_run_seconds: 60, run_seconds: 60, project_bytes: 67108864, max_run_bytes: 8388608, lease_seconds: 15, session_seconds: 900})])
    fail(400, "policy configuration must be an object") unless Map === options
    options = decode(Json.generate(options))
    @core.transaction:
      if options.has_key?(:core) or options.has_key?(:users) or options.has_key?(:projects) or options.has_key?(:profiles):
        options.each |kind, values|:
          fail(400, "unknown policy section") unless ["core", "users", "projects", "profiles"].include?(kind)
          if kind == "core": configure("core", "core", values)
          else:
            fail(400, "policy section must be an object") unless Map === values
            scope = {users: "user", projects: "project", profiles: "profile"}[kind]
            values.each |id, limits|: configure(scope, id, limits)
      elif not options.empty?: configure("core", "core", options)
    @live = {}
    @supervising = false
    @fault = null
    @public_ip_cleanup_day = null
    # Reconcile the final unflushed interval conservatively after a crash. The
    # durable scope counters survive both history GC and agent restarts.
    @core.transaction:
      @core.rows("SELECT * FROM run_usage WHERE active=1").each |record|:
        charge(record, elapsed_since(record))
        @core.sql("UPDATE run_usage SET active=0 WHERE run=?", [record[:run]])
      @core.sql("UPDATE policy_projects SET closed=1 WHERE session=1")
      collect_public_ip_usage()

  def now(): Time.now.unix_milliseconds
  def monotonic(): (Time.monotonic.total_nanoseconds / 1000000).to_int
  def scope(kind, id):
    row = @core.row("SELECT limits FROM policy_scopes WHERE kind=? AND id=?", [kind, id])
    if row then decode(row[:limits]) else {}

  def configure(kind, id, limits):
    fail(400, "invalid policy scope") unless ["core", "user", "project", "profile", "desktop"].include?(kind)
    identifier(id)
    fail(400, "Core policy id must be core") if kind == "core" and id != "core"
    fail(400, "policy limits must be an object") unless Map === limits
    limits = decode(Json.generate(limits))
    limits.each |key, value|:
      if key == "public_ip_daily_seconds":
        fail(400, "public IP budget must be a positive integer of seconds on the Core scope") unless kind == "core" and Int === value and value > 0 and value <= 2147483647
        next
      if key == "public_max_active_workers":
        fail(400, "public worker limit must be an integer from 1 to 8 on the Core scope") unless kind == "core" and Int === value and value >= 1 and value <= 8
        next
      fail(400, "unknown policy limit: " + key) unless @defaults.has_key?(key)
      if key == "persistence":
        fail(400, "invalid persistence policy") unless ["durable", "session"].include?(value)
      else:
        fail(400, "policy limits must be positive integers or null") unless value == null or (Int === value and value > 0)
    @core.sql("INSERT INTO policy_scopes VALUES(?,?,?) ON CONFLICT(kind,id) DO UPDATE SET limits=excluded.limits", [kind, id, Json.generate(limits)])
    {scope: kind, id: id, limits: limits}

  def anonymous_public?(user, profile): profile == "public" and user and user.starts_with?("anonymous_")

  def public_user(user):
    # Anonymous copies share a concrete user ledger. Restrict atomically in
    # Core; reopening must never replace a tighter operator/user ceiling.
    limits = scope("user", user)
    {total_run_seconds: 60, project_bytes: 67108864, total_bytes: 67108864, max_run_bytes: 8388608, lease_seconds: 15, session_seconds: 900}.each |key, cap|:
      previous = limits[?key]
      limits[key] = cap if previous == null or previous > cap
    configure("user", user, limits)

  def merge(parent, child):
    result = decode(Json.generate(parent))
    child.each |key, value|:
      next if value == null
      if key == "persistence": result[key] = "session" if value == "session"
      elif key == "minimum_free_bytes": result[key] = value if value > result[key]
      elif result[key] == null or value < result[key]: result[key] = value
    result

  def binding(project): @core.row("SELECT * FROM policy_projects WHERE project=?", [project])
  def overlay(parent, child):
    result = decode(Json.generate(parent))
    child.each |key, value|:
      result[key] = value unless value == null
    result

  def effective(project, book: true):
    authored = {}
    current = @core.row("SELECT json_extract(r.document,'$.resource_policy') AS policy FROM projects p JOIN revisions r ON r.id=p.head WHERE p.id=?", [project])
    if current and book:
      value = current[:policy]
      fail(422, "resource_policy must be an object") if value != null and not (Str === value)
      authored = if value then decode(value) else {}
      validate_desktop(authored)
    desktop = scope("desktop", project)
    result = overlay(@defaults, scope("core", "core"))
    if @allow_book_policy_overrides:
      # Local hosts opt in explicitly. App values are defaults, then the book
      # replaces them. Explicit operator scopes below remain hard ceilings.
      result = overlay(overlay(result, desktop), authored)
      result = merge(result, scope("core", "core"))
    owner = binding(project)
    if owner and owner[:user_id]: result = merge(result, scope("user", owner[:user_id]))
    if owner and owner[:profile]: result = merge(result, scope("profile", owner[:profile]))
    result = merge(result, scope("project", project))
    unless @allow_book_policy_overrides: result = merge(merge(result, desktop), authored)
    # Public execution always has a finite, per-copy budget. Neither authored
    # metadata, app declarations nor a replaced profile may lift this ceiling.
    if owner and owner[:profile] == "public":
      result = merge(result, decode("{\"persistence\":\"session\",\"run_seconds\":60,\"total_run_seconds\":60}"))
    result

  def bind(project, user, profile = null):
    identifier(project)
    identifier(user) if user
    identifier(profile) if profile
    old = binding(project)
    fail(409, "project policy owner is immutable") if old and (old[:user_id] != user or old[:profile] != profile)
    @core.sql("INSERT INTO policy_projects(project,user_id,profile) VALUES(?,?,?)", [project, user, profile]) unless old
    {project_id: project, policy: effective(project)}

  def require_open(project):
    owner = binding(project)
    fail(410, "Temporary notebook session expired; open a fresh session") if project and project.starts_with?("session_") and not owner
    if owner and owner[:session] == 1:
      fail(410, "Temporary notebook session expired; open a fresh session") if owner[:closed] == 1 or owner[:expires] <= now() or owner[:deadline] <= now()
      fail(410, "Open a fresh public session to apply the IP execution budget") if anonymous_public?(owner[:user_id], owner[:profile]) and not owner[:public_ip]
    elif effective(project)[:persistence] == "session":
      fail(409, "This policy requires a temporary notebook session")

  def open(project, user, profile, public_ip):
    bind(project, user, profile)
    policy = effective(project)
    fail(400, "session profile must require temporary persistence") unless policy[:persistence] == "session"
    @core.sql("UPDATE policy_projects SET session=1,expires=?,deadline=?,public_ip=? WHERE project=?", [now() + policy[:lease_seconds] * 1000, now() + policy[:session_seconds] * 1000, public_ip, project])

  def touch(project):
    require_open(project)
    owner = binding(project)
    fail(400, "not a temporary session") unless owner and owner[:session] == 1
    expires = now() + effective(project)[:lease_seconds] * 1000
    @core.sql("UPDATE policy_projects SET expires=? WHERE project=?", [expires, project])
    {project_id: project, expires_at: expires}

  def close(project):
    owner = binding(project)
    fail(404, "temporary session not found") unless owner and owner[:session] == 1
    @core.sql("UPDATE policy_projects SET closed=1 WHERE project=?", [project])
    @core.policy_stop(project, "Temporary notebook session closed")
    {closed: true}

  def temporary?(project):
    owner = binding(project)
    owner != null and owner[:session] == 1

  def public_ip_day(): now() // 86400000

  def collect_public_ip_usage():
    day = public_ip_day()
    return null if day == @public_ip_cleanup_day
    @core.sql("DELETE FROM policy_usage WHERE kind='public_ip' AND CAST(substr(id,1,instr(id,':')-1) AS INTEGER)<?", [day - 1])
    @public_ip_cleanup_day = day

  def groups(project, day = null):
    limits = scope("core", "core")
    result = [{kind: "core", id: "core", limits: limits}]
    owner = binding(project)
    result.push!({kind: "user", id: owner[:user_id], limits: scope("user", owner[:user_id])}) if owner and owner[:user_id]
    if owner and owner[:public_ip]:
      bucket = (if day == null then public_ip_day() else day).to_str + ":" + owner[:public_ip]
      result.push!({kind: "public_ip", id: bucket, limits: {total_run_seconds: limits[?:public_ip_daily_seconds] or 300}})
    # A profile's total is per concrete project/session, never shared across
    # all visitors of that profile. User/core scopes can additionally cap them.
    result.push!({kind: "project", id: project, limits: effective(project)})
    result

  def spent(kind, id):
    row = @core.row("SELECT milliseconds FROM policy_usage WHERE kind=? AND id=?", [kind, id])
    if row then row[:milliseconds] else 0

  def check(project, day = null):
    fail(503, "Execution policy accounting is unavailable; work is paused") if @fault
    require_open(project)
    budgets = groups(project, day)
    budgets.each |group|:
      limit = group[:limits][?:total_run_seconds]
      fail(403, "Execution time budget exhausted for " + group[:kind]) if limit and spent(group[:kind], group[:id]) >= limit * 1000
    slots = budgets[0][:limits][?:public_max_active_workers]
    guest = budgets.find: $it[:kind] == "public_ip"
    if slots and guest:
      active = @core.row("SELECT COUNT(*) AS n FROM run_usage r JOIN policy_projects p ON p.project=r.project WHERE r.active=1 AND p.public_ip IS NOT NULL")[:n]
      fail(429, "public worker capacity reached") if active >= slots

  def start(plan):
    stamp = now()
    day = stamp // 86400000
    check(plan[:project], day)
    owner = binding(plan[:project])
    limits = effective(plan[:project])
    # A run crossing midnight is charged to the UTC day on which it was accepted.
    limits[:public_ip_day] = day if owner and owner[:public_ip]
    @core.sql("INSERT INTO run_usage VALUES(?,?,?,?,?,?,?)", [plan[:id], plan[:project], (if owner then owner[:user_id] else null), 0, stamp, 1, Json.generate(limits)])

  def launched(run): @live[run] = monotonic()
  def elapsed_since(record):
    elapsed = if @live.has_key?(record[:run]) then monotonic() - @live[record[:run]] - record[:elapsed] else now() - record[:last_at]
    if elapsed < 0 then 0 else elapsed

  def charge(record, delta):
    policy = decode(record[:limits])
    if policy[:run_seconds]:
      remaining = policy[:run_seconds] * 1000 - record[:elapsed]
      delta = if delta > remaining then remaining else delta
    delta = 0 if delta < 0
    groups(record[:project], policy[?:public_ip_day]).each |group|:
      @core.sql("INSERT INTO policy_usage VALUES(?,?,?) ON CONFLICT(kind,id) DO UPDATE SET milliseconds=milliseconds+excluded.milliseconds", [group[:kind], group[:id], delta])
    @core.sql("UPDATE run_usage SET elapsed=elapsed+?,last_at=? WHERE run=?", [delta, now(), record[:run]])

  def finished(run):
    record = @core.row("SELECT * FROM run_usage WHERE run=? AND active=1", [run])
    if record:
      charge(record, elapsed_since(record))
      @core.sql("UPDATE run_usage SET active=0 WHERE run=?", [run])

  def supervise():
    return null if @supervising
    @supervising = true
    task.async:
      loop:
        task.sleep(100)
        keep = true
        @core.synchronize:
          try:
            @core.reconcile_policy_stops()
            tick()
            keep = @core.row("SELECT run FROM run_usage WHERE active=1 LIMIT 1") != null or @core.row("SELECT project FROM policy_projects WHERE session=1 LIMIT 1") != null
            @fault = null
          rescue Exception |error|:
            @fault = error.message
            @core.policy_unavailable()
            print("execution policy supervisor deferred: " + error.message)
          @supervising = false unless keep
        break unless keep

  def tick():
    collect_public_ip_usage()
    active = @core.rows("SELECT * FROM run_usage WHERE active=1")
    live_ids = active.map: $it[:run]
    @live.keys.each |run|:
      @live.delete!(run) unless live_ids.include?(run)
    unless active.empty?:
      @core.transaction: active.each: charge($it, elapsed_since($it))
    @core.rows("SELECT * FROM run_usage WHERE active=1").each |record|:
      limits = effective(record[:project])
      reason = null
      reason = "Per-run execution time limit reached" if limits[:run_seconds] and record[:elapsed] >= limits[:run_seconds] * 1000
      groups(record[:project], decode(record[:limits])[?:public_ip_day]).each |group|:
        limit = group[:limits][?:total_run_seconds]
        reason = "Execution time budget exhausted for " + group[:kind] if limit and spent(group[:kind], group[:id]) >= limit * 1000
      @core.policy_stop(record[:project], reason, run: record[:run]) if reason
    @core.rows("SELECT * FROM policy_projects WHERE session=1").each |session|:
      if session[:closed] == 1 or session[:expires] <= now() or session[:deadline] <= now():
        @core.sql("UPDATE policy_projects SET closed=1 WHERE project=?", [session[:project]])
        @core.policy_stop(session[:project], "Temporary notebook session expired")
        @core.purge_session(session[:project])

  def status(project):
    owner = binding(project)
    {effective: effective(project), defaults: effective(project, book: false), allow_book_policy_overrides: @allow_book_policy_overrides, user_id: (if owner then owner[:user_id] else null),
      temporary: temporary?(project), spent_ms: spent("project", project),
      scopes: groups(project).map |group|: {kind: group[:kind], id: group[:id], spent_ms: spent(group[:kind], group[:id]), limits: group[:limits]}}

  def storage_scopes(project):
    result = [{projects: null, limit: effective(project)[:total_bytes]}]
    owner = binding(project)
    if owner and owner[:user_id]:
      limit = scope("user", owner[:user_id])[?:total_bytes]
      if limit:
        ids = @core.rows("SELECT project FROM policy_projects WHERE user_id=?", [owner[:user_id]]).map: $it[:project]
        result.push!({projects: ids, limit: limit})
    result


  def validate_desktop(limits):
    allowed = ["run_count", "run_age_seconds", "project_bytes", "max_run_bytes", "minimum_free_bytes", "revision_count", "run_seconds", "total_run_seconds"]
    fail(422, "desktop resource policy must be an object") unless Map === limits
    limits.each |key, value|:
      fail(422, "unsupported desktop resource policy field") unless allowed.include?(key.to_str)
      fail(422, "desktop limits must be positive integers") unless value == null or (Int === value and value > 0)

  def desktop(project, params):
    limits = params[?:limits] or {}
    validate_desktop(limits)
    @core.sql("INSERT INTO policy_scopes VALUES('desktop',?,?) ON CONFLICT(kind,id) DO UPDATE SET limits=excluded.limits", [project, Json.generate(limits)])
    status(project)
