package app

import orbit
from orbit import respond
import orbit.oauth as oauth
import orbit.session as sessions
from orbit.security import CsrfMiddleware
from orbit.assets import StaticFiles
from orbit.integrations.orm import pool as orm_pool
from models import WebError, AuthenticationRequired, InvalidInput, NotFound
import views
import layouts
from notebooks import Notebooks
from execution import Execution
from sources import Sources
from transfer import Transfer
from packages import Packages
from inputs import Inputs, MediaInputs
from preview import PreviewSessions
from public_sessions import PublicSessions
from resources import Resources
from environments import Environments
from run_history import RunHistory

export application

class Schemas:
  attr project
  attr membership
  attr notebook
  attr empty
  attr run
  attr invocation
  attr invocation_restart
  attr service_change
  attr stop
  attr restart
  attr import_inspect
  attr import_start
  attr package_change
  attr draft
  attr input_change
  attr media_change
  attr environment_prepare
  attr worker_change
  attr run_history_change
  attr public_open
  def init():
    @public_open = orbit.params(unknown: :reject):
      field(:template_id, type: Str, required: true)
      field(:command_id, type: Str, required: true)
    @project = orbit.params(unknown: :reject):
      field(:title, type: Str, required: true)
    @membership = orbit.params(unknown: :reject):
      field(:account_id, type: Str, required: true)
      field(:role, type: Str, required: true)
    @empty = orbit.ParamSchema([], unknown: :reject)
    @notebook = orbit.params(unknown: :reject):
      field(:command_id, type: Str, required: true)
      field(:base_revision, type: Str, required: true)
      field(:document, type: Str, required: true)
    @draft = orbit.params(unknown: :reject):
      field(:base_revision, type: Str, required: true)
      field(:document, type: Str, required: true)
    @import_inspect = orbit.params(unknown: :reject):
      field(:archive, type: Str)
      array(:entries, unknown: :reject):
        field(:path, type: Str, required: true)
        field(:data, type: Str, required: true)
    @import_start = orbit.params(unknown: :reject):
      field(:command_id, type: Str, required: true)
      field(:title, type: Str, required: true)
      field(:fingerprint, type: Str, required: true)
      field(:archive, type: Str)
      array(:entries, unknown: :reject):
        field(:path, type: Str, required: true)
        field(:data, type: Str, required: true)
    @package_change = orbit.params(unknown: :reject):
      field(:command_id, type: Str, required: true)
      field(:action, type: Str, required: true)
      field(:name, type: Str, required: true)
      field(:version, type: Str, required: true)
      field(:variant, type: Str, required: true)
      field(:allow_native, type: Bool, required: true)
      field(:build_from_source, type: Bool, required: true)
      field(:allow_native_large, type: Bool, required: true)
    @input_change = orbit.params(unknown: :reject):
      field(:command_id, type: Str, required: true)
      field(:revision, type: Str, required: true)
      field(:base_version, type: Str, required: true)
    @media_change = orbit.params(unknown: :reject):
      field(:command_id, type: Str, required: true)
      field(:revision, type: Str, required: true)
      field(:base_version, type: Str, required: true)
      field(:board_id, type: Str, required: true)
      field(:component_id, type: Str, required: true)
      field(:operation, type: Str, required: true)
      field(:extension, type: Str, required: true)
      field(:name, type: Str, required: true)
      field(:data, type: Str, required: true)
    @run_history_change = orbit.params(unknown: :reject):
      field(:command_id, type: Str, required: true)
      field(:base_version, type: Str, required: true)
      field(:operation, type: Str, required: true)
      field(:title, type: Str, required: true)
      field(:pinned, type: Bool, required: true)
    @environment_prepare = orbit.params(unknown: :reject):
      field(:command_id, type: Str, required: true)
      field(:revision, type: Str, required: true)
      field(:retry, type: Bool, required: true)
    @worker_change = orbit.params(unknown: :reject):
      field(:command_id, type: Str, required: true)
      field(:revision, type: Str, required: true)
      field(:sheet_id, type: Str, required: true)
      field(:base_version, type: Str, required: true)
      field(:runtime_epoch, type: Str, required: true, nullable: true)
      field(:environment_id, type: Str, required: true)
      array(:grants, of: Str, required: true)
    @run = orbit.params(unknown: :reject):
      field(:command_id, type: Str, required: true)
      field(:revision, type: Str, required: true)
      field(:sheet_id, type: Str, required: true)
      field(:cell_id, type: Str, required: true)
      field(:action, type: Str, required: true)
    @invocation = orbit.params(unknown: :reject):
      field(:command_id, type: Str, required: true)
      field(:revision, type: Str, required: true)
      field(:board_id, type: Str, required: true)
      field(:component_id, type: Str, required: true)
    @invocation_restart = orbit.params(unknown: :reject):
      field(:command_id, type: Str, required: true)
      field(:runtime_epoch, type: Str, required: true)
    @service_change = orbit.params(unknown: :reject):
      field(:command_id, type: Str, required: true)
      field(:revision, type: Str, required: true)
      field(:board_id, type: Str, required: true)
      field(:component_id, type: Str, required: true)
      field(:operation, type: Str, required: true)
    @stop = orbit.params(unknown: :reject):
      field(:command_id, type: Str, required: true)
      field(:runtime_epoch, type: Str, required: true)
      field(:force, type: Bool, required: true)
    @restart = orbit.params(unknown: :reject):
      field(:command_id, type: Str, required: true)
      field(:sheet_id, type: Str, required: true)
      field(:runtime_epoch, type: Str, required: true, nullable: true)

