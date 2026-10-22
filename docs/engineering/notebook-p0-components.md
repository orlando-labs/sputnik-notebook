# P0: inputs, parameter forms, data tables and category accents

Implemented 2026-10-15 on top of the shared P00 components.

## Try it

Open `tools/notebook-macos/Samples/Parameters and Tables.sputnikbook` and select
**Experiment dashboard**. Run the sheet once. Edit Gain, Offset and Device in
the **Parameter Form**, then Apply: the score and table update once, with all
new values together. The Manual snapshot stays stale until its explicit Run.
The Exact integer Stepper demonstrates values near Int64.max.

The sample includes a board text template, a table, a form, a standalone input,
nested Tabs, and an independent stopped Periodic Work service. The audit module
counts evaluations so the sample can verify batch behavior rather than only
checking the final arithmetic value.

## Input family

Input remains one component with a project-input binding. Its inspector selects
Automatic, Number field, Slider, Stepper, Select, Segmented or Radio. Numeric
controls support min/max, step, units and display precision. Boolean Automatic
uses the existing toggle; String Automatic uses a text field. Choice controls
use labeled static String/Integer options.

Typed validation runs before publication. Effective numeric bounds intersect
project bounds and component bounds. Project validation remains authoritative.
Integer Number/Stepper preserves the exact signed Int64 value and rejects
overflow. Integer Sliders are restricted to exactly representable Double ranges;
use Number/Stepper for larger integers. Decimal precision changes presentation,
not the stored value. Creating a project input now exposes optional numeric bounds.

Standalone text fields publish on Apply/Return. A Slider publishes on release;
Stepper, Select, Segmented, Radio and Toggle publish their completed action.
Slider dragging does not trigger one evaluation per pointer movement.

```json
{"id":"gain_control","kind":"input","title":"Gain","input":"gain",
 "row":"controls","span":4,
 "control":{"style":"slider","minimum":0,"maximum":10,"step":0.1,"unit":"×","precision":1}}
```

Options store their scalar as `value_json`, an exact scalar JSON string matching
the project input type. This uses the same exact-value transport as project
inputs; it does not encode Integer choices as JSON doubles in the native editor.

```json
{"style":"select","options":[
  {"label":"CPU","value_json":"\"cpu\""},
  {"label":"MPS","value_json":"\"mps\""}
]}
```

## Parameter Form and atomic Apply

`parameter_form` owns an ordered list of input bindings with their control settings.
The designer adds/removes/reorders fields and configures their controls. Runtime
edits are a private draft. Field validation displays errors next to the field;
Apply is disabled while any field is invalid or a binding is unavailable.
**Reset to current** discards the draft. **Defaults** fills it with saved defaults;
the user still presses Apply. Fixed-height forms scroll inside their authored row.

```json
{"id":"parameters","kind":"parameter_form","title":"Experiment parameters",
 "row":"controls","span":8,"fields":[
  {"input":"epochs","control":{"style":"stepper","step":1}},
  {"input":"device","control":{"style":"select","options":[
    {"label":"CPU","value_json":"\"cpu\""},{"label":"MPS","value_json":"\"mps\""}
  ]}}
]}
```

The native `set_inputs` command takes a map of input IDs to scalar JSON strings.
`ProjectTabs::set_inputs` validates the whole batch into a staged snapshot,
publishes it to every sheet, and sends one changed-key set to each dependency
graph. Rejection retains every previous value and runs no code. Equal values
are quiet. Accepted inputs are not rolled back by a subsequent runtime failure.

Watch consumers run in graph order once per batch. Manual consumers become stale.
An unstarted sheet is never initialized by an edit. Edited code and stale module
environments still require explicit evaluation/Apply. Board saves retain source
and control settings; current parameter values remain session state rather than
becoming saved defaults.

## Inputs in the isolated worker

Ordinary project inputs and atomic Apply now work in worker mode. The host Sync
sends the current immutable inputs with the document snapshot. The worker records
the changed keys and the new `Inputs` command uses the same dependency planner
as the in-process session. This command has ordinary Started/Draining/Result,
live output and Stop behavior. Input edits address only workers already started
by explicit execution; they do not create a runtime or load native dependencies.
Periodic Work continues to snapshot inputs per invocation.

Protocol version is **11**, presentation schema **v10**. Previously running
workers must be retired normally when switching to this build.

## Data Table

The `table` component binds to a controller code cell returning an Array/Tuple
of records, rows or scalar values. Record keys may be strings or symbols;
column names are collected from retained records. Row arrays may be ragged;
missing values become null. Nested values use a bounded text cell rather than
being represented as live runtime objects. A scalar expression or mixed row
shapes do not produce a tabular snapshot.

```sputnik
rows = [{:name: "Alpha", :score: 12, :count: 9223372036854775807},
        {:name: "Beta", :score: 6, :count: null}]
rows
```

Capture occurs directly from the owned result Value before it leaves the runtime,
independently from Inspect/Pretty. The snapshot includes column types, scalar
cells, source row identities, total row count and truncation. It retains at most
4,096 rows, 32 columns and 1 MiB of encoded table data. Individual textual cells
are bounded to 4 KiB during traversal; nested previews also have node/depth limits.
Truncation is explicit. Table state replaces with the committed result, clears
on a failed evaluation, and is not saved into the project.

The shared sheet/board viewer offers numeric-aware column sorting, substring
filtering across columns, row selection/copy, Copy CSV and Save CSV. CSV quotes
commas, quotes and multiline cells. Export covers retained, filtered rows in
the displayed order. Row IDs remain stable while sorting/filtering that snapshot;
they are source positions, not durable record IDs across independently reordered
datasets. Body rows are virtualized. Fixed-height board tables scroll internally.
The sheet Result Inspector offers **View table / View result** using the same view.

## Category colors in Design

The runtime board keeps its usual visual surfaces. The designer uses a small
colored icon, border and leading strip plus a light tint to identify categories.
Category names and icons remain present, so color is supplementary.

| Category | Accent | Light | Dark |
| --- | --- | --- | --- |
| Layout | Muted burgundy | `#7e4054` | `#d6a0b2` |
| Controls | Muted orange | `#87512c` | `#e4b587` |
| Display | Existing Foxglove-family rose | `#86505f` | `#d3a2b0` |
| Services | Muted plum | `#75516d` | `#c9a8c0` |

Main text remains the existing Ink. The additional accents are warm, subdued
tones chosen alongside Night Sky, Foxglove and Lily White. They adapt to the
current theme, including category buttons and the nonvisual service tray.

## Verification

`make test-notebook-p0` verifies input/control/form validation, real atomic Watch
evaluation in both execution modes, rejected/equal batches, unstarted/Manual
behavior, native form editing and Apply, exact Int64, table capture/sort/filter/CSV,
source/settings roundtrip and light/dark native board/designer previews under
`build/p0-components`. Worker transport tests additionally cover structured table
IPC, truncation, distinct long column keys, failure clearing and independent inputs.
Existing board layout, result, rich-text, model and worker tests remain applicable.
