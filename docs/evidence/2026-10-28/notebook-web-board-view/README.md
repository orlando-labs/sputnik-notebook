# Notebook web — existing board viewing

28 October 2026. This slice opens existing boards and reuses the implemented
cell presentation/input controls. Board authoring and the remaining palette
features continue in the [implementation plan](../../../engineering/notebook-web-implementation.md).

## Behavior

- Boards appear in notebook navigation. Selecting one reads its controller
  sheet's registry, accepted project parameters and run snapshots. Open Sheet
  returns to that controller. Browsing never changes the saved active sheet,
  document revision, runtime inputs or schedule.
- Native twelve-column rows/spans, fixed/automatic heights and alignment are
  rendered with nested groups, tabs and horizontal/vertical split panels.
  Legacy columns are normalized for display only. Narrow grids stack cards;
  split ratios honor minimum panel size or stack when it cannot fit. Group
  expansion, panel selection and divider ratio remain local view state.
- Metric, Table, Result, Progress, Plot and Log resolve controller source cells.
  Chart/image channels are selected only within the controller sheet, following
  reverse authored cell order for duplicate channel names. Stopwatches resolve
  their declared channel. Missing sources and channels have visible states.
  Tables, plots and images retain the existing inspection/export controls.
- Board Input/Range/Parameter Form uses project parameter definitions and the
  existing explicit versioned Apply transaction. Cold Apply remains inert;
  initialized Watch/Manual follows core semantics. Hidden panels keep unapplied
  drafts. Leaving a board guards those drafts; merely switching its tabs/groups
  does not discard them. Viewer controls are read-only.
- Run Sheet and source-cell Run buttons explicitly use the existing Run/Run All
  protocol. Live data, terminal results, historical runs and reconnect reuse the
  same bounded snapshots without automatic replay. Reader revocation clears
  runtime values/channels from an open board.

## Public data and execution boundaries

`backend/results.s` recursively collects Metric cell/name bindings from boards
belonging to the run's controller sheet, including hidden nested panels. It
uses that run's immutable execution document and the existing numeric-only
`presentation_bound_snapshot`, not current browser configuration or arbitrary
queries. Newly authored bindings cannot reveal undeclared values from old runs.
The shared 32 MiB public snapshot limit and project/run ACLs remain in force;
private paths, runtime IDs, VM values and general locals stay excluded.

Controller presentation and Stop/Restart controls accept only sheet Run/Run All,
Inputs and Watch records. A separate Action/Service invocation world cannot
replace the controller's board or sheet result, even when it shares the
controller label or finishes later. Its history entry explicitly marks the
unavailable invocation view until the corresponding UI is implemented.

## Explicit remaining limitations

The board designer, Action/Execution Controls, periodic-service controls, audio,
managed media assets/editing, shared selections, presets/date/media inputs,
formatted/markdown text rendering and variable text bindings are later slices.
They retain saved settings and visible unavailable notices. Saved rich-text
source is displayed as escaped plain text. Services have a separate visible
tray; opening it never starts or changes a schedule. This is not full palette
parity with Swift.

## Verification

All 56 browser scenarios passed in each configuration: **224 full-suite passes**.

| Backend | Assets | Result |
| --- | --- | --- |
| VM | Production | [56 passed](browser-vm-production.log) |
| VM | Development + HMR | [56 passed](browser-vm-development.log) |
| Full native | Production | [56 passed](browser-native-production.log) |
| Full native | Development + HMR | [56 passed](browser-native-development.log) |

The six new scenarios use the real core to check inert board browsing and saved
document/extension preservation; legacy columns and fixed modern rows; nested
tabs/groups/splits and keyboard tabs; cold/Watch Apply and guarded/hidden drafts;
live charts/images/progress/stopwatch and reload without replay; controller
isolation and frozen numeric bindings; reader exports and revocation; and a real
isolated Action invocation that cannot replace sheet results. The final
New Sheet navigation adjustment also passed in the later full VM/development and
native/production runs and a dedicated [VM/production check](navigation-final-vm.log).

- [Board unit tests](boards-unit.log): inert legacy normalization, exact source
  IDs, reverse source order, channel/controller isolation and stale provenance.
- Existing [display](displays-test.log), [input](inputs-test.log) and
  [telemetry](telemetry-test.log) unit checks remain green.
- [Vue/TypeScript and production Vite build](frontend-build.log).
- [Shared core package/direct API](core-api.log).
- Real entry startup: [VM](main-entry-vm.log), [native](main-entry-native.log).
- Both [main](main-native-build.json) and [fixture](fixture-native-build.json)
  builds require `--target native --require-full-native`: **2972 native bodies
  each**, full body coverage, VM independence, no runtime bridge and zero fallback.
  [Compact build summary](native-summary.json).

Layouts were checked in light/dark themes at 1280, 375 and 320 px with no
horizontal page overflow. Final layout and result screenshots were visually
inspected; saved images cover desktop and mobile widths:

| View | Light | Dark |
| --- | --- | --- |
| Layout, desktop | [1280 px](board-layout-light-1280.png) | [1280 px](board-layout-dark-1280.png) |
| Layout, mobile | [375 px](board-layout-light-375.png) | [375 px](board-layout-dark-375.png) |
| Results, desktop | [1280 px](board-results-light-1280.png) | [1280 px](board-results-dark-1280.png) |
| Results, mobile | [375 px](board-results-light-375.png) | [375 px](board-results-dark-375.png) |

The offline fixture preview at `http://127.0.0.1:3010` was refreshed with its
existing database and external core retained. The page and both current assets
returned HTTP 200: [preview check](preview.json). It uses fixture OAuth.
