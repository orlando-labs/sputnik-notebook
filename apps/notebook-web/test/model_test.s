package model_test

import "../backend/database" as database
import orm
import task
from "../backend/models" import Account, Identity, Project, Membership, Forbidden, NotFound, InvalidInput, AuthenticationRequired

export main

def check(value, message):
  raise ValueError("web models: " + message) unless value

def fails(type, &block):
  caught = false
  try: block()
  rescue Exception |error|:
    raise error unless type === error
    caught = true
  check(caught, "expected failure")

def main():
  parser = ArgParser()
  parser.arg("--database", required: true)
  parser.arg("--migrations", default: "./db/migrations")
  parser.flag("--existing")
  args = parser.parse_or_raise
  opened = database.open(args[:database], migrations: args[:migrations])
  pool = opened[0]
  catalog = opened[1]
  try:
    if args[:existing]:
      alice = catalog.sign_in("github", "9007199254740995", "renamed", name: "Alice New")
      check(catalog.projects(alice)[0][:title] == "Edited", "projects survive reopening")
      check(Account.all.or_raise.count == 3 and Identity.all.or_raise.count == 3, "identities survive reopening")
      print "PASS notebook-web persisted catalog and migrations"
      return null
    alice = catalog.sign_in("github", "9007199254740995", "alice", name: "Alice")
    original = alice[:id]
    alice = catalog.sign_in("github", "9007199254740995", "renamed", name: "Alice New")
    check(alice[:id] == original and catalog.profile(alice)[:login] == "renamed", "identity is stable across login changes")
    bob = catalog.sign_in("github", "2", "renamed", name: "  ")
    check(bob[:name] == null, "optional GitHub name can be blank")
    check(bob[:id] != original, "same login cannot link two provider UIDs")
    check(Account.all.or_raise.count == 2 and Identity.all.or_raise.count == 2, "repeated login does not duplicate accounts")
    jobs = [1, 2].map:
      task.spawn: catalog.sign_in("github", "3", "parallel", name: "Parallel")[:id]
    ids = jobs.map: _1.wait
    check(ids[0] == ids[1], "concurrent first sign-in creates one account")
    project = catalog.create_project(alice, "  Research  ")
    id = project[:id]
    check(project[:title] == "Research" and project[:role] == "owner" and project[:permissions][:manage], "owner and normalized title")
    check(catalog.projects(bob).empty?, "private projects are not listed")
    fails(NotFound): catalog.require_project(bob, id)
    fails(NotFound): catalog.rename_project(bob, id, "stolen")
    catalog.grant(alice, id, bob[:id], "viewer")
    check(catalog.projects(bob)[0][:role] == "viewer", "shared catalog")
    fails(Forbidden): catalog.rename_project(bob, id, "viewer write")
    fails(Forbidden): catalog.require_project(bob, id, capability: :execute)
    fails(Forbidden): catalog.grant(bob, id, alice[:id], "editor")
    catalog.grant(alice, id, bob[:id], "editor")
    check(catalog.rename_project(bob, id, "Edited")[:title] == "Edited", "editor write")
    check(catalog.require_project(bob, id, capability: :execute)[:id] == id, "editor execute policy")
    check(catalog.memberships(alice, id).count == 1, "grant updates rather than duplicates")
    fails(InvalidInput): catalog.grant(alice, id, bob[:id], "owner")
    fails(InvalidInput): catalog.grant(alice, id, alice[:id], "viewer")
    fails(InvalidInput): catalog.revoke(alice, id, alice[:id])
    fails(InvalidInput): catalog.rename_project(alice, id, "  ")
    fails(InvalidInput): catalog.create_project(alice, "x" * 201)
    fails(orm.PersistenceError):
      Identity.create(id: SecureRandom.hex(16), account_id: bob[:id], provider: "github", uid: "9007199254740995",
        login: "duplicate", created_at: 1, updated_at: 1).or_raise
    fails(orm.PersistenceError):
      Membership.create(id: SecureRandom.hex(16), project_id: id, account_id: "missing", role: "viewer",
        created_at: 1, updated_at: 1).or_raise
    fails(ValueError):
      Project.with_lock:
        catalog.create_project(alice, "Rolled back")
        raise ValueError("cancel project creation")
    catalog.revoke(alice, id, bob[:id])
    fails(NotFound): catalog.require_project(bob, id)
    check(catalog.projects(bob).empty?, "revocation applies immediately")
    bob[:state] = "disabled"
    bob.save.or_raise
    fails(AuthenticationRequired): catalog.account(bob[:id])
    fails(AuthenticationRequired): catalog.sign_in("github", "2", "renamed")
    check(Project.all.or_raise.count == 1, "logout/account policy performs no project cleanup")
    print "PASS notebook-web models: identity, concurrency, ownership, roles and revocation"
  ensure:
    pool.close!
