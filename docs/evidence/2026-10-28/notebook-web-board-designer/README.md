# Notebook web — Board Designer

28 October 2026. Board authoring follows the Swift palette/canvas/Object
Inspector structure and uses the same document fields and existing web display
and parameter inspectors. See the [implementation plan](../../../engineering/notebook-web-implementation.md).

## Behavior

- New board, Design…, Duplicate and Delete edit the notebook draft. The designer
  owns a lossless copy; Cancel discards that copy. Update notebook draft, including
  Cmd/Ctrl+S inside the modal, returns changes without a server mutation. Normal
  Save then uses the existing revision/CAS and durable command-receipt contract.
- Palette categories/search insert supported controls, displays and containers.
  The inspector authors controller/source bindings, component titles, widths and
  alignment, parameter controls and shared display settings. Rows have automatic
  or fixed heights. Groups, tabs and splits support nested editing, breadcrumbs,
  panel titles, tab ordering and split settings.
- Rows/cards/panels support reordering and deletion. Card duplication assigns new
  structural IDs recursively and remaps known internal component references.
  Cards move between rows by real mouse drag or an accessible row selector;
  rejected structural edits leave the draft intact.
- Undo/Redo retains at most 100 snapshots within 16 MiB total UTF-8 history;
  adjacent text edits coalesce within 500 ms. Local validation checks the native
  limits: twelve columns, 256 components/rows, 128 total panels, 32 panels per
  container and eight nesting levels. Row heights are 48–4096 points.
- Preview disables Run, Apply and Open Sheet. Opening/editing/duplicating a board
  never creates execution, parameter or scheduling commands. Designer drafts
  participate in the existing unsaved-navigation guard. Current write access and
  execution availability gate commits; revocation preserves the local draft
  while disabling updates. A Save conflict preserves committed notebook edits.
- Legacy layout conversion happens on the designer copy. Cancel leaves the
  stored legacy document unchanged. Unknown row/panel/component/document fields
  and exact Int64 values survive editing, nested duplication, Save and reload.
  Inspecting absent optional control settings does not insert defaults.

The palette is intentionally limited to implemented web behavior. Saved audio,
actions, periodic services, managed media, shared selections and other unavailable
components retain their settings. Existing services remain in the separate tray;
their specialized editing/execution controls are a later slice. Formatted text
source remains read-only; new plain text can be authored. This slice does not
claim full Swift palette parity.

## Verification

All 61 browser scenarios passed in each configuration: **244 full-suite passes**.

| Backend | Assets | Result |
| --- | --- | --- |
| VM | Production | [61 passed](browser-vm-production.log) |
| VM | Development + HMR | [61 passed](browser-vm-development.log) |
| Full native | Production | [61 passed](browser-native-production.log) |
| Full native | Development + HMR | [61 passed](browser-native-development.log) |

Final visual inspection corrected generic dialog CSS overriding the desktop
width and overlapping canvas/inspector tracks on narrow screens. The final
VM/development full suite includes those fixes. The five designer scenarios also
passed again on [VM/production](designer-vm-production-final.log),
[native/production](designer-native-production-final.log) and
[native/development](designer-native-development-final.log): **15 additional
passes**. Assertions cover the wide desktop dialog, absence of page/modal
horizontal overflow and nonoverlapping stacked inspector bounds at 375/320 px.

The five new scenarios use the real core for inert creation/preview/cancellation,
explicit Save/Run, legacy and opaque metadata, Int64 retention, real mouse drag,
nested duplication/ID remapping, Undo/Redo, tabs/splits/parameter authoring, viewer
access and revocation, concurrent revision conflicts, modal shortcuts, lost
accepted Save responses and board duplicate/delete lifecycle.

The [initial VM/development full run](browser-vm-development-initial.log) had two
failures in existing OAuth/login scenarios (a 403 during sign-in and an incomplete
callback); all five designer scenarios passed. The complete repeated run above
passed 61/61, including those two tests. No authentication behavior or timeouts
were changed; the intermittent cause was not established.

- [Editor unit tests](editor-unit.log): capacity/atomic moves, nested identities
  and metadata, exact integers, native limits and bounded history.
- Existing [board](boards-unit.log), [display](displays-unit.log),
  [input](inputs-unit.log) and [telemetry](telemetry-unit.log) checks pass.
- [Vue/TypeScript and production build](frontend-build.log).
- Real application entry startup: [VM](main-entry-vm.log),
  [full native](main-entry-native.log).
- This is a frontend-only slice. Native main/fixture binaries from the preceding
  slice were reused, without a new native build. Their
  [recorded build summary](../notebook-web-board-view/native-summary.json)
  confirms 2972 native bodies each, full coverage, VM independence and no
  bridge/fallback. Current native browser and real-entry checks use those binaries.
- [Source/build-manifest hashes](source-sha256.json); modified-source whitespace
  was checked explicitly, including new untracked files.

Both themes and desktop/mobile screenshots were visually inspected. Narrow
designer rows retain their twelve-column blueprint with local horizontal scroll;
canvas and inspector stack in the modal's scrolling body.

| Layout | Light | Dark |
| --- | --- | --- |
| Desktop | [1280 px](board-designer-light-1280.png) | [1280 px](board-designer-dark-1280.png) |
| Mobile | [375 px](board-designer-light-375.png) | [375 px](board-designer-dark-375.png) |

The preview at `http://127.0.0.1:3010` was refreshed. The page and current JS/CSS
assets return HTTP 200; its database and external core socket were retained:
[preview check](preview.json). Preview uses the offline OAuth fixture.
