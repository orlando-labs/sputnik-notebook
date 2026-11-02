# Notebook web — project and cell parameters

27 October 2026. Added an actual read/write/runtime path for project inputs,
cell-local parameters and pre/post-cell Input / Parameter Form controls, with
the Swift palette, controls and execution semantics.

## Implementation

- `backend/inputs.s` authorizes current read/execute capabilities before scoped
  accepted-state reads, explicit Apply or receipt reads. Browser scope is either
  project parameters or one code cell; private project/runtime IDs, full core
  records, service state and server paths are excluded. Accepted responses expose
  a version and verified Inputs run IDs only. Registry/run DTOs retain the input
  version used by immutable execution snapshots.
- Apply forwards exact scalar JSON strings to the existing `project.inputs.set`
  and `cell.inputs.set` transactions. The shared worker owns validation of types,
  bounds, authored control constraints, JSON/YAML/TOML config syntax and batches.
  Accepted values, all Inputs runs and the command receipt commit atomically.
  No evaluator, input store, new worker grant or scheduler is added by the web.
- Cold Apply never creates a runtime. Initialized Watch consumers recompute;
  Manual consumers become stale and their downstreams report the shared core's
  blocked-dependency diagnostics until explicit Run. Busy/interrupted workers,
  stale revisions and stale accepted-state versions reject updates without
  modifying accepted values. Equal changes remain quiet.
- Project Inputs and cell Components edit authored definitions/defaults in the
  ordinary notebook draft. Save remains explicit and inert. Schema upgrades
  preserve native required fields, local interfaces use v4, and unknown metadata
  in definitions/interfaces/components/options/displays survives supported edits.
  New Input/Parameter Form controls support pre/post placement and ordering.
  Other authored display settings remain intact for their next rendering slice.
- Decimal/Int64, boolean, text, slider, exact stepper, select/segmented/radio,
  integer/decimal ranges with shared/separate slider domains and config text
  controls use the same serialized vocabulary as Swift. Numeric editing preserves
  Int64 and the distinction between integer and decimal Range endpoints. All web
  controls apply explicitly. Accepted values never overwrite saved defaults.
- Form drafts survive invalid/conflicting requests. Reset to current resolves a
  stale base; Defaults stages saved defaults. Unapplied values guard navigation,
  reload and view changes. Uncertain commands persist per account/project in
  session storage; read-only receipt polling/focus recovery resolves acceptance,
  while only explicit Retry repeats the exact ID/revision/base/values. Competing
  execution controls are disabled while an input command is uncertain.
- Apply is limited to 128 values / 8 MiB; scoped previews to 8 MiB and the visible
  browser parameter cache to 32 MiB. Project definition panels page in groups
  of 128. Viewer controls remain read-only and current revocation is enforced.

## Verification

All **42 browser scenarios passed in each configuration — 168 full-suite passes**:

| Backend | Assets | Result |
| --- | --- | --- |
| VM | Production | [42 passed](browser-vm-production.log) |
| VM | Development + HMR | [42 passed](browser-vm-development.log) |
| Full native | Production | [42 passed](browser-native-production.log) |
| Full native | Development + HMR | [42 passed](browser-native-development.log) |

Seven new scenarios cover atomic project/local Apply, cold state, actual
Watch/Manual execution and scope isolation; invalid/conflicting/revoked updates;
inert definition/control authoring; accepted/unaccepted response loss, reload
and exact retry; busy workers and frozen input versions; all value types,
range sliders, config validation and extension metadata; navigation guards and
responsive light/dark layouts at 1280, 375 and 320 px. The final
[VM input suite](inputs-final.log) also checks integer/decimal slider endpoints
with the final frontend. Previous 35 execution/source/transfer/result/catalog
scenarios remain passing.

[Exact-value unit checks](input-values.log) exercise Int64 boundaries/stepping,
integer and decimal Range round trips, choice and string validation, and numeric
token preservation. [Vue/TypeScript and Vite](frontend-build.log) passed, as did
Node syntax and explicit whitespace checks (including untracked sources).

Both production entry and fixture compiled **2957 bodies** with
`--target native --require-full-native`, full body coverage, VM independence,
no runtime bridge and zero fallback: [summary](native-summary.json),
[production](main-native-build.json), [fixture](fixture-native-build.json).
Real entry startup passed in [VM](main-entry-vm.log) and
[native](main-entry-native.log) with a lazy, unstarted core.

Actual [light desktop](notebook-inputs-light-1280.png),
[dark mobile](notebook-inputs-dark-375.png) and
[mobile designer](notebook-input-designer-dark-375.png) screenshots verify the
native palette, card spacing, control layout and bounded dialogs. Unsupported
display components are not advertised as rendered controls.

## Preview

The existing catalog and independent agent remain in place. Only the HTTP
preview was updated at http://127.0.0.1:3010. Validation used disposable projects
and agents; no user project, runtime grant or background schedule was changed.
