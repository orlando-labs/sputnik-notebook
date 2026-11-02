# Notebook web — presentation gap fixes

27 October 2026. Scope: runtime result projection, measurement state and explicit
unavailable states for authored cell components. Authored display bindings and
inspectors, boards, audio playback/input and other palette features remain in
the [implementation plan](../../../engineering/notebook-web-implementation.md).

## Changes

- `notebook.core.host.presentation_snapshot` now includes progress descriptions,
  current/total/done/elapsed time, named stopwatches, cell timing and full retained
  live-chart channel snapshots. It uses the shared validated binary codec and
  the existing 32 MiB JSON limit. Double values use round-trip decimal output;
  milliseconds and total point counters are strings, including counters beyond
  the JavaScript safe-integer range. Audio/control-only output remains explicitly
  unsupported. Private locals, worker state and artifact paths are excluded.
- The authorized backend DTO and browser carry these measurements through live,
  terminal, reconnect and history paths. A running dirty cell's new measurements
  remain current. Invalidated finished measurements and older source/run
  snapshots are marked stale. Stop leaves a partial progress count unchanged.
- The Swift-style panels show progress, cell time, stopwatches and chart channels.
  Chart bounds follow incoming data until the user zooms. A chosen viewport stays
  fixed across updates; Reset returns to the full current domain. Drawing samples
  bounded geometry, preserving extrema and point order; CSV includes every
  retained point. Responsive plot margins and constrained tick labels prevent
  clipping scientific/negative axis labels or consuming the entire plot frame.
- Preserved pre/post-cell display components have visible unavailable notices.
  Their authored settings survive save; they are not silently omitted. Inputs
  and Watch commands have descriptive run-history labels.
- The README capability introduction now reflects the implemented modules,
  resources, dependencies, import/export and parameter controls.

## Verification

All 45 browser scenarios passed in each configuration (180 full-suite passes):

| Backend | Assets | Result |
| --- | --- | --- |
| VM | Production | [45 passed](browser-vm-production.log) |
| VM | Development + HMR | [45 passed](browser-vm-development.log) |
| Full native | Production | [45 passed](browser-native-production.log) |
| Full native | Development + HMR | [45 passed](browser-native-development.log) |

After the final responsive-axis adjustment, five affected scenarios passed again
on [VM/production](browser-final-vm.log) and
[native/development](browser-final-native.log). These cover real plot zoom/pan/PNG,
live precision, stopwatch/chart recovery without replay, viewport persistence,
Stop with partial progress, large-chart CSV, read-only sharing/revocation, stale
Manual measurements after Apply, frozen history and authored-setting preservation.

- [Telemetry tests](telemetry-test.log): exact large durations, tiny/large and
  degenerate chart domains, extrema/order-preserving sampling, complete CSV,
  narrow scientific axes and coordinate mapping.
- [Input conversion tests](inputs-test.log): exact Int64, typed ranges, choices
  and string validation.
- [Vue/TypeScript and production asset build](frontend-build.log).
- [Common-core package boundary and direct API](core-api.log).
- [Real native application entry](main-entry-native.log), with a lazy unstarted core.
- Both [main](main-native-build.json) and [fixture](fixture-native-build.json)
  builds used `--target native --require-full-native`: 2957 native bodies each,
  full body coverage, VM independence, no runtime bridge and zero fallback.
  [Compact summary](native-summary.json).

Light/dark layouts were checked at 1280, 375 and 320 px without horizontal page
overflow. Final mobile screenshots were visually inspected after the axis fix:

- [Light, 1280 px](runtime-telemetry-light-1280.png)
- [Dark, 1280 px](runtime-telemetry-dark-1280.png)
- [Light, 375 px](runtime-telemetry-light-375.png)
- [Dark, 375 px](runtime-telemetry-dark-375.png)

The offline fixture preview was refreshed at `http://127.0.0.1:3010` with its
existing database and external core retained. The page and both current assets
returned HTTP 200; [preview check](preview.json). This preview uses fixture OAuth.
