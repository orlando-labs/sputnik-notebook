package preview_test

import "../backend/database" as database
from "../backend/notebooks" import Notebooks
from "../backend/preview" import PreviewSessions
from "../backend/resources" import Resources
from "../backend/models" import NotFound, Forbidden
from notebook.core.client import Client
from notebook.core.common import terminal?

export main

def check(value, message):
  raise ValueError("preview: " + message) unless value

def main():
  parser = ArgParser()
  parser.arg("--database", required: true)
  parser.arg("--core-root", required: true)
  args = parser.parse_or_raise
  opened = database.open(args[:database])
  try:
    catalog = opened[1]
    core = Client(args[:core_root])
    catalog.core_policy!(core)
    books = Notebooks(catalog, core)
    resources = Resources(catalog, books)
    previews = PreviewSessions(catalog, books, opened[0])
    alice = catalog.sign_in("github", "preview-alice", "alice")
    bob = catalog.sign_in("github", "preview-bob", "bob")
    project = catalog.create_project(alice, "Template")
    original = books.create(alice, project[:id])[:notebook]
    document = Json.parse(original[:document])
    document[:sheets][0][:cells][0][:source] = "42\n"
    saved = books.save(alice, project[:id], "save-template", original[:revision], Json.generate(document))[:notebook]
    template = catalog.require_project(alice, project[:id])
    owner = core.handle("policy.get", {project_id: template[:core_project_id]})
    check(owner[:user_id] == alice[:id], "server binds catalog ownership")
    document[:resource_policy] = {run_count: 7, run_seconds: 180, total_run_seconds: 180}
    saved = books.save(alice, project[:id], "save-policy", saved[:revision], Json.generate(document))[:notebook]
    visible = resources.read(alice, project[:id])[:resources]
    check(visible[:effective][:run_count] == "7" and visible[:defaults][:run_count] == "100" and visible[:spent_ms] == "0", "public policy uses exact strings and distinguishes inherited limits")
    check(not Json.generate(visible).contains?(template[:core_project_id]) and not visible.has_key?(:user_id), "resource DTO hides core identities")
    core.handle("policy.configure", {scope: "user", id: alice[:id], limits: {run_count: 5}})
    first = previews.open(alice, project[:id])
    check(first[:policy][:persistence] == "session" and first[:policy][:total_run_seconds] == 60 and first[:policy][:run_count] == 5, "public profile inherits user ceilings")
    check(first[:resources][:remaining_ms] == "60000", "preview exposes server budget")
    denied = false
    try: previews.read(bob, first[:session_id])
    rescue NotFound: denied = true
    check(denied, "session cannot be read by another account")
    document[:sheets][0][:cells][0][:source] = "99\n"
    changed = previews.save(alice, first[:session_id], {command_id: "edit-copy", base_revision: first[:revision], document: Json.generate(document)})[:notebook]
    accepted = previews.start(alice, first[:session_id], {command_id: "run-copy", revision: changed[:revision], sheet_id: "main", cell_id: "1", action: "run"})[:run]
    result = null
    600.times:
      result = previews.run(alice, first[:session_id], accepted[:id])[:run]
      break if terminal?(result[:state])
      task.sleep(0.01)
    check(result[:state] == "succeeded" and result[:cells][0][:result] == "99", "preview runs edited copy")
    check(previews.receipt(alice, first[:session_id], "run-copy")[:command][:run][:id] == accepted[:id], "preview receipt reattaches without a second run")
    check(previews.receipt(alice, first[:session_id], "edit-copy")[:command][:revision] == changed[:revision], "preview save receipt retains revision")
    check(books.read(alice, project[:id])[:notebook][:revision] == saved[:revision], "template remains unchanged")
    second = previews.open(alice, project[:id])
    clean = previews.read(alice, second[:session_id])
    check(clean[:runs].empty? and clean[:spent_ms] == 0 and clean[:notebook][:document].contains?("42"), "new session has no previous state")
    previews.close(alice, first[:session_id])
    denied = false
    try: previews.read(alice, first[:session_id])
    rescue NotFound: denied = true
    check(denied, "closed session cannot be reattached")
    catalog.grant(alice, project[:id], bob[:id], "viewer")
    denied = false
    try: previews.open(bob, project[:id])
    rescue Forbidden: denied = true
    check(denied, "viewers cannot create execution sessions")
    catalog.grant(alice, project[:id], bob[:id], "editor")
    visitor = previews.open(bob, project[:id])
    core_id = ""
    opened[0].with_connection |db|:
      core_id = db.query("SELECT core_project_id FROM preview_sessions WHERE id=?", params: [visitor[:session_id]])[0][:core_project_id]
    check(core.handle("policy.get", {project_id: core_id})[:user_id] == bob[:id], "preview charges server-selected visitor identity")
    previews.close(bob, visitor[:session_id])
    previews.close(alice, second[:session_id])
    print "PASS notebook-web preview: server policy, authorization, isolated copies, clean reopen, visitor billing"
  ensure:
    opened[0].close!
