package test.notebook_remote_regressions

from "./notebook_remote_test_support" import check, eventually, document
from notebook.core.common import digest
import sqlite3

export inputs, actions, durable_restart

def equal(left, right, message): check(digest(left) == digest(right), message)

def input_cell(id, name, default, mode = "watch"):
  {id: id, kind: "code", mode: mode,
    source: name + " = notebook.cell_input(\"gain\")\n" + name + " * 2\n",
    cell_ui: {inputs: [{id: "gain", title: "Gain", type: "integer", default_json: default, minimum: 0, maximum: 100},
      {id: "exact", title: "Exact", type: "integer", default_json: "9223372036854775806"}],
      pre: [{id: "form", kind: "parameter_form", title: "Parameters", fields: [{input: "gain"}, {input: "exact"}]}],
      post: [{id: "metric", kind: "metric", title: "Result"}]}}

def inputs(h):
  project = "cell_inputs"
  doc = document()
  doc[:version] = 4
  doc[:inputs] = []
  doc[:boards] = []
  doc[:dependencies] = []
  doc[:sheets][0][:cells] = [input_cell("1", "a", "2"), input_cell("2", "b", "5"),
    {id: "3", kind: "code", mode: "watch", source: "a + b\n"}, input_cell("4", "m", "2", "manual")]
  doc[:sheets][0][:cells][1][:source] = "b = notebook.cell_input(\"gain\")\nb * 3\n"
  saved = h.upload(project, doc)
  route = "/v1/projects/" + project + "/cell-inputs"
  state = h.call("GET", route)
  first = h.call("PUT", route, {command_id: "input-before-run", revision: saved[:revision], base_version: state[:version], cell_id: "1", values: {gain: "3"}})
  check(not first.has_key?(:run_id), "editing unopened inputs does not execute")
  run = h.start(project, saved[:revision], null, {action: "run_all"})
  equal(h.wait_run(run[:run_id])[:result][:cells].map: $it[:result], ["6", "15", "8", "4"], "scoped input values")
  body = {command_id: "input-watch", revision: saved[:revision], base_version: first[:version], cell_id: "1", values: {gain: "7", exact: "9223372036854775807"}}
  applied = h.call("PUT", route, body)
  equal(h.call("PUT", route, body), applied, "input receipt")
  equal(h.wait_run(applied[:run_id])[:result][:cells].map: $it[:result], ["14", "15", "12", "4"], "watch updates do not rerun manual cells")
  state = h.call("GET", route)
  bad = {command_id: "overflow", revision: saved[:revision], base_version: state[:version], cell_id: "1", values: {gain: "8", exact: "9223372036854775808"}}
  check(h.request("PUT", route, bad)[0] == 422, "input overflow rejects atomic batch")
  equal(h.call("GET", route), state, "failed input batch leaves state unchanged")
  check(h.request("PUT", route, {command_id: "old-input", revision: saved[:revision], base_version: first[:version], cell_id: "1", values: {gain: "8"}})[0] == 409, "stale input version")
  h.restart_agent()
  equal(h.call("GET", route), state, "input state persists across agent restart")
  h.delete(project)
  project = "idle_watch"
  doc = document("x = 1\nKernel.watch(x)\nx\n")
  doc[:sheets][0][:cells][0][:mode] = "watch"
  saved = h.upload(project, doc)
  run = h.start(project, saved[:revision])
  h.wait_run(run[:run_id])
  registry_route = "/v1/projects/" + project + "/registry"
  watches = eventually:
    values = h.call("GET", registry_route)[:runs].filter: $it[:action] == "watch"
    values unless values.empty?
  h.wait_run(watches[-1][:id])
  task.sleep(0.5)
  count = h.call("GET", "/v1/projects/" + project + "/runs")[:runs].count
  check(count == 2, "idle watch pump stops creating work: " + count.to_str)
  h.upload(project, document("raise \"draft must not run\"\n"), {}, saved[:revision])
  task.sleep(0.4)
  check(h.call("GET", "/v1/projects/" + project + "/runs")[:runs].count == count, "saving a draft is inert")
  h.delete(project)
  print "PASS inputs and watch: atomic batches, int64, receipts, manual scope, durability and idle pump"

