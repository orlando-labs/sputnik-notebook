# Notebook web — portable rich text

28 October 2026. Text cells and board Text now share a source-selection editor
and formatted preview for the native portable rich-text versions 1/2. This is
the first text/editor slice from gap-review item 4; see the
[implementation plan](../../../engineering/notebook-web-implementation.md).

## Behavior

- Select source text for Bold, Italic, Underline, Inline code or Clear. Paragraph
  styles provide Body and Heading 1–3; bullet/numbered lists retain native text
  markers and paragraph metadata. Enter continues a list, and numbered lists
  renumber after edits.
- The Table menu inserts a 2 × 2 table, adds/removes rows or columns, removes a
  table and continues after it. Tab/Shift+Tab moves among cell ranges. Retained
  cell text and inline styles survive structural operations, including insertion
  before another table.
- Source edits remap checked UTF-16 ranges. Unicode scalars cannot be split.
  Deleting a table cell terminator or joining prose across its boundary is
  rejected without changing the document, with a visible explanation. Complete
  table selections and structural commands can remove it.
- The preview uses literal text nodes, checked styles, paragraph elements and
  rectangular table cells. It does not insert HTML or execute code. Preview
  mode alone does not normalize source/formatting. Readers get rendered text;
  unsupported formatting remains preserved and read-only with a notice.
- Undo/Redo is per editor, bounded to 100 snapshots / 16 MiB total history;
  typing coalesces within 500 ms. Keyboard formatting and Undo shortcuts work
  without consuming normal notebook Save. IME composition keeps the in-progress
  buffer local and commits only when composition ends. Clipboard input is text.
- Sheet edits and board inspector edits use the existing draft/Save/CAS/receipt
  lifecycle. Cancel drops only the board designer copy. Exact unknown source
  metadata survives Save/reload. Current ACLs still authorize persistence; lost
  Save responses retry the same command, while a conflict retains the draft.

The editor follows the Swift portable document shape and palette/toolbar styling;
its source-selection editing surface is not a native WYSIWYG text view.
Published-variable interpolation, Markdown rendering, syntax highlighting and
diagnostics remain subsequent slices. `{{name}}` remains literal with an explicit
preview notice; Markdown boards keep their source view. No runtime-variable
projection changed here.

Additional browser work bounds are visible: formatted preview at 256 Ki UTF-16
units / 4000 lines, then bounded source preview; at most 500 changed list items
per operation. The full source remains intact and editable within normal
document limits. Native table limits remain twelve columns, 240 cells and 100
tables. Formatting validates at the native limit of 20000 runs/paragraphs; inline
rendering/formatting uses ordered traversal rather than repeated full scans.

## Verification

All 75 browser scenarios passed in each configuration: **300 full-suite passes**.

| Backend | Assets | Result |
| --- | --- | --- |
| VM | Production | [75 passed](browser-vm-production.log) |
| VM | Development + HMR | [75 passed](browser-vm-development.log) |
| Full native | Production | [75 passed](browser-native-production.log) |
| Full native | Development + HMR | [75 passed](browser-native-development.log) |

After final adjacent-table, range-validation, large-run traversal and list-indent
adjustments, all seven text scenarios passed again in all four modes:
[VM/production](rich-text-vm-production-final.log),
[VM/development](rich-text-vm-development-final.log),
[native/production](rich-text-native-production-final.log),
[native/development](rich-text-native-development-final.log): **28 additional
passes**. A separate single-process [visual capture](visual-final.log) passed too,
avoiding concurrent screenshot writes/capture artifacts.

The seven new scenarios use the real core for the native Swift sample's
headings/lists/tables; inline authoring and Save/reload; emoji offsets and literal
HTML; local Undo/Redo; list and table structure, protected boundaries and adjacent
tables; board authoring/cancellation and metadata; viewers/revocation; lost Save
receipts and concurrent revisions; list Enter/numbering, composition buffering
and bounded large previews. Every new workflow asserts an empty execution
registry, including after Save and preview.

- [Rich-text unit tests](rich-text-unit.log) cover both codecs, the Swift sample,
  Unicode, source diff/remapping, list and table transformations, unsupported
  schemas, adjacent tables and rendering/formatting at 20000 runs.
- [Editor](editor-unit.log), [board](boards-unit.log), [display](displays-unit.log),
  [input](inputs-unit.log) and [telemetry](telemetry-unit.log) checks pass.
- [Vue/TypeScript and production build](frontend-build.log).
- Real entry startup: [VM](main-entry-vm.log), [full native](main-entry-native.log).
- This frontend-only slice reuses the preceding native main/fixture binaries.
  Their SHA-256 hashes match the previous build exactly:
  [native reuse check](native-reuse.json). The
  [original build evidence](../notebook-web-board-actions/native-summary.json)
  records 3018 native bodies each, full coverage, VM independence and no
  bridge/fallback. No new native build is claimed.
- [Final source/build-manifest hashes](source-sha256.json). New/untracked files
  received an explicit whitespace check.

Screenshots were visually inspected in both themes. Browser checks cover no
horizontal page overflow at 1280, 375 and 320 px.

| Preview | Light | Dark |
| --- | --- | --- |
| Desktop | [1280 px](rich-text-light-1280.png) | [1280 px](rich-text-dark-1280.png) |
| Mobile | [375 px](rich-text-light-375.png) | [375 px](rich-text-dark-375.png) |

The preview at `http://127.0.0.1:3010` was refreshed. Its page and current JS/CSS
assets return HTTP 200, with the existing database and external core socket
retained: [preview check](preview.json). It uses fixture OAuth.
