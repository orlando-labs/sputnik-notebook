package test.notebook_remote

from "./notebook_package_catalog_test" import PackageCatalogFixture
from "./notebook_remote_test_support" import check, eventually, document, reserve, close_process, signal, alive?, Harness
from notebook.core.common import digest, command_at
from notebook.core.host import ServiceProcess
from net.http import Server
from "./notebook_remote_regression_tests" import inputs, actions, durable_restart
from "./notebook_remote_desktop_tests" import desktop_actions, targeted_commands

export main

def equal(left, right, message): check(digest(left) == digest(right), message)

def catalog(h):
  project = "catalog"
  saved, run, _result = h.value(project, "42\n")
  route = "/v1/projects/" + project + "/package-catalog"
  body = {command_id: "catalog-versions", query: "versions", source: "editor-probe"}
  check(h.request("POST", route, body, authenticated: false)[0] == 401, "catalog authentication")
  versions = h.call("POST", route, body)
  check(versions[:package_ref] == "test/editor-probe", "canonical package reference")
  equal(versions[:versions].map: $it[:version], ["3.0.0", "2.0.0-rc.1", "1.1.0", "1.0.0", "0.9.0"], "ordered versions")
  builds = h.call("POST", route, {command_id: "catalog-variants", query: "variants", source: "test/editor-probe@1.0.0"})
  check(builds[:recommended_variant] == "source", "portable variant recommendation")
  builds[:artifacts].each |artifact|:
    check(artifact[:host_selection][:compatible] == (artifact[:variant] == "source"), "execution-host compatibility")
    equal(artifact[:runtime_grants], ["fs.read=/package-fixture"], "catalog preserves the declared grant target")
  check(["macos", "linux"].include?(builds[:host][:os]), "catalog reports execution host")
  ["install", "--help", "missing"].each |value|:
    query = if value == "install" then "install" else "versions"
    reply = h.request("POST", route, {query: query, source: value})
    check(reply[0] == (if value == "missing" then 422 else 400), "catalog rejects invalid requests")
  inventory = h.call("GET", "/v1/projects/" + project + "/dependencies")
  check(inventory[:packages].empty? and inventory[:jobs].empty?, "catalog never installs")
  again = h.start(project, saved[:revision])
  check(h.wait_run(again[:run_id])[:state] == "succeeded", "worker remains usable")
  check(again[:runtime_epoch] == run[:runtime_epoch], "catalog never retires execution runtime")
  # Exercise the real native CLI adapter too.
  request = h.directory + "/catalog-request.json"
  fs.atomic_write_text(request, Json.generate({command_id: "cli-catalog", query: "variants", source: "test/editor-probe@1.0.0"}))
  checked = system.command(h.args[:core], "--mode", "cli", "--url", "http://127.0.0.1:" + h.port.to_str,
    "--token-file", h.root + "/token", "--command", "package_catalog", "--project", project, "--request-file", request).capture(timeout: 30.0)
  check(checked.success? and Json.parse(checked.stdout.to_str)[:recommended_variant] == "source", "native CLI catalog")
  h.delete(project)
  print "PASS package catalog: authentication, versions, compatibility, CLI, no installation or worker retirement"

def snapshots(h):
  project = "snapshots"
  doc = document("answer()\n")
  doc[:modules] = [{id: "helpers", path: "modules/helpers.s"}]
  doc[:auto_imports] = ["helpers"]
  files = {"modules/helpers.s": Base64.encode("package helpers\nexport answer\ndef answer(): 42\n".bytes)}
  saved = h.upload(project, doc, files, null, "save")
  equal(h.upload(project, doc, files, null, "save"), saved, "snapshot receipt")
  check(h.request("GET", "/v1/projects/" + project, authenticated: false)[0] == 401, "HTTP authentication")
  check(h.request("PUT", "/v1/projects/" + project, {command_id: "conflict", base_revision: "missing", document: Json.generate(doc), files: files})[0] == 409, "snapshot conflict")
  rejected = h.request("PUT", "/v1/projects/" + project, {command_id: "unsafe", base_revision: saved[:revision], document: Json.generate(doc), files: {"../escape.s": Base64.encode("bad".bytes)}})
  check(rejected[0] == 400, "snapshot traversal")
  run = h.start(project, saved[:revision], "run")
  equal(h.start(project, saved[:revision], "run"), run, "run receipt")
  done = h.wait_run(run[:run_id])
  check(done[:state] == "succeeded" and done[:result][:cells][0][:result] == "42", "bundled module execution")
  receipt = h.call("GET", "/v1/projects/" + project + "/commands/run")
  check(receipt[:response][:run_id] == run[:run_id], "lost-response reattachment")
  registry = h.call("GET", "/v1/projects/" + project + "/registry")
  check(registry[:runs].count == 1, "receipt does not duplicate work")
  snapshot = h.call("GET", "/v1/projects/" + project + "/revisions/" + saved[:revision] + "/document")
  check(Json.generate(snapshot).contains?("сохранить"), "snapshot retains opaque Unicode metadata")
  presentation = h.request("GET", "/v1/runs/" + run[:run_id] + "/presentation", binary: true)
  check(presentation[0] == 200 and presentation[1].count > 0, "terminal presentation download")
  h.restart_gateway()
  check(h.call("GET", "/v1/runs/" + run[:run_id])[:state] == "succeeded", "gateway restart preserves run")
  h.restart_agent()
  check(h.call("GET", "/v1/projects/" + project)[:head] == saved[:revision], "agent restart preserves snapshot")
  check(h.call("GET", "/v1/runs/" + run[:run_id])[:state] == "succeeded", "agent restart preserves history")
  h.delete(project)
  print "PASS snapshots: opaque data, modules, conflicts, traversal, receipts, presentation, reconnect and restart"