def actions(h):
  project = "actions"
  doc = document("raise \"controller must not execute\"\n")
  doc[:version] = 2
  doc[:inputs] = [{id: "gain", title: "Gain", type: "integer", default: 4}]
  doc[:modules] = [{id: "jobs", path: "modules/jobs.s"}]
  doc[:boards] = [{id: "dashboard", title: "Board", sheet: "main", columns: 1, components: [
    {id: "act", kind: "action", title: "Action", module_id: "jobs", function: "compute", p1: {arguments: [{id: "gain_arg", input: "gain"}]}},
    {id: "timer", kind: "periodic_work", title: "Timer", module_id: "jobs", function: "tick", period_seconds: 0.05, retention: "tail", tail_limit: 2, timing: "fixed_rate"}]}]
  module_source = "package jobs\nimport task\nclass Counter:\n  def init(): @value = 0\n  def next():\n    @value += 1\n    @value\nState = Counter()\ndef compute(x): [State.next(), x]\ndef tick():\n  task.sleep(300)\n  State.next()\nexport compute, tick\n"
  saved = h.upload(project, doc, {"modules/jobs.s": Base64.encode(module_source.bytes)})
  route = "/v1/projects/" + project
  body = {command_id: "action", revision: saved[:revision], action: "action_run", board_id: "dashboard", component_id: "act"}
  run = h.call("POST", route + "/runs", body)
  equal(h.call("POST", route + "/runs", body), run, "action receipt")
  check(h.wait_run(run[:run_id])[:result][:cells][0][:result] == "[1, 4]", "action isolates controller and captures arguments")
  settings = h.call("GET", route + "/inputs")
  h.call("PUT", route + "/inputs", {command_id: "gain", revision: saved[:revision], base_version: settings[:version], values: {gain: "9"}})
  body[:command_id] = "action-again"
  again = h.call("POST", route + "/runs", body)
  check(h.wait_run(again[:run_id])[:result][:cells][0][:result] == "[2, 9]", "action retains its private world")
  service = {command_id: "periodic-start", revision: saved[:revision], board_id: "dashboard", component_id: "timer", operation: "start"}
  h.call("POST", route + "/services", service)
  eventually: h.call("GET", route + "/services")[:services][0][:runs] >= 2
  h.restart_gateway()
  eventually: h.call("GET", route + "/services")[:services][0][:runs] >= 3
  service[:command_id] = "periodic-pause"
  service[:operation] = "pause"
  paused = h.call("POST", route + "/services", service)
  eventually: not h.call("GET", route + "/services")[:services][0][:running]
  state = h.call("GET", route + "/services")[:services][0]
  check(not state[:enabled] and state[:history].count == 2 and state[:skipped] > 0, "periodic pause, retention and skipped ticks")
  equal(h.call("POST", route + "/services", service), paused, "periodic receipt")
  service[:command_id] = "periodic-restart"
  service[:operation] = "start"
  h.call("POST", route + "/services", service)
  eventually: h.call("GET", route + "/services")[:services][0][:running]
  h.restart_agent()
  state = h.call("GET", route + "/services")[:services][0]
  check(not state[:enabled] and not state[:running], "agent restart pauses automatic execution")
  h.delete(project)
  print "PASS board actions and periodic work: isolated world, inputs, receipts, gateway restart, pause, retention and agent restart"

def durable_restart(h):
  project = "durable_restart"
  saved, run, _result = h.value(project, "42\n")
  route = "/v1/projects/" + project
  body = {command_id: "durable-reset", sheet_id: "main", runtime_epoch: run[:runtime_epoch]}
  sqlite3.open(h.root + "/metadata.sqlite") |db|:
    db.exec("BEGIN IMMEDIATE")
    try:
      check(h.request("POST", route + "/restart", body)[0] == 500, "restart reports failed durable publication")
    ensure: db.exec("ROLLBACK")
  registry = h.call("GET", route + "/runs")
  check(registry[:runtimes][0][:state] == "idle" and registry[:runtimes][0][:worker_pid] != null, "failed publication does not destroy live heap")
  h.call("POST", route + "/restart", body)
  newer = h.start(project, saved[:revision])
  check(h.wait_run(newer[:run_id])[:state] == "succeeded" and newer[:runtime_epoch] != run[:runtime_epoch], "retry publishes reset and creates new world")
  h.call("POST", route + "/restart", body)
  check(h.call("GET", route + "/runs")[:runtimes][-1][:epoch] == newer[:runtime_epoch], "old reset receipt cannot destroy newer world")
  h.delete(project)
  print "PASS durable restart: SQLite failure preserves heap, retry and receipt protect newer world"
