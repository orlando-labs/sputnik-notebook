package fixture

# Offline integration test entry; main.s always uses the real GitHub provider.
import orbit.oauth.github as github
from "../backend/oauth_transport" import NotebookOAuthTransport
from orbit.vite import Assets
from "../backend/app" import application
import "../backend/database" as database
from notebook.core.client import Client

from "../backend/environments" import web_grants
import public_fixture

export main

def main():
  parser = ArgParser()
  parser.arg("--port", type: Int, required: true)
  parser.arg("--origin", required: true)
  parser.arg("--github-origin", required: true)
  parser.arg("--database", required: true)
  parser.arg("--mode", default: "production")
  parser.arg("--vite-origin", default: "http://127.0.0.1:5173")
  parser.arg("--core-root")
  parser.flag("--allow-environment-preparation")
  parser.arg("--web-worker-grants", default: "")
  parser.flag("--public-fixture")
  parser.flag("--public-only")
  args = parser.parse_or_raise
  mode = if args[:mode] == "development" then :development else :production
  provider = github.Provider(client_id: "fixture-client", client_secret: "fixture-secret",
    redirect_uri: args[:origin] + "/auth/github/callback", scopes: ["read:user"], fetch_emails: false,
    site_url: args[:github_origin], api_url: args[:github_origin], transport: NotebookOAuthTransport(), allow_http_loopback: true)
  opened = database.open(args[:database])
  try:
    core = if args[:core_root] then Client(args[:core_root]) else null
    application(if args[:public_only] then null else provider, Assets(mode: mode, dev_origin: args[:vite_origin]), opened[0], opened[1], core: core,
      environment_preparation: args[:allow_environment_preparation], worker_grants: web_grants(args[:web_worker_grants]),
      public_templates: if args[:public_fixture] then public_fixture.templates(core) else [],
      origin: args[:origin], debug: true, session_secret: "fixture-session-secret-at-least-32-bytes",
      csrf_secret: "fixture-csrf-secret-at-least-32-bytes").run(port: args[:port], max_body_bytes: 117440512)
  ensure:
    provider.close!
    opened[0].close!