def execution(h):
  sources = [
    "callback = &print\ncopied = &callback\nvalue = copied\nraise ValueError(\"reference\") unless value == null and (&callback) == (&print)\n42\n",
    "raise ValueError(\"membership\") unless 2 in [1, 2, 3]\n42\n",
    "raise ValueError(\"Unicode regexp\") unless r\"\\Aя+\\z\"i ~= \"ЯЯ\"\n42\n",
    "from system import cmd\ncommand = cmd\"/usr/bin/printf literal\"\nraise ValueError(\"argv\") unless command.argv == [\"/usr/bin/printf\", \"literal\"]\n42\n"
  ]
  sources.each_with_index |source, index|:
    project = "language_" + index.to_str
    h.value(project, source)
    h.delete(project)
  project = "live_heap"
  first = h.upload(project, document("import task\ntask.sleep(700)\n42\n"))
  run = h.start(project, first[:revision])
  h.wait_run(run[:run_id], "running")
  next_revision = h.upload(project, document("84\n"), {}, first[:revision])
  previous = h.wait_run(run[:run_id])
  check(previous[:result][:cells][0][:result] == "42", "accepted run keeps its frozen source")
  again = h.start(project, next_revision[:revision])
  result = h.wait_run(again[:run_id])
  check(result[:state] == "succeeded" and result[:result][:cells][0][:result] == "84", "next run sees edited source")
  check(again[:runtime_epoch] == run[:runtime_epoch], "edit retains live runtime")
  reset = h.call("POST", "/v1/projects/" + project + "/restart", {command_id: "restart", sheet_id: "main", runtime_epoch: again[:runtime_epoch]})
  after = h.start(project, next_revision[:revision])
  check(h.wait_run(after[:run_id])[:state] == "succeeded", "restarted runtime executes current revision")
  check(after[:runtime_epoch] != again[:runtime_epoch], "restart changes epoch")
  h.delete(project)
  print "PASS execution: function references, membership, Unicode, command argv, live heap and explicit restart"

def cancellation(h):
  project = "cancel"
  saved = h.upload(project, document("import task\ntask.sleep(60000)\n42\n"))
  run = h.start(project, saved[:revision])
  h.wait_run(run[:run_id], "running")
  route = "/v1/runs/" + run[:run_id] + "/stop"
  check(h.request("POST", route, {command_id: "stale-stop", runtime_epoch: "stale", force: true})[0] == 409, "stale stop epoch")
  h.call("POST", route, {command_id: "stop", runtime_epoch: run[:runtime_epoch], force: false})
  check(["cancelled", "force-stopped"].include?(h.wait_run(run[:run_id])[:state]), "cooperative cancellation")
  h.call("POST", "/v1/projects/" + project + "/restart", {command_id: "reset", sheet_id: "main", runtime_epoch: run[:runtime_epoch]})
  run = h.start(project, saved[:revision])
  h.wait_run(run[:run_id], "running")
  h.call("POST", "/v1/runs/" + run[:run_id] + "/stop", {command_id: "force", runtime_epoch: run[:runtime_epoch], force: true})
  check(h.wait_run(run[:run_id])[:state] == "force-stopped", "forced cancellation")
  h.delete(project)
  project = "owner_deleted"
  saved = h.upload(project, document("import task\ntask.sleep(60000)\n42\n"))
  run = h.start(project, saved[:revision])
  h.wait_run(run[:run_id], "running")
  h.delete(project)
  check(["cancelled", "force-stopped", "interrupted"].include?(h.wait_run(run[:run_id])[:state]), "owner deletion stops work")
  check(h.request("POST", "/v1/projects/" + project + "/runs", {command_id: "resurrect", revision: saved[:revision], sheet_id: "main", cell_id: "1"})[0] == 409, "deleted owner cannot be reused")
  print "PASS cancellation: stale epoch, cooperative stop, force stop and owner retirement"

