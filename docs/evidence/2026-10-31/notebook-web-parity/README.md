# Notebook web — parity and deployment-readiness audit

31 October 2026, macOS arm64. Stage 4i.1. Existing workspace changes were preserved;
no external service was deployed. [Findings and complete palette matrix](../../../engineering/notebook-web-parity-audit-2026-10-31.md).

## What changed

- Reproducible source inventory: **35 Swift tools / 33 saved kinds / 30 web palette
  kinds**. Status/Alert, Artifact Browser and Task Monitor remain explicitly
  unavailable; their authored settings survive. Config Editor and Image Annotator
  use existing kinds. Result/Log controls have documented semantic gaps.
- A test-only native C-API adapter and generated version-4 palette fixture exercise
  native save → browser import/edit/save/export → native reopen/edit/save. The
  complete document matches except for the intended code edit, including nested
  panels, unknown settings, exact integers, book quotas and bundled bytes. Import,
  opening and Save create no runs or environments. This uses the bridge called
  by Swift, not an automated SwiftUI session or runtime execution of every tool.
- A real backend/main + independent Core acceptance probe uses a locally seeded
  signed session through actual production session/authentication/CSRF middleware.
  No fixture provider or auth bypass is installed in the application.
- An [operator guide](../../../../apps/notebook-web/deploy/README.md) and
  [nginx example](../../../../apps/notebook-web/deploy/nginx.conf.example) cover
  original Host/forwarded provenance, public assets, private paths, an explicit
  112 MiB upload envelope, persistent stores and release/restart ordering.
- App README and implementation/gap plans now reflect implemented media/history
  features and the remaining work.

## Verification

All **18 browser scenarios passed**: the new transfer scenario in all four
configurations plus the existing seven source/transfer scenarios in VM/development
and native/production. The latter cover real module execution, binary resources,
file conflicts, exact metadata, unsafe archives, ACLs, packages, reloads, lost
responses and explicit same-command retry.

| Backend | Assets | Result | Log |
| --- | --- | --- | --- |
| VM | Production | 1/1 transfer | [log](browser-vm-production.log) |
| VM | Vite development | 8/8 transfer + regressions | [log](browser-vm-development.log) |
| Full native | Production | 8/8 transfer + regressions | [log](browser-native-production.log) |
| Full native | Vite development | 1/1 transfer | [log](browser-native-development.log) |

[Transfer summary](parity-transfer-summary.json) ·
[Source inventory](parity-inventory.json) · [Inventory check](parity-inventory.log) ·
[Native probe build](native-transfer-probe-build.log) ·
[Vue/TypeScript and production build](frontend-build.log).

The production build passes with the existing Vite warning about a JS chunk
larger than 500 kB. No production assets were changed during the final browser
acceptance run.

All **five real-entry acceptance groups passed**:

1. SSR/bootstrap/CSP, unauthenticated private-API rejection, direct-backend HTTPS
   provenance rejection and replacement of forged forwarded headers.
2. Signed session, CSRF, authenticated save, a 1.2 MB resource upload and exact
   byte download through Core.
3. Hashed immutable assets; manifest, source, migrations, binary and test helper
   routes unavailable to public requests.
4. Accepted work survives HTTP restart, finishes once, and the same command
   returns the same run. Effective computation/storage limits are 60 seconds /
   64 MiB and completed work has positive charged time.
5. Core outage gives sanitized 503; independent Core restart retains results and
   charged time.

[Probe report](production-probe.json) · [Result](production-probe.log) ·
[Child-process log](production-processes.log).

The proxy probe uses loopback HTTP with the documented original Host and one-hop
HTTPS provenance headers. It does **not** perform TLS or launch nginx. nginx is
not installed here, so `nginx -t` and actual nginx routing were not executed.
Real GitHub consent, Linux service operation and backup/restore were not tested.
The test seed helper keeps secrets/session tokens in memory and out of reports.
Temporary stores and child processes are cleaned up.

The existing authenticated temporary preview retains its public cumulative and
per-run **60-second** ceilings. An anonymous public landing/template lifecycle
is still unimplemented; this audit does not establish that product mode.

The default workspace SDK was used with no compiler override. SDK HEAD 05142d1
only changes a regexp regression test relative to b3ed894; compiler/runtime,
application/Core sources and their native binaries match the
[30 October integration](../../2026-10-30/notebook-web-current-sdk/README.md).
[Reused native build summary](native-summary-reused.json) records Core 1365/1365
and main/fixture 3219/3219, zero VM fallback. These builds were reused, not rebuilt
for this audit. The new C-API probe was compiled against that shared native Core.
[Identities](identities.json) and [source/binary fingerprints](source-sha256.json)
make that scope explicit.

Light/dark desktop and phone screenshots were inspected; all transfer runs
assert no document horizontal overflow at both widths:

| View | Light | Dark |
| --- | --- | --- |
| 1280 px | [desktop](palette-light-1280.png) | [desktop](palette-dark-1280.png) |
| 375 px | [phone](palette-light-375.png) | [phone](palette-dark-375.png) |

Node syntax, changed-file whitespace, relative links and reused build hashes
were checked. These checks do not establish whole-SDK or full Swift feature
conformance.

## Reproduce

Keep the production assets unchanged for the lifetime of each test server. Use
the current sibling SDK with SPUTNIK unset. Build Core/worker and main/fixture
using the [app instructions](../../../../apps/notebook-web/README.md), then:

```sh
# From sputnik-notebook:
make build/notebook_web_transfer_probe
cd apps/notebook-web
node tools/parity_inventory.mjs
node tools/production_probe.mjs
cd frontend
npm run test:browser -- test/parity-transfer.spec.ts
```

Set PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH to installed Chromium if needed. Repeat
with ORBIT_E2E_NATIVE=1 and/or ORBIT_E2E_MODE=development. Add
test/sources-transfer.spec.ts for the seven existing regression scenarios.
The fixture archive tooling uses Python 3's standard library; no Python runtime
is required by the production application. The native transfer probe, palette
fixture and seed helper are test-only.

Next is **4i.2: remaining palette runtime**, followed by the anonymous public
lifecycle and external deployment acceptance recorded in the
[implementation plan](../../../engineering/notebook-web-implementation.md).
