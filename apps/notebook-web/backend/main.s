package main

from orbit import Origin
import orbit.oauth.github as github
from oauth_transport import NotebookOAuthTransport
from orbit.vite import Assets
from notebook.core.client import Client
from app import application
import database

from environments import web_grants
from public_sessions import public_templates

export main

def main():
  parser = ArgParser(name: "sputnik-notebook-web")
  parser.arg("--mode", choices: ["development", "production"], default: "production", env: "ORBIT_MODE")
  parser.arg("--port", type: Int, default: 3000, env: "ORBIT_PORT")
  parser.arg("--host", default: "127.0.0.1", env: "ORBIT_HOST")
  parser.arg("--origin", default: "http://127.0.0.1:3000", env: "ORBIT_ORIGIN")
  parser.arg("--vite-origin", default: "http://127.0.0.1:5173", env: "VITE_ORIGIN")
  parser.arg("--database", default: "data/notebook-web.sqlite", env: "NOTEBOOK_WEB_DATABASE")
  parser.arg("--core-root", env: "NOTEBOOK_CORE_ROOT")
  parser.arg("--client-id", env: "GITHUB_CLIENT_ID")
  parser.arg("--client-secret", env: "GITHUB_CLIENT_SECRET")
  parser.arg("--session-secret", required: true, env: "ORBIT_SESSION_SECRET")
  parser.arg("--csrf-secret", required: true, env: "ORBIT_CSRF_SECRET")
  parser.flag("--behind-proxy")
  parser.arg("--trusted-proxy-cidrs", default: "127.0.0.1/32,::1/128", env: "ORBIT_TRUSTED_PROXY_CIDRS")
  parser.flag("--public-only")
  parser.flag("--allow-native-packages")
  parser.flag("--allow-environment-preparation")
  parser.arg("--web-worker-grants", default: "")
  parser.arg("--public-templates", env: "NOTEBOOK_PUBLIC_TEMPLATES")
  args = parser.parse_or_raise
  origin = Origin(args[:origin])
  mode = if args[:mode] == "development" then :development else :production
  assets = Assets(mode: mode, dev_origin: args[:vite_origin])
  templates = public_templates(args[:public_templates])
  raise ArgumentError("public-only mode requires a public template") if args[:public_only] and templates.empty?
  raise ArgumentError("GitHub client ID and secret are required unless --public-only is selected") unless args[:public_only] or (args[:client_id] and args[:client_secret])
  trusted = args[:trusted_proxy_cidrs].split(",").map: _1.trim
  raise ArgumentError("select at most sixteen explicit trusted proxy CIDRs") unless trusted.count > 0 and trusted.count <= 16 and trusted.all?: _1.present?
  provider = if args[:public_only] then null else github.Provider(client_id: args[:client_id], client_secret: args[:client_secret],
    redirect_uri: origin.to_str + "/auth/github/callback", scopes: ["read:user"], fetch_emails: false,
    transport: NotebookOAuthTransport(), allow_http_loopback: mode == :development)
  opened = database.open(args[:database])
  try:
    core = if args[:core_root] then Client(args[:core_root]) else null
    application(provider, assets, opened[0], opened[1], core: core,
      environment_preparation: args[:allow_environment_preparation], worker_grants: web_grants(args[:web_worker_grants]),
      public_templates: templates,
      session_secret: args[:session_secret], csrf_secret: args[:csrf_secret], origin: origin,
      behind_proxy: args[:behind_proxy], trusted_proxy_cidrs: trusted, native_packages: args[:allow_native_packages], debug: mode == :development).run(host: args[:host], port: args[:port], max_body_bytes: if args[:public_only] then 2097152 else 117440512)
  ensure:
    provider.close! if provider
    opened[0].close! unless opened[0].closed?