class WebBoundary < orbit.Integration:
  def around_controller(request, next):
    try:
      next(request)
    rescue WebError |error|:
      if request.path.starts_with?("/api/"):
        orbit.render(json: {error: {code: error.code, message: error.message}}, status: error.status)
      elif error.status == 401:
        orbit.redirect("/", status: 303)
      else:
        orbit.render(text: error.message, status: error.status)

class NotebookSecurityPolicy < orbit.SecurityPolicy:
  def protect_response(response, request):
    protected = super(response, request)
    # Only this origin may request a microphone; the browser still requires
    # explicit user permission. Keep every other standard security header.
    orbit.with_response_header(protected, "permissions-policy", "geolocation=(), microphone=(self), camera=()")

class Pages < oauth.Controller:
  include sessions.ControllerSession

  def catalog(): service(:catalog)

  def current_account():
    return null unless service(:sign_in_available)
    id = session[:account_id]
    return null unless id
    try:
      catalog.account(id)
    rescue AuthenticationRequired:
      session.destroy
      null

  def require_account():
    current = current_account()
    raise AuthenticationRequired() unless current
    current

  def snapshot(project: null):
    current = current_account()
    session[:public_visitor] = SecureRandom.hex(32) if service(:public).enabled? and not session[:public_visitor]
    {
      schema: "notebook.web.v1",
      host: "server",
      account: if current then catalog.profile(current) else null,
      projects: if current then catalog.projects(current) else [],
      project: project,
      auth_error: request.query("auth_error") == "1",
      sign_in_available: service(:sign_in_available),
      public_templates: service(:public).listing()
    }

  def shell(data):
    layouts.application(views.index(), title: "Sputnik Notebook", assets: service(:assets), bootstrap: data)

  def home():
    data = snapshot()
    respond:
      html: shell(data)
      json: data

  def session_info():
    respond:
      json: snapshot()

  def sign_in():
    raise NotFound() unless service(:sign_in_available)
    header("referrer-policy", "no-referrer")
    target = service(:oauth).flow(:github).start(session, return_to: "/")
    respond:
      html: redirect(target, status: 303, external: true)
      json: {authorize_url: target}

  def callback():
    raise NotFound() unless service(:sign_in_available)
    try:
      result = oauth_callback(:github)
      identity = result.identity
      current = catalog.sign_in(identity.provider, identity.uid, identity.info[:login], name: identity.info[:name])
      session.reset
      session[:account_id] = current[:id]
      redirect("/", status: 303)
    rescue oauth.OAuthError, AuthenticationRequired:
      redirect("/?auth_error=1", status: 303)

  def logout():
    session.destroy
    respond:
      html: redirect("/", status: 303)
      json: render(status: :no_content)

  def projects():
    current = require_account()
    respond:
      json: {projects: catalog.projects(current)}

  def create_project():
    current = require_account()
    params = request.params.json.expect(service(:schemas).project)
    project = catalog.create_project(current, params[:title])
    status(:created)
    respond:
      json: {project: project}

  def show_project(id as Str):
    current = require_account()
    project = catalog.presentation(current, catalog.require_project(current, id))
    respond:
      html: shell(snapshot(project: project))
      json: {project: project}

  def rename_project(id as Str):
    current = require_account()
    params = request.params.json.expect(service(:schemas).project)
    respond:
      json: {project: catalog.rename_project(current, id, params[:title])}

  def memberships(id as Str):
    current = require_account()
    respond:
      json: {memberships: catalog.memberships(current, id)}

  def notebook(id as Str):
    current = require_account()
    respond:
      json: service(:notebooks).read(current, id)

  def resource_status(id as Str):
    respond:
      json: service(:resources).read(require_account(), id)

  def create_notebook(id as Str):
    current = require_account()
    request.params.json.expect(service(:schemas).empty)
    respond:
      json: service(:notebooks).create(current, id)

  # File edits have dynamic relative member keys; scalar strong parameters still
  # validate the fixed envelope and the source service validates every member.
  def file_params(schema, required: false, member: :changes):
    media = (request.header("content-type") or "").split(";")[0].trim.downcase
    raise InvalidInput("Expected a JSON request.") unless media == "application/json"
    value = null
    try: value = Json.parse(request.body_text)
    rescue Exception: raise InvalidInput("Invalid JSON request.")
    raise InvalidInput("Expected a JSON object.") unless Map === value
    changes = value[?member]
    raise InvalidInput("Expected project file changes.") if (required and changes == null) or (changes != null and not (Map === changes))
    value.delete!(member)
    extra = {}
    extra[member] = changes or {}
    schema.expect(value).merge(extra)

  def save_notebook(id as Str):
    current = require_account()
    params = file_params(service(:schemas).notebook)
    respond:
      json: service(:notebooks).save(current, id, params[:command_id], params[:base_revision], params[:document], params[?:changes] or {})

  def source_index(id as Str):
    current = require_account()
    respond:
      json: service(:sources).index(current, id, request.query("revision"))

  def source_file(id as Str):
    current = require_account()
    respond:
      json: service(:sources).read(current, id, request.query("revision"), request.query("path"))

  def source_download(id as Str):
    current = require_account()
    bytes = service(:sources).download(current, id, request.query("revision"), request.query("path"))
    render(body: bytes, headers: {"content-type": "application/octet-stream", "content-disposition": "attachment; filename=project-file", "cache-control": "private, no-store"})

  def notebook_archive(id as Str):
    current = require_account()
    bytes = service(:sources).archive(current, id, request.query("revision"))
    render(body: bytes, headers: {"content-type": "application/zip", "content-disposition": "attachment; filename=Notebook.sputnikbook.zip", "cache-control": "private, no-store"})

  def notebook_history(id as Str):
    current = require_account()
    respond:
      json: service(:sources).history(current, id, request.query("before"))

  def draft_archive(id as Str):
    current = require_account()
    params = file_params(service(:schemas).draft, required: true)
    bytes = service(:sources).draft_archive(current, id, params[:base_revision], params[:document], params[:changes])
    render(body: bytes, headers: {"content-type": "application/zip", "content-disposition": "attachment; filename=Draft.sputnikbook.zip", "cache-control": "private, no-store"})

  def inspect_import():
    current = require_account()
    params = request.params.json.expect(service(:schemas).import_inspect)
    respond:
      json: service(:transfer).inspect(current, params[?:archive], params[?:entries])

  def import_notebook():
    current = require_account()
    params = request.params.json.expect(service(:schemas).import_start)
    respond:
      json: service(:transfer).start(current, params[:command_id], params[:title], params[:fingerprint], params[?:archive], params[?:entries])

  def import_status(command as Str):
    current = require_account()
    respond:
      json: service(:transfer).status(current, command)

  def input_state(id as Str):
    current = require_account()
    respond:
      json: service(:inputs).read(current, id, request.query("cell"))

  def apply_inputs(id as Str):
    current = require_account()
    params = file_params(service(:schemas).input_change, required: true, member: :values)
    respond:
      json: service(:inputs).change(current, id, request.query("cell"), params[:command_id], params[:revision], params[:base_version], params[:values])

  def input_receipt(id as Str, command as Str):
    current = require_account()
    respond:
      json: service(:inputs).receipt(current, id, command)

  def accept_media(id as Str):
    current = require_account()
    params = request.params.json.expect(service(:schemas).media_change)
    respond:
      json: service(:media_inputs).change(current, id, params)

  def media_receipt(id as Str, command as Str):
    current = require_account()
    respond:
      json: service(:media_inputs).receipt(current, id, command)

  def annotation_source(id as Str):
    current = require_account()
    respond:
      json: service(:media_inputs).source(current, id, request.query("revision"), request.query("board"), request.query("component"))

  def environment_status(id as Str):
    respond:
      json: service(:environments).state(require_account(), id)

  def environment_details(id as Str, environment as Str):
    respond:
      json: service(:environments).details(require_account(), id, environment)

  def environment_prepare(id as Str):
    current = require_account()
    params = request.params.json.expect(service(:schemas).environment_prepare)
    respond:
      json: service(:environments).prepare(current, id, params[:command_id], params[:revision], params[:retry])

  def worker_settings(id as Str):
    respond:
      json: service(:environments).settings(require_account(), id, request.query("sheet"))

  def worker_configure(id as Str):
    current = require_account()
    params = request.params.json.expect(service(:schemas).worker_change)
    respond:
      json: service(:environments).configure(current, id, params)

  def runtime_receipt(id as Str, command as Str):
    respond:
      json: service(:environments).receipt(require_account(), id, command)

  def package_status(id as Str):
    current = require_account()
    respond:
      json: service(:packages).status(current, id)

  def package_job(id as Str, operation as Str):
    current = require_account()
    respond:
      json: service(:packages).read(current, id, operation)

  def package_catalog(id as Str):
    current = require_account()
    respond:
      json: service(:packages).catalog(current, id, request.query("name"), request.query("version"))

  def package_change(id as Str):
    current = require_account()
    params = request.params.json.expect(service(:schemas).package_change)
    respond:
      json: service(:packages).change(current, id, params[:command_id], params[:action], params[:name], params[:version], params[:variant], params[:allow_native], params[:build_from_source], params[:allow_native_large])

  def package_receipt(id as Str, command as Str):
    current = require_account()
    respond:
      json: service(:packages).receipt(current, id, command)

  def grant(id as Str):
    current = require_account()
    params = request.params.json.expect(service(:schemas).membership)
    respond:
      json: catalog.grant(current, id, params[:account_id], params[:role])

  def preview_open(id as Str):
    current = require_account()
    request.params.json.expect(service(:schemas).empty)
    respond:
      json: service(:preview).open(current, id)

  def public_open():
    params = request.params.json.expect(service(:schemas).public_open)
    respond:
      json: service(:public).open(session[:public_visitor], params[:template_id], params[:command_id])

  def public_read(session as Str):
    respond:
      json: service(:public).read(self.session[:public_visitor], session)

  def public_touch(session as Str):
    request.params.json.expect(service(:schemas).empty)
    respond:
      json: service(:public).touch(self.session[:public_visitor], session)

  def public_close(session as Str):
    respond:
      json: service(:public).close(self.session[:public_visitor], session)

  def public_run(session as Str, run as Str):
    respond:
      json: service(:public).run(self.session[:public_visitor], session, run)

  def public_start(session as Str):
    params = request.params.json.expect(service(:schemas).run)
    respond:
      json: service(:public).start(self.session[:public_visitor], session, params)

  def public_stop(session as Str, run as Str):
    params = request.params.json.expect(service(:schemas).stop)
    respond:
      json: service(:public).stop(self.session[:public_visitor], session, run, params)

  def public_receipt(session as Str, command as Str):
    respond:
      json: service(:public).receipt(self.session[:public_visitor], session, command)

  def public_save(session as Str):
    params = request.params.json.expect(service(:schemas).notebook)
    respond:
      json: service(:public).save(self.session[:public_visitor], session, params)

  def preview_read(session as Str):
    respond:
      json: service(:preview).read(require_account(), session)

  def preview_touch(session as Str):
    current = require_account()
    request.params.json.expect(service(:schemas).empty)
    respond:
      json: service(:preview).touch(current, session)

  def preview_close(session as Str):
    respond:
      json: service(:preview).close(require_account(), session)

  def preview_run(session as Str, run as Str):
    respond:
      json: service(:preview).run(require_account(), session, run)

  def preview_start(session as Str):
    current = require_account()
    params = request.params.json.expect(service(:schemas).run)
    respond:
      json: service(:preview).start(current, session, params)

  def preview_stop(session as Str, run as Str):
    current = require_account()
    params = request.params.json.expect(service(:schemas).stop)
    respond:
      json: service(:preview).stop(current, session, run, params)

  def preview_receipt(session as Str, command as Str):
    respond:
      json: service(:preview).receipt(require_account(), session, command)

  def preview_save(session as Str):
    current = require_account()
    params = request.params.json.expect(service(:schemas).notebook)
    respond:
      json: service(:preview).save(current, session, params)

  def run_snapshot(id as Str, run_id as Str):
    respond:
      json: service(:run_history).snapshot(require_account(), id, run_id)

  def run_history_change(id as Str, run_id as Str):
    current = require_account()
    params = request.params.json.expect(service(:schemas).run_history_change)
    respond:
      json: service(:run_history).change(current, id, run_id, params)

  def history_receipt(id as Str, command as Str):
    respond:
      json: service(:run_history).receipt(require_account(), id, command)

  def execution_history(id as Str):
    respond:
      json: service(:execution).history(require_account(), id, request.query("before"))

  def execution_registry(id as Str):
    current = require_account()
    respond:
      json: service(:execution).registry(current, id, request.query("board_id"))

  def invoke(id as Str):
    current = require_account()
    params = request.params.json.expect(service(:schemas).invocation)
    respond:
      json: service(:execution).invoke(current, id, params[:command_id], params[:revision], params[:board_id], params[:component_id])

  def services(id as Str):
    current = require_account()
    respond:
      json: service(:execution).services(current, id)

  def service_history(id as Str, board as Str, component as Str):
    current = require_account()
    respond:
      json: service(:execution).service_history(current, id, board, component, request.query("before"))

  def configure_service(id as Str):
    current = require_account()
    params = request.params.json.expect(service(:schemas).service_change)
    respond:
      json: service(:execution).configure_service(current, id, params[:command_id], params[:revision], params[:board_id], params[:component_id], params[:operation])

  def restart_invocation(id as Str, run_id as Str):
    current = require_account()
    params = request.params.json.expect(service(:schemas).invocation_restart)
    respond:
      json: service(:execution).restart_invocation(current, id, run_id, params[:command_id], params[:runtime_epoch])

  def show_run(id as Str, run_id as Str):
    current = require_account()
    respond:
      json: service(:execution).read(current, id, run_id)

  def start_run(id as Str):
    current = require_account()
    params = request.params.json.expect(service(:schemas).run)
    respond:
      json: service(:execution).start(current, id, params[:command_id], params[:revision], params[:sheet_id], params[:cell_id], params[:action])

  def stop_run(id as Str, run_id as Str):
    current = require_account()
    params = request.params.json.expect(service(:schemas).stop)
    respond:
      json: service(:execution).stop(current, id, run_id, params[:command_id], params[:runtime_epoch], params[:force])

  def restart_worker(id as Str):
    current = require_account()
    params = request.params.json.expect(service(:schemas).restart)
    respond:
      json: service(:execution).restart(current, id, params[:command_id], params[:sheet_id], params[:runtime_epoch])

  def execution_receipt(id as Str, command_id as Str):
    current = require_account()
    respond:
      json: service(:execution).receipt(current, id, command_id)

  def revoke(id as Str, account_id as Str):
    current = require_account()
    catalog.revoke(current, id, account_id)
    render(status: :no_content)