def dependencies(h, fixture):
  project = "packages"
  saved = h.upload(project, document("from editor_probe import answer\nanswer()\n"))
  route = "/v1/projects/" + project + "/dependencies"
  body = {command_id: "install", action: "install_sputnik", source: "editor-probe", version: "1.0.0", variant: "source"}
  job = h.call("POST", route, body)
  equal(h.call("POST", route, body), job, "install receipt")
  installed = eventually:
    value = h.call("GET", route + "/" + job[:id])
    value unless ["queued", "running"].include?(value[:state])
  check(installed[:state] == "succeeded", Json.generate(installed))
  inventory = h.call("GET", route)[:packages]
  check(inventory.count == 1 and inventory[0][:version] == "1.0.0", "exact registry installation")
  check(inventory[0][:display_name] == "editor-probe" and inventory[0][:scope] == "shared" and fs.metadata(inventory[0][:directory]).symlink?, "book holds a shared package reference with a short display name")
  catalog = h.call("POST", "/v1/projects/" + project + "/package-catalog", {query: "variants", source: "editor-probe@1.0.0"})
  cached = catalog[:artifacts].find |item|: item[:variant] == "source" and item[:shared_installed]
  check(cached != null, "catalog marks the installed shared build")
  foreign = h.directory + "/foreign-package"
  fs.mkdir_p(foreign)
  fs.atomic_write_text(foreign + "/modules.index", "sputnik.package.index.v2\nevil/private\n1.0.0\n" + inventory[0][:digest] + "\nsource\nevil.private\n")
  foreign_link = h.root + "/projects/" + project + "/packages/foreign"
  system.command("/bin/ln", "-s", foreign, foreign_link).run()
  try: check(h.call("GET", route)[:packages].count == 1, "inventory follows shared references but never an arbitrary symlink outside the package store")
  ensure: fs.remove(foreign_link)
  run = h.start(project, saved[:revision])
  done = h.wait_run(run[:run_id])
  check(done[:state] == "succeeded" and done[:result][:cells][0][:result] == "42", "installed worker import")
  other = "packages-other"
  other_saved = h.upload(other, document("from editor_probe import answer\nanswer()\n"))
  downloads = fixture.downloads.count
  second_route = "/v1/projects/" + other + "/dependencies"
  second = h.call("POST", second_route, body.merge({command_id: "install-other", source: "test/editor-probe"}))
  reused = eventually:
    value = h.call("GET", second_route + "/" + second[:id])
    value unless ["queued", "running"].include?(value[:state])
  check(reused[:state] == "succeeded" and fixture.downloads.count == downloads, "second book reuses verified installation without downloading")
  local_project = "packages-local"
  local_saved = h.upload(local_project, document("from editor_probe import answer\nanswer()\n"))
  local_route = "/v1/projects/" + local_project + "/dependencies"
  local_job = h.call("POST", local_route, body.merge({command_id: "install-private", scope: "local"}))
  copied = eventually:
    value = h.call("GET", local_route + "/" + local_job[:id])
    value unless ["queued", "running"].include?(value[:state])
  check(copied[:state] == "succeeded" and fixture.downloads.count == downloads + 1, Json.generate(copied))
  private_package = h.call("GET", local_route)[:packages][0]
  check(private_package[:scope] == "local" and not fs.metadata(private_package[:directory]).symlink?, "notebook-only install keeps a private copy")
  check(fs.metadata(inventory[0][:directory]).symlink?, "notebook-only install leaves other shared references intact")
  local_run = h.wait_run(h.start(local_project, local_saved[:revision])[:run_id])
  check(local_run[:state] == "succeeded" and local_run[:result][:cells][0][:result] == "42", "notebook-only package resolves in its worker")
  h.delete(local_project)
  removed = h.call("POST", route, {command_id: "remove", action: "remove_sputnik", source: "test/editor-probe"})
  terminal = eventually:
    value = h.call("GET", route + "/" + removed[:id])
    value unless ["queued", "running"].include?(value[:state])
  check(terminal[:state] == "succeeded" and h.call("GET", route)[:packages].empty?, "remove installation")
  registry = h.call("GET", "/v1/projects/" + project + "/registry")
  check(registry[:reset_epochs].include?(run[:runtime_epoch]), "dependency changes retire runtime")
  other_run = h.start(other, other_saved[:revision])
  other_result = h.wait_run(other_run[:run_id])
  check(other_result[:state] == "succeeded" and other_result[:result][:cells][0][:result] == "42", "removing a book reference preserves another book's short import")
  missing = h.start(project, saved[:revision])
  missing_result = h.wait_run(missing[:run_id])
  check(missing_result[:state] == "failed" and missing_result[:result][:environment_error].starts_with?("Package module 'editor_probe'") and not missing_result[:result][:environment_error].contains?(h.root), "missing import explains the package action without server paths")
  damaged = "packages-damaged-cache"
  h.upload(damaged)
  other_inventory = h.call("GET", second_route)[:packages]
  archive = fs.entries(other_inventory[0][:directory]).find: $it.to_str.ends_with?(".sputnikpkg")
  original = fs.read_bytes(archive)
  try:
    # A different valid archive must not be trusted using the old index hash.
    fs.atomic_write_bytes(archive, fixture.archive("1.1.0"))
    rejected = h.call("POST", "/v1/projects/" + damaged + "/dependencies", body.merge({command_id: "damaged-cache"}))
    rejected_job = eventually:
      value = h.call("GET", "/v1/projects/" + damaged + "/dependencies/" + rejected[:id])
      value unless ["queued", "running"].include?(value[:state])
    check(rejected_job[:state] == "failed" and rejected_job[:error].contains?("failed verification"), "reuse verifies actual archive identity and digest instead of trusting the cached index")
  ensure: fs.atomic_write_bytes(archive, original)
  h.delete(damaged)
  h.delete(other)
  h.delete(project)
  print "PASS dependencies: registry install, receipts, isolated worker import, removal and runtime retirement"

