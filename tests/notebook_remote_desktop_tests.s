package test.notebook_remote_desktop

from "./notebook_remote_test_support" import check, eventually, document, Harness

export desktop_actions, targeted_commands

def targeted_commands(h):
  project = "desktop_contract"
  doc = document("42\n")
  doc[:version] = 2
  doc[:inputs] = []
  doc[:modules] = [{id: "jobs", path: "modules/jobs.s"}]
  doc[:boards] = [{id: "board", title: "Board", sheet: "main", columns: 1, components: [
    {id: "act", kind: "action", title: "Action", module_id: "jobs", function: "next"},
    {id: "timer", kind: "periodic_work", title: "Timer", module_id: "jobs", function: "next", period_seconds: 60, run_immediately: false}]}]
  source = "package jobs\nclass Counter:\n  def init(): @n = 0\n  def next():\n    @n += 1\n    @n\nState = Counter()\ndef next(): State.next()\nexport next\n"
  saved = h.upload(project, doc, {"modules/jobs.s": Base64.encode(source.bytes)})
  route = "/v1/projects/" + project
  invoke = {command_id: "first", revision: saved[:revision], board_id: "board", component_id: "act", action: "action_run"}
  first = h.call("POST", route + "/runs", invoke)
  check(h.wait_run(first[:run_id])[:result][:cells][0][:result] == "1", "first invocation")
  reset = {command_id: "reset", run_id: first[:run_id], runtime_epoch: first[:runtime_epoch]}
  check(h.request("POST", route + "/restart", reset.merge({runtime_epoch: "wrong", command_id: "stale"}))[0] == 409, "restart rejects stale epoch")
  check(h.request("POST", "/v1/projects/unknown/restart", reset)[0] == 404, "restart rejects cross-project run")
  h.call("POST", route + "/restart", reset)
  second = h.call("POST", route + "/runs", invoke.merge({command_id: "second"}))
  check(h.wait_run(second[:run_id])[:result][:cells][0][:result] == "1" and second[:runtime_epoch] != first[:runtime_epoch], "targeted restart resets invocation heap")
  h.call("POST", route + "/restart", reset)
  third = h.call("POST", route + "/runs", invoke.merge({command_id: "third"}))
  check(h.wait_run(third[:run_id])[:result][:cells][0][:result] == "2" and third[:runtime_epoch] == second[:runtime_epoch], "receipt replay cannot reset newer world")
  service = {command_id: "once", revision: saved[:revision], board_id: "board", component_id: "timer", operation: "once"}
  once = h.call("POST", route + "/services", service)
  h.wait_run(once[:run_id])
  h.call("POST", route + "/services", service.merge({command_id: "enable", operation: "start"}))
  once_record = h.call("GET", "/v1/runs/" + once[:run_id])
  service_reset = {command_id: "service-reset", run_id: once[:run_id], runtime_epoch: once_record[:epoch]}
  check(h.request("POST", route + "/restart", service_reset)[0] == 409, "enabled idle schedule must be paused before reset")
  h.call("POST", route + "/services", service.merge({command_id: "pause", operation: "pause"}))
  h.call("POST", route + "/restart", service_reset)
  metadata_route = route + "/runs/" + first[:run_id] + "/metadata"
  changed = h.call("POST", metadata_route, {command_id: "pin", operation: "update", base_version: "0", title: "Shared baseline", pinned: true})
  check(h.call("GET", "/v1/runs/" + first[:run_id])[:metadata][:title] == "Shared baseline", "server metadata persists")
  check(h.request("POST", metadata_route, {command_id: "old-version", operation: "update", base_version: "0", title: "Wrong", pinned: false})[0] == 409, "metadata CAS")
  check(h.request("POST", metadata_route, {command_id: "delete-pin", operation: "delete", base_version: changed[:metadata][:version]})[0] == 409, "pinned runs cannot be deleted")
  unpinned = h.call("POST", metadata_route, {command_id: "unpin", operation: "update", base_version: changed[:metadata][:version], title: "Shared baseline", pinned: false})
  deletion = {command_id: "delete", operation: "delete", base_version: unpinned[:metadata][:version]}
  h.call("POST", metadata_route, deletion)
  h.call("POST", metadata_route, deletion)
  check(h.request("GET", "/v1/runs/" + first[:run_id])[0] == 404, "delete removes server history and receipt replays safely")
  page = h.call("GET", route + "/runs?limit=1")
  check(page[:runs].count == 1 and page[:next] != null, "bounded history page")
  check(h.call("GET", route + "/runs?limit=1&before=" + page[:next].to_str)[:runs].count == 1, "older history cursor")
  h.delete(project)
  print "PASS desktop HTTP contract: targeted restart, service pause, epoch, replay, shared metadata, deletion and history paging"

