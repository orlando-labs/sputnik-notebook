package public_template

from notebook.core.client import Client

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
  document = {format: "sputnik-notebook", version: 4, title: "Getting started", active_sheet: "main",
    sheets: [{id: "main", title: "Main", cells: [{id: "1", kind: "code", mode: "manual", source: "message = \"Hello, Sputnik!\"\nmessage\n"}]}],
    modules: [], auto_imports: [], dependencies: [], inputs: [], boards: []}
  saved = core.handle("project.put", {project_id: "web_public_starter", command_id: "publish-starter-v1", base_revision: null, document: Json.generate(document), files: {}})
  print Json.generate([{id: "starter", title: "Getting started", source_project: "web_public_starter", revision: saved[:revision]}])
