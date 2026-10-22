# Notebook boards: first vertical slice

Boards are a third project entity beside sheets and bundled modules. Their saved
descriptions are inert; services require an explicit Start. The native host
renders rows on a twelve-column grid, with a component palette and object inspector.
isputnik preserves boards and can drive the same inputs without rendering them.

## Try it

```sh
make -j4 notebook-macos
python3 tools/notebook-macos/make-plot-sample.py build/notebook-macos/Interactive.sputnikbook --board
open -a "build/Sputnik Notebook.app" build/notebook-macos/Interactive.sputnikbook
```

The generator requires the local plot checkout and refuses replacement.
An input/value/button example without plot is included at
`tools/notebook-macos/Samples/Inputs.sputnikbook`.
Choose **Boards → Interactive Curve → Run Sheet** once. Changing Gain and
pressing Apply updates the computed value and figure. Caption edits update the
same figure. The Manual snapshot stays stale until its explicit button runs.
Images retain the sheet gallery's lightbox, PNG save and share actions.

The page header identifies the current view with a compact icon badge:
**Board**, **Sheet** or **Module**. Boards and sheets do not reserve content
space for general execution instructions or routine session-status messages.
The board's controller sheet is available in its badge tooltip.

For a new board, use **+** beside Boards and choose its controller sheet.
The Delphi-style designer has a categorized **Component Palette**, a row canvas and
an **Object Inspector**. Palette tabs are **Layout**, **Controls**, **Display**,
**Annotations**, and **Services**. **Annotations** groups Image Annotator and Audio Annotator.
Select a row, choose **Width: n/12**, then click an Input,
Text Cell, Text / Value, Result Inspector, Progress, Figure, Live Chart, Image,
Image Carousel, Tabs or Run Button tile to place it. A row holds up
to twelve column units; palette tiles disable when the chosen width will not fit.
**Add Row** creates more space. The numbered column guides show proportions;
unused columns remain empty.

[P00 shared components](notebook-shared-components-p00.md) unifies sheet and
board Result Inspector, Progress, Figure and Text Cell. Progress on a board is
an explicit row/span component. Text Cell edits its rich-text/Markdown template
in the designer; the running board renders published `{{name}}` references.

**Services → Periodic Work** adds a nonvisual component to the board's service
tray, without consuming row columns. It calls an exported module function and
supports start-to-start / after-completion scheduling, optional result/error
history, tail retention and lifecycle controls. See
[Periodic Work](notebook-periodic-work.md) for settings and execution semantics.

Select a row header to set **Explicit height** in UI points (48–4096), or leave
height automatic. Select a component to edit its span, row, title, bindings,
horizontal alignment (Left / Center / Right / Stretch) and vertical alignment
(Top / Center / Bottom / Stretch). Row arrows reorder rows; component arrows
reorder cells within their row. Drag a component onto another row (including
an empty row or its header) to move it after that row's existing cells. The
target highlights while dragging and the footer shows available capacity;
a row without enough columns rejects the drop. Moving preserves the component's
width, bindings and alignment, and updates the inspector selection.
A fixed row clips content that cannot fit; a
stretched live chart uses the available cell height. Narrow windows scroll
horizontally below the 720-point board width, preserving authored proportions.

**Save Board** persists this structure immediately, independently of unsaved
sheet/module sources. Unknown metadata on surviving board, row and component
IDs is retained by the backend without numeric rounding. Cancel discards the
board draft. Existing ordered grids open as equivalent rows, retaining component
order and distributing their old columns across twelve units; the conversion
is persisted only on Save Board. The designer's canvas previews component
placement; execution and published output remain in the running board.

Input controls can be placed before any project parameters exist. In the
component's Object Inspector, choose an existing **Parameter** or use
**New parameter…** to define and immediately bind a Number, Integer, Boolean or
String value. Range inputs offer two distinct numeric parameters; Date / Time
and File / Dataset inputs offer String parameters. Parameter Forms use the same
picker to add existing or new fields. New controls start without a binding;
**Save Board** becomes available after every required binding is configured,
including controls inside nested panels.

