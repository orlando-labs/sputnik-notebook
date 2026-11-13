package public_template

from notebook.core.client import Client
from starter import starter_document

export main

# Operator command, never an HTTP route. Creates an inert shared-Core source and
# prints its pinned publication entry for NOTEBOOK_PUBLIC_TEMPLATES.
def main():
  parser = ArgParser()
  parser.arg("--core-root", required: true)
  parser.flag("--health-only")
  args = parser.parse_or_raise
  core = Client(args[:core_root])
  if args[:health_only]:
    core.handle("health", {})
    print Json.generate({ready: true})
    return null
  source = "web_public_starter_v2"
  saved = core.handle("project.put", {project_id: source, command_id: "publish-starter-v2", base_revision: null, document: Json.generate(starter_document()), files: {}})
  print Json.generate([{id: "starter", title: "Getting started", source_project: source, revision: saved[:revision]}])
