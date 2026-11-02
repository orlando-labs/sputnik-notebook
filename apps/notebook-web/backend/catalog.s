package catalog

import orm
from models import Account, Identity, Project, Membership, NotebookImport
from models import AuthenticationRequired, NotFound, Forbidden, InvalidInput, WebError

export Catalog

def text(value, label, limit):
  raise InvalidInput(label + " must be a string.") unless Str === value
  normalized = value.trim
  if normalized.empty? or normalized.length > limit or normalized.contains?("\u{0}"):
    raise InvalidInput(label + " is empty or too long.")
  normalized

def optional(result):
  return result.value if result.ok?
  raise result.error unless orm.NotFoundError === result.error
  null

class Catalog:
  # Models are bound once to this application's database during boot.
  def init(@database): @core = null
  def core_policy!(core): @core = core

  def account(id):
    raise AuthenticationRequired() unless Str === id
    found = optional(Account.find(id))
    raise AuthenticationRequired() unless found and found[:state] == "active"
    found

  def sign_in(provider, uid, login, name: null):
    provider = text(provider, "Provider", 64)
    uid = text(uid, "Provider UID", 256)
    login = text(login, "Login", 256)
    name = name.trim if Str === name
    name = null if name == ""
    name = text(name, "Name", 256) if name != null
    Account.with_lock:
      identity = optional(Identity.where({provider: provider, uid: uid}).first)
      stamp = Time.now.unix_seconds
      current = if identity then account(identity[:account_id]) else Account.create(
        id: SecureRandom.hex(16), name: name, state: "active", created_at: stamp, updated_at: stamp).or_raise
      if identity:
        current[:name] = name
        current[:updated_at] = stamp
        current.save.or_raise
        identity[:login] = login
        identity[:updated_at] = stamp
        identity.save.or_raise
      else:
        Identity.create(id: SecureRandom.hex(16), account_id: current[:id], provider: provider,
          uid: uid, login: login, created_at: stamp, updated_at: stamp).or_raise
      current

  def profile(current):
    identity = Identity.where({account_id: current[:id], provider: "github"}).first.or_raise
    {id: current[:id], name: current[:name], provider: identity[:provider], uid: identity[:uid], login: identity[:login]}

  def role(current, project):
    return "owner" if project[:owner_account_id] == current[:id]
    member = optional(Membership.where({project_id: project[:id], account_id: current[:id]}).first)
    if member then member[:role] else null

  def permissions(role):
    {read: role != null, write: ["owner", "editor"].include?(role),
      execute: ["owner", "editor"].include?(role), manage: role == "owner"}

  def require_project(current, id, capability: :read):
    account(current[:id])
    project = optional(Project.find(id))
    raise NotFound() unless project
    selected = role(current, project)
    raise NotFound() unless selected
    allowed = permissions(selected)
    raise Forbidden() unless allowed[?capability]
    if @core:
      try: @core.handle("policy.bind", {project_id: project[:core_project_id], user_id: project[:owner_account_id]})
      rescue Exception: raise WebError(503, "policy_unavailable", "The notebook policy service is unavailable.")
    project

  def presentation(current, project):
    selected = role(current, project)
    imported = optional(NotebookImport.where({project_id: project[:id], state: "pending"}).first)
    {id: project[:id], title: project[:title], owner_account_id: project[:owner_account_id],
      role: selected, permissions: permissions(selected), created_at: project[:created_at], updated_at: project[:updated_at]}
      .merge({import_pending: imported != null, import_command_id: if imported and selected == "owner" then imported[:command_id] else null})

  def import_record(current, command):
    account(current[:id])
    optional(NotebookImport.where({account_id: current[:id], command_id: command}).first)

  def begin_import(current, command, fingerprint, title):
    title = text(title, "Title", 200)
    Project.with_lock:
      record = import_record(current, command)
      if record:
        raise WebError(409, "import_command_conflict", "This import belongs to different contents or a different title.") unless record[:fingerprint] == fingerprint and record[:title] == title
      else:
        created = create_project(current, title)
        record = NotebookImport.create(id: SecureRandom.hex(16), account_id: current[:id], command_id: command,
          fingerprint: fingerprint, title: title, project_id: created[:id], state: "pending").or_raise
      record

  def complete_import(current, command):
    Project.with_lock:
      record = import_record(current, command)
      raise NotFound() unless record
      record[:state] = "complete"
      record.save.or_raise
      record

  def projects(current):
    account(current[:id])
    owned = Project.where({owner_account_id: current[:id]}).all.or_raise
    shared = Membership.where({account_id: current[:id]}).all.or_raise
    ids = owned.map: _1[:id]
    shared.each |member|:
      ids.push!(member[:project_id]) unless ids.include?(member[:project_id])
    ids.map |id|: presentation(current, require_project(current, id))

  def create_project(current, title):
    title = text(title, "Title", 200)
    Project.with_lock:
      account(current[:id])
      stamp = Time.now.unix_seconds
      project = Project.create(id: SecureRandom.hex(16), owner_account_id: current[:id], core_project_id: SecureRandom.hex(16),
        title: title, created_at: stamp, updated_at: stamp).or_raise
      presentation(current, project)

  def rename_project(current, id, title):
    title = text(title, "Title", 200)
    Project.with_lock:
      project = require_project(current, id, capability: :write)
      project[:title] = title
      project[:updated_at] = Time.now.unix_seconds
      project.save.or_raise
      presentation(current, project)

  def memberships(current, id):
    project = require_project(current, id, capability: :manage)
    Membership.where({project_id: project[:id]}).all.or_raise.map |member|:
      {account_id: member[:account_id], role: member[:role]}

  def grant(current, id, target, role):
    raise InvalidInput("Role must be editor or viewer.") unless ["editor", "viewer"].include?(role)
    Project.with_lock:
      project = require_project(current, id, capability: :manage)
      raise InvalidInput("The owner already has access.") if target == project[:owner_account_id]
      raise NotFound() unless optional(Account.where({id: target, state: "active"}).first)
      member = optional(Membership.where({project_id: id, account_id: target}).first)
      stamp = Time.now.unix_seconds
      if member:
        member[:role] = role
        member[:updated_at] = stamp
        member.save.or_raise
      else:
        Membership.create(id: SecureRandom.hex(16), project_id: id, account_id: target, role: role,
          created_at: stamp, updated_at: stamp).or_raise
      {account_id: target, role: role}

  def revoke(current, id, target):
    Project.with_lock:
      project = require_project(current, id, capability: :manage)
      raise InvalidInput("The owner cannot be removed.") if target == project[:owner_account_id]
      member = optional(Membership.where({project_id: id, account_id: target}).first)
      member.delete.or_raise if member
    null
