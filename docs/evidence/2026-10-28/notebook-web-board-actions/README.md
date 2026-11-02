# Notebook web — actions and server services

28 October 2026. This slice implements Action Button, Execution Controls and
Periodic Work using the existing core invocation/scheduling contracts. The
designer authors their native settings without execution. See the
[implementation plan](../../../engineering/notebook-web-implementation.md).

## Behavior

- An Action calls an exported notebook module function in a persistent world
  scoped to that board/component. Positional and named arguments capture accepted
  project inputs and exact scalar JSON constants at acceptance. No sheet source
  or authored parameter default is rewritten.
- Registry summaries expose public board/component/controller IDs. Private
  invocation owner IDs and worker paths remain internal. Invocation workers do
  not appear as controller-sheet workers. The selected board retains each
  component's latest invocation alongside recent/active records.
- Execution Controls target a controller sheet, cell, action or service. Explicit
  Run/Run Once and View output use separate invocation results, including existing
  text, table, image, plot and telemetry renderers. Controller results retain
  their own provenance and worker. Historical invocation output is accessible
  through Run history. Source/input changes and worker resets mark old output.
- Stop and Force Stop address the invocation's actual run/epoch. Restart derives
  its private owner on the server from an owned run; an enabled/running service
  must first be paused and idle. Controller workers remain independent.
- Periodic Start/Once/Pause/Clear use durable core receipts. The agent owns fixed
  delay/rate, overlap skipping, retention, value/error storage and stop-on-error.
  Pause drains the current call; Stop cancels it and pauses future calls.
  Opening/hiding a board and closing the browser never configure a schedule.
- Scheduling continues without the HTTP gateway. Agent restart preserves history
  and counters but pauses scheduling. An old accepted Start receipt does not
  resume it; a new explicit Start is required. Executable settings/module changes
  also pause future calls. The saved desktop pause-while-hidden flag is retained
  and does not control server schedules.
- A per-account/project browser journal is written before sending commands.
  Lost accepted responses reconnect by receipt; unaccepted commands repeat only
  through explicit Retry with the original payload/ID. Run Once receipts are
  recovered without a second physical invocation.
- Start/Once require current saved source. Pause/Stop remain available with a
  draft. Every mutation checks execution access, ownership and CSRF. Readers
  inspect results/history only; access revocation clears open runtime output and
  history. Scheduler diagnostics are allowlisted rather than forwarding internal
  exceptions.
- History pages contain up to 50 entries. Each retained value/error preview is
  bounded to 4096 characters with an explicit truncation notice. Counters and
  history IDs use exact decimal strings. Rich results share the existing bounded
  presentation/cache contracts.

Audio, managed media/selections, formatted text rendering/editing and the
remaining palette items are separate stages. This does not claim full Swift
palette parity.

## Verification

All 68 browser scenarios passed in each configuration: **272 full-suite passes**.

| Backend | Assets | Result |
| --- | --- | --- |
| VM | Production | [68 passed](browser-vm-production.log) |
| VM | Development + HMR | [68 passed](browser-vm-development.log) |
| Full native | Production | [68 passed](browser-native-production.log) |
| Full native | Development + HMR | [68 passed](browser-native-development.log) |

The seven new scenarios use the real core to cover exact positional/named
arguments and persistent module state; controller isolation; independent output
history and reconnect; a schedule surviving a closed board/browser page;
Pause/Tail/Clear; fixed-rate overlap skipping; failed calls and module-edit pause;
cooperative/force Stop and epoch-checked invocation Restart; lost accepted and
unaccepted commands across reload; same-ID Once deduplication; viewer, CSRF,
cross-project ownership and revocation; and inert designer authoring/preview.

The final fixture spells sleeps in integer milliseconds. Both affected
VM/production timing/cancellation tests also passed in a dedicated
[final check](browser-vm-timing-final.log): **2 additional passes**. The other
three complete configurations use that final fixture.

The extended independent [lifecycle test](lifecycle.log), with its
[compact report](lifecycle.json), proves:

- A web restart reattaches to one physical sheet run without mutation replay.
- A killed disposable worker requires explicit restart into a new epoch.
- A server service continues ticking while its HTTP gateway is stopped.
- Reopening the board sends zero service configuration requests.
- A restarted independent agent retains Tail history/counters and pauses the
  schedule. Repeating the old Start receipt is inert; a new Start resumes it.

Additional checks:

- [Execution DTO tests](dto-unit.log): empty/cleared history, paging, long
  previews, Unicode, exact counters and private scheduler diagnostic filtering.
- [Editor tests](editor-unit.log): exact scalar argument limits/ordering,
  nonvisual service copies and schedule bounds, plus grid/history regressions.
- Existing [board](boards-unit.log), [display](displays-unit.log),
  [input](inputs-unit.log) and [telemetry](telemetry-unit.log) checks pass.
- [Vue/TypeScript and Vite production build](frontend-build.log).
- Actual application entry startup: [VM](main-entry-vm.log),
  [full native](main-entry-native.log).
- Both [main](main-native-build.json) and [fixture](fixture-native-build.json)
  were rebuilt with `--target native --require-full-native`: **3018 native bodies
  each**, full coverage, VM independence, no runtime bridge and zero fallback.
  [Build summary and binary hashes](native-summary.json).
- [Final source/build-manifest hashes](source-sha256.json). New/untracked source
  whitespace was checked explicitly.

Desktop/mobile command and invocation-output layouts were visually inspected in
both themes. Browser assertions check no page horizontal overflow at 1280, 375
and 320 px.

| Layout | Light | Dark |
| --- | --- | --- |
| Desktop | [1280 px](board-commands-light-1280.png) | [1280 px](board-commands-dark-1280.png) |
| Mobile | [375 px](board-commands-light-375.png) | [375 px](board-commands-dark-375.png) |

The preview at `http://127.0.0.1:3010` was refreshed with the existing database and
external core socket retained. The page and both current JS/CSS assets return
HTTP 200: [preview check](preview.json). Preview uses the offline OAuth fixture.