Creating a parameter is a separate explicit structure save, so cancelling the
enclosing board editor does not undo it. Current input values are session state:
Save does not turn them into defaults, and reopening restores defaults.

## Tabs and panel grids

**Tabs** in the **Layout** palette is a layout container placed in a row like any other component. It starts
with two panels. Select it to rename, reorder, add or delete panels in the Object
Inspector. **Edit Grid** opens that panel's own twelve-column grid; use the same
Add Row, palette, height, width, alignment and drag controls as on the outer board.
**Back** returns to the parent grid with the Tabs component selected. Deleting a
panel or its container also deletes its nested layout from the designer draft.
At least one panel must remain.

Each panel owns its `rows` and `components`; row IDs are local to that grid.
Nested Tabs are supported up to eight levels. The board's 256-row and
256-component budgets include every panel, with at most 32 panels per Tabs
component and 128 panels per board. Component IDs are unique across the board.
The container occupies its authored span in the parent grid; all panel column
widths are measured inside that space. In a fixed-height parent row, the active
panel scrolls vertically. Automatic height follows the selected panel's content.

The runtime initially shows the first panel. Clicking a tab selects its grid
without evaluating cells or saving the project. All panels share the board's
controller sheet and project inputs. Tab selection is transient UI state;
reopening starts with the first panel. The console preserves nested layouts.
Unknown metadata on surviving panels, nested rows and components is preserved
when the native designer saves, including exact JSON numbers.

Open `tools/notebook-macos/Samples/Tabs.sputnikbook` for a self-contained example
with Parameters and Snapshot panels. Run Sheet once to publish their values.

A Tabs component uses this shape inside the parent board's `components` array:

```json
{"id":"workspace","kind":"tabs","title":"Workspace","row":"main_row","span":12,
 "panels":[
   {"id":"parameters","title":"Parameters","rows":[{"id":"content"}],
    "components":[{"id":"panel_gain","kind":"input","title":"Gain","input":"gain","row":"content","span":4},
                  {"id":"panel_value","kind":"text","title":"Value","cell":"1","row":"content","span":8}]},
   {"id":"snapshot","title":"Snapshot","rows":[{"id":"content","height":180}],
    "components":[{"id":"panel_run","kind":"run","title":"Refresh","cell":"2","row":"content","span":12}]}
 ]}
```

## Execution contract

```sputnik
gain = notebook.input("gain")
value = gain * 42
p = figure().line([[0, 0], [1, gain], [2, 4 * gain]])
notebook.show(p, caption: "Response")
value
```

- Inputs are shared at project scope. Every sheet has its own runtime; only
  immutable portable scalars cross this boundary, never heap Values.
- `notebook.input(key)` records actual synchronous reads in a run-local closed
  capture. Conditional reads replace the previous dependency set only after a
  successful output transaction. Failed runs retain their last successful
  dependencies and retry conservatively on the next changed input.
- Changing an input invalidates readers and their static downstreams. Watch
  consumers run in graph order; Manual cells and dependents become stale.
  A successful empty capture removes the input edge. Equal publication is quiet.
- Opening, defining inputs or saving boards never starts execution. Changing
  an input does not initialize an unstarted sheet. Edited source and stale
  module environments require explicit evaluation/Apply; input events do not
  silently execute uncompiled drafts.
- A root invocation sees one immutable input snapshot. Detached/resumable or
  foreign-thread execution cannot read that invocation's inputs. Read the
  needed value synchronously before passing it to asynchronous work.
- Values are validated before publication: finite numbers, exact signed Int64,
  Boolean, or UTF-8 strings up to 64 KiB without NUL. Optional numeric bounds
  are enforced. Input errors retain the old value. Runtime failures after an
  accepted edit are shown on the cells; they do not roll the input back.
