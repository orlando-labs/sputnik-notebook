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
    public = PublicSessions(catalog, books, opened[0], templates)
    alice = SecureRandom.hex(32)
    bob = SecureRandom.hex(32)
    first = public.open(alice, "starter", "open-one")
    same = public.open(alice, "starter", "open-one")
    check(first[:session_id] == same[:session_id] and first[:revision] == same[:revision], "uncertain open retries one copy")
    check(first[:resources][:effective][:run_seconds] == "60" and first[:resources][:effective][:total_run_seconds] == "60", "published book cannot lift public ceilings")
    check(first[:resources][:effective][:project_bytes] == "67108864", "anonymous storage ceiling bounds a higher book override")
    policy = core.handle("policy.get", {project_id: public.owned(alice, first[:session_id])[:core_project_id]})[:effective]
    check(policy[:lease_seconds] <= 15 and policy[:session_seconds] <= 900 and policy[:persistence] == "session", "replaced public profiles cannot extend anonymous leases or persistence")
    expect_status(404, "cookie principal is required in addition to the token"): public.read(bob, first[:session_id])
    expect_status(404, "unlisted templates stay private"): public.open(alice, "unlisted", "foreign")
    expect_status(429, "one active copy per visitor"): public.open(alice, "starter", "second-active")
    source = public.read(alice, first[:session_id])
    check(source[:runs].empty? and source[:notebook][:document].contains?("Hello, Sputnik!") and not source[:notebook][:document].contains?("Unpublished"), "pinned revision, inert opening")
    check(not Json.generate(public.listing()).contains?("source_project"), "listing hides Core identities")
    core.handle("policy.configure", {scope: "user", id: "anonymous_" + bob, limits: {total_run_seconds: 2, project_bytes: 1048576, max_run_bytes: 65536}})
    bounded = public.open(bob, "starter", "operator-ceiling")
    check(bounded[:resources][:effective][:total_run_seconds] == "2" and bounded[:resources][:effective][:project_bytes] == "1048576", "anonymous open preserves tighter operator ceilings")
    parallel = Json.parse(public.read(bob, bounded[:session_id])[:notebook][:document])
    parallel[:sheets][0][:cells][0][:source] = "import task\ntask.sleep(10000)\n1\n"
    parallel[:sheets].push!({id: "other", title: "Other", cells: [{id: "2", kind: "code", mode: "manual", source: "import task\ntask.sleep(10000)\n2\n"}]})
    edited = public.save(bob, bounded[:session_id], {command_id: "parallel-save", base_revision: bounded[:revision], document: Json.generate(parallel)})[:notebook]
    public.start(bob, bounded[:session_id], {command_id: "parallel-main", revision: edited[:revision], sheet_id: "main", cell_id: "1", action: "run_all"})
    public.start(bob, bounded[:session_id], {command_id: "parallel-other", revision: edited[:revision], sheet_id: "other", cell_id: "2", action: "run_all"})
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
    accepted = public.start(alice, first[:session_id], {command_id: "run-copy", revision: saved[:notebook][:revision], sheet_id: "main", cell_id: "1", action: "run_all"})[:run]
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
    reopened = public.open(alice, "starter", "new-copy")
    check(reopened[:resources][:remaining_ms].to_int <= remaining, "fresh copies do not reset anonymous aggregate accounting")
    expect_status(404, "foreign visitor cannot read a run"): public.run(bob, reopened[:session_id], accepted[:id])
    public.close(alice, reopened[:session_id])
    copies = []
    16.times |index|:
      visitor = SecureRandom.hex(32)
      copy = public.open(visitor, "starter", "capacity")
      copies.push!([visitor, copy[:session_id]])
    expect_status(429, "global active-copy admission cannot be bypassed with a new visitor"):
      public.open(SecureRandom.hex(32), "starter", "over-capacity")
    copies.each |copy|: public.close(copy[0], copy[1])
    print "PASS public pinned templates, idempotent opens, visitor isolation, admission, storage/time ceilings, explicit execution and aggregate accounting"
  ensure:
    opened[0].close!
