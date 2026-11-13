# notebook.sputnik-lang.online

Selected topology for Stage 4i.4:

| Role | Host | SSH |
| --- | --- | --- |
| Docker builder | 192.168.1.136 | lab.orlando-labs.com:22136 |
| Core / web / persistent data | 192.168.1.97 | lab.orlando-labs.com:22097 |
| nginx / TLS / hashed assets | 192.168.1.155 | lab.orlando-labs.com:22155 |

The GitHub OAuth App has not been created. Deploy `--public-only`: no provider
credentials, sign-in button or private workspace authority are enabled. Published
anonymous copies retain the 60-second cumulative visitor budget. Enabling GitHub
later requires a real OAuth App callback at
`https://notebook.sputnik-lang.online/auth/github/callback`, protected client ID /
secret in the host environment file, removing `--public-only`, and separate live
consent acceptance. Review operator quotas before enabling private workspaces.

## Image

Use [Dockerfile](Dockerfile) with the sibling context from
`sputnik-notebook/tools/container-context`. The builder already has the current
Sputnik 1.0.0 SDK image `sputnik-release-sdk:1.0.0`. If unavailable, the Notebook
root Dockerfile's `sdk` target can build a suitable SDK base from that context;
pass its tag as SDK_IMAGE. The build checks current SDK sources, requires full
native Core/web/operator binaries, runs the Sputnik public-session integration
suite, and builds frontend assets with Node in a separate build stage. Python
and Node are not installed in the runtime image.

```sh
docker build --build-arg BUILD_JOBS=16 \
  -f sputnik-notebook/apps/notebook-web/deploy/Dockerfile \
  -t docker.orlando-labs.com/sputnik-notebook-web:UNIQUE_TAG .
docker push docker.orlando-labs.com/sputnik-notebook-web:UNIQUE_TAG
```

Pin the resulting registry digest in `/opt/sputnik-notebook/.env` as
NOTEBOOK_IMAGE. A source-verified native build cache may supply SDK_IMAGE when
all SDK/Core/dependency source fingerprints match; application binaries and
tests must still be rebuilt. Never assume a mutable tag proves source identity.

## Services and data

[compose.yaml](compose.yaml) defines independent Core and web containers using
the same image digest, UID/GID 10197, read-only roots, dropped capabilities,
bounded CPU/memory/processes/logs and `unless-stopped` restarts. Core publishes no
TCP port. Web publishes only `192.168.1.97:18197`; it trusts forwarded provenance
from the exact nginx address `192.168.1.155/32` and its own loopback health check.
The default listener/proxy configuration remains loopback for other installations.

The demo policy admits up to three active guest workers through
`core.public_max_active_workers`, including preparation and cancellation.
Saturated starts return HTTP 429 before accepting the command. Compose uses
`notebook-demo-worker` for this dedicated Core. Each execution worker runs on
one logical CPU and has hard limits of 30 CPU seconds over its process lifetime
and 192 MiB of virtual address space. Override the two limits with
`NOTEBOOK_DEMO_WORKER_CPU_SECONDS` and `NOTEBOOK_DEMO_WORKER_MEMORY_BYTES` in the
Core container environment. The container-wide limits also cover the Core
process and workers retained between runs.

| Host path | Container use |
| --- | --- |
| /md0/sputnik-notebook/core | Core state / Unix socket; web mounts it read-only |
| /md0/sputnik-notebook/web | Web catalog / opening receipts |
| /md0/sputnik-notebook/packages | Operator package store |
| /md0/sputnik-notebook/cache-core | SDK/Core caches |
| /md0/sputnik-notebook/cache-web | Web caches |
| /md0/sputnik-notebook/config | Read-only policy / publication configuration |

Data/cache directories are owned by 10197:10197, mode 0700. Config is owned by
the host operator with group 10197, mode 0750; policy/publication files are 0640.
`config/web.env` is operator-owned, mode 0600. It contains independent persistent
ORBIT_SESSION_SECRET and ORBIT_CSRF_SECRET values generated on the target host.
It is read by Compose, and its contents must not enter reports, Git, process
arguments or `docker compose config` output. Use `config --quiet` for validation.

Start Core first and wait for its native RPC health check. Publish the starter
with `/usr/local/bin/notebook-public-template --core-root /var/lib/notebook-core`
using a one-shot container with the Core mount; atomically install its JSON
output as `config/public-templates.json`, owner operator:10197, mode 0640. Start
web only afterward. `/health/ready` checks Core as well as HTTP; both roles have
health checks. Do not use test providers, session seed helpers or Node smoke
servers in production.

## Edge and maintenance

[nginx.remote.conf](nginx.remote.conf) serves the selected host. Copy only the
image's `frontend/dist/assets/` into `/srv/sputnik-notebook/public/assets/` on
22155. Preserve previously published hashed assets when updating. The Vite
manifest, sources, migrations and binaries are not public files. Set the
SELinux content context for this public directory. The `sputnik-lang.online`
certificate on 22155 covers both `sputnik-lang.online` and
`notebook.sputnik-lang.online`. Certbot uses the existing `/var/www/letsencrypt`
webroot, renewal timer and nginx reload hook. Run `nginx -t` before every reload.

The proxy preserves Host, overwrites forwarded provenance, caps request bodies
at 2 MiB for the public demo, disables caching and automatic upstream retries, and
omits query strings from its access log. These controls follow the
[nginx proxy documentation](https://nginx.org/en/docs/http/ngx_http_proxy_module.html).
It also limits dynamic traffic to 10 requests/s per peer IP and 80 requests/s
per virtual host, with immediate bursts of 20 and 80 respectively. Excess
requests receive HTTP 429. Cached assets have their own location.

Restart only web with `docker compose restart --no-deps web` when updating HTTP.
Core retains its workers and charged time. Core maintenance interrupts work;
quiesce admission and active runs first. Paused/failed runs are never replayed.

For an offline backup, stop admission/web, wait for or explicitly stop active
work, then stop Core. Copy the complete stopped `core`, `web`, `packages` and
`config` directories with permissions preserved, including SQLite WAL files if
present; exclude Unix socket entries. Session/CSRF keys are part of recovery.
Restore into the same container paths: Core revisions contain absolute paths.
Keep backups on independent storage for protection against loss of `/md0`.
Do not downgrade a migrated catalog without a compatible backup.

## Acceptance

The local real nginx/TLS probe is opt-in:

```sh
NOTEBOOK_WEB_PROBE_NGINX=/absolute/path/to/nginx \
  node tools/production_probe.mjs
```

It uses an explicitly trusted ephemeral certificate, tests the actual nginx
example and restores stopped data at original paths. It does not establish
external GitHub consent. `test/deployment_probe.s` creates an anonymous visitor,
executes real work and writes only non-secret counters to its report; its 0600
private state file enables a separate verify phase after restart/restore. HTTPS
verification stays enabled. The explicit loopback override is for an isolated
container preflight before publishing the edge route.

Run the browser acceptance against the selected live origin:

```sh
NOTEBOOK_WEB_DEPLOY_ORIGIN=https://notebook.sputnik-lang.online \
NOTEBOOK_WEB_DEPLOY_PUBLIC_ONLY=1 NOTEBOOK_WEB_TEST_PUBLIC_FULL=1 \
  npm run test:browser -- --config playwright.deployment.config.ts
```

This checks actual anonymous use, ownership/CSRF, a full sixty-second worker
termination, remaining time across copies and disabled sign-in/private APIs.
The rollout's image digest, Linux build/test reports, restoration and live
browser evidence are recorded separately from the source-only configuration.
