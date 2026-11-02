# Notebook web — stage 2: execution and reconnect

27 October 2026. Added explicit notebook execution through the existing shared
core, with the compact macOS palette, toolbar, cell actions and result surfaces.

## Behavior

- Run / Run All / Shift+Enter execute the exact saved revision. Unsaved or
  outdated source cannot start a new run. Sheet workers retain variables across
  runs. Save/load remain inert and do not create execution or scheduling work.
- Values, live stdout/stderr, cell errors and unobserved task failures render
  as escaped text. History opens earlier results without replacing source;
  revision/source/epoch changes mark previous output. Rich binary presentation
  and interactive components remain a later slice.
- Stop requests cancellation; Force Stop and Restart Worker are explicitly
  confirmed. Force-stopped/interrupted workers require a restart. Core enforces
  busy-sheet and exact revision/epoch checks.
- Registry polling reattaches after reload or closing/reopening a tab. It pauses
  while hidden and resumes on focus. Closing the browser or restarting only the
  HTTP server leaves accepted work with the independent core agent.
- Uncertain commands retain their exact payload and ID per account/project in
  session storage. Receipt GETs resolve accepted work. Only an explicit retry
  resends an unaccepted command, retaining its original revision and ID.
- Execution uses current owner/editor/viewer permissions. Every privileged call
  checks project ACL; run read/Stop/receipt presentation verifies trusted core
  ownership. Live role changes update execution controls. DTOs exclude private
  project/runtime IDs, worker PIDs, execution documents, filesystem paths,
  service records and agent-global event counters. History returns the recent
  100 runs plus all active runs.

## Checks

Vue/TypeScript and Vite production build passed (23 modules). Node syntax checks,
explicit whitespace checks for untracked application source and `git diff
--check` passed.

All 23 browser scenarios passed against a real core agent in each supported
configuration, for **92 passing browser tests**:

| Backend | Assets | Result |
| --- | --- | --- |
| VM | Production | [23 passed](browser-vm-production.log) |
| VM | Development + HMR | [23 passed](browser-vm-development.log) |
| Rebuilt full-native fixture | Production | [23 passed](browser-native-production.log) |
| Rebuilt full-native fixture | Development + HMR | [23 passed](browser-native-development.log) |

The seven execution scenarios cover Run All and single-cell state, live output,
source provenance/history, failures, preparation/cooperative/force cancellation,
restart and stale epochs, reload and closed-tab reattachment without replay,
accepted-response loss, explicit retry of an unaccepted command, ownership,
current ACL/live role changes, receipts, CSRF, DTO boundaries and task failures.
The previous 16 document/catalog/library scenarios also remain green.

The separate `tools/execution_lifecycle_test.mjs` uses an independent disposable
agent and the same catalog/core paths across an HTTP-process restart. It asserts
one physical run, unchanged ID/epoch, result `42` and zero replayed Run requests.
It then kills only that agent's own disposable worker, observes `interrupted`
and the restart gate in the UI, explicitly restarts and completes `84` in a new
epoch. See [the assertion report](execution-lifecycle-report.json).

Both production entry and fixture compiled with `--target native
--require-full-native`: 2696 native bodies, full body coverage, VM independence,
no runtime bridge and zero fallback. Binary hashes and compiler timings are in
[the native summary](native-summary.json). The real entry also passed anonymous
startup with an unstarted core in [VM](main-entry-vm.log) and
[full-native](main-entry-native.log).

OAuth uses the offline Alice/Bob fixture throughout these checks. The refreshed
preview at `http://127.0.0.1:3010` uses the existing catalog and independent core
agent. A browser check under Bob confirmed the original single catalog project,
its uninitialized notebook, successful document reads and no JavaScript errors;
no notebook was provisioned by this check. See [preview check](preview-check.json).
Real GitHub consent and production deployment are outside these local checks.

## Visual review

Reviewed saved code, text output and values in both themes on desktop and mobile.
The browser scenarios also assert no horizontal overflow at 320/375/1280 px.

- [Light desktop](results-light-1280.png), [dark desktop](results-dark-1280.png).
- [Light mobile](results-light-375.png), [dark mobile](results-dark-375.png).

The implementation and remaining stages are described in
[the implementation plan](../../../engineering/notebook-web-implementation.md).
