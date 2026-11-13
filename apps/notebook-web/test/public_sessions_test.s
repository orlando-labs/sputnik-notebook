package public_sessions_test

import "../backend/database" as database
from "../backend/notebooks" import Notebooks
from "../backend/public_sessions" import PublicSessions
from "../backend/models" import WebError, NotFound
from notebook.core.client import Client
from notebook.core.common import terminal?
import public_fixture

export main

def check(value, message):
  raise ValueError("public sessions: " + message) unless value

def status(&operation):
  try:
    operation()
    200
  rescue WebError |error|: error.status

def expect_status(expected, message, &operation):
  check(status(&operation) == expected, message)

def sleeping_run(public, visitor, session):
  token = session[:session_id]
  document = Json.parse(public.read(visitor, token)[:notebook][:document])
  document[:sheets][0][:cells][0][:source] = "import task\ntask.sleep(10000)\n1\n"
  saved = public.save(visitor, token, {command_id: "ip-save", base_revision: session[:revision], document: Json.generate(document)})[:notebook]
  {command_id: "ip-run", revision: saved[:revision], sheet_id: "main", cell_id: "1", action: "run_all"}

def check_worker_capacity(core, public, root):
  core.handle("policy.configure", {scope: "core", id: "core", limits: {public_max_active_workers: 1}})
  alice = SecureRandom.hex(32)
  bob = SecureRandom.hex(32)
  first = public.open(alice, "starter", "capacity", "192.0.2.81")
  second = public.open(bob, "starter", "capacity", "192.0.2.82")
  run = public.start(alice, first[:session_id], sleeping_run(public, alice, first), "192.0.2.81")[:run]
  next_run = {command_id: "waiting", revision: second[:revision], sheet_id: "main", cell_id: "1", action: "run_all"}
  runtimes = fs.entries(root + "/runtimes").map: $it.to_str
  expect_status(429, "active guest workers share a Core-wide limit across IPs"):
    public.start(bob, second[:session_id], next_run, "192.0.2.82")
  unchanged = fs.entries(root + "/runtimes").all? |path|: runtimes.include?(path.to_str)
  check(unchanged, "a rejected worker slot does not stage a new runtime")
  check(public.receipt(bob, second[:session_id], "waiting")[:command][:state] == "unknown", "a rejected worker slot leaves no accepted command")
  check(public.read(bob, second[:session_id])[:resources][:spent_ms] == "0", "a rejected worker slot uses no guest budget")
  public.stop(alice, first[:session_id], run[:id], {command_id: "free-slot", runtime_epoch: run[:runtime_epoch], force: true})
  300.times:
    break if terminal?(public.run(alice, first[:session_id], run[:id])[:run][:state])
    task.sleep(0.02)
  accepted = public.start(bob, second[:session_id], next_run, "192.0.2.82")
  check(accepted[:run][:id] != run[:id], "the same command can be submitted when the active slot is released")
  public.close(alice, first[:session_id])
  public.close(bob, second[:session_id])