routes = orbit.routes:
  get "/", to: &Pages#home
  get "/projects/:id", to: &Pages#show_project
  get "/api/session", to: &Pages#session_info
  get "/api/projects", to: &Pages#projects
  post "/api/projects", to: &Pages#create_project
  get "/api/projects/:id", to: &Pages#show_project
  patch "/api/projects/:id", to: &Pages#rename_project
  get "/api/projects/:id/notebook", to: &Pages#notebook
  get "/api/projects/:id/resources", to: &Pages#resource_status
  post "/api/projects/:id/notebook", to: &Pages#create_notebook
  put "/api/projects/:id/notebook", to: &Pages#save_notebook
  get "/api/projects/:id/notebook/files", to: &Pages#source_index
  get "/api/projects/:id/notebook/file", to: &Pages#source_file
  get "/api/projects/:id/notebook/download", to: &Pages#source_download
  get "/api/projects/:id/notebook/archive", to: &Pages#notebook_archive
  get "/api/projects/:id/notebook/revisions", to: &Pages#notebook_history
  post "/api/projects/:id/notebook/draft-archive", to: &Pages#draft_archive
  post "/api/imports/inspect", to: &Pages#inspect_import
  post "/api/imports", to: &Pages#import_notebook
  get "/api/imports/:command", to: &Pages#import_status
  get "/api/projects/:id/inputs", to: &Pages#input_state
  put "/api/projects/:id/inputs", to: &Pages#apply_inputs
  get "/api/projects/:id/inputs/commands/:command", to: &Pages#input_receipt
  post "/api/projects/:id/media-inputs", to: &Pages#accept_media
  get "/api/projects/:id/media-inputs/commands/:command", to: &Pages#media_receipt
  get "/api/projects/:id/media-inputs/source", to: &Pages#annotation_source
  get "/api/projects/:id/environments", to: &Pages#environment_status
  post "/api/projects/:id/environments", to: &Pages#environment_prepare
  get "/api/projects/:id/environments/:environment", to: &Pages#environment_details
  get "/api/projects/:id/worker-settings", to: &Pages#worker_settings
  put "/api/projects/:id/worker-settings", to: &Pages#worker_configure
  get "/api/projects/:id/runtime-commands/:command", to: &Pages#runtime_receipt
  get "/api/projects/:id/dependencies", to: &Pages#package_status
  get "/api/projects/:id/dependencies/catalog", to: &Pages#package_catalog
  post "/api/projects/:id/dependencies", to: &Pages#package_change
  get "/api/projects/:id/dependencies/jobs/:operation", to: &Pages#package_job
  get "/api/projects/:id/dependencies/commands/:command", to: &Pages#package_receipt
  post "/api/projects/:id/preview-sessions", to: &Pages#preview_open
  post "/api/public/sessions", to: &Pages#public_open
  get "/api/public/sessions/:session", to: &Pages#public_read
  delete "/api/public/sessions/:session", to: &Pages#public_close
  post "/api/public/sessions/:session/lease", to: &Pages#public_touch
  put "/api/public/sessions/:session/notebook", to: &Pages#public_save
  post "/api/public/sessions/:session/runs", to: &Pages#public_start
  get "/api/public/sessions/:session/runs/:run", to: &Pages#public_run
  post "/api/public/sessions/:session/runs/:run/stop", to: &Pages#public_stop
  get "/api/public/sessions/:session/commands/:command", to: &Pages#public_receipt
  get "/api/preview-sessions/:session", to: &Pages#preview_read
  delete "/api/preview-sessions/:session", to: &Pages#preview_close
  post "/api/preview-sessions/:session/lease", to: &Pages#preview_touch
  put "/api/preview-sessions/:session/notebook", to: &Pages#preview_save
  post "/api/preview-sessions/:session/runs", to: &Pages#preview_start
  get "/api/preview-sessions/:session/runs/:run", to: &Pages#preview_run
  post "/api/preview-sessions/:session/runs/:run/stop", to: &Pages#preview_stop
  get "/api/preview-sessions/:session/commands/:command", to: &Pages#preview_receipt
  get "/api/projects/:id/execution", to: &Pages#execution_registry
  get "/api/projects/:id/execution/history", to: &Pages#execution_history
  get "/api/projects/:id/execution/runs/:run_id/snapshot", to: &Pages#run_snapshot
  post "/api/projects/:id/execution/runs/:run_id/history", to: &Pages#run_history_change
  get "/api/projects/:id/history-commands/:command", to: &Pages#history_receipt
  post "/api/projects/:id/execution/invocations", to: &Pages#invoke
  get "/api/projects/:id/execution/services", to: &Pages#services
  post "/api/projects/:id/execution/services", to: &Pages#configure_service
  get "/api/projects/:id/execution/services/:board/:component", to: &Pages#service_history
  post "/api/projects/:id/execution/runs/:run_id/restart", to: &Pages#restart_invocation
  post "/api/projects/:id/execution/runs", to: &Pages#start_run
  get "/api/projects/:id/execution/runs/:run_id", to: &Pages#show_run
  post "/api/projects/:id/execution/runs/:run_id/stop", to: &Pages#stop_run
  post "/api/projects/:id/execution/restart", to: &Pages#restart_worker
  get "/api/projects/:id/execution/commands/:command_id", to: &Pages#execution_receipt
  get "/api/projects/:id/memberships", to: &Pages#memberships
  post "/api/projects/:id/memberships", to: &Pages#grant
  delete "/api/projects/:id/memberships/:account_id", to: &Pages#revoke
  post "/auth/github", to: &Pages#sign_in
  get "/auth/github/callback", to: &Pages#callback
  post "/auth/logout", to: &Pages#logout

