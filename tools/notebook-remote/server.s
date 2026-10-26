package notebook.remote.server

from net.http import Server, ServerResponse
from notebook.remote.common import APIError, fail, decode, rpc
from notebook.remote.core import Core

export agent, gateway

def agent(root, worker, python, ruby, gc_interval, gc_age, compiler):
  fail(400, "GC interval and age must be nonnegative") if gc_interval < 0 or gc_age < 0
  core = Core(root, worker, python: python, ruby: ruby, compiler: compiler)
  core.schedule_work()
  core.schedule_gc(gc_interval, gc_age)
  path = root + "/agent.sock"
  fs.remove(path) if fs.exists?(path)
  listener = net.unix.listen(path, isolation: :unchecked)
  active = Atomic.new(0)
  loop:
    socket = listener.accept!()
    if active.get >= 16:
      socket.close!()
    else:
      active.update: $it + 1
      serve_connection(core, socket, active)

# Each call owns a separate parameter frame, so concurrent requests cannot
# capture a socket variable reassigned by the accept loop.
def serve_connection(core, socket, active):
  task.async:
    try:
      response = null
      try:
        text = socket.read_line!(limit: 100663296, timeout: 30.0)
        fail(400, "invalid agent request") unless text
        request = decode(text.to_str)
        params = request[?:params] or {}
        fail(400, "invalid request") unless Map === request and Map === params
        response = {status: 200, data: core.handle(request[?:method], params)}
      rescue APIError |e|:
        response = {status: e.status, error: e.message}
      rescue JsonParseError, ArgumentError, TypeError |e|:
        response = {status: 400, error: e.message}
      rescue Exception |e|:
        response = {status: 500, error: e.message}
      socket.write_all!((Json.generate(response) + "\n").bytes, timeout: 30.0)
    rescue Exception:
      null
    ensure:
      try: socket.close!()
      ensure: active.update: $it - 1

def reply(status, value):
  ServerResponse.text(Json.generate(value), status: status, headers: {"content-type": "application/json; charset=utf-8"})

def dispatch(root, token, request):
  return reply(401, {error: "unauthorized"}) unless request.headers.first("authorization") == "Bearer " + token
  body = request.body_text()
  params = if body == "" then {} else decode(body)
  fail(400, "request must be an object") unless Map === params
  route = request.path.split("/").filter: $it != ""
  verb = request.method
  method = null
  download = null
  if route == ["v1", "maintenance", "orphans"] and verb == "POST": method = "environments.gc"
  elif route == ["v1", "health"] and verb == "GET": method = "health"
  elif route == ["v1", "projects"] and verb == "GET": method = "project.list"
  elif route.count >= 3 and route[0] == "v1" and route[1] == "projects":
    params[:project_id] = route[2]
    if route.count == 3:
      method = {GET: "project.get", PUT: "project.put", DELETE: "project.delete"}[?verb]
    elif route.count == 4:
      if route[3] == "dependencies": method = {GET: "dependency.status", POST: "dependency.change"}[?verb]
      elif route[3] == "package-catalog" and verb == "POST": method = "dependency.catalog"
      elif route[3] == "environments": method = {GET: "environment.list", POST: "environment.prepare"}[?verb]
      elif route[3] == "runs": method = {GET: "run.list", POST: "run.start"}[?verb]
      elif route[3] == "inputs": method = {GET: "project.inputs", PUT: "project.inputs.set"}[?verb]
      elif route[3] == "services": method = {GET: "service.list", POST: "service.configure"}[?verb]
      elif route[3] == "cell-inputs": method = {GET: "cell.inputs", PUT: "cell.inputs.set"}[?verb]
      elif route[3] == "registry" and verb == "GET": method = "run.registry"
      elif route[3] == "restart" and verb == "POST": method = "runtime.restart"
      elif route[3] == "events" and verb == "GET":
        method = "events"
        query = request.query or ""
        fail(400, "invalid event cursor") unless query == "" or query.starts_with?("after=")
        params[:after] = if query == "" then 0 else query.slice(6...query.length).to_int()
    elif route.count == 5 and verb == "GET":
      if route[3] == "dependencies":
        method = "dependency.get"
        params[:operation_id] = route[4]
      elif route[3] == "environments":
        method = "environment.get"
        params[:environment_id] = route[4]
      elif route[3] == "worker-settings":
        method = "worker.settings"
        params[:sheet_id] = route[4]
      elif route[3] == "revisions":
        method = "revision.get"
        params[:revision] = route[4]
      elif route[3] == "commands":
        method = "receipt.get"
        params[:command_id] = route[4]
    elif route.count == 5 and verb == "PUT" and route[3] == "worker-settings":
      method = "worker.configure"
      params[:sheet_id] = route[4]
    elif route.count == 6 and verb == "GET" and route[3] == "revisions" and route[5] == "document":
      method = "revision.document"
      params[:revision] = route[4]
  elif route.count >= 3 and route[0] == "v1" and route[1] == "runs":
    params[:run_id] = route[2]
    if route.count == 3 and verb == "GET": method = "run.get"
    elif route.count == 4:
      if route[3] == "stop" and verb == "POST": method = "run.stop"
      elif ["presentation", "live"].include?(route[3]) and verb == "GET":
        method = "run.get"
        download = route[3]
  fail(404, "unknown endpoint") unless method
  response = rpc(root, method, params: params)
  return reply(response[:status], {error: response[:error]}) unless response[:status] == 200
  if download:
    path = response[:data][if download == "live" then "live_presentation" else "presentation"]
    fail(404, "no terminal presentation") unless path
    fail(500, "invalid artifact location") unless fs.Path(path).parent.to_str == root + "/runs"
    ServerResponse(body: fs.read_bytes(path, limit: 134217728), headers: {"content-type": "application/vnd.sputnik.notebook-presentation"})
  else: reply(200, response[:data])

def gateway(root, port):
  token = fs.read_text(root + "/token").trim
  server = Server(host: "127.0.0.1", port: port, workers: 4, max_concurrent_per_worker: 4,
    max_header_bytes: 32768, max_body_bytes: 100663296, read_timeout: 30.0, write_timeout: 30.0)
  server.serve |request|:
    try: dispatch(root, token, request)
    rescue APIError |e|: reply(e.status, {error: e.message})
    rescue JsonParseError, ArgumentError, TypeError |e|: reply(400, {error: e.message})
    rescue Exception |e|: reply(503, {error: "agent unavailable: " + e.message})
