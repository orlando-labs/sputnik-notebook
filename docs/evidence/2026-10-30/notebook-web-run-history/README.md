# Web run snapshots and experiments — Stage 4h.2

30 October 2026. Implemented in the existing notebook web app and shared Core.

## Delivered

- Snapshots and experiments… opens from Run history and Run History / Experiment
  Compare board components. The retained list is paginated and can include removed
  sheets. Active results cannot be presented as immutable snapshots.
- The public snapshot contains exact project/local scalar JSON, executed cell
  sources, module/revision references, bounded rich results and frozen environment,
  worker-settings and installed-package provenance. Mutable labels are separate.
  Older records without captured provenance explicitly say it is unavailable.
- Inspection/export does not replay code. Private Core IDs, worker paths/PIDs,
  grants and installer specs/logs are filtered by the adapter. Snapshot exports
  fit 48 MiB. Module contents/input assets remain in the retained revision export;
  this is not an installed-environment archive or a restorable worker heap.
- Rename and Pin use separate metadata versions, write ACL and durable command
  receipts. Up to ten pinned final results survive automatic retention, while
  consuming effective run-count/storage quotas. Delete requires confirmation,
  refuses pinned/current/active results, uses the durable deletion queue and
  expires associated Run receipts without permitting replay. Usage stays charged.
  Releasing a pin and eligible deletion remain possible at archive exhaustion.
- Comparison presents project/local inputs, metrics and elapsed time with exact
  Int64/decimal/exponent deltas. CSV quoting also neutralizes formula prefixes.
- Restore reviews one scalar scope, checks current definitions/types/bounds/date
  settings and excludes current/historical file bindings. The existing atomic
  Apply, revision/input-version CAS, quotas and receipt recovery remain in force.
  The UI warns that initialized Watch workers may execute after explicit Apply.
  Sources/defaults/assets are separate. Stale reviews remain visible until reset.
- Viewers can inspect/export; mutations and restore are denied. Revocation clears
  snapshot contents. Pending commands retain their exact ID for explicit recovery.

Core stores provenance at run acceptance, rather than inferring it later from
current settings or packages. Metadata/provenance participate in archive accounting,
retention cleanup and temporary-project purge. Pin protection does not raise any
policy ceiling; public computation still has its cumulative 60-second cap.

## Verification

All nine final scenarios passed in all four configurations, using **explicit web
SDK 3eb0f05** and the current workspace SDK for Core/worker. The SDK qualification
below is part of the result.

| Backend | Assets | Result | Log |
| --- | --- | --- | --- |
| VM | Production | 9 passed | [log](browser-vm-production.log) |
| VM | Vite development | 9 passed | [log](browser-vm-development.log) |
| Full native | Production | 9 passed | [log](browser-native-production.log) |
| Full native | Vite development | 9 passed | [log](browser-native-development.log) |

Scenarios cover exact Int64/local values and immutable content after label edits,
snapshot export/source inspection, board entry/comparison/CSV, metadata conflicts
and lost replies, pin/unpin/confirmed deletion and unchanged usage, project/local
scalar review, stale review rejection and file exclusion, explicit Watch restore,
retention and quota rejection, unpin/delete at exhaustion, foreign-project denial,
viewer/revocation behavior, the ten-pin limit, active/force-stopped snapshots and
historical inspection after a sheet is removed. Test cleanup releases workers so
separate scenarios do not occupy the server's eight-worker limit.

Additional checks:

- [Pure history checks](unit.log): exact integer/decimal/exponent deltas, missing
  values, CSV escaping, typed restore validation and nested file-binding exclusion.
- [Board editor checks](board-unit.log), [adjacent controls checks](controls-unit.log)
  and [frontend typecheck/build](frontend.log) passed. Bundle-size advisory remains.
- [Native build summary](native-summary.json): Core 1365/1365 and web fixture/main 3219/3219 bodies require full
  native coverage with zero VM fallback; Core uses the current SDK, fixture and
  backend/main use the explicit compatible web compiler.
- Existing Core [receipt/retention](policy-0.log) and
  [bounded registry/pagination](policy-1.log) regression tests passed.
- [33 adjacent browser regressions](regressions.log) passed: resources/public limits,
  environments/worker settings, selection/date/preset controls and Board Designer.
- Light/dark desktop/phone screenshots and comparison were inspected. Dialog
  overflow is checked at phone width.
- git diff --check and changed-file whitespace/relative-link checks passed.

Preliminary runs found a nested SQLite transaction-mode error in explicit deletion;
the outer transaction now starts in immediate mode. Exact select labels were made
explicit for accessible controls. No arbitrary delay, sign-in retry or assertion
removal was used. A focused [delete/pin recheck](delete-check.log) also passed.

## SDK qualification

The newest workspace SDK still fails during web startup with a callback arity
ArgumentError at database.s:20 before notebook routes are available. See the
[probe](current-sdk-gate.log), [startup trace](current-sdk-startup.log) and
[compiler/dependency identities](sdk-compatibility.json). This stage changes no SDK
or sibling dependency sources and does not report the newest SDK as web compatible.
The browser matrix and web native builds explicitly select isolated SDK 3eb0f05;
the default compiler was not replaced. No deployment or real GitHub OAuth check
was performed; local tests use the existing provider fixture.

## Reproduce and limits

Build Core/worker with make remote-core and frontend assets with npm run build
from apps/notebook-web/frontend. Build test/app_fixture.s and backend/main.s using
isolated SDK 3eb0f05 with --target native --require-full-native and the existing
grants in the app README. From the frontend set SPUTNIK to that compiler and
PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH to installed Chromium, then run npm run
test:browser -- test/run-history.spec.ts. Repeat with ORBIT_E2E_NATIVE=1 and/or
ORBIT_E2E_MODE=development. Verification used Chromium 152.0.7977.82.

Core regressions use tests/notebook_policy_tests.py --worker /absolute/worker
--core /absolute/core with --test PolicyTests.test_collection_preserves_failure_and_previous_result_and_expires_receipts
or PolicyTests.test_registry_is_bounded_and_history_pages_survive_collection.
Pure checks run with node apps/notebook-web/tools/run_history_test.mjs.

Restore is atomic per scope, not across project and multiple cell scopes. Current
values of a cell scope are loaded when its sheet is active. Rich output uses the
existing bounded presentation codec; omitted/unsupported output stays marked.
Retention may remove an unpinned snapshot, so it is not a permanent backup. Current
retained presentations remain protected, including those of removed owners.
Safari/mobile operating systems and production deployment were not tested.
The next plan slice is the cross-platform examples/parity and deployment audit.

## Screenshots and sources

| Light | Dark |
| --- | --- |
| [Desktop](history-light-1280.png) | [Desktop](history-dark-1280.png) |
| [Phone](history-light-375.png) | [Phone](history-dark-375.png) |

[Comparison](comparison.png) · [Source and binary hashes](source-sha256.json) ·
[Plan](../../../engineering/notebook-web-implementation.md) ·
[Resource contract](../../../engineering/notebook-resource-policies.md)
