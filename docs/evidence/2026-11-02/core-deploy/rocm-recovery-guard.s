package maintenance.rocm_recovery_guard

export main

def rpc(root, method, params = {}):
  net.unix.connect(root + "/agent.sock", timeout: 10.0) |socket|:
    socket.write_all!((Json.generate({method: method, params: params}) + "\n").bytes, timeout: 10.0)
    result = Json.parse(socket.read_line!(limit: 33554432, timeout: 20.0).to_str)
    raise ValueError(Json.generate(result)) unless result[:status] == 200
    result[:data]

def main():
  parser = ArgParser()
  parser.arg("--root", required: true)
  args = parser.parse_or_raise
  root = args[:root]
  terminal = ["succeeded", "failed", "cancelled", "force-stopped", "interrupted"]
  rpc(root, "project.list")[:projects].each |project|:
    id = project[:id]
    registry = rpc(root, "run.registry", {project_id: id})
    raise ValueError("dependency operation is active") if registry[:dependency_busy]
    registry[:runs].each |run|:
      unless terminal.include?(run[:state]):
        raise ValueError("non-probe run is active") unless id == "core_upgrade_probe_f9b70cd49ba11e09"
        print Json.generate({probe: id, run: run[:id], state: run[:state], epoch: run[:epoch]})
    registry[:runtimes].each |runtime|:
      unless ["idle", "terminated", "interrupted"].include?(runtime[:state]):
        raise ValueError("non-probe runtime is busy") unless id == "core_upgrade_probe_f9b70cd49ba11e09"
    registry[:services].each |service|:
      raise ValueError("automatic work is enabled") if service[:enabled] or service[:running]
    rpc(root, "environment.list", {project_id: id})[:environments].each |environment|:
      raise ValueError("environment preparation is active") if ["queued", "installing"].include?(environment[:state])
  print "PASS no user work is active; only the known maintenance probe may be terminating"
  0
