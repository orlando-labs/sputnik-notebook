# Web environments and worker settings — Stage 4h.1

30 October 2026. Implemented in the existing notebook web app and shared Core.

## Delivered

- Environments… lists the latest 100 Python/Ruby environment records with opaque
  generation IDs, language flags, state and fixed diagnostics. Opening the dialog
  does not prepare an environment, execute cells or reset a worker.
- Only the project owner can prepare/retry saved manifests or change settings.
  Preparation is disabled by default; --allow-environment-preparation enables it.
  --web-worker-grants defines the exact editable capability names, empty by default.
  The browser cannot author targets or absolute server paths. Private operator
  grants are preserved without revealing their values.
- Each sheet can retain its current environment setting, resolve saved manifests
  or bind a ready generation from its own project. The adapter maps Core's generation records to
  private directories. Existing custom operator directories can be retained.
- Review and explicit confirmation precede reset. Core checks saved revision,
  settings version and runtime epoch, refuses active controller/action/service
  work, pauses services and discards variables. The next Run is explicit.
  Preparation alone keeps existing workers unchanged.
- Polling preserves local values and input focus. Reload settings explicitly
  rebases the draft. Permission loss closes it. Lost replies query durable Core
  receipts; only an explicit retry sends the same frozen command again.
- Archive storage admission covers preparation receipts, including the serialized
  spec, and worker settings receipts/events before accepting side effects.
  Installed environments remain outside logical archive accounting, following
  the existing resource contract; free disk space is checked separately.
  Worker resets keep cumulative execution usage. Public temporary sessions cannot
  install environments or change grants and retain their 60-second ceilings.

Raw installer logs, specs, interpreter paths, resolved URLs, private grants and
Core identities are never copied into the browser DTO. Inspect returns fixed
diagnostic summaries and indicates whether installer output exists; full logs
remain available to the server operator.

## Verification

The web compiler is explicitly isolated SDK **3eb0f05**. Core/worker use the
current workspace SDK. The qualification below is part of these results.

| Backend | Assets | Operator policy | Result | Log |
| --- | --- | --- | --- | --- |
| VM | Production | Preparation + two grants enabled | 6 passed | [log](browser-vm-production.log) |
| VM | Vite development | Default, preparation disabled | 5 passed; 1 intentional skip | [log](browser-vm-development.log) |
| Full native | Production | Preparation + two grants enabled | 6 passed | [log](browser-native-production.log) |
| Full native | Vite development | Default, preparation disabled | 5 passed; 1 intentional skip | [log](browser-native-development.log) |

All 22 applicable checks passed. The skipped scenario creates a real Python venv
and is exercised in both enabled production configurations. Default configurations
instead prove that preparation is denied. The scenarios cover private DTOs,
arbitrary grant/path and unknown-field rejection, unknown sheets, local review,
focus across a real registry poll, stale settings/revision/epoch, active-run
rejection, lost-response recovery, owner/editor ACL and revocation, preservation
of private grants, real empty-requirements preparation, ready binding, failed
installation/retry, storage rejection, unchanged cumulative counters and public
temporary-session restrictions. Initial uninitialized sheets remain idle.

Additional checks:

- [Frontend typecheck/build](frontend.log) passed. The existing bundle-size
  advisory remains non-fatal.
- [Native summary](native-summary.json): Core 1359/1359 native bodies; fixture
  and real backend/main 3186/3186; zero VM fallback. All builds require full native.
- [Existing Core generation/restart/log test](core-regression.log) passed on the
  final Core. It covers generation reuse, restart, failure and retained logs.
- [15 adjacent browser regressions](regressions.log) passed, covering shared
  selection, dates/presets, media binding, resource policies and public 60 seconds.
  An [initial run](regressions-initial.log) had 14 passes and one application-load
  timeout because assets were rebuilt while its server was running. The unchanged
  carousel case [passed alone](carousel-recheck.log); the final complete run used
  stable assets and passed all 15. No retry loop or assertion removal was added.
- Desktop/phone and light/dark screenshots were inspected; ready-generation
  controls also assert no dialog overflow at phone width.
- git diff --check and changed-file whitespace/relative-link checks passed.

## SDK qualification

The workspace SDK is now 1b5bbfa and the prior namespace/Orbit startup failure has
changed after upstream updates. A fresh-cache probe still fails at application
startup with callback arity ArgumentError, before notebook routes are available.
See [probe](current-sdk-gate.log), [startup trace](current-sdk-startup.log) and
[compiler/dependency identities](sdk-compatibility.json).

This stage changes no SDK or sibling dependency sources. It does not report the
newest SDK as web compatible or replace the default compiler. The verified web
builds and browser matrix explicitly select isolated SDK 3eb0f05. Current SDK
callback compatibility remains a release gate. No deployment or real GitHub
OAuth check was performed; browser tests use the local provider fixture.

## Reproduce

Build the current Core/worker with make remote-core from the repository root.
Build frontend assets with npm run build from apps/notebook-web/frontend. Build
test/app_fixture.s and backend/main.s with isolated SDK 3eb0f05, --target native
and --require-full-native, using the existing grants in the app README.

From the frontend, select SPUTNIK=/absolute/path/to/3eb0f05/build/sputnik and an
installed PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH, then run npm run test:browser --
test/environments.spec.ts. Set ORBIT_E2E_NATIVE=1 for the native backend and
ORBIT_E2E_MODE=development for Vite. Set NOTEBOOK_WEB_TEST_ENVIRONMENTS=1 to enable
test preparation and time.now/random.secure grants; leave it unset for the default
closed policy. Verification used Chromium 152.0.7977.82. Do not rebuild assets
while production browser servers are active.

Actual Ruby installation, Safari/mobile operating systems and an interrupted
installer UI path were not exercised by this stage. Core's existing interrupted
state is presented with explicit retry. Expanded immutable run snapshots,
inspection and experiment comparison remain Stage 4h.2.

## Screenshots and sources

| Light | Dark |
| --- | --- |
| [Desktop](environments-light-1280.png) | [Desktop](environments-dark-1280.png) |
| [Phone](environments-light-375.png) | [Phone](environments-dark-375.png) |

[Ready generation](environment-ready.png) · [Ready generation on phone](environment-ready-phone.png) ·
[Source and binary hashes](source-sha256.json) ·
[Plan](../../../engineering/notebook-web-implementation.md) ·
[Resource contract](../../../engineering/notebook-resource-policies.md)