def grants(h):
  project = "grants"
  saved = h.upload(project, document("from system import cmd\ncmd\"/usr/bin/printf allowed\".output\n"))
  run = h.start(project, saved[:revision])
  check(h.wait_run(run[:run_id])[:state] == "failed", "spawn is denied without grant")
  route = "/v1/projects/" + project + "/worker-settings/main"
  state = h.call("GET", route)
  h.call("PUT", route, {command_id: "grant", grants: ["process.spawn=/usr/bin/printf"], base_version: state[:version], runtime_epoch: run[:runtime_epoch]})
  check(h.request("PUT", route, {command_id: "stale", grants: [], base_version: state[:version], runtime_epoch: null})[0] == 409, "stale settings")
  run = h.start(project, saved[:revision])
  check(h.wait_run(run[:run_id])[:state] == "succeeded", "scoped spawn grant")
  h.restart_agent()
  check(h.call("GET", route)[:grants] == ["process.spawn=/usr/bin/printf"], "grants persist across restart")
  h.delete(project)
  print "PASS worker settings: deny, scoped grant, stale version and durable settings"

def interrupted(h):
  project = "interrupted"
  saved = h.upload(project, document("import task\ntask.sleep(60000)\n42\n"))
  run = h.start(project, saved[:revision], "once")
  h.wait_run(run[:run_id], "running")
  signal(h.agent, "KILL")
  eventually: not h.agent.running?
  h.restart_agent()
  done = h.wait_run(run[:run_id])
  check(done[:state] == "interrupted" and done[:error].contains?("not replayed"), "agent loss is interrupted without replay")
  check(h.start(project, saved[:revision], "once")[:run_id] == run[:run_id], "receipt survives interruption")
  h.delete(project)
  print "PASS agent failure: interrupted durable run, no replay and preserved receipt"

