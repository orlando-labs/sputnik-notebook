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
        settings.push!([sheet[:id], policy[:grants], policy[:environment_directory], policy[:version]])
    snapshot.push!([id, project[:head], project[:state], history, settings])
  # First validate every owner, then retire idle workers with admission frozen.
  if retire:
    projects.each |project|:
      rpc(root, "run.registry", {project_id: project[:id]})[:runtimes].each |runtime|:
        if runtime[:state] == "idle":
          rpc(root, "runtime.restart", {project_id: project[:id], command_id: SecureRandom.hex(8), sheet_id: runtime[:sheet_id], runtime_epoch: runtime[:epoch]})
  fs.atomic_write_text(output, Json.generate(snapshot))
  print "PASS quiescent state snapshot"

class API:
  def init(root):
    @http = Client(timeout: 30.0)
    @headers = {authorization: "Bearer " + fs.read_text(root + "/token").trim, "content-type": "application/json"}

  def request(method, route, body = null):
    url = "http://127.0.0.1:18765" + route
    response = case method:
      when "GET": @http.get(url, headers: @headers)
      when "PUT": @http.put(url, headers: @headers, body: Json.generate(body))
      when "POST": @http.post(url, headers: @headers, body: Json.generate(body))
    text = response.body_text
    raise ValueError(text) unless response.status == 200
    Json.parse(text)

  def close!(): @http.close!()

def gpu(root, count):
  api = API(root)
  project = "core_upgrade_probe_" + SecureRandom.hex(8)
  source = "import torch\nfrom torch.tensor.factories import tensor\nfrom torch.backends import cuda_available?, cuda_device_count\nraise ValueError(\"GPU unavailable\") unless cuda_available?\nraise ValueError(\"GPU count\") unless cuda_device_count == " + count.to_str + "\ncuda_device_count.times |i|:\n  x = tensor([1.0, 2.0, 3.0], device: \"cuda:\" + i.to_str, requires_grad: true)\n  loss = x.square.sum\n  loss.backward!\n  raise ValueError(\"forward\") unless loss.item == 14.0\n  raise ValueError(\"gradient\") unless x.grad.to_a == [2.0, 4.0, 6.0]\n42\n"
  document = {format: "sputnik-notebook", version: 1, title: "GPU without Python", active_sheet: "main", modules: [], auto_imports: [],
    sheets: [{id: "main", title: "Main", cells: [{id: "1", kind: "code", source: source, mode: "manual"}]}]}
  created = false
  try:
    health = api.request("GET", "/v1/health")
    require(health[:capabilities].include?("targeted_restart") and health[:capabilities].include?("desktop_history"), "updated desktop capabilities")
    saved = api.request("PUT", "/v1/projects/" + project, {command_id: SecureRandom.hex(8), base_revision: null, document: Json.generate(document), files: {}})
    created = true
    install = api.request("POST", "/v1/projects/" + project + "/dependencies", {command_id: SecureRandom.hex(8), action: "install_sputnik", source: "torch", version: "0.1.4", variant: if count == 3 then "linux-x86_64-gnu-rocm643-prebuilt-source-runtime" else "linux-x86_64-gnu-cu130-prebuilt-source-runtime", allow_native: true, allow_native_large: true})
    installed = null
    4800.times:
      installed = api.request("GET", "/v1/projects/" + project + "/dependencies/" + install[:id])
      break unless ["queued", "running"].include?(installed[:state])
      task.sleep(0.05)
    require(installed[:state] == "succeeded", Json.generate(installed))
    packages = api.request("GET", "/v1/projects/" + project + "/dependencies")[:packages]
    require(packages.count == 1 and packages[0][:display_name] == "torch", "short package display name")
    require(packages[0][:digest] == (if count == 3 then "sha256:72a3ef90ea65d9fc98b205d8ec1eaa334f1cb2c3ea32f3e53cdff62d52d67334" else "sha256:aa74c897a9a662ececa7b14d0c02b6d35ac2900cd81ed49797845a8c3ffb2e81"), "verified CUDA Torch build identity")
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
    require(result[:result][:cells][0][:result] == "42", "GPU result")
    print "PASS short torch import, shared package reference and GPU forward/backward without Python on " + count.to_str + " devices"
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
  args = parser.parse_or_raise
  if ["audit", "retire"].include?(args[:mode]): audit(args[:root], args[:output], args[:mode] == "retire")
  elif args[:mode] == "cleanup-test-projects":
    audit(args[:root], "/tmp/maintenance-state-audit.json")
    rpc(args[:root], "project.list")[:projects].each |project|:
      if project[:id].starts_with?("core_upgrade_probe_"):
        rpc(args[:root], "project.delete", {project_id: project[:id], command_id: SecureRandom.hex(8)})
        print "Removed maintenance test project " + project[:id]
  else: gpu(args[:root], args[:gpus])
  0
