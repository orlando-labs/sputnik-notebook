package notebook.remote.service

from notebook.core.host import ServiceProcess, ServiceSignals, executable
from notebook.remote.common import rpc

export serve

# Service ownership stays in Sputnik. Native bindings only expose signals,
# executable discovery and scoped child processes with inherited log streams.
def serve(root, args):
  program = executable()
  worker = args[:worker] or fs.Path(program).parent.to_str + "/sputnik-notebook-worker"
  child_args = ["--mode", "agent", "--root", root, "--worker", worker,
    "--python", args[:python], "--ruby", args[:ruby], "--sputnik", args[:sputnik],
    "--orphan-gc-interval", args[:orphan_gc_interval].to_str,
    "--orphan-min-age", args[:orphan_min_age].to_str]
  [[:policy_file, "--policy-file"], [:storage_policy, "--storage-policy"]].each |option|:
    if args[option[0]]:
      child_args.push!(option[1])
      child_args.push!(args[option[0]])
  child_args.push!("--allow-book-policy-overrides") if args[:allow_book_policy_overrides]
  signals = ServiceSignals()
  agent = null
  gateway = null
  try:
    agent = ServiceProcess(program, child_args)
    started = Time.monotonic
    loop:
      return null if signals.requested?
      raise IOError("execution agent exited during startup") unless agent.running?
      ready = false
      try:
        response = rpc(root, "health")
        ready = response[:status] == 200 and response[:data][:agent_pid] == agent.pid
      rescue Exception:
        null
      break if ready
      raise IOError("execution agent startup timed out") if (Time.monotonic - started).total_nanoseconds > 30000000000
      task.sleep(0.05)
    gateway = ServiceProcess(program, ["--mode", "gateway", "--root", root,
      "--host", args[:host], "--port", args[:port].to_str])
    until signals.requested?:
      raise IOError("execution agent exited; stopping service") unless agent.running?
      raise IOError("HTTP gateway exited; stopping service") unless gateway.running?
      task.sleep(0.1)
  ensure:
    try:
      if gateway:
        try: gateway.close!()
        ensure: gateway.destroy!()
    ensure:
      try:
        if agent:
          try: agent.close!()
          ensure: agent.destroy!()
      ensure: signals.destroy!()
