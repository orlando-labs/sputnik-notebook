# Notebook web — runtime observations and process cleanup

31 October 2026. Stage 4i.2 implemented on the **current workspace Sputnik 1.0.0**,
without an isolated compiler or SPUTNIK override in final acceptance. Existing
SDK/other workspace edits were preserved. No external deployment was performed.

## Implemented behavior

- Status / Alert supports sheet, cell, action, service and runtime targets,
  source navigation, current errors/staleness, restart advice and authoritative
  computation exhaustion. Exact charged/remaining time is visible; restart cannot
  renew the quota. Book computation/storage policy and public 60-second ceilings
  remain Core-owned.
- Task Monitor projects the shared validated binary telemetry: at most 512 task
  records, exact identities/parents/counters, hierarchy, duration, state/errors,
  known controller-cell/line links, CPU/memory and omissions. Private worker file
  paths and PIDs are not exported. Errors only is a local filter. Missing data
  stays unavailable; source/environment/worker/history changes mark it stale.
- Artifact Browser interprets captured result path/name/caption records, up to
  128 references. Preview/download uses existing ACL-checked Core file APIs against
  that run's **immutable saved revision**. A newer bundle does not retarget old
  references. External paths, traversal and generated files outside the saved
  bundle remain explicitly unavailable. Download retains exact bytes.
- Result Inspector adds native captured Inspect/Pretty/table, bounded literal
  Unicode Find, case selection, match navigation, wrap, copy and download. It
  searches captured text, not arbitrary runtime locals. Log Viewer adds stream/
  substring filters, bounded adjacent-event grouping, copy/export and omission
  markers. Rendering is literal; these controls do not run source.
- All **35 Swift tools / 33 persisted kinds** now have web kind coverage; Config
  Editor and Image Annotator configure existing kinds. Designer/Save and full
  native → web → native transfer preserve authored/unknown settings, exact
  integers, nested panels, book quotas and bundled bytes. Kind coverage is not
  complete SwiftUI interaction or local filesystem equivalence.

[Current inventory](parity-inventory.json) · [Inventory check](parity-inventory.log) ·
[Transfer summary](parity-transfer-summary.json) ·
[Implementation plan](../../../engineering/notebook-web-implementation.md) ·
[Stage 4i.1 audit snapshot](../../../engineering/notebook-web-parity-audit-2026-10-31.md).

## Acceptance

**64 browser scenarios passed** on the current SDK. The same seven new runtime
scenarios and the all-palette transfer check run in all four configurations.
Native/production additionally runs 32 existing board/designer/execution/resource/
history regressions. Actual Core/worker execution covers nested child failures,
exact result text, literal search/export, captured-revision artifacts, invalid
paths, inert authoring, quota termination, viewers/revocation and action/service
targets. Tests use the existing local GitHub provider fixture.

| Backend | Assets | Result | Log |
| --- | --- | --- | --- |
| VM | Production | 8/8 | [log](browser-vm-production.log) |
| VM | Development | 8/8 | [log](browser-vm-development.log) |
| Full native | Production | 40/40 | [log](browser-native-production.log) |
| Full native | Development | 8/8 | [log](browser-native-development.log) |

After fixing runner teardown, all four configurations were repeated with the
eight new/transfer scenarios: **32 more passes**, **96 browser executions in
total**. Product sources/assets were unchanged during those runs.

| Backend | Production | Development |
| --- | --- | --- |
| VM | [8/8](browser-cleanup-vm-production.log) | [8/8](browser-cleanup-vm-development.log) |
| Full native | [8/8](browser-cleanup-native-production.log) | [8/8](browser-cleanup-native-development.log) |

The [real backend/main + independent Core probe](production-probe.json) passes
all five groups: production SSR/session/provenance/CSRF, >1 MiB exact upload,
hashed/public vs private paths, HTTP restart during work with same-command
identity, and Core outage/restart retaining results and positive charged time.
It checks effective 60-second/64 MiB book limits. This uses a disposable locally
seeded signed session and a loopback proxy contract, not live GitHub consent,
actual nginx routing or TLS. See [result](production-probe.log) and
[process output](production-processes.log).

Native builds were rebuilt on current Sputnik 1.0.0:

- [Core](core-native-build.log): 1365/1365 native bodies, zero VM fallback.
- [Actual main](main-native-build.log) and [fixture](fixture-native-build.log):
  3222/3222 native bodies each, zero VM fallback.
- [Summary](native-summary.json), [SDK build](sdk-build.log),
  [identities](identities.json) and [source/binary hashes](source-sha256.json).
  The SDK has existing local changes, so HEAD alone is not its build identity.
