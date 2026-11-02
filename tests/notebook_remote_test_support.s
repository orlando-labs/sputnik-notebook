package test.notebook_remote_support

from net.http import Client, Server
from notebook.core.host import ServiceProcess
from notebook.core.common import digest

export check, eventually, document, reserve, close_process, signal, alive?, Harness

def check(value, message = "assertion failed"):
  raise ValueError(message) unless value

def eventually(&probe):
  last_error = ""
  1200.times:
    value = null
    try: value = probe()
    rescue Exception |error|: last_error = error.message
    return value if value
    task.sleep(0.025)
  raise ValueError("timed out waiting for test condition: " + last_error)

def document(source = "42\n"):
  {format: "sputnik-notebook", version: 1, title: "Remote test", active_sheet: "main",
    sheets: [{id: "main", title: "Main", cells: [{id: "1", kind: "code", source: source, mode: "manual"}]}],
    modules: [], auto_imports: [], future_metadata: {integer: 9007199254740995, text: "сохранить"}}

def reserve(): Server(host: "127.0.0.1", port: 0, workers: 1, reuse_addr: false)

def close_process(process):
  if process:
    try: process.close!()
    ensure: process.destroy!()

def signal(process, name):
  system.command("/bin/sh", "-c", "kill -\"$1\" \"$2\"", "kill", name, process.pid.to_str).run()

def alive?(pid):
  path = "/proc/" + pid.to_str + "/stat"
  if fs.exists?(path): return fs.read_text(path).split(") ")[1].split(" ")[0] != "Z"
  system.command("/bin/sh", "-c", "kill -0 \"$1\"", "kill", pid.to_str).capture(check: false).success?

class Harness:
  attr root
  attr port
  attr token
  attr agent
  attr gateway
  attr args
  attr directory

  def init(@args, @directory, origin = null, serve: false, host: "127.0.0.1", port: null):
    @root = directory + "/new/state"
    fs.mkdir_p(directory)
    reservation = reserve()
    @port = port or reservation.port
    reservation.close!()
    @origin = origin
    @serve = serve
    @host = host
    @agent = null
    @gateway = null
    @http = Client(timeout: 10.0)
    start_agent()
    start_gateway() unless serve
    ready()

  def spawn(mode, extra = []):
    env = ["SPUTNIK_PKG_HOME=" + @directory + "/packages", "SPUTNIK_PKG_CREDENTIALS="]
    env.push!("SPUTNIK_PKG_REGISTRY=" + @origin) if @origin
    command = [@args[:core], "--mode", mode, "--root", @root, "--worker", @args[:worker],
      "--sputnik", @args[:compiler], "--python", "/__sputnik_test_no_python__",
      "--port", @port.to_str, "--host", @host] + extra
    ServiceProcess("/usr/bin/env", env + command)

  def start_agent():
    @agent = spawn(if @serve then "serve" else "agent")
    eventually: fs.exists?(@root + "/token") and fs.exists?(@root + "/agent.sock")
    @token = fs.read_text(@root + "/token").trim

  def start_gateway(): @gateway = spawn("gateway")

  def ready():
    eventually:
      check(@agent.running?, "agent exited during startup")
      response = request("GET", "/v1/health")
      response[1] if response[0] == 200

  def request(method, route, body = null, authenticated: true, binary: false):
    headers = {"content-type": "application/json", connection: "close"}
    headers["authorization"] = "Bearer " + @token if authenticated
    url = "http://127.0.0.1:" + @port.to_str + route
    if method == "DELETE":
      config = @directory + "/http-private-config"
      fs.File.open(config, :write, create: true, permissions: 384) |file|:
        file.write_all!(("header = \"Authorization: Bearer " + @token + "\"\n").bytes)
      payload = @directory + "/http-body.json"
      fs.atomic_write_text(payload, Json.generate(body or {}))
      result = system.command("curl", "--http1.1", "--silent", "--show-error", "--max-time", "3",
        "--config", config, "--request", "DELETE", "--header", "Content-Type: application/json",
        "--data-binary", "@" + payload, "--write-out", "\n%{http_code}", url).capture(timeout: 5.0)
      check(result.success?, result.stderr.to_str)
      lines = result.stdout.to_str.split("\n")
      return [lines[-1].to_int, Json.parse(lines[0])]
    response = case method:
      when "GET": @http.get(url, headers: headers)
      when "POST": @http.post(url, headers: headers, body: Json.generate(body or {}))
      when "PUT": @http.put(url, headers: headers, body: Json.generate(body or {}))
      else: raise ArgumentError("test HTTP method")
    [response.status, (if binary then response.body_bytes else Json.parse(response.body_text))]

  def call(method, route, body = null):
    reply = request(method, route, body)
    check(reply[0] == 200, Json.generate(reply))
    reply[1]

  def upload(project, doc = null, files = {}, base = null, command = null):
    call("PUT", "/v1/projects/" + project, {command_id: command or SecureRandom.hex(12), base_revision: base,
      document: Json.generate(doc or document()), files: files})

  def start(project, revision, command = null, options = {}):
    body = {command_id: command or SecureRandom.hex(12), revision: revision, sheet_id: "main", cell_id: "1", action: "run"}
    options.each |key, value|: body.store!(key, value)
    call("POST", "/v1/projects/" + project + "/runs", body)

  def wait_run(id, state = null):
    eventually:
      value = call("GET", "/v1/runs/" + id)
      value if value[:state] == state or (state == null and ["succeeded", "failed", "cancelled", "force-stopped", "interrupted"].include?(value[:state]))

  def value(project, source, expected = "42"):
    saved = upload(project, document(source))
    run = start(project, saved[:revision])
    result = wait_run(run[:run_id])
    check(result[:state] == "succeeded", Json.generate(result))
    check(result[:result][:cells][0][:result] == expected, Json.generate(result))
    [saved, run, result]

  def delete(project):
    reply = request("DELETE", "/v1/projects/" + project, {command_id: SecureRandom.hex(12)})
    check([200, 404].include?(reply[0]), Json.generate(reply))
    if reply[0] == 200:
      eventually: call("GET", "/v1/projects/" + project)[:state] == "deleted"

  def restart_agent():
    close_process(@agent)
    @agent = null
    close_process(@gateway) if @serve
    start_agent()
    ready()

  def restart_gateway():
    close_process(@gateway)
    @gateway = null
    start_gateway()
    ready()

  def close!():
    try: close_process(@gateway)
    ensure:
      try: close_process(@agent)
      ensure: @http.close!()