def check_ip_budget(core, public):
  core.handle("policy.configure", {scope: "core", id: "core", limits: {public_ip_daily_seconds: 3}})
  first_ip = "2001:db8::1"
  same_ip = "2001:0DB8:0000:0000:0000:0000:0000:0001"
  different_ip = "2001:db8::2"
  alice = SecureRandom.hex(32)
  bob = SecureRandom.hex(32)
  first = public.open(alice, "starter", "network", first_ip)
  second = public.open(bob, "starter", "network", same_ip)
  retry = public.open(alice, "starter", "network", same_ip)
  check(retry[:session_id] == first[:session_id] and first[:resources][:ip_remaining_ms] == "3000", "equivalent IPv6 forms share one IP budget and retry")
  expect_status(410, "a retry cannot change the IP for a public copy"): public.open(alice, "starter", "network", different_ip)
  run = sleeping_run(public, alice, first)
  expect_status(410, "a moved session cannot start new work from a different IP"):
    public.start(alice, first[:session_id], run, different_ip)
  other_run = sleeping_run(public, bob, second)
  public.start(alice, first[:session_id], run, first_ip)
  public.start(bob, second[:session_id], other_run, same_ip)
  left = null
  right = null
  600.times:
    left = public.read(alice, first[:session_id])
    right = public.read(bob, second[:session_id])
    break if terminal?(left[:runs][0][:state]) and terminal?(right[:runs][0][:state])
    task.sleep(0.02)
  [left, right].each |state|:
    check(state[:runs][0][:state] == "force-stopped" and state[:resources][:remaining_ms] == "0", "the shared IP limit stops both active runs")
    check(state[:resources][:spent_ms].to_int < 3000, "each cookie used only part of the shared budget")
  public.close(alice, first[:session_id])
  public.close(bob, second[:session_id])
  visitor = SecureRandom.hex(32)
  fresh = public.open(visitor, "starter", "fresh-cookie", same_ip)
  check(fresh[:resources][:spent_ms] == "0" and fresh[:resources][:ip_remaining_ms] == "0", "new cookie does not reset the IP budget")
  expect_status(403, "new starts are blocked at the IP cap"):
    public.start(visitor, fresh[:session_id], {command_id: "fresh-run", revision: fresh[:revision], sheet_id: "main", cell_id: "1", action: "run_all"}, same_ip)
  public.close(visitor, fresh[:session_id])
  independent = public.open(visitor, "starter", "other-ip", different_ip)
  check(independent[:resources][:remaining_ms] == "3000", "another IPv6 address has its own budget")
  public.close(visitor, independent[:session_id])
  v4 = public.open(visitor, "starter", "ipv4", "192.0.2.40")
  mapped = public.open(visitor, "starter", "ipv4", "::FFFF:C000:0228")
  dotted = public.open(visitor, "starter", "ipv4", "::ffff:192.0.2.40")
  check(mapped[:session_id] == v4[:session_id] and dotted[:session_id] == v4[:session_id], "IPv4 and mapped IPv6 share one identity")
  public.close(visitor, v4[:session_id])

