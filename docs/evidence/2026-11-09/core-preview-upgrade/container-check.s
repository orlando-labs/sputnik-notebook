package maintenance.container_check

from net.http import Client

export main

def rpc(root, method, params = {}):
  net.unix.connect(root + "/agent.sock", timeout: 10.0) |socket|:
    socket.write_all!((Json.generate({method: method, params: params}) + "\n").bytes, timeout: 10.0)
    result = Json.parse(socket.read_line!(limit: 33554432, timeout: 20.0).to_str)
    raise ValueError(Json.generate(result)) unless result[:status] == 200
    result[:data]

def require(value, message): raise ValueError(message) unless value

def audit(root, output, retire = false):
  capabilities = rpc(root, "health")[:capabilities]
  projects = rpc(root, "project.list")[:projects]
  snapshot = []
  projects.each |project|:
    id = project[:id]
    registry = rpc(root, "run.registry", {project_id: id})
    require(not registry[:dependency_busy], "dependency operation is active")
    registry[:runs].each |run|:
      require(["succeeded", "failed", "cancelled", "force-stopped", "interrupted"].include?(run[:state]), "run is active")
    registry[:runtimes].each |runtime|:
      require(["idle", "terminated", "interrupted"].include?(runtime[:state]), "runtime is busy")
    registry[:services].each |service|:
      require(not service[:enabled] and not service[:running], "automatic work is enabled")
    environments = rpc(root, "environment.list", {project_id: id})[:environments]
    environments.each |environment|:
      require(not ["queued", "installing"].include?(environment[:state]), "environment preparation is active")
    history = []
    before = null
    loop:
      params = {project_id: id, limit: 100}
      params[:before] = before if before
      page = rpc(root, "run.list", params)
      history += page[:runs].map |run|: [run[:id], run[:state], run[:revision], run[:sheet_id], run[:cell_id], run[:epoch], run[?:input_version], run[?:metadata]]
      before = page[?:next]
      break unless before
    settings = []
    if project[:state] == "active":
      document = Json.parse(rpc(root, "revision.document", {project_id: id, revision: project[:head]})[:document])
      document[:sheets].each |sheet|:
        policy = rpc(root, "worker.settings", {project_id: id, sheet_id: sheet[:id]})
        own = policy[?:own_grants] or policy[:grants]
        inherited = policy[?:inherited_grants] or []
        settings.push!([sheet[:id], own, inherited, policy[:environment_directory]])
    book = if capabilities.include?("book_worker_grants") then rpc(root, "worker.book_settings", {project_id: id})[:grants] else []
    snapshot.push!([id, project[:head], project[:state], history, settings, book])
  # First validate every owner, then retire idle workers with admission frozen.
  if retire:
    projects.each |project|:
      rpc(root, "run.registry", {project_id: project[:id]})[:runtimes].each |runtime|:
        if runtime[:state] == "idle":
          rpc(root, "runtime.restart", {project_id: project[:id], command_id: SecureRandom.hex(8), sheet_id: runtime[:sheet_id], runtime_epoch: runtime[:epoch]})
  fs.atomic_write_text(output, Json.generate(snapshot))
  print "PASS quiescent state snapshot: #{projects.count} projects, full history and grant semantics"

class API:
  def init(root, port):
    @port = port
    @http = Client(timeout: 30.0)
    @headers = {authorization: "Bearer " + fs.read_text(root + "/token").trim, "content-type": "application/json"}

  def request(method, route, body = null):
    url = "http://127.0.0.1:" + @port.to_str + route
    response = case method:
      when "GET": @http.get(url, headers: @headers)
      when "PUT": @http.put(url, headers: @headers, body: Json.generate(body))
      when "POST": @http.post(url, headers: @headers, body: Json.generate(body))
    text = response.body_text
    raise ValueError(text) unless response.status == 200
    Json.parse(text)

  def close!(): @http.close!()

  def binary(route):
    response = @http.get("http://127.0.0.1:" + @port.to_str + route, headers: @headers)
    raise ValueError("presentation download failed") unless response.status == 200
    response.body_bytes