- Figures bind to the **published display batch** of a cell, not to a borrowed
  plot object. Text binds to that cell's expression result or a named assignment.
  A missing/deleted cell is a visible broken binding, never an implicit rebind.
- Live Charts are board-owned components with a channel ID, axis labels and
  stroke color and optional numeric `x_min` / `x_max` and `y_min` / `y_max` bounds. Code calls
  `notebook.ui.publish_point(channel_id, x, y)`; the board renders the numeric
  stream with the native plot scene renderer at the component's current grid
  size. Live redraws are coalesced to 500 ms; terminal samples flush immediately.
- Buttons explicitly run a controller cell using normal notebook evaluation.
  They are not yet module action handlers. Runtime work uses the host's existing
  serial queue, off the main AppKit thread. Cancellation is not added here.

isputnik's F3 accepts `set-input gain 2.5`, `set-input enabled false`, or
`set-input label "Caption"`. `--project-info` lists boards and input definitions;
`--run-sheet` uses project defaults. This first terminal UI does not render or
edit the board layout.

## Project format

Version 1 projects stay version 1 until an input or board is saved. Version 2
requires `inputs` and `boards` arrays. Existing cells, modules and auto-imports
keep their format and behavior. Sources remain in `project.json` and `.s`
files; runtime values, images and dependency captures are not persisted.

```json
{
  "inputs": [{"id":"gain","title":"Gain","type":"number","default":1.0,"minimum":0,"maximum":10}],
  "boards": [{"id":"dashboard","title":"Dashboard","sheet":"main","columns":2,
    "rows":[{"id":"controls","height":180},{"id":"plots","height":420},{"id":"actions"}],
    "components":[
      {"id":"gain_control","kind":"input","title":"Gain","input":"gain","row":"controls","span":4},
      {"id":"result","kind":"text","title":"Result","cell":"1","binding":"value","row":"controls","span":8,"h_align":"center","v_align":"center"},
      {"id":"figure","kind":"plot","title":"Curve","cell":"1","row":"plots","span":6},
      {"id":"live_curve","kind":"live_chart","title":"Live curve","chart_id":"curve","x_label":"Step","y_label":"Loss","stroke":"#d97706","row":"plots","span":6,"v_align":"stretch"},
      {"id":"refresh","kind":"run","title":"Refresh","cell":"2","row":"actions","span":12}
    ]}]
}
```

This is a fragment of a version 2 manifest, not a complete project. Cell IDs
are decimal strings. Board/row/component IDs are ASCII identifiers. The columns
field (1–6) is retained for legacy grids; explicit rows determine the current
layout. Every visual component in a row board references a row and has a span of 1–12;
the sum in each row must not exceed 12. Missing alignments default to horizontal
stretch and vertical top. Limits are 1024 inputs, 128 boards, and 256 rows /
256 components per board. The bridge sends input values
as JSON **strings containing scalar JSON**, avoiding Int64-to-Double conversion.

## Next increments

1. Named action handlers exported by bundled modules, with explicit invocation
   context and parameter changes; cancellation and status before timers.
2. Periodic Work arguments, exported-function pickers and durable/exportable
   execution history. Scheduling and lifecycle controls are implemented.
3. Placement within a row by dragging. Typed table views, input variants and
   atomic Parameter Forms are implemented in [P0](notebook-p0-components.md).
4. Parameter/default editing/removal, binding pickers, undo for the designer,
   and presentation mode. No arbitrary expressions in the binding format yet.

## Verification

`make test-notebook-macos` includes project/input tests, native model tests and
an isolated board smoke scenario when plot is available. The smoke test
changes Gain, checks the numeric result and a newly rendered PNG, and verifies
that the manifest was not rewritten. Existing VM/kernel tests remain separate.

The **test-notebook-board-layout** make target covers legacy conversion,
capacity checks, row deletion/movement, geometry persistence, extension metadata
and native layout measurements. It writes light/dark designer and runtime
previews under **build/board-layout**.
