package notebook.remote.local_dependencies

from notebook.remote.common import decode, fail
from notebook.remote.core import Core

export local_dependencies

# A local explicit operation uses the same installers as an agent. The helper
# stays alive until completion; no background command is replayed on opening.
def local_dependencies(args):
  directory = fs.Path(args[:directory]).normalize.to_str
  fail(400, "notebook directory must be absolute") unless fs.Path(directory).absolute?
  fail(400, "project.json is missing") unless fs.exists?(directory + "/project.json")
  core = Core(directory + "/.sputnik/dependencies", "", python: args[:python], ruby: args[:ruby], compiler: args[:sputnik], package_directory: directory + "/packages")
  core.sql("INSERT OR REPLACE INTO projects VALUES('local','local','active')")
  core.sql("INSERT OR REPLACE INTO revisions VALUES('local','local',?,?,?)", [directory, fs.read_text(directory + "/project.json"), "local"])
  command = args[:command]
  result = {}
  if command == "status": result = core.handle("dependency.status", {project_id: "local"})
  elif command == "prepare":
    accepted = core.handle("environment.prepare", {project_id: "local", command_id: SecureRandom.hex(16), retry: true})
    if accepted[?:id]:
      loop:
        result = core.handle("environment.get", {project_id: "local", environment_id: accepted[:id]})
        if ["ready", "failed", "interrupted"].include?(result[:state]): break
        task.sleep(0.1)
    else: result = accepted
  else:
    params = decode(fs.read_text(args[:request_file]))
    params[:project_id] = "local"
    accepted = core.handle("dependency.change", params)
    loop:
      result = core.handle("dependency.get", {project_id: "local", operation_id: accepted[:id]})
      if ["succeeded", "failed", "interrupted"].include?(result[:state]): break
      task.sleep(0.1)
  print Json.generate(result)
