package notebook.remote.client

from net.http import Client
from notebook.remote.common import APIError, decode, digest, identifier, terminal?, project_files

export client

class RemoteClient:
  def init(@args):
    @http = Client(timeout: 30.0)
    @token = fs.read_text(@args[?:token_file]).trim

  def request(method, route, body = null):
    if body:
      identifier(body[:command_id])
      directory = @args[?:token_file] + ".commands"
      fs.mkdir_p(directory)
      path = directory + "/" + body[:command_id] + ".json"
      receipt = {command_id: body[:command_id], method: method, route: route, body_sha256: digest(body)}
      if fs.exists?(path):
        raise ValueError("command_id already used locally with different content") unless digest(decode(fs.read_text(path))) == digest(receipt)
      else: fs.atomic_write_text(path, Json.generate(receipt))
    url = @args[?:url] + route
    headers = {"authorization": "Bearer " + @token, "content-type": "application/json"}
    response = case method:
      when "GET": @http.get(url, headers: headers)
      when "POST": @http.post(url, headers: headers, body: Json.generate(body))
      when "PUT": @http.put(url, headers: headers, body: Json.generate(body))
      else: raise ArgumentError("unsupported CLI request method")
    text = response.body_text()
    raise APIError(response.status, "HTTP #{response.status}: #{text}") unless response.status == 200
    decode(text)

  def snapshot_body(id):
    directory = @args[?:directory]
    source = if @args[?:snapshot_file] then decode(fs.read_text(@args[:snapshot_file])) else {document: fs.read_text(directory + "/project.json"), modules: {}}
    files = project_files(directory)
    source[:modules].each |path, text|:
      files[path] = Base64.encode(text.bytes)
    {command_id: id, base_revision: @args[?:base], document: source[:document], files: files}

  def download(route):
    response = @http.get(@args[:url] + route, headers: {authorization: "Bearer " + @token})
    raise APIError(response.status, "HTTP #{response.status}: #{response.body_text()}") unless response.status == 200
    fs.atomic_write_bytes(@args[:output], response.body_bytes())
    {output: @args[:output]}

  def execute():
    command = @args[?:command]
    id = @args[?:command_id] or SecureRandom.hex(16)
    project = @args[?:project]
    identifier(project) if project
    route = "/v1/projects/" + (project or "")
    case command:
      when "dependencies": request("GET", route + "/dependencies")
      when "dependency": request("GET", route + "/dependencies/" + identifier(@args[:run_id]))
      when "change_dependency": request("POST", route + "/dependencies", decode(fs.read_text(@args[:request_file])))
      when "health": request("GET", "/v1/health")
      when "gc_orphans": request("POST", "/v1/maintenance/orphans", decode(fs.read_text(@args[:request_file])))
      when "environments": request("GET", route + "/environments")
      when "environment": request("GET", route + "/environments/" + identifier(@args[:run_id]))
      when "prepare_environment": request("POST", route + "/environments", decode(fs.read_text(@args[:request_file])))
      when "projects": request("GET", "/v1/projects")
      when "project": request("GET", route)
      when "revision": request("GET", route + "/revisions/" + identifier(@args[:revision]))
      when "document": request("GET", route + "/revisions/" + identifier(@args[:revision]) + "/document")
      when "upload":
        request("PUT", route, snapshot_body(id))
      when "prepare":
        body = snapshot_body(id)
        fs.atomic_write_text(@args[:request_file], Json.generate(body))
        {command_id: id, fingerprint: digest({document: body[:document], files: body[:files]})}
      when "upload_prepared":
        request("PUT", route, decode(fs.read_text(@args[:request_file])))
      when ("presentation" | "live"):
        download("/v1/runs/" + identifier(@args[:run_id]) + "/" + command)
      when "checkout":
        record = request("GET", route + "/revisions/" + identifier(@args[:revision]))
        directory = @args[:directory]
        raise ArgumentError("checkout destination must not exist") if fs.exists?(directory)
        record[:files].keys.each |name|:
          raise ArgumentError("unsafe snapshot path") if name == "project.json" or name.starts_with?("/") or name.contains?("\\") or name.contains?("\u{0}") or name.split("/").any? |p|: ["", ".", ".."].include?(p)
        fs.mkdir_p(directory)
        record[:files].each |name, data|:
          path = fs.Path(directory + "/" + name)
          fs.mkdir_p(path.parent)
          fs.atomic_write_bytes(path, Base64.decode(data))
        fs.atomic_write_text(directory + "/project.json", record[:document])
        {directory: directory, revision: record[:revision]}
      when "run":
        request("POST", route + "/runs", {command_id: id, revision: @args[?:revision], sheet_id: @args[?:sheet], cell_id: @args[?:cell], action: if @args[?:all] then "run_all" else "run"})
      when "runs": request("GET", route + "/runs")
      when "registry": request("GET", route + "/registry")
      when "cell_inputs": request("GET", route + "/cell-inputs")
      when "set_cell_inputs": request("PUT", route + "/cell-inputs", decode(fs.read_text(@args[:request_file])))
      when "worker_settings": request("GET", route + "/worker-settings/" + identifier(@args[:sheet]))
      when "configure_worker": request("PUT", route + "/worker-settings/" + identifier(@args[:sheet]), decode(fs.read_text(@args[:request_file])))
      when "receipt": request("GET", route + "/commands/" + @args[?:command_id])
      when "restart":
        registry = null
        try: registry = request("GET", route + "/registry")
        rescue APIError |error|:
          raise error unless error.status == 404
          registry = request("GET", route + "/runs")
        runtime = registry[:runtimes].reversed.find: $it[:sheet_id] == @args[?:sheet]
        request("POST", route + "/restart", {command_id: id, sheet_id: @args[?:sheet], runtime_epoch: if runtime then runtime[:epoch] else null})
      when ("status" | "wait" | "stop"):
        route = "/v1/runs/" + @args[?:run_id]
        result = if command == "stop" and @args[?:epoch] then {epoch: @args[:epoch]} else request("GET", route)
        if command == "stop":
          result = request("POST", route + "/stop", {command_id: id, runtime_epoch: result[:epoch], force: @args[?:force]})
        elif command == "wait":
          until terminal?(result[:state]):
            task.sleep(500)
            result = request("GET", route)
        result
      else: raise ArgumentError("unknown CLI command")

def client(args):
  try: print Json.generate(RemoteClient(args).execute())
  rescue APIError |error|:
    if args[?:json_errors]: print Json.generate({remote_error: {status: error.status, message: error.message}})
    else: raise IOError(error.message)
  rescue Exception |error|:
    if args[?:json_errors]: print Json.generate({remote_error: {status: 0, message: error.message}})
    else: raise error
