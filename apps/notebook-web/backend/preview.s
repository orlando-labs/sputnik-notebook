package preview

from models import WebError, NotFound, InvalidInput
from notebook.core.common import APIError
from execution import Execution
from resources import Resources

export PreviewSessions

# This adapter is authenticated today. A future public page must choose a
# server-owned template/principal before calling open; browsers never choose a
# core ID, policy profile or billing user. Session documents are never imported
# into the user's catalog and their lease is renewed only by explicit heartbeats.
class PreviewSessions:
  def init(@catalog, @notebooks, @database): @execution = Execution(@catalog, @notebooks)

  def aggregate_user?(): false

  def resources(policy): Resources(@catalog, @notebooks).present(policy, aggregate_user: aggregate_user?())

  def open(current, id):
    project = @catalog.require_project(current, id, capability: :execute)
    accepted = @notebooks.call("session.open", {source_project: project[:core_project_id], user_id: current[:id], profile: "public"}, execution: true)
    session = SecureRandom.hex(32)
    @database.with_connection |db|:
      db.execute("DELETE FROM preview_sessions WHERE expires<?", params: [Time.now.unix_milliseconds])
      db.execute("INSERT INTO preview_sessions VALUES(?,?,?,?,?)", params: [session, current[:id], id, accepted[:project_id], Time.now.unix_milliseconds + accepted[:policy][:effective][:lease_seconds] * 1000])
    {session_id: session, revision: accepted[:revision], policy: accepted[:policy][:effective], spent_ms: 0, resources: resources(accepted[:policy]), lease_seconds: accepted[:policy][:effective][:lease_seconds]}

  def owned(current, session):
    raise NotFound() unless Str === session and session.length == 64 and session.chars.all? |c|: "0123456789abcdef".contains?(c)
    @catalog.account(current[:id])
    row = null
    @database.with_connection |db|:
      rows = db.query("SELECT * FROM preview_sessions WHERE id=? AND account_id=? AND expires>?", params: [session, current[:id], Time.now.unix_milliseconds])
      row = rows[0] unless rows.empty?
    raise NotFound() unless row
    @catalog.require_project(current, row[:template_id], capability: :execute)
    row

  def read(current, session):
    row = owned(current, session)
    document = @notebooks.call("project.get", {project_id: row[:core_project_id]}, execution: true)
    policy = @notebooks.call("policy.get", {project_id: row[:core_project_id]}, execution: true)
    source = @notebooks.call("run.registry", {project_id: row[:core_project_id]}, execution: true)
    values = source[:runs].map: @execution.run_summary($it)
    {notebook: @notebooks.present(document), policy: policy[:effective], spent_ms: policy[:spent_ms], runs: values, resources: resources(policy)}

  def touch(current, session, status: false):
    row = owned(current, session)
    renewed = @notebooks.call("session.touch", {project_id: row[:core_project_id], status: status}, execution: true)
    renew_expiry(session, renewed[:expires_at])
    return {renewed: true} unless status
    policy = renewed[?:policy]
    raise WebError(503, "preview_status_unavailable", "The preview status is unavailable.") unless policy
    runs = renewed[:runs].map: @execution.run_summary($it)
    {renewed: true, lease_seconds: policy[:effective][:lease_seconds], resources: resources(policy), runs: runs}

  def renew_expiry(session, expires):
    @database.with_connection |db|:
      db.execute("UPDATE preview_sessions SET expires=? WHERE id=?", params: [expires, session])

  def close(current, session):
    row = owned(current, session)
    result = @notebooks.call("session.close", {project_id: row[:core_project_id]}, execution: true)
    @database.with_connection |db|: db.execute("DELETE FROM preview_sessions WHERE id=?", params: [session])
    result

  def start(current, session, params):
    start_owned(owned(current, session), params)

  def start_owned(row, params):
    raise InvalidInput("Preview accepts Run or Run All.") unless ["run", "run_all"].include?(params[:action])
    accepted = @notebooks.call("run.start", {project_id: row[:core_project_id], command_id: params[:command_id], revision: params[:revision], sheet_id: params[:sheet_id], cell_id: params[:cell_id], action: params[:action]}, execution: true)
    {run: @execution.run_summary(@notebooks.call("run.get", {run_id: accepted[:run_id]}, execution: true))}

  def run(current, session, run):
    row = owned(current, session)
    record = @notebooks.call("run.get", {run_id: run}, execution: true)
    raise NotFound() unless record[:project] == row[:core_project_id]
    {run: @execution.presentation(record)}

  def stop(current, session, run, params):
    row = owned(current, session)
    record = @execution.owned_run(row, run)
    @notebooks.call("run.stop", {run_id: record[:id], command_id: params[:command_id], runtime_epoch: params[:runtime_epoch], force: params[:force]}, execution: true)
    {run: @execution.run_summary(@execution.owned_run(row, run))}

  def receipt(current, session, command):
    row = owned(current, session)
    record = null
    try: record = @notebooks.call("receipt.get", {project_id: row[:core_project_id], command_id: command}, execution: true)[:response]
    rescue WebError |error|:
      raise error unless error.status == 404
    return {command: {state: "unknown"}} unless record
    if record[?:run_id]:
      return {command: {state: "accepted", run: @execution.run_summary(@execution.owned_run(row, record[:run_id]))}}
    if record[?:revision]: return {command: {state: "accepted", revision: record[:revision]}}
    {command: {state: "unknown"}}

  def save(current, session, params):
    row = owned(current, session)
    raise WebError(413, "notebook_too_large", "The notebook exceeds the supported size limit.") if params[:document].bytes.count > 7340032
    original = @notebooks.call("revision.get", {project_id: row[:core_project_id], revision: params[:base_revision]}, execution: true)
    saved = @notebooks.call("project.put", {project_id: row[:core_project_id], command_id: params[:command_id], base_revision: params[:base_revision], document: params[:document], files: original[:files]}, execution: true)
    {notebook: {revision: saved[:revision], document: params[:document]}}
