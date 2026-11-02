# Notebook web — authored cell displays

28 October 2026. Implemented the next presentation slice against Swift's
`NotebookCellComponents`, `NotebookP1DisplayViews` and shared native validator.

## Behavior

- Cell Components authors and renders Metric, Live Chart, Table and Image
  alongside Input and Parameter Form, before/after code and in authored order.
  Definitions/settings join the normal local draft. Cancel discards inspector
  changes; Update Draft and Save do not execute code or apply parameters.
- Metric reads a declared numeric module-cell variable or the successful scalar
  result. Int64 display stays exact. Unit, precision, percentage, target, baseline
  and improvement settings match the native vocabulary. Half-even formatting was
  checked against Swift Foundation for 0.125, 0.375, 1.005 and -0.125. Large
  whole-valued Float settings remain Float JSON; opaque authored Int64 tokens
  keep their exact values.
- Live Chart supports channel selection, title/caption, labels, colors,
  automatic/one-sided/fixed bounds and up to 16 configured series. The local
  legend and manually chosen viewport survive live updates. CSV includes all
  retained samples of all configured series, including hidden ones; PNG uses
  the current plot view. Reopening/reconnecting does not replay Run.
- Table selects a named published table. An empty binding shows published
  tables, falling back to the implicit result when none are published. Image
  selects a channel and supports fit/fill/auto-height, caption and optional save.
  Claimed sources are excluded from automatic output; unclaimed sources remain
  visible. Explicit duplicate authored references are kept as authored.
- Missing/nonnumeric bindings and empty channels have explicit unavailable or
  waiting states. Failed/invalidated and historical results retain stale labels.
  Post-cell components enable local source collapse; outputs and diagnostics
  remain visible. Collapsing does not save, apply values or start work.
- Unsupported Audio stays visible as unavailable with its saved settings retained.

## Public data boundary

The additive `notebook.core.host.presentation_bound_snapshot` uses the same
validated binary presentation codec and 32 MiB JSON budget. The backend obtains
cell/name pairs exclusively from Metric components in the run's immutable
execution document. Only matching initialized numeric `module_cell` values
leave the host, as exact text; nonnumeric values are null and unknown names are
unavailable. General locals, watch bindings, VM values and source locations are
excluded. The existing unbound presentation API remains available.

Authored settings cannot retroactively publish an undeclared value from an old
run. Saving a new binding leaves it unavailable until an explicit saved Run.
Current project/run ACLs apply to every read; revocation clears cached displayed
values. Rendering, legend changes, source collapse and exports do not execute code.

## Verification

All 50 scenarios passed in each configuration: **200 full-suite passes**.

| Backend | Assets | Result |
| --- | --- | --- |
| VM | Production | [50 passed](browser-vm-production.log) |
| VM | Development + HMR | [50 passed](browser-vm-development.log) |
| Full native | Production | [50 passed](browser-native-production.log) |
| Full native | Development + HMR | [50 passed](browser-native-development.log) |

The five new scenarios cover numeric/private/missing bindings, exact Int64,
settings validation and cancel/save, unknown component/settings metadata, a
large Float target, named/wildcard/implicit tables, image save controls,
unclaimed channels, multi-series live updates/legend/CSV, reload without replay,
source collapse, failed/history results, frozen binding changes and reader ACLs.
The pre-existing image download/figure tests also pass with default save enabled.

- [Display unit tests](displays-unit.log): formatting, exact tokens, large Float
  serialization, source ownership, bounds and extension preservation.
- [Telemetry tests](telemetry-test.log) and [input conversion tests](inputs-test.log).
- [Vue/TypeScript and Vite build](frontend-build.log).
- [Shared core package boundary/direct API](core-api.log).
- Real application startup: [VM](main-entry-vm.log), [native](main-entry-native.log).
- Both [main](main-native-build.json) and [fixture](fixture-native-build.json)
  use `--target native --require-full-native`: **2964 native bodies each**, full
  body coverage, VM independence, no runtime bridge and zero fallback.
  [Compact summary](native-summary.json).

Components and settings were checked at 1280, 375 and 320 px in light/dark themes,
including horizontal overflow checks and visual inspection of screenshots:

| View | Light | Dark |
| --- | --- | --- |
| Cell, desktop | [1280 px](cell-displays-light-1280.png) | [1280 px](cell-displays-dark-1280.png) |
| Cell, mobile | [375 px](cell-displays-light-375.png) | [375 px](cell-displays-dark-375.png) |
| Settings, desktop | [1280 px](cell-display-settings-light-1280.png) | [1280 px](cell-display-settings-dark-1280.png) |
| Settings, mobile | [375 px](cell-display-settings-light-375.png) | [375 px](cell-display-settings-dark-375.png) |

The fixture preview at `http://127.0.0.1:3010` was refreshed with its database and
external core preserved. Page and both current assets returned HTTP 200:
[preview check](preview.json). It continues to use offline fixture OAuth.

Next in the [plan](../../../engineering/notebook-web-implementation.md): render
existing boards using the common components and input controls. Audio, media
input, board authoring/actions/services and remaining palette features are later
slices.
