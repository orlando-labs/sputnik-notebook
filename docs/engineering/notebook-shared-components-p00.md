# P00: shared sheet and board components

Implemented 2026-10-14. This increment standardizes existing notebook output
before introducing new input families and data tables.

## Component contract

`NotebookComponentTool.all` is the common catalog. Sheet cells adapt their output
to `NotebookCellDisplay`; authored boards place the same displays in their row
grids. Result, Progress and Figure use `NotebookModel.presentation(for:in:)`
and the existing result/progress/figure viewers. The shared snapshot contains
committed results, retained figures, current progress and running/stale state.

- `result`: a controller code-cell binding, with Inspect/Pretty, Find, Copy,
  bounded output, expansion and the same stale/result rules as sheet output.
- `progress`: a controller code-cell binding and an optional `progress_id`.
  An empty ID selects all progress channels of that cell. A missing channel
  leaves a visible waiting slot; its row/span remains authored.
  The designer preselects a source only when one cell has published progress;
  otherwise it requires a cell selection before saving. Progress belongs to
  its publishing cell, including when Run All starts at an earlier settings cell.
- `plot`: the existing Figure binding. It contains only figures; progress is
  an independent component.
- `rich_text`: board-owned text source and portable formatting, rendered by
  the same text-cell view and interpolation engine as sheet text cells.

Sheet output remains contextual to its code cell, including automatic discovery
of its progress. On boards every progress display is explicitly placed in the
grid; there is no aggregate progress strip above the grid or implicit progress
inside a Figure. Existing boards that need progress should add a Progress tile.
The MNIST project generator declares its training progress explicitly.

## Text Cell: Design and Run

In Board Designer, Text Cell edits the original template inline, with the shared
rich-text editor, formatting actions, variable picker and native Undo. Changes
belong to the board draft until **Save Board**. Cancel does not save the template.
Text components participate in row/span/alignment and nested panel layouts;
dragging their header moves them without consuming text-selection gestures.

The inspector selects **Rich text** or **Markdown**. Markdown has a source editor
and variable insertion; Foundation parses block/inline Markdown and the renderer
uses the shared rich-text typography. The initial Markdown presentation supports
headings, paragraphs, lists, emphasis, inline/fenced code, strikethrough and links.
This is not a separate editable HTML/webview output protocol.

Run mode uses a selectable, read-only attributed preview. `{{name}}` resolves
only to published `module_cell` assignments of the controller sheet. Board text
sees the whole controller sheet; sheet text sees its preceding code cells.
Both use the same shadowing, import exclusion, unavailable and conservative
staleness rules, including unsaved code drafts and stale module environments.
There is no expression evaluation. Markdown is parsed **before** interpolation:
published values remain literal text rather than new Markdown or nested tokens.

Opening a board or its designer does not execute code. Explicit Run updates
published values and the rendered text. Rendering never overwrites `{{name}}`
or portable formatting with computed text. Reopening restores the source;
runtime values still require evaluation.

## Manifest

The component kinds extend version 2. Text uses the exact inert text-content
schema and validation used by sheet text cells, including UTF-16 formatting
ranges, Unicode boundaries and supported formatting versions.

```json
{"id":"dashboard","title":"Dashboard","sheet":"main","rows":[
  {"id":"notes"},{"id":"outputs","height":180}
],"components":[
  {"id":"note","kind":"rich_text","title":"Summary","row":"notes","span":12,
   "text_mode":"markdown","text_content":{"source":"# Results\n\nAccuracy: {{accuracy}}"}},
  {"id":"inspection","kind":"result","title":"Result Inspector","cell":"2","row":"outputs","span":8},
  {"id":"training","kind":"progress","title":"Training","cell":"2","progress_id":"training",
   "row":"outputs","span":4}
]}
```

`text_mode` defaults to `richtext`; `text_content` is required for `rich_text`.
A text component owns its source and has no cell/input/binding. Result and
Progress require a cell ID; missing/deleted cell bindings remain visible and
editable. Unknown metadata survives saving. Clearing `progress_id` returns to
all channels rather than restoring a previous selector.

The sheet badge, designer cell picker and variable-source labels use the same
position, including text cells. The picker shows `Cell 04` and the first line
of source. Persistent IDs stay internal: the fourth cell may have the saved
binding `"cell":"5"`. Reordering changes the displayed position without
changing the binding. A deleted target shows `Source cell unavailable`.

The palette scrolls horizontally as the Display category grows. The original
`text` kind continues to mean the existing large Text / Value display.

## Verification

- C++ board tests cover new kinds, geometry, text roundtrip, shared formatting
  validation, invalid modes/bindings/channel IDs and clearing known settings
  while preserving opaque metadata.
- Model tests cover shared name resolution and staleness for sheet/board text.
- Rich-text tests cover Markdown structure/styles and literal interpolation.
- Native board-layout tests run a real controller, render both text formats,
  observe draft staleness and rerun updates, edit/save/reopen source, and capture
  `build/board-layout/components-runtime.png` and `components-designer.png`.

Run `make test-notebook-board-layout` and
`build/notebook_macos_richtext_tests` after building the rich-text test target.