def serve_tests(args, root):
  h = Harness(args, root + "/lifecycle", serve: true, host: "0.0.0.0")
  try:
    saved, run, _result = h.value("serve", "40 + 2\n")
    check(h.request("GET", "/v1/health", authenticated: false)[0] == 401, "serve authentication")
    token = h.token
    agent = h.call("GET", "/v1/health")[:agent_pid]
    registry = h.call("GET", "/v1/projects/serve/registry")
    worker = registry[:runtimes].filter: $it[?:worker_pid] .first[:worker_pid]
    h.restart_agent()
    check(h.token == token and h.call("GET", "/v1/runs/" + run[:run_id])[:state] == "succeeded", "serve restart token and history")
    eventually: not alive?(agent) and not alive?(worker)
    duplicate = h.spawn("serve")
    try:
      eventually: not duplicate.running?
      check(h.agent.running? and h.call("GET", "/v1/health")[:agent_pid] != agent, "second service cannot adopt running agent")
    ensure: close_process(duplicate)
    agent = h.call("GET", "/v1/health")[:agent_pid]
    system.command("/bin/sh", "-c", "kill -KILL \"$1\"", "kill", agent.to_str).run()
    eventually: not h.agent.running?
    h.restart_agent()
    h.delete("serve")
  ensure: h.close!()
  occupied = Server(host: "0.0.0.0", port: 0, workers: 1, reuse_addr: false)
  occupied_port = occupied.port
  check(occupied_port > 0, "exclusive listener has an assigned port")
  process = ServiceProcess(args[:core], ["--mode", "serve", "--host", "0.0.0.0", "--port", occupied_port.to_str,
    "--root", root + "/bind-failure/new/state", "--worker", args[:worker], "--sputnik", args[:compiler]])
  try: eventually: not process.running?
  ensure:
    close_process(process)
    occupied.close!()
  retry = Harness(args, root + "/bind-failure", serve: true, port: occupied_port)
  retry.close!()
  print "PASS serve: SIGTERM cleanup, durable restart, duplicate ownership, agent failure and bind failure"

def command_test(root):
  directory = root + "/space ; $(touch SHOULD_NOT_EXIST) ' quoted"
  fs.mkdir_p(directory)
  literal = "literal $(touch ALSO_NOT_CREATED); \"quotes\""
  result = command_at(directory, "/bin/sh", ["-c", "printf '%s\\n%s\\n' \"$PWD\" \"$1\"", "child", literal], {LAUNCHER_TEST: "literal"}).capture(timeout: 10.0)
  check(result.stdout.to_str == directory + "\n" + literal + "\n", "literal cwd and argv")
  environment = command_at(directory, "/bin/sh", ["-c", "printf %s \"$LAUNCHER_TEST\""], {LAUNCHER_TEST: literal}).capture(timeout: 10.0)
  check(environment.stdout.to_str == literal, "literal environment")
  failed = command_at(directory + "/missing", "/usr/bin/printf", ["must not run"]).capture(timeout: 10.0, check: false)
  check(not failed.success? and not failed.stdout.to_str.contains?("must not run"), "missing cwd never runs command")
  check(not fs.exists?(directory + "/SHOULD_NOT_EXIST") and not fs.exists?(directory + "/ALSO_NOT_CREATED"), "no shell expansion")
  print "PASS command launcher: literal cwd, argv, environment and missing-directory rejection"

def main():
  parser = ArgParser()
  parser.arg("--core", required: true)
  parser.arg("--worker", required: true)
  parser.arg("--compiler", required: true)
  parser.arg("--root", required: true)
  parser.arg("--mode", default: "remote", choices: ["remote", "serve", "catalog", "catalog-ui", "command", "restart", "desktop-actions"])
  parser.arg("--ui-test")
  args = parser.parse_or_raise
  root = args[:root]
  fs.mkdir_p(root)
  if args[:mode] == "desktop-actions":
    desktop_actions(args, root)
    return 0
  if args[:mode] == "command":
    command_test(root)
    return 0
  if args[:mode] == "serve":
    serve_tests(args, root)
    return 0
  if args[:mode] == "restart":
    h = Harness(args, root + "/restart")
    try: durable_restart(h)
    ensure: h.close!()
    return 0
  fixture = PackageCatalogFixture(args[:compiler], root + "/registry")
  try:
    if args[:mode] == "catalog-ui":
      checked = system.command(args[:ui_test], args[:core], env: {SPUTNIK_PKG_REGISTRY: fixture.origin, SPUTNIK_TEST_PACKAGE_CATALOG: "1", SPUTNIK_PKG_CREDENTIALS: ""}).capture(timeout: 180.0)
      check(checked.success?, checked.stdout.to_str + checked.stderr.to_str)
      equal(fixture.downloads, ["1.0.0"], "editor downloads only its selected version")
      print checked.stdout.to_str
    else:
      h = Harness(args, root + "/remote", fixture.origin)
      try:
        catalog(h)
        unless args[:mode] == "catalog":
          snapshots(h)
          execution(h)
          cancellation(h)
          dependencies(h, fixture)
          grants(h)
          inputs(h)
          actions(h)
          durable_restart(h)
          targeted_commands(h)
          interrupted(h)
      ensure: h.close!()
  ensure: fixture.close!()
  print "PASS native Sputnik remote integration"
  0