def gpu(root, count, port, output):
  api = API(root, port)
  project = "core_upgrade_probe_" + SecureRandom.hex(8)
  source = "import torch as T\nfrom torch.tensor.factories import tensor\nfrom torch.backends import cuda_available?, cuda_device_count\nraise ValueError(\"GPU unavailable\") unless cuda_available?\nraise ValueError(\"GPU count\") unless cuda_device_count == " + count.to_str + "\ncuda_device_count.times |i|:\n  x = tensor([1.0, 2.0, 3.0], device: \"cuda:\" + i.to_str, requires_grad: true)\n  loss = x.square.sum\n  loss.backward!\n  raise ValueError(\"forward\") unless loss.item == 14.0\n  raise ValueError(\"gradient\") unless x.grad.to_a == [2.0, 4.0, 6.0]\n(T.zeros([5, 10]), T.Tensor((2, 4)), tensor([1.0, 2.0, 3.0], device: \"cuda:0\"))\n"
  document = {format: "sputnik-notebook", version: 1, title: "GPU without Python", active_sheet: "main", modules: [], auto_imports: [],
    sheets: [{id: "main", title: "Main", cells: [{id: "1", kind: "code", source: source, mode: "manual"}]}]}
  created = false
  try:
    health = api.request("GET", "/v1/health")
    require(health[:capabilities].include?("targeted_restart") and health[:capabilities].include?("desktop_history"), "updated desktop capabilities")
    saved = api.request("PUT", "/v1/projects/" + project, {command_id: SecureRandom.hex(8), base_revision: null, document: Json.generate(document), files: {}})
    created = true
    install = api.request("POST", "/v1/projects/" + project + "/dependencies", {command_id: SecureRandom.hex(8), action: "install_sputnik", source: "slowpilot/torch", version: "0.1.7", variant: "linux-x86_64-gnu-rocm1030-gfx906-prebuilt-source-runtime", allow_native: true, allow_native_large: true})
    installed = null
    4800.times:
      installed = api.request("GET", "/v1/projects/" + project + "/dependencies/" + install[:id])
      break unless ["queued", "running"].include?(installed[:state])
      task.sleep(0.05)
    require(installed[:state] == "succeeded", Json.generate(installed))
    packages = api.request("GET", "/v1/projects/" + project + "/dependencies")[:packages]
    require(packages.count == 1 and packages[0][:display_name] == "torch", "short package display name")
    require(packages[0][:digest] == "sha256:9627468462f75f87e8cfb384d82c3c15324718fcfbf1536fcb8c3aed3be7c6c9", "verified ROCm Torch build identity")
    require(fs.metadata(packages[0][:directory]).symlink?, "shared package reference")
    require(fs.read_text(root + "/projects/" + project + "/packages/imports.index").contains?("torch\tslowpilot.torch"), "short module alias")
    settings_route = "/v1/projects/" + project + "/worker-settings/main"
    settings = api.request("GET", settings_route)
    api.request("PUT", settings_route, {command_id: SecureRandom.hex(8), base_version: settings[:version], runtime_epoch: null, grants: ["ffi.call", "ffi.load", "fs.read"]})
    run = api.request("POST", "/v1/projects/" + project + "/runs", {command_id: SecureRandom.hex(8), revision: saved[:revision], sheet_id: "main", cell_id: "1", action: "run"})
    result = null
    4800.times:
      result = api.request("GET", "/v1/runs/" + run[:run_id])
      break if ["succeeded", "failed", "interrupted", "force-stopped", "cancelled"].include?(result[:state])
      task.sleep(0.05)
    require(result[:state] == "succeeded", Json.generate(result))
    cell = result[:result][:cells][0]
    preview = cell[:result]
    require(not preview.contains?("<instance"), "tensor must have a native result preview")
    ["<Tensor shape=[5, 10]", "<Tensor shape=[2]", "values=[2, 4]", "device=cuda:0", "values=[1, 2, 3]"].each |expected|:
      require(preview.contains?(expected), "missing tensor preview component: " + expected + ": " + preview)
    binary = api.binary("/v1/runs/" + run[:run_id] + "/presentation")
    require(binary.hex.contains?(preview.bytes.hex), "desktop presentation retains the exact tensor preview")
    if output:
      fs.write_bytes(output + ".presentation", binary)
      fs.atomic_write_text(output, Json.pretty_generate({gpus: count, torch: packages[0][:version], digest: packages[0][:digest],
        preview: preview, presentation_bytes: binary.count, presentation_sha256: Digest.sha256(binary).hex,
        document: Json.generate(document), run_id: run[:run_id]}) + "\n")
    print preview
    print "PASS CPU tuple and GPU tensor previews, short torch import and forward/backward on " + count.to_str + " devices"
  ensure:
    try:
      rpc(root, "project.delete", {project_id: project, command_id: SecureRandom.hex(8)}) if created
    ensure: api.close!()


def main():
  parser = ArgParser()
  parser.arg("--root", required: true)
  parser.arg("--mode", required: true, choices: ["audit", "retire", "gpu", "cleanup-test-projects"])
  parser.arg("--output")
  parser.arg("--gpus", type: Int)
  parser.arg("--port", type: Int, default: 18765)
  args = parser.parse_or_raise
  if ["audit", "retire"].include?(args[:mode]): audit(args[:root], args[:output], args[:mode] == "retire")
  elif args[:mode] == "cleanup-test-projects":
    audit(args[:root], "/tmp/maintenance-state-audit.json")
    rpc(args[:root], "project.list")[:projects].each |project|:
      if project[:id].starts_with?("core_upgrade_probe_"):
        rpc(args[:root], "project.delete", {project_id: project[:id], command_id: SecureRandom.hex(8)})
        print "Removed maintenance test project " + project[:id]
  else: gpu(args[:root], args[:gpus], args[:port], args[:output])
  0
