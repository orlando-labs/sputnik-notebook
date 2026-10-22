# P1 components and Parameter Presets

Implemented 2026-10-15. Parameter Presets moves from P2 into this P1 set.
The shared catalog now has 23 components; Multi-series remains an option of
Live Chart. Existing category accents apply to every new component.

## Try it

Open `tools/notebook-macos/Samples/Workstation.sputnikbook`, select
**Experiment console**, and Run Sheet. Choose Fast trial in Parameter Presets,
review the changes, and Apply preset. The Watch metric updates; Manual outputs
wait for explicit Run. Calibrate calls a saved exported module function with a
snapshot of the accepted Gain, Offset and Label parameters. It owns a separate
runtime, so its module state and result do not replace the sheet's values.

## Components

| Component | Authored settings and runtime behavior |
| --- | --- |
| Metric / KPI | Numeric cell result or published variable; unit, percentage, decimal places, optional target and delta baseline, higher/lower improvement direction; stale and update time. Automatic integer display preserves Int64 spelling. Arithmetic formatting/deltas use finite Double values. |
| Status / Alert | Sheet, cell, Periodic Work or Action target; state and reason, source navigation. Reports running/draining/stopping from the existing execution phase, failure and stale state from committed results. |
| Log Viewer | Committed stdout/stderr and diagnostics for a cell; stream filter, substring search, source file/line when available, copy and save. Event ordering is retained. It shows up to 4,096 events and bounds individual display text; captured transport limits still apply. This version displays committed output, not a new streaming log protocol. |
| File / Dataset Input | Binds to a String project input. Choose or drop one external file; optional extension filter; size, bounded text and CSV/JSON summary. Publishes the absolute file path using the existing input pipeline. File contents are not copied into the project. Opening/reopening never reads a file in the VM or starts execution. |
| Action Button | Saved module and exported function, ordered positional/named scalar arguments from accepted inputs or exact scalar JSON constants. Explicit invocation, busy/result/error and cancellation through Execution Controls. No overlapping invocations. |
| Execution Controls | Explicit sheet/cell/service/action target; Run, service Start/Pause, and capability-based Stop/Force Stop/Restart. Force Stop confirms discarding that worker. Stop only addresses the matching active target. In-process execution does not promise interruptibility. |
| Group / Accordion | One titled, nested panel grid using the same layout, limits and inspector as Tabs. Authored initial collapsed state; expansion is transient and never executes code. |
| Multi-series Live Chart | Up to 16 named channel bindings and colors, one domain, legend visibility, persistent viewer viewport, PNG export including visible series names/colors. Each channel retains the existing independent history limit. Native paints coalesce to 2 Hz and flush on completion. |
| Artifact Browser | A cell returns records containing `path`, optional `name` and `caption`. The bounded typed table snapshot is the file manifest; it is never parsed from Inspect. Relative paths resolve in the project directory. Shows metadata, text preview, Reveal and Save copy, with unavailable-file and stale states. It lists at most 128 retained records. Files are not automatically persisted or scanned. |
| Parameter Presets | Named saved parameter sets scoped to selected inputs or all inputs. Capture current, rename, delete, import/export JSON, compare and Apply. All scalar types and bounds validate before one atomic publication. Save preserves project defaults. Capturing/importing/choosing a preset does not execute code. |

## Portable settings

P1 settings live in the optional `component.p1` object. Hosts preserve extension
fields on known component kinds; new kinds require a P1-capable host. Settings
contain authored configuration only, never live
results, logs, selected tabs, chart points or expanded/collapsed runtime state.

```json
{"kind":"parameter_presets","id":"presets","title":"Presets","row":"r","span":6,
 "p1":{"preset_inputs":["epochs","device"],"presets":[
   {"id":"fast","title":"Fast","values":{"epochs":"2","device":"\"cpu\""}}
 ]}}
```

Preset `values` map input names to scalar JSON **strings**, matching P0's exact
transport. Import/export uses an array of preset objects, up to 128 sets and a
1 MiB import file. Imported sets receive fresh internal identities; incompatible
parameters reject the entire import. The running board explicitly saves a
capture/rename/delete/import into the project. Current parameter values remain
session state; the saved defaults remain separate. Applying a preset uses the
same `set_inputs` transaction as Parameter Form: Watch consumers update once,
Manual consumers become stale, and unstarted sheets do not initialize.

```json
{"kind":"action","id":"calibrate","title":"Calibrate","row":"r","span":6,
 "module_id":"experiments","function":"calibrate",
 "p1":{"arguments":[
   {"id":"a","input":"gain"},
   {"id":"b","name":"label","value_json":"\"Trial\""}
 ]}}
```

Arguments have exactly one input binding or scalar constant. Constants never
enter executable source: the host stages them in an immutable invocation input
snapshot and the synthetic cell reads those exact scalars through notebook.input.
Module/function/keyword names validate before evaluation. Runtime export/signature
checking remains authoritative. Modified module tabs must be saved first. Explicit
Run applies saved module changes and follows existing native-dependency trust.
The worker sees the same frozen inputs; Stop/Force Stop use its existing lifetime
protocol. Private worker protocol version is 14 so a worker that cannot parse
P1 document kinds is rejected at the handshake. The remote-core transport does not yet support these invocations and
rejects them explicitly rather than falling back to local execution.

Group owns exactly one `panels` entry. Nesting and total board limits are shared
with Tabs. Live Chart's `p1.series` lists `{id,title,stroke}`; the channel ID is the
series identity and points continue to use publish_point/channel transport.

## File contracts

File Input is an external-reference first version. Paths may become unavailable
on another computer; saved presets containing paths have the same limitation.
Code explicitly reads the accepted path (for example with fs.read_text). Preview
reads at most 64 KiB, shows at most 16,000 characters, and handles quoted CSV,
embedded newlines and CRLF. JSON summaries are produced only for complete files
within that bound. File selection validates the extension and regular-file type.

Artifact Browser uses an explicit committed result manifest, for example:

```sputnik
[{:path: "/tmp/experiment/report.csv", :name: "Validation report", :caption: "Run output"}]
```

The manifest is replaced on a new committed result and clears on evaluation
failure with Data Table. Files themselves retain their existing filesystem
lifetime; the browser labels project/external files and missing files. Preview
and export occur only after a user action. No automatic artifact directory scan,
copy into the document, remote upload or retention policy is implied. File Input
and Artifact Browser explicitly report unavailable transfer in remote mode; they
do not interpret remote paths as local files.

## Designer

Search matches component title, purpose and category across the full palette;
category navigation and horizontal scrolling remain. New components inherit
category accents, labels and icons. Undo/Redo restores board draft snapshots,
coalescing typing changes. Duplicate copies a component and nested grids with
fresh identities; Save still validates total layout limits. Saving/cancelling
retains the same document semantics as P00/P0.

## Verification

`make test-notebook-p1` covers validation/roundtrip, exact preset values, default
preservation and reopen, exported Action invocation/state through both the
in-process C bridge and isolated GUI worker, worker cancellation, bounded file preview, artifact manifests, CSV quoting,
metric formatting, shared-domain chart scenes and PNG export with a legend. Native UI checks capture and apply a named preset through real field editing and mouse events. Native board/designer previews
are written to `build/p1-components` in both themes. P0, board layout, model,
result, worker, rich-text and theme checks remain regression suites.
