# One-host notebook web deployment

This directory contains an operator example, not a deployment performed by Codex.
The supported layout has an independent Core agent, a loopback Orbit backend and
one HTTPS reverse proxy. The Node smoke server, test provider and production seed
helper are test tools and must not be launched as the production service.

Build the current SDK and Core/worker, then frontend assets and the actual entry:

The current SDK is Sputnik 1.0.0. A legacy lock without sputnik_version must be
explicitly migrated before building: run sputnik pkg lock backend/main.s from
apps/notebook-web and sputnik pkg lock sputnik.build.json from tools/notebook-remote,
using the sibling build/sputnik binary. Keep the recorded language version and
SDK release aligned; review lock changes with the release.

```sh
# From sputnik-notebook:
make remote-core
cd apps/notebook-web
npm ci --prefix frontend
npm run build --prefix frontend
SPUTNIK_VM_CACHE="$PWD/build/main-build-cache" ../../../sputnik-lang/build/sputnik build backend/main.s \
  -o build/native/notebook-web --target native --require-full-native \
  --grant net.listen --grant net.connect --grant random.secure --grant time.now \
  --grant fs.read --grant fs.write --grant fs.metadata --grant ffi
```

Run the agent from the repository root, under a separate supervised service:

```sh
build/sputnik-notebook-remote --mode agent --root "$NOTEBOOK_CORE_ROOT" \
  --worker "$PWD/build/sputnik-notebook-worker" \
  --sputnik "$PWD/../sputnik-lang/build/sputnik"
```

Use an absolute short Core path (on macOS the Unix socket path must fit 104 bytes;
use a real /private/... path rather than the /tmp symlink). The service identity
needs access to that socket/state and the web catalog. They are two separate
persistent stores. Preserve both across service restarts and releases.

Run the web binary **from apps/notebook-web**, so migrations and the Vite manifest
resolve correctly. Supply these operator environment values through the service's
secret/environment facility:

| Variable | Meaning |
| --- | --- |
| ORBIT_ORIGIN | Exact external HTTPS origin, e.g. https://notebook.example.com |
| ORBIT_PORT | Loopback backend port, 3000 in the example |
| NOTEBOOK_WEB_DATABASE | Absolute persistent catalog SQLite path |
| NOTEBOOK_CORE_ROOT | The independent agent's state/socket path |
| GITHUB_CLIENT_ID / GITHUB_CLIENT_SECRET | Real GitHub OAuth App credentials |
| ORBIT_SESSION_SECRET / ORBIT_CSRF_SECRET | Independent persistent secrets, at least 32 bytes each |

The GitHub callback is ORBIT_ORIGIN + /auth/github/callback. Real consent and
provider credentials require a separate live acceptance check; the local probe
does not establish that integration.

```sh
build/native/notebook-web --mode production --behind-proxy
```

Orbit binds loopback by default. The example trusts exactly one loopback proxy
hop. Keep the original Host header: Orbit validates it before forwarded
provenance. The proxy overwrites all X-Forwarded-* headers instead of appending
browser-supplied chains. Keep backend/Core ports and private state behind that
boundary. Different network topologies need their own explicit trust policy.

Adapt [nginx.conf.example](nginx.conf.example) to the external host, certificate
paths and release directory, and validate it with the installed nginx -t before
activation. Its 112 MiB body envelope matches the backend's encoded import limit;
the default nginx body limit would reject otherwise-valid notebook uploads.
Only hashed /assets/ files are public. The Vite manifest, source, migrations,
binaries and test helpers are not served. Access logs omit query strings because
OAuth callback queries contain authorization codes.

Build assets before a release is exposed. Retain the old hashed asset files in
the served assets directory when switching releases: an already-open page may
still reference them. Rebuilding/removing production assets while that release
serves clients can strand a page at its loading screen.

The server operator controls environment preparation (--allow-environment-preparation),
native package installation (--allow-native-packages), and the exact editable
worker capabilities (--web-worker-grants). All are closed by default. A browser
cannot author a server path or a new grant target. Core owns effective book/app/
operator quotas; --allow-book-policy-overrides on the agent selects override mode,
while explicit owner/server/public ceilings remain authoritative. Worker reset,
web restart and a new temporary copy do not reset aggregate time accounting.

An HTTP restart does not own workers. Stop active work explicitly before agent
maintenance; a restarted agent never replays interrupted runs or silently resumes
paused services. To copy stores without an application-consistent online backup,
quiesce work and stop both services first. Rotate session secrets intentionally:
changing the key invalidates existing login cookies while Core receipts/results
remain in the persistent state.

## Local acceptance

From apps/notebook-web, with the built native entries and Core/worker:

```sh
node tools/production_probe.mjs
```

The probe uses backend/main, a fresh independent agent, and a loopback proxy
implementing the documented Host/HTTPS provenance contract. A test-only helper
seeds a signed session into a disposable catalog; no OAuth provider is mocked or
contacted. It checks authenticated save/run, a >1 MiB upload, static/private paths,
CSRF, HTTP restart during work, duplicate-command identity, Core outage/recovery,
results and unchanged quota accounting. Secrets and session tokens stay out of
its logs/report. All processes and temporary state are cleaned up.

The sixth probe group uses an actual anonymous browser-cookie principal and
checks its budget across HTTP/Core restarts. OAuth HTTP exchanges use a separate
client per request, closed after consuming the bounded response; an expired idle
provider socket is not reused and an authorization code is never replayed.

This is a local HTTP transport test of the proxy contract. The acceptance host
does not have nginx installed, so neither nginx -t, actual nginx routing nor a TLS
handshake was executed here. Linux process supervision, real GitHub consent,
production load/backups and external deployment are not claimed.

## Anonymous public notebooks

Public execution is disabled when NOTEBOOK_PUBLIC_TEMPLATES / --public-templates
is absent. To publish the bundled starter, start Core, then from apps/notebook-web:

```sh
../../../sputnik-lang/build/sputnik run tools/public_template.s \
  --grant net.connect --grant fs.read --grant fs.metadata --grant ffi \
  -- --core-root "$NOTEBOOK_CORE_ROOT" > /absolute/private/public-templates.json
```

Set NOTEBOOK_PUBLIC_TEMPLATES=/absolute/private/public-templates.json on the web
service and restart it. The operator-only JSON allowlist has at most sixteen
entries, each with id, title, source_project and revision. Only id/title reach
the browser. The pinned revision is copied even if the source head changes;
keep that source/revision retained. Use a separate Core-only publication project.
Removing/changing an entry and restarting revokes access to existing copies;
the short Core lease expires them. Keep configuration outside public assets.

Guests open a disposable copy in the standard notebook editor. The starter
includes two sheets and an interactive board. Guests can edit the book, work
with bundled files and parameters, run code, inspect history and export the
book. No account or catalog project is created. Requests require both the encrypted visitor cookie
and opaque copy token, with normal Origin/CSRF checks. HTTP fields cannot select
Core identities, billing principals, profiles, server paths or worker grants.

Guests can attach files and media up to 256 KiB each. The editor and API accept
up to 1 MiB of file changes per save or draft export, including folder uploads.
The public nginx host accepts request bodies up to 2 MiB, including JSON and
Base64 overhead.

Core restricts each anonymous cookie principal to **60 seconds accumulated wall
time across copies**; concurrent runs add their time. Each run also has a
60-second ceiling. Tighter book/operator limits still apply. New copies, reloads,
HTTP restart and Core restart do not reset charged visitor time. Storage is
bounded to 64 MiB per copy/visitor and an 8 MiB per-run reservation. Existing
tighter operator limits are preserved. Lease is at most fifteen seconds without
heartbeat and lifetime at most fifteen minutes. Closing/hiding/disconnecting
the view discards its token and heartbeats; Core expires copies and stops work
independently of HTTP polling.

The browser renews the lease and reads compact run and quota status in one
request. An idle guest editor polls every five seconds by default. Live runs and
command recovery poll every second. Shorter leases reduce both intervals.
The browser reads the document when opening a copy, uses the accepted revision
after Save, and keeps the displayed final result while that run remains selected.

Admission allows one active copy per visitor, sixteen globally, ten openings
per visitor/hour and 120 globally/hour. Uncertain open retries retain command/
copy identity; later mutations use durable receipts without automatic replay.
Opening records remain for 24 hours; expired older rows are removed on new opens.

Core also charges each anonymous run to a shared IP budget of **300 seconds per
UTC day** by default. Set `core.public_ip_daily_seconds` in the operator policy
file to change the limit. A run is charged to the day on which Core accepts it.
New cookies share the same IP budget, and a copy opened on a different IP needs
to be reopened before another run. The web adapter uses Orbit's verified client
address and stores a keyed hash derived from the persistent session secret.
Keep the session secret stable and configure the trusted proxy to overwrite
`X-Forwarded-For` with the client address. Same-day usage survives service
restarts. Global admission and Core-wide quotas still apply. Private projects,
package installation, environment preparation and worker settings require login.
Public copies cannot install dependencies or inherit template worker grants.
Live OAuth, nginx/TLS and external deployment acceptance remain separate.

[Implementation and acceptance](../../../docs/evidence/2026-11-01/notebook-web-public/README.md).