def desktop_actions(args, root):
  h = Harness(args, root + "/desktop")
  try:
    book = h.directory + "/Audit.sputnikbook"
    fs.mkdir_p(book + "/modules")
    fs.mkdir_p(book + "/images")
    fs.mkdir_p(book + "/inputs")
    doc = document("[notebook.read_image(\"gallery\")[:caption], notebook.input(\"when\"), notebook.cell_input(\"exact\")]\n")
    doc[:version] = 4
    doc[:dependencies] = []
    doc[:inputs] = [{id: "when", title: "Timestamp", type: "string", default: ""}, {id: "day", title: "Calendar date", type: "string", default: ""}, {id: "dataset", title: "Dataset", type: "string", default: "inputs/sample.txt"}]
    doc[:sheets][0][:cells][0][:cell_ui] = {inputs: [{id: "exact", title: "Exact", type: "integer", default_json: "9223372036854775806"}], pre: [], post: []}
    doc[:sheets][0][:cells].push!({id: "2", kind: "code", source: "import task\ntask.sleep(30000)\n42\n", mode: "manual"})
    doc[:modules] = [{id: "jobs", path: "modules/jobs.s"}]
    components = [
      {id: "counter", kind: "action", title: "Counter", module_id: "jobs", function: "next"},
      {id: "a", kind: "action", title: "A", module_id: "jobs", function: "slow"},
      {id: "b", kind: "action", title: "B", module_id: "jobs", function: "slow"},
      {id: "timer", kind: "periodic_work", title: "Timer", module_id: "jobs", function: "next", period_seconds: 60, run_immediately: false},
      {id: "gallery", kind: "image_carousel", title: "Gallery", image_id: "gallery", image_allow_load: true, image_allow_read: true, image_selection: 0,
        image_items: [{path: "images/one.png", caption: "First"}, {path: "images/one.png", caption: "Second"}]},
      {id: "history", kind: "run_history", title: "History", cell: "1"},
      {id: "dataset", kind: "file_input", title: "Dataset", input: "dataset"},
      {id: "date", kind: "date_input", title: "Date", input: "day", date_mode: "date", date_time_zone: "Europe/Moscow"},
      {id: "timestamp", kind: "date_input", title: "Timestamp", input: "when", date_mode: "date_time", date_time_zone: "Europe/Moscow"}]
    [["a", "action"], ["b", "action"], ["timer", "service"]].each |pair|:
      components.push!({id: "control_" + pair[0], kind: "execution_controls", title: "Controls " + pair[0], p1: {target_kind: pair[1], target_component: pair[0]}})
    doc[:boards] = [{id: "board", title: "Remote regression", sheet: "main", columns: 1, components: components}]
    fs.atomic_write_text(book + "/project.json", Json.generate(doc))
    fs.atomic_write_text(book + "/modules/jobs.s", "package jobs\nimport task\nclass Counter:\n  def init(): @n = 0\n  def next():\n    @n += 1\n    @n\nState = Counter()\ndef next(): State.next()\ndef slow():\n  task.sleep(30000)\n  State.next()\nexport next, slow\n")
    fs.atomic_write_bytes(book + "/images/one.png", Base64.decode("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII="))
    fs.atomic_write_text(book + "/inputs/sample.txt", "first")
    fs.atomic_write_text(book + "/inputs/other.txt", "second")
    wrapper = h.directory + "/lost-reply-client"
    fs.atomic_write_text(wrapper, "#!/bin/sh\n" + """
      command=''
      previous=''
      for argument in "$@"; do
        if [ "$previous" = '--command' ]; then command=$argument; fi
        previous=$argument
      done
      response=$(mktemp /tmp/spr-reply.XXXXXXXX)
      trap 'rm -f -- "$response"' EXIT
      "$SPUTNIK_TEST_CORE" "$@" > "$response"
      status=$?
      if [ "$status" = 0 ] && [ -f "$SPUTNIK_TEST_FAULT" ] && [ "$command" = "$(cat "$SPUTNIK_TEST_FAULT")" ]; then
        rm -f -- "$SPUTNIK_TEST_FAULT"
        exit 74
      fi
      cat "$response"
      exit "$status"
      """)
    system.command("/bin/chmod", "700", wrapper).run()
    result = system.command(args[:ui_test], "--root", h.directory, "--book", book, "--core", args[:core], "--worker", args[:worker],
      "--fault-core", wrapper, "--url", "http://127.0.0.1:" + h.port.to_str, "--token", h.root + "/token",
      env: {SPUTNIK_TEST_CORE: args[:core], SPUTNIK_TEST_FAULT: h.directory + "/drop-reply"}).capture(timeout: 360.0, check: false)
    print result.stdout.to_str
    print result.stderr.to_str unless result.stderr.empty?
    check(result.success?, "desktop remote regression failed")
  ensure: h.close!()