- [App lock migration](package-lock-migration.log) and
  [Core lock migration](core-lock-migration.log) explicitly record Sputnik 1.0.0.
  Initial legacy locks were rejected as LOCK_LANGUAGE_MISMATCH. No lock check
  was bypassed and no language changes were made for this web implementation.
- [Core telemetry/protocol checks](core-telemetry.log),
  [observation unit cases](observation-unit.log),
  [board editor](board-editor-unit.log), [boards](boards-unit.log) and
  [duration/chart checks](telemetry-unit.log) pass.
- [Vue/TypeScript and production build](frontend-build.log) passes with the
  existing Vite large-chunk warning. Native logs contain SDK/dependency compiler
  deprecation warnings; builds succeed.

Initial acceptance exposed incorrect test expectations: a resource change
requires explicit worker restart; current registry entries exclude reset epochs;
viewers have no Run button; an inherited unlimited per-run quota has no ceiling
label. Fixtures now exercise those existing contracts explicitly. One initial
OAuth fixture sign-in also failed during concurrent native compilation; its
cause was not established and no retry loop/assertion weakening was added.
[Initial log](browser-initial.log), [recheck](browser-initial-recheck.log) and
[successful corrected run](browser-initial-final.log) are retained. Final complete
runs above have no outstanding failures.

## Process leak and fix

The user's process audit found **42 remaining test processes**: Vite, Sputnik
provider/backend fixtures, Core agents and their workers. Their original test
parents had exited. They were identified by exact test paths/state roots and
known PIDs, signalled and confirmed gone; no generic killall or process-name kill
was used. Unrelated Codex/ChatGPT node services were left running.
[Cleanup record](orphan-cleanup.json).

Playwright's default forced process-group teardown killed the smoke orchestrator,
while its detached children lived in separate groups and survived. The fix keeps
test provider/Vite/backend/Core processes in the runner group, uses exec for the
POSIX launcher, requests graceful SIGTERM with a bounded timeout, closes proxy
connections and stops children concurrently. A forced group cancellation now
also kills the services; worker channel closure ends the separate worker session.
The production probe uses inherited groups and stops individual HTTP/Core child
processes explicitly. Production application's independent Core lifetime is
unchanged, and the real-entry restart test still passes.

[Process cleanup integration](process-cleanup.log) exercises **four cases**, each
with a real active worker: VM/development and native/production × SIGTERM/SIGKILL.
All owned processes reach zero: six per VM case, five per native case.
[Machine-readable result](process-cleanup-summary.json).

After the final four Playwright runs and real-entry probe, a separate process
inventory confirmed **zero owned test processes**, with four unrelated node
services untouched. [Final audit](process-final-audit.json).

## Visual check and limits

Desktop/phone Task Monitor screenshots were inspected in both themes. Browser
checks assert no document horizontal overflow at 1280/375 px. The transfer test
also captures the whole palette viewport; SwiftUI itself is not automated.

| View | Light | Dark |
| --- | --- | --- |
| Tasks, 1280 px | [desktop](tasks-light-1280.png) | [desktop](tasks-dark-1280.png) |
| Tasks, 375 px | [phone](tasks-light-375.png) | [phone](tasks-dark-375.png) |
| Palette, 1280 px | [desktop](palette-light-1280.png) | [desktop](palette-dark-1280.png) |
| Palette, 375 px | [phone](palette-light-375.png) | [phone](palette-dark-375.png) |

Anonymous public landing/template lifecycle remains Stage 4i.3. Its implemented
authenticated preview still enforces cumulative/per-run 60-second ceilings.
Safari/mobile capture, live OAuth, nginx/TLS and Linux deployment remain external
acceptance work. Artifact files generated outside the saved bundle require a
separate capture/storage contract. No whole-SDK conformance is claimed.

## Reproduce

Use the current sibling SDK with SPUTNIK unset. Build Core and main/fixture with
the [app commands](../../../../apps/notebook-web/README.md), including lock
migration when needed. From apps/notebook-web:

```sh
node tools/runtime_observation_test.mjs
node tools/board_editor_test.mjs
node tools/parity_inventory.mjs
node tools/process_cleanup_test.mjs
node tools/production_probe.mjs
cd frontend
npm run test:browser -- test/runtime-observation.spec.ts test/parity-transfer.spec.ts
```

Repeat with ORBIT_E2E_NATIVE=1 and/or ORBIT_E2E_MODE=development and installed
Chromium. The broad native/production pass additionally uses boards.spec.ts,
board-designer.spec.ts, execution.spec.ts, resources.spec.ts and run-history.spec.ts.
Keep production assets unchanged while serving a run. The process cleanup
acceptance requires POSIX ps/signals; the archive fixture uses Python 3 ZIP tools.
Neither tool is a production runtime dependency.
