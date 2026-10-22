# Components attached to sheet cells

Code cells can own authored **pre-cell** and **post-cell** components. Open
**Components…** in a cell header to edit local parameter definitions, add
components, select their placement, configure their bindings and reorder them.
Save Components persists the interface; Cancel discards the draft. Opening the
editor, changing placement and saving display settings do not execute code.

The first set supports Input, Parameter Form, Live Chart (including saved
multi-series settings), Metric, Image and Data Table. All six may be placed in
either area. Placement describes visual order; post-cell output updates during
execution. Components use the existing controls, viewers, validation and bounded
runtime snapshots. Periodic Work and other independent execution controls are
not available inside cells. Progress remains automatic and is not authored.

Try `tools/notebook-macos/Samples/Cell Components.sputnikbook`. Run the sheet,
change Gain and Offset in the first form, then Apply. The Watch cell updates
its score, chart, image and table. The next cell has its own Gain and publishes
the same chart channel ID without replacing the first cell's chart.

## Local parameters

```sputnik
gain = notebook.cell_input("gain")
score = gain * 10
score
```

`notebook.input("gain")` continues to read a project parameter.
`notebook.cell_input("gain")` reads only the currently executing code cell's
local parameter. The two namespaces are separate. Equal local names in different
cells are independent, and missing values fail explicitly. A local parameter
does not automatically publish a notebook binding. Assigning a read value to a
top-level name publishes that name under the ordinary notebook dependency rules.
Synchronous module calls inherit their calling cell's input capture. Detached
work cannot read inputs after the root invocation or from another thread.

Local edits reuse immutable input snapshots and dynamic read dependencies.
A Parameter Form validates the complete batch before publishing any value.
Equal edits are quiet; Watch readers and their downstreams evaluate in graph
order, while Manual readers stay stale until Run. Unstarted sheets remain
uninitialized. Inputs are disabled during execution. Each invocation sees the
accepted snapshot from its start. Invalid edits and failed computations do not
rewrite saved defaults. Opening the book restores defaults, as with project
inputs. Exact Int64 scalar values use JSON strings at the host boundary.

## Sources and lifetime

A cell component always reads output from its owning cell, optionally selecting
a channel or a published variable. Live Chart and Image never search other
cells for a matching channel. Data Table selects an explicit table ID, or shows
published tables / the typed result table when its ID is empty. Explicit tables
replace automatic rendering of the same channels to avoid duplication; other
published tables keep their automatic rendering.
The result inspector, diagnostics and automatic progress remain available.
A missing channel remains a visible waiting component.

Chart points, images and progress retain their existing live-output semantics;
partial output after Stop is telemetry. Committed results and tables retain
existing successful-result/stale rules. Components and definitions belong to
stable cell IDs, so reordering a cell carries its interface with it. Deleting
and saving a cell removes its authored configuration. Runtime output is not
saved into the manifest.

## Collapsing source

The source-collapse action is offered only when a code cell has at least one
explicit post-cell component, including before it has published any data.
Implicit progress, automatic results and pre-cell components do not qualify.
Collapsing leaves the header, execution controls, parameters, diagnostics and
outputs visible. Removing the final explicit post-cell component expands the
source and removes the action. Adding a component does not collapse code
automatically. Collapse state remains transient UI state.

## Format and transport

Cell interfaces require project schema **4**. Older hosts reject the version
instead of ignoring executable inputs. Books without the feature retain their
existing schema version. `cell_ui` is a validated field on a code cell:

```json
{"id":"1","kind":"code","mode":"watch","source":"notebook.cell_input(\"gain\")",
 "cell_ui":{
   "inputs":[{"id":"gain","title":"Gain","type":"number","default_json":"2"}],
   "pre":[{"id":"gain","kind":"input","title":"Gain","input":"gain"}],
   "post":[{"id":"metric","kind":"metric","title":"Result"}]
 }}
```

The input's `default_json` contains exact scalar JSON. Control settings, fields,
chart/image/table selectors and metric settings reuse the board component
vocabulary. Board geometry, nested panel grids and foreign cell sources are
rejected. Image is currently a display; image loading and readable image inputs
remain board features. Each cell permits at most 128 local inputs and 64
components across both areas. Surviving root, input and component extension
metadata is preserved when editing supported settings.

The common input dependency map uses an internal cell-qualified identity that
cannot be authored as a project-input ID. The VM constructs it from the active
cell identity, so code cannot select another cell's input scope. Worker Sync
carries accepted values through the v4 interface definitions without persisting
them as defaults. Private worker protocol is **15**. Local in-process and
isolated-worker execution share the semantics. The remote UI synchronizes
cell-interface edits with ordinary project revisions.
Accepted cell parameters belong to the server and survive reconnect/agent
restart, independently from saved defaults. Apply uses a versioned, atomic
server transaction; an already-started idle worker receives the existing Inputs
command, so Watch and Manual follow the same rules as local execution. Editing
an unstarted sheet does not create a runtime. Active workers reject parameter
changes. Each Run retains an immutable execution document with its exact values.
The server advertises `cell_inputs`; earlier cores show an update message when
Apply is requested. Project-wide inputs, dependency bundles and Periodic Work
retain their existing remote restrictions.
`tools/notebook-macos/Samples/Remote Cell Components.sputnikbook` demonstrates
the remote flow without external dependencies.

## Verification

Run `make test-notebook-cell-components`. The C++ checks cover v4 validation,
unsupported kinds, scope, exact integers, atomic/rejected/equal edits,
Watch/Manual dependencies, worker Sync, metadata, defaults and moving cells.
Native checks exercise the sample through both execution modes, cell-qualified
chart/image sources, Data Table publication, collapse eligibility/removal,
source collapse through native button activation, and render the interface/editor to
`build/cell-components/`.

Remote coverage: `make test-notebook-remote` includes cell input validation,
Watch/Manual, quiet edits, receipts, conflicts, busy-worker rejection, frozen
snapshots and durable accepted values. `make test-notebook-remote-cell-components`
exercises Components, forms, same-name channel isolation, Image/Data Table,
large integers, lost-response recovery, reattachment and untrusted input tickets
through the native model and a real remote agent/gateway/worker.