def main():
  parser = ArgParser()
  parser.arg("--database", required: true)
  parser.arg("--core-root", required: true)
  args = parser.parse_or_raise
  opened = database.open(args[:database])
  try:
    core = Client(args[:core_root])
    catalog = opened[1]
    catalog.core_policy!(core)
    books = Notebooks(catalog, core)
    templates = public_fixture.templates(core)
    core.handle("policy.configure", {scope: "profile", id: "public", limits: {persistence: "durable", run_seconds: 600, total_run_seconds: 600, lease_seconds: 600, session_seconds: 36000}})
    public = PublicSessions(catalog, books, opened[0], templates, "fixture-session-secret-at-least-32-bytes")
    alice = SecureRandom.hex(32)
    bob = SecureRandom.hex(32)
    ip = "192.0.2.10"
    first = public.open(alice, "starter", "open-one", ip)
    same = public.open(alice, "starter", "open-one", ip)
    check(first[:session_id] == same[:session_id] and first[:revision] == same[:revision], "uncertain open retries one copy")
    check(first[:resources][:effective][:run_seconds] == "60" and first[:resources][:effective][:total_run_seconds] == "60", "published book cannot lift public ceilings")
    check(first[:resources][:effective][:project_bytes] == "67108864", "anonymous storage ceiling bounds a higher book override")
    policy = core.handle("policy.get", {project_id: public.owned(alice, first[:session_id])[:core_project_id]})[:effective]
    check(policy[:lease_seconds] <= 15 and policy[:session_seconds] <= 900 and policy[:persistence] == "session", "replaced public profiles cannot extend anonymous leases or persistence")
    expect_status(404, "cookie principal is required in addition to the token"): public.read(bob, first[:session_id])
    expect_status(404, "unlisted templates stay private"): public.open(alice, "unlisted", "foreign", ip)
    expect_status(429, "one active copy per visitor"): public.open(alice, "starter", "second-active", ip)
    source = public.read(alice, first[:session_id])
    check(source[:runs].empty? and source[:notebook][:document].contains?("Hello, Sputnik!") and not source[:notebook][:document].contains?("Unpublished"), "pinned revision, inert opening")
    check(not Json.generate(public.listing()).contains?("source_project"), "listing hides Core identities")
    core.handle("policy.configure", {scope: "user", id: "anonymous_" + bob, limits: {total_run_seconds: 2, project_bytes: 1048576, max_run_bytes: 65536}})
    bounded = public.open(bob, "starter", "operator-ceiling", ip)
    check(bounded[:resources][:effective][:total_run_seconds] == "2" and bounded[:resources][:effective][:project_bytes] == "1048576", "anonymous open preserves tighter operator ceilings")
    parallel = Json.parse(public.read(bob, bounded[:session_id])[:notebook][:document])
    parallel[:sheets][0][:cells][0][:source] = "import task\ntask.sleep(10000)\n1\n"
    parallel[:sheets].push!({id: "other", title: "Other", cells: [{id: "4", kind: "code", mode: "manual", source: "import task\ntask.sleep(10000)\n2\n"}]})
    edited = public.save(bob, bounded[:session_id], {command_id: "parallel-save", base_revision: bounded[:revision], document: Json.generate(parallel)})[:notebook]
    public.start(bob, bounded[:session_id], {command_id: "parallel-main", revision: edited[:revision], sheet_id: "main", cell_id: "1", action: "run_all"}, ip)
    public.start(bob, bounded[:session_id], {command_id: "parallel-other", revision: edited[:revision], sheet_id: "other", cell_id: "4", action: "run_all"}, ip)
    exhausted = null
    600.times:
      exhausted = public.read(bob, bounded[:session_id])
      break if exhausted[:runs].count == 2 and exhausted[:runs].all? |run|: terminal?(run[:state])
      task.sleep(0.02)
    check(exhausted[:resources][:remaining_ms] == "0", "parallel sheets share the anonymous aggregate ceiling")
    public.close(bob, bounded[:session_id])
    document = Json.parse(source[:notebook][:document])
    document[:sheets][0][:cells][0][:source] = "import task\ntask.sleep(300)\n99\n"
    saved = public.save(alice, first[:session_id], {command_id: "save-copy", base_revision: first[:revision], document: Json.generate(document)})
    accepted = public.start(alice, first[:session_id], {command_id: "run-copy", revision: saved[:notebook][:revision], sheet_id: "main", cell_id: "1", action: "run_all"}, ip)[:run]
    final = null
    600.times:
      final = public.run(alice, first[:session_id], accepted[:id])[:run]
      break if terminal?(final[:state])
      task.sleep(0.02)
    check(final[:state] == "succeeded" and final[:cells][0][:result] == "99", "anonymous code executes only after explicit run")
    check(public.receipt(alice, first[:session_id], "run-copy")[:command][:run][:id] == accepted[:id], "run receipt preserves command identity")
    remaining = public.read(alice, first[:session_id])[:resources][:remaining_ms].to_int
    check(remaining < 60000, "real execution charges the visitor")
    public.close(alice, first[:session_id])
    reopened = public.open(alice, "starter", "new-copy", ip)
    check(reopened[:resources][:remaining_ms].to_int <= remaining, "fresh copies do not reset anonymous aggregate accounting")
    expect_status(404, "foreign visitor cannot read a run"): public.run(bob, reopened[:session_id], accepted[:id])
    public.close(alice, reopened[:session_id])
    copies = []
    16.times |index|:
      visitor = SecureRandom.hex(32)
      copy = public.open(visitor, "starter", "capacity", ip)
      copies.push!([visitor, copy[:session_id]])
    expect_status(429, "global active-copy admission cannot be bypassed with a new visitor"):
      public.open(SecureRandom.hex(32), "starter", "over-capacity", ip)
    copies.each |copy|: public.close(copy[0], copy[1])
    check_ip_budget(core, public)
    check_worker_capacity(core, public, args[:core_root])
    print "PASS public pinned templates, idempotent opens, visitor isolation, admission, worker capacity, storage/time ceilings and shared IP accounting"
  ensure:
    opened[0].close!
