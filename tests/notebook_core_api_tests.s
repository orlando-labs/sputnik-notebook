package test.notebook_core_api

from notebook.core import Core
from notebook.core.common import digest

export main

def check(value, message):
  raise ValueError("notebook-core API: " + message) unless value

def wait_run(core, id):
  600.times:
    result = core.handle("run.get", {run_id: id})
    return result if ["succeeded", "failed", "cancelled", "force-stopped", "interrupted"].include?(result[:state])
    task.sleep(0.05)
  raise ValueError("run did not finish")

def main():
  parser = ArgParser()
  parser.arg("--root", required: true)
  parser.arg("--worker", required: true)
  args = parser.parse_or_raise
  root = args[:root]
  core = Core(root, args[:worker])
  check(core.handle("health", {})[:protocol] == 1, "direct health")
  check(not fs.exists?(root + "/token") and not fs.exists?(root + "/agent.sock"), "core creates no transport or credentials")
  document = {
    format: "sputnik-notebook", version: 1, title: "Shared core", active_sheet: "main",
    sheets: [{id: "main", title: "Main", cells: [{id: "1", kind: "code", source: "answer()\n", mode: "manual"}]}],
    modules: [{id: "helpers", path: "modules/helpers.s"}], auto_imports: ["helpers"]
  }
  upload = {project_id: "book", command_id: "save-1", base_revision: null,
    document: Json.generate(document), files: {"modules/helpers.s": Base64.encode("package helpers\nexport answer\ndef answer(): 42\n".bytes)}}
  saved = core.handle("project.put", upload)
  check(digest(core.handle("project.put", upload)) == digest(saved), "save receipt is idempotent")
  registry = core.handle("run.registry", {project_id: "book"})
  check(registry[:runs].empty?, "loading does not execute code")
  command = {project_id: "book", command_id: "run-1", revision: saved[:revision], sheet_id: "main", cell_id: "1", action: "run"}
  accepted = core.handle("run.start", command)
  check(digest(core.handle("run.start", command)) == digest(accepted), "run receipt is idempotent")
  receipt = core.handle("receipt.get", {project_id: "book", command_id: "run-1"})
  check(receipt[:response][:run_id] == accepted[:run_id], "receipt reattaches to accepted work")
  result = wait_run(core, accepted[:run_id])
  check(result[:state] == "succeeded" and result[:result][:cells][0][:result] == "42", "direct worker execution")
  check(core.handle("run.registry", {project_id: "book"})[:runs].count == 1, "one physical run")
  core.handle("project.delete", {project_id: "book", command_id: "delete-1"})
  600.times:
    current = core.handle("project.get", {project_id: "book"})
    break if current[:state] == "deleted"
    task.sleep(0.01)
  check(core.handle("project.get", {project_id: "book"})[:state] == "deleted", "delete retires runtime")
  check(not fs.exists?(root + "/token") and not fs.exists?(root + "/agent.sock"), "no network adapter was started")
  # Budget and lease supervision belong to Core, even without schedule_work,
  # an HTTP gateway, a connected browser or an application polling timer.
  document[:sheets][0][:cells][0][:source] = "import task\ntask.sleep(60000)\n42\n"
  timed = core.handle("project.put", {project_id: "timed", command_id: "create", base_revision: null, document: Json.generate(document), files: {"modules/helpers.s": Base64.encode("package helpers\nexport answer\ndef answer(): 42\n".bytes)}})
  core.handle("policy.configure", {scope: "project", id: "timed", limits: {total_run_seconds: 1}})
  accepted = core.handle("run.start", {project_id: "timed", command_id: "run", revision: timed[:revision], sheet_id: "main", cell_id: "1"})
  result = wait_run(core, accepted[:run_id])
  check(result[:state] == "force-stopped" and result[:error].contains?("time budget"), "automatic time budget without an adapter scheduler")
  core.handle("policy.configure", {scope: "profile", id: "test_preview", limits: {persistence: "session", lease_seconds: 1, total_run_seconds: 60}})
  preview = core.handle("session.open", {source_project: "timed", user_id: "visitor", profile: "test_preview"})
  core.handle("session.close", {project_id: preview[:project_id]})
  600.times:
    break unless core.row("SELECT project FROM policy_projects WHERE project=?", [preview[:project_id]])
    task.sleep(0.01)
  check(core.row("SELECT id FROM projects WHERE id=?", [preview[:project_id]]) == null, "closed temporary session is erased")
  # A future Electron/local adapter opts in at construction; a document or
  # client request cannot switch a running remote Core into this mode.
  local = Core(root + "-local", args[:worker], allow_book_policy_overrides: true)
  check(local.handle("health", {})[:allow_book_policy_overrides] == true, "local adapter explicitly opts in")
  document[:resource_policy] = {run_count: 200, run_seconds: 5}
  document[:sheets][0][:cells][0][:source] = "import task\ntask.sleep(1200)\n42\n"
  saved = local.handle("project.put", {project_id: "local", command_id: "create", base_revision: null, document: Json.generate(document), files: {"modules/helpers.s": Base64.encode("package helpers\nexport answer\ndef answer(): 42\n".bytes)}})
  policy = local.handle("policy.desktop", {project_id: "local", limits: {run_count: 5, run_seconds: 1}})
  check(policy[:effective][:run_count] == 200 and policy[:effective][:run_seconds] == 5, "local book replaces app and built-in defaults")
  accepted = local.handle("run.start", {project_id: "local", command_id: "run", revision: saved[:revision], sheet_id: "main", cell_id: "1"})
  check(wait_run(local, accepted[:run_id])[:state] == "succeeded", "raised local budget executes beyond app default")
  local.handle("policy.configure", {scope: "project", id: "local", limits: {run_seconds: 1}})
  check(local.handle("policy.get", {project_id: "local"})[:effective][:run_seconds] == 1, "explicit operator ceiling remains hard in local override mode")
  print "PASS notebook-core direct API: receipts, worker, budgets, temporary sessions, retirement"
