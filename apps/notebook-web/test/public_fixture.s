package public_fixture

from "../tools/starter" import starter_document

export templates

# Test-only trusted publication. No browser can call this setup or choose its
# private source identity; production reads an explicit operator allowlist.
def templates(core):
  ready = false
  400.times:
    try:
      core.handle("health", {})
      ready = true
      break
    rescue Exception: task.sleep(0.05)
  raise IOError("public fixture Core was not ready") unless ready
  document = starter_document()
  document[:resource_policy] = {run_seconds: 600, total_run_seconds: 600, project_bytes: 134217728}
  saved = core.handle("project.put", {project_id: "public_fixture_source", command_id: "publish-starter", base_revision: null, document: Json.generate(document), files: {}})
  # Advance head after publication: every visitor must still receive the pin.
  document[:sheets][0][:cells][0][:source] = "\"Unpublished private head\"\n"
  core.handle("project.put", {project_id: "public_fixture_source", command_id: "advance-head", base_revision: saved[:revision], document: Json.generate(document), files: {}})
  [{id: "starter", title: "Getting started", source_project: "public_fixture_source", revision: saved[:revision]}]
