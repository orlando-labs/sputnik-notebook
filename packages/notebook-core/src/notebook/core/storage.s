package notebook.core.storage

from notebook.core.common import fail, identifier, terminal?
from notebook.core.host import storage_available, storage_bytes

export Storage

# All calls run under the Core owner lock. Metadata is deleted before files;
# the durable deletion queue keeps failed/crash-interrupted unlinks retryable.
class Storage:

  def init(@core, @policies):
    @core.schema("""
      CREATE TABLE IF NOT EXISTS run_storage(seq INTEGER PRIMARY KEY AUTOINCREMENT,run TEXT UNIQUE,created INTEGER NOT NULL,artifact_bytes INTEGER NOT NULL DEFAULT 0,live_bytes INTEGER NOT NULL DEFAULT 0);
      CREATE TABLE IF NOT EXISTS revision_storage(revision TEXT PRIMARY KEY,created INTEGER NOT NULL,bytes INTEGER NOT NULL);
      CREATE TABLE IF NOT EXISTS receipt_storage(project TEXT,command TEXT,created INTEGER NOT NULL,PRIMARY KEY(project,command));
      CREATE TABLE IF NOT EXISTS run_heads(project TEXT,owner TEXT,latest TEXT,presentation TEXT,PRIMARY KEY(project,owner));
      CREATE TABLE IF NOT EXISTS runtime_resets(project TEXT,epoch TEXT,PRIMARY KEY(project,epoch));
      CREATE TABLE IF NOT EXISTS storage_deletions(path TEXT PRIMARY KEY,project TEXT,bytes INTEGER NOT NULL);
      CREATE INDEX IF NOT EXISTS runs_owner ON runs(project,sheet_id);
      CREATE INDEX IF NOT EXISTS runtimes_owner ON runtime_records(project,sheet_id);
      CREATE INDEX IF NOT EXISTS events_project ON events(project,seq);
    """)
    # An old database has no timestamps. Start its age clock at migration; count
    # and byte limits still apply immediately. Existing command IDs stay inert.
    @core.transaction:
      @core.rows("SELECT id FROM runs WHERE id NOT IN (SELECT run FROM run_storage) ORDER BY rowid").each |record|:
        @core.sql("INSERT INTO run_storage(run,created,artifact_bytes,live_bytes) VALUES(?,?,?,?)", [record[:id], now(), file_bytes("runs/" + record[:id] + ".bin"), file_bytes("runs/" + record[:id] + ".live.bin")])
      @core.rows("SELECT id,directory FROM revisions WHERE id NOT IN (SELECT revision FROM revision_storage)").each |record|:
        @core.sql("INSERT INTO revision_storage VALUES(?,?,?)", [record[:id], now(), storage_bytes(record[:directory]) + file_bytes("revisions/" + record[:id] + ".manifest.json")])
      @core.sql("INSERT OR IGNORE INTO receipt_storage SELECT project,command,? FROM receipts", [now()])
      @core.sql("INSERT OR IGNORE INTO runtime_resets SELECT project,json_extract(response,'$.reset_epoch') FROM receipts WHERE response IS NOT NULL AND json_extract(response,'$.reset_epoch') IS NOT NULL")
      @core.sql("INSERT OR IGNORE INTO runtime_resets SELECT project,epoch FROM dependency_resets")
      @core.sql("INSERT OR IGNORE INTO run_heads(project,owner,latest) SELECT project,sheet_id,id FROM runs WHERE rowid IN (SELECT MAX(rowid) FROM runs GROUP BY project,sheet_id)")
      @core.sql("UPDATE run_heads SET presentation=(SELECT id FROM runs WHERE project=run_heads.project AND sheet_id=run_heads.owner AND presentation IS NOT NULL ORDER BY rowid DESC LIMIT 1) WHERE presentation IS NULL")
    @core.rows("SELECT run FROM run_storage").each |record|:
      @core.sql("UPDATE run_storage SET artifact_bytes=?,live_bytes=? WHERE run=?", [file_bytes("runs/" + record[:run] + ".bin"), file_bytes("runs/" + record[:run] + ".live.bin"), record[:run]])
      if @core.row("SELECT id FROM runs WHERE id=? AND state IN ('succeeded','failed','cancelled','force-stopped','interrupted')", [record[:run]]):
        @core.transaction: terminal(record[:run])
    @next_gc = 0

  def now(): Time.now.unix_seconds
  def file_bytes(relative):
    path = @core.root + "/" + relative
    if fs.exists?(path) then storage_bytes(path) else 0

  def scalar(sql, values = []): @core.row(sql, values)[:n]
  def used(project = null):
    where = if project then " WHERE project=?" else ""
    params = if project then [project] else []
    runs = scalar("SELECT COALESCE(SUM(COALESCE(length(CAST(i.document AS BLOB)),0)+COALESCE(length(CAST(r.result_json AS BLOB)),0)+COALESCE(length(CAST(r.live_json AS BLOB)),0)+length(CAST(r.error AS BLOB))+s.artifact_bytes+s.live_bytes+1024),0) AS n FROM runs r JOIN run_storage s ON s.run=r.id LEFT JOIN run_inputs i ON i.run=r.id" + (if project then " WHERE r.project=?" else ""), params)
    revisions = scalar("SELECT COALESCE(SUM(s.bytes+length(CAST(r.document AS BLOB))+512),0) AS n FROM revisions r JOIN revision_storage s ON s.revision=r.id" + (if project then " WHERE r.project=?" else ""), params)
    receipts = scalar("SELECT COALESCE(SUM(COALESCE(length(CAST(response AS BLOB)),0)+length(command)+length(digest)+256),0) AS n FROM receipts" + where, params)
    events = scalar("SELECT COALESCE(SUM(length(CAST(payload AS BLOB))+128),0) AS n FROM events" + where, params)
    services = scalar("SELECT COALESCE(SUM(length(CAST(state AS BLOB))+256),0) AS n FROM services" + where, params)
    pending = scalar("SELECT COALESCE(SUM(bytes),0) AS n FROM storage_deletions" + where, params)
    history = scalar("SELECT COALESCE(SUM(length(CAST(m.title AS BLOB))+length(m.version)+128),0) AS n FROM run_metadata m JOIN runs r ON r.id=m.run" + (if project then " WHERE r.project=?" else ""), params)
    provenance = scalar("SELECT COALESCE(SUM(length(CAST(p.payload AS BLOB))+128),0) AS n FROM run_provenance p JOIN runs r ON r.id=p.run" + (if project then " WHERE r.project=?" else ""), params)
    runs + revisions + receipts + events + services + pending + history + provenance

  def active(project = null):
    scalar("SELECT COUNT(*) AS n FROM runs WHERE state NOT IN ('succeeded','failed','cancelled','force-stopped','interrupted')" + (if project then " AND project=?" else ""), if project then [project] else [])

  def reservations(project = null):
    scalar("SELECT COALESCE(SUM(json_extract(limits,'$.max_run_bytes')),0) AS n FROM run_usage WHERE active=1" + (if project then " AND project=?" else ""), if project then [project] else [])

  def check_space(project, extra, run: false):
    policy = @policies.effective(project)
    fail(507, "Remote project storage limit reached; remove old history or increase the storage policy") if used(project) + reservations(project) + extra > (if policy[:project_bytes] < policy[:total_bytes] then policy[:project_bytes] else policy[:total_bytes])
    fail(507, "Remote agent storage limit reached; remove old history or increase the storage policy") if used() + reservations() + extra > @policies.effective(null)[:total_bytes]
    fail(507, "Remote disk reserve reached; free server disk space before starting more work") if storage_available(@core.root) < policy[:minimum_free_bytes] + reservations() + extra
    @policies.storage_scopes(project).each |group|:
      if group[:projects]:
        consumed = 0
        group[:projects].each |member|: consumed += used(member) + reservations(member)
        fail(507, "Remote user storage limit reached") if consumed + extra > group[:limit]
    if run:
      count = scalar("SELECT COUNT(*) AS n FROM runs WHERE project=?", [project])
      fail(507, "Remote run retention limit is occupied by protected results or active runs") if count >= policy[:run_count]

  def prepare(project, bytes):
    policy = @policies.effective(project)
    fail(413, "Run input document exceeds max_run_bytes") if bytes > policy[:max_run_bytes]
    collect(project, incoming: policy[:max_run_bytes] + bytes, slots: 1)
    check_space(project, policy[:max_run_bytes] + bytes, run: true)

  def admit(project, document):
    policy = @policies.effective(project)
    # Called inside the dispatch transaction: multi-sheet inputs reserve every
    # accepted run, and a rollback launches none of them. No file deletion here.
    fail(413, "Run input document exceeds max_run_bytes") if document.bytes.count > policy[:max_run_bytes]
    check_space(project, policy[:max_run_bytes] + document.bytes.count, run: true)

  def record(plan):
    @core.sql("INSERT INTO run_storage(run,created) VALUES(?,?)", [plan[:id], now()])
    @core.sql("INSERT INTO run_heads(project,owner,latest) VALUES(?,?,?) ON CONFLICT(project,owner) DO UPDATE SET latest=excluded.latest", [plan[:project], plan[:runtime].sheet, plan[:id]])

  def remember(project, command, response):
    @core.sql("INSERT INTO receipt_storage VALUES(?,?,?)", [project, command, now()])
    if response[?:reset_epoch]: @core.sql("INSERT OR IGNORE INTO runtime_resets VALUES(?,?)", [project, response[:reset_epoch]])

  def revision(id, directory):
    @core.sql("INSERT OR IGNORE INTO revision_storage VALUES(?,?,?)", [id, now(), storage_bytes(directory) + file_bytes("revisions/" + id + ".manifest.json")])

  def output(run, text, binary, live: false):
    record = @core.run(run)
    policy = @policies.effective(record[:project])
    bytes = binary.count + text.bytes.count + (record[:execution_document] or "").bytes.count
    bytes += scalar("SELECT artifact_bytes AS n FROM run_storage WHERE run=?", [run]) if live
    fail(507, "Run result exceeds max_run_bytes; reduce output or increase the storage policy") if bytes > policy[:max_run_bytes]
    fail(507, "Remote disk reserve reached while publishing a result") if storage_available(@core.root) < policy[:minimum_free_bytes] + binary.count + text.bytes.count

  def published(run, bytes, live: false):
    @core.sql("UPDATE run_storage SET " + (if live then "live_bytes" else "artifact_bytes") + "=? WHERE run=?", [bytes, run])
    unless live:
      @core.sql("UPDATE run_heads SET presentation=? WHERE latest=?", [run, run])

  def terminal(run):
    bytes = scalar("SELECT live_bytes AS n FROM run_storage WHERE run=?", [run])
    project = @core.row("SELECT project FROM runs WHERE id=?", [run])[:project]
    @core.sql("UPDATE runs SET live_json=NULL WHERE id=?", [run])
    @core.sql("UPDATE run_storage SET live_bytes=0 WHERE run=?", [run])
    queue("runs/" + run + ".live.bin", project, bytes)

  def queue(path, project, bytes): @core.sql("INSERT OR IGNORE INTO storage_deletions VALUES(?,?,?)", [path, project, bytes])
  def drain():
    @core.rows("SELECT path FROM storage_deletions").each |record|:
      relative = record[:path]
      # Queue paths are constructed internally from validated IDs, never from
      # artifact locations in a remote request or an old metadata row.
      fail(500, "invalid storage deletion path") unless ["runs", "revisions", "runtimes", "projects"].include?(relative.split("/")[0]) and relative.split("/").count == 2 and not relative.contains?("..")
      path = @core.root + "/" + relative
      @core.remove_tree(path) if fs.exists?(path)
      @core.sql("DELETE FROM storage_deletions WHERE path=?", [relative])

  def protected_ids(project):
    @core.rows("SELECT latest AS id FROM run_heads WHERE project=? UNION SELECT presentation AS id FROM run_heads WHERE project=? AND presentation IS NOT NULL UNION SELECT r.id FROM runs r JOIN run_metadata m ON m.run=r.id WHERE r.project=? AND m.pinned=1 UNION SELECT id FROM runs WHERE project=? AND state NOT IN ('succeeded','failed','cancelled','force-stopped','interrupted')", [project, project, project, project]).map: $it[:id]

  def drop_run(record):
    id = record[:id]
    @core.transaction:
      queue("runs/" + id + ".bin", record[:project], record[:artifact_bytes])
      queue("runs/" + id + ".live.bin", record[:project], record[:live_bytes])
      # Retain command identity/digest, but stop promising a recoverable result
      # once its run has expired. Old commands return 410 and never execute.
      @core.sql("UPDATE receipts SET response=NULL WHERE project=? AND (json_extract(response,'$.run_id')=? OR EXISTS (SELECT 1 FROM json_each(response,'$.run_ids') WHERE value=?))", [record[:project], id, id])
      ["run_inputs", "run_targets", "run_metadata", "run_provenance"].each: @core.sql("DELETE FROM " + $it + " WHERE run=?", [id])
      @core.sql("DELETE FROM runs WHERE id=?", [id])
      @core.sql("DELETE FROM run_storage WHERE run=?", [id])
      @core.sql("DELETE FROM run_usage WHERE run=? AND active=0", [id])

  def collect(project = null, incoming: 0, slots: 0):
    sweep_orphans()
    drain()
    projects = if project then [{id: project}] else @core.rows("SELECT id FROM projects")
    if project:
      @policies.storage_scopes(project).each |group|:
        if group[:projects]:
          projects = group[:projects].map |id|: {id: id}
    removed = 0
    projects.each |entry|:
      id = entry[:id]
      policy = @policies.effective(id)
      desired_slots = if id == project then slots else 0
      project_incoming = if id == project then incoming else 0
      user_groups = []
      @policies.storage_scopes(id).each |group|:
        if group[:projects]:
          consumed = 0
          group[:projects].each |member|: consumed += used(member) + reservations(member)
          user_groups.push!({used: consumed, limit: group[:limit]})
      protected = protected_ids(id)
      count = scalar("SELECT COUNT(*) AS n FROM runs WHERE project=?", [id])
      project_used = used(id)
      total_used = used()
      reserved_project = reservations(id)
      reserved_total = reservations()
      candidates = @core.rows("SELECT r.id,r.project,s.created,s.artifact_bytes,s.live_bytes,COALESCE(length(CAST(i.document AS BLOB)),0)+COALESCE(length(CAST(r.result_json AS BLOB)),0)+COALESCE(length(CAST(r.live_json AS BLOB)),0)+length(CAST(r.error AS BLOB))+s.artifact_bytes+s.live_bytes+1024 AS bytes FROM runs r JOIN run_storage s ON s.run=r.id LEFT JOIN run_inputs i ON i.run=r.id WHERE r.project=? AND r.state IN ('succeeded','failed','cancelled','force-stopped','interrupted') ORDER BY s.seq", [id])
      candidates.each |record|:
        next if protected.include?(record[:id])
        over = project_used + reserved_project + project_incoming > (if policy[:project_bytes] < policy[:total_bytes] then policy[:project_bytes] else policy[:total_bytes]) or total_used + reserved_total + incoming > @policies.effective(null)[:total_bytes]
        over = over or user_groups.any? |group|: group[:used] + incoming > group[:limit]
        if count + desired_slots > policy[:run_count] or record[:created] < now() - policy[:run_age_seconds] or over:
          drop_run(record)
          drain()
          reclaimed = project_used - used(id)
          project_used -= reclaimed
          total_used -= reclaimed
          user_groups.each |group|:
            group[:used] = group[:used] - reclaimed
          count -= 1
          removed += 1
      # Keep current head, all revisions used by retained runs/live workers, and
      # a recent revision tail. No document required for reconnect is removed.
      revisions = @core.rows("SELECT r.id,r.directory,s.bytes FROM revisions r JOIN revision_storage s ON s.revision=r.id WHERE r.project=? ORDER BY s.created DESC,r.rowid DESC", [id])
      revisions.each_with_index |record, index|:
        next if index < policy[:revision_count]
        next if @core.row("SELECT id FROM projects WHERE head=? UNION SELECT id FROM runs WHERE revision=?", [record[:id], record[:id]])
        next if @core.runtime_revision?(record[:id])
        @core.transaction:
          queue("revisions/" + record[:id], id, record[:bytes])
          queue("revisions/" + record[:id] + ".manifest.json", id, 0)
          @core.sql("UPDATE receipts SET response=NULL WHERE project=? AND json_extract(response,'$.revision')=?", [id, record[:id]])
          @core.sql("DELETE FROM revisions WHERE id=?", [record[:id]])
          @core.sql("DELETE FROM revision_storage WHERE revision=?", [record[:id]])
      @core.rows("SELECT id FROM runtime_records WHERE project=? AND state IN ('terminated','interrupted') AND id NOT IN (SELECT runtime_id FROM runs WHERE project=?) AND rowid NOT IN (SELECT MAX(rowid) FROM runtime_records WHERE project=? GROUP BY sheet_id)", [id, id, id]).each |record|:
        next if @core.runtime_owned?(record[:id])
        @core.transaction:
          queue("runtimes/" + record[:id], id, file_bytes("runtimes/" + record[:id]))
          @core.sql("DELETE FROM runtime_records WHERE id=?", [record[:id]])
      @core.transaction:
        @core.sql("DELETE FROM events WHERE project=? AND seq NOT IN (SELECT seq FROM events WHERE project=? ORDER BY seq DESC LIMIT ?)", [id, id, policy[:event_count]])
        @core.sql("UPDATE receipts SET response=NULL WHERE project=? AND command IN (SELECT command FROM receipt_storage WHERE project=? AND created<?) AND NOT EXISTS (SELECT 1 FROM runs WHERE runs.project=receipts.project AND runs.state NOT IN ('succeeded','failed','cancelled','force-stopped','interrupted') AND (runs.id=json_extract(receipts.response,'$.run_id') OR runs.id IN (SELECT value FROM json_each(receipts.response,'$.run_ids'))))", [id, id, now() - policy[:receipt_age_seconds]])
        @core.sql("DELETE FROM dependency_resets WHERE project=? AND epoch NOT IN (SELECT epoch FROM runs WHERE project=?)", [id, id])
        @core.sql("DELETE FROM runtime_resets WHERE project=? AND epoch NOT IN (SELECT epoch FROM runs WHERE project=?)", [id, id])
    drain()
    {removed_runs: removed, pending_deletions: scalar("SELECT COUNT(*) AS n FROM storage_deletions")}

  def tick():
    return null if now() < @next_gc
    @next_gc = now() + @policies.effective(null)[:gc_interval_seconds]
    collect()

  def status(project):
    {policy: @policies.effective(project), project_bytes: used(project), total_bytes: used(), available_bytes: storage_available(@core.root),
      active_runs: active(project), retained_runs: scalar("SELECT COUNT(*) AS n FROM runs WHERE project=?", [project])}


  def purge(project):
    fail(409, "temporary project still has runtime owners") if @core.owners_pending?(project)
    @core.transaction:
      @core.rows("SELECT r.id,r.project,s.artifact_bytes,s.live_bytes FROM runs r JOIN run_storage s ON s.run=r.id WHERE r.project=?", [project]).each |record|:
        queue("runs/" + record[:id] + ".bin", project, record[:artifact_bytes])
        queue("runs/" + record[:id] + ".live.bin", project, record[:live_bytes])
      @core.rows("SELECT id FROM revisions WHERE project=?", [project]).each |record|:
        queue("revisions/" + record[:id], project, file_bytes("revisions/" + record[:id]))
        queue("revisions/" + record[:id] + ".manifest.json", project, 0)
      @core.rows("SELECT id FROM runtime_records WHERE project=?", [project]).each |record|:
        queue("runtimes/" + record[:id], project, file_bytes("runtimes/" + record[:id]))
      ["run_inputs", "run_targets", "run_metadata", "run_provenance"].each: @core.sql("DELETE FROM " + $it + " WHERE run IN (SELECT id FROM runs WHERE project=?)", [project])
      @core.sql("DELETE FROM run_storage WHERE run IN (SELECT id FROM runs WHERE project=?)", [project])
      @core.sql("DELETE FROM revision_storage WHERE revision IN (SELECT id FROM revisions WHERE project=?)", [project])
      ["runs", "run_heads", "run_usage", "revisions", "runtime_records", "receipts", "receipt_storage", "events", "services", "cell_inputs", "worker_settings", "worker_environments", "tombstones", "runtime_resets", "dependency_resets"].each:
        @core.sql("DELETE FROM " + $it + " WHERE project=?", [project])
      @core.sql("DELETE FROM projects WHERE id=?", [project])
      @core.sql("DELETE FROM policy_usage WHERE kind='project' AND id=?", [project])
      @core.sql("DELETE FROM policy_projects WHERE project=?", [project])
      @core.sql("DELETE FROM policy_scopes WHERE kind='project' AND id=?", [project])
      queue("projects/" + project, project, file_bytes("projects/" + project))
    drain()


  def sweep_orphans():
    # A crash between atomic file publication and SQLite commit can leave an
    # unreferenced file. Only the leased Core writes these private namespaces.
    @core.transaction:
      fs.entries(@core.root + "/runs").each |path|:
        next unless fs.metadata(path).file? and not fs.metadata(path).symlink?
        name = path.basename
        id = null
        if name.ends_with?(".live.bin"): id = name.slice(0...(name.length - 9))
        elif name.ends_with?(".bin"): id = name.slice(0...(name.length - 4))
        next unless id
        next if @core.row("SELECT id FROM runs WHERE id=?", [id])
        queue("runs/" + name, "@orphan", storage_bytes(path.to_str))
      fs.entries(@core.root + "/revisions").each |path|:
        name = path.basename
        id = if name.ends_with?(".manifest.json") then name.slice(0...(name.length - 14)) else name
        info = fs.metadata(path)
        next if info.symlink?
        next if name.ends_with?(".manifest.json") and not info.file?
        next if not name.ends_with?(".manifest.json") and not info.dir?
        next if @core.row("SELECT id FROM revisions WHERE id=?", [id])
        next unless name.starts_with?("staging-") or name.starts_with?("check-") or (id.length == 64 and id.chars.all? |c|: "0123456789abcdef".contains?(c))
        queue("revisions/" + name, "@orphan", storage_bytes(path.to_str))