def application(provider, assets, database, catalog, session_secret:, csrf_secret:, origin:, core: null, behind_proxy: false, trusted_proxy_cidrs: ["127.0.0.1/32", "::1/128"], debug: false, native_packages: false, environment_preparation: false, worker_grants: [], public_templates: []):
  security = NotebookSecurityPolicy(origin: origin, content_security_policy: assets.csp.with(img_src: [:self, :data], media_src: ["blob:"]),
    trusted_proxy_cidrs: if behind_proxy then trusted_proxy_cidrs else [],
    forwarded: if behind_proxy then :x_forwarded else :none, forwarded_hops: if behind_proxy then 1 else 0)
  catalog.core_policy!(core)
  notebooks = Notebooks(catalog, core)
  resources = Resources(catalog, notebooks)
  execution = Execution(catalog, notebooks)
  orbit.App(routes: routes, security: security, expose_exceptions: debug,
    services: {sign_in_available: provider != null, public: PublicSessions(catalog, notebooks, database, public_templates), run_history: RunHistory(catalog, notebooks, execution), environments: Environments(catalog, notebooks, environment_preparation, worker_grants), resources: resources, preview: PreviewSessions(catalog, notebooks, database), assets: assets, catalog: catalog, core: core, notebooks: notebooks, execution: execution, sources: Sources(catalog, notebooks), transfer: Transfer(catalog, notebooks), packages: Packages(catalog, notebooks, native_packages), inputs: Inputs(catalog, notebooks), media_inputs: MediaInputs(catalog, notebooks), schemas: Schemas(), oauth: oauth.Registry(if provider then [oauth.Flow(provider, max_pending: 1)] else [])},
    integrations: [orm_pool(database), WebBoundary()],
    middleware: [StaticFiles(), sessions.Middleware(store: sessions.CookieStore(), secret: session_secret, secure: security.origin.secure?),
      CsrfMiddleware(secret: csrf_secret, session_service: :session)])
