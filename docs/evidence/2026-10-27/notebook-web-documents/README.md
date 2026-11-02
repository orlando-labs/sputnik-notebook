# Notebook web — stage 1: real documents

27 October 2026. Implemented the first vertical slice from authenticated server
project to a persisted, editable Sputnik notebook through the shared core.

## Behavior

- `backend/notebooks.s` authorizes through the web catalog before invoking the
  privileged IPC client. GET reads without provisioning; POST initializes
  idempotently; PUT saves with a durable command ID and exact base revision.
  Browser responses include only `{revision, document}` or null, never private
  core project authority, storage paths or a selectable file map.
- New Notebook creates its catalog record then explicitly initializes the
  document. If the core request fails, the catalog project remains recoverable.
  Existing catalog-only projects show Create Notebook; reads never create files.
- Swift-style sidebar and source cells, sheets (add/rename/select), code/text
  insertion, cell movement/deletion, explicit Save and Cmd/Ctrl+S. Cell IDs use
  canonical uint64 decimal strings and retain precision in JS/JSON.
- Full draft retained after a 409 or failed request. Unchanged uncertain writes
  retry the same command; reload/discard and sign-out/navigation require an
  explicit user decision. Draft JSON can be downloaded after an error/conflict.
- Versions 1–4 retain unknown fields and unsupported authored content. Text
  with formatting is read-only. Bundled modules/resources come from the exact
  base revision and survive source edits. Loading/saving creates no runs.
- Project metadata/access controls remain in collapsible settings, with the
  existing owner/editor/viewer policy. No execution controls were introduced.

Implementation stages and remaining work:
[notebook-web-implementation.md](../../../engineering/notebook-web-implementation.md).

## Checks

Vue/TypeScript and Vite production build passed (20 modules). Node syntax and
whitespace checks passed, along with `git diff --check` for tracked work.

All 16 browser scenarios passed against the real core agent in each supported
configuration, for **64 passing browser tests**:

| Backend | Assets | Result |
| --- | --- | --- |
| VM | Production | [16 passed](browser-vm-production.log) |
| VM | Development + HMR | [16 passed](browser-vm-development.log) |
| Rebuilt native fixture | Production | [16 passed](browser-native-production.log) |
| Rebuilt native fixture | Development + HMR | [16 passed](browser-native-development.log) |

The six new real-core scenarios cover explicit/concurrent initialization,
multiple sheets and cell structure across save/reload, no run on save/load,
competing editors without lost drafts, accepted writes with lost responses,
CSRF/ACL/revocation/invalid documents, version-4 formatting/unknown-field/file
preservation, responsive layout, unsaved navigation and offline load recovery.

Both the real production entry and fixture were rebuilt with
`--target native --require-full-native`. Each compiled 2639 bodies with full
body coverage, VM independence, no runtime bridge and zero fallback. See
[native summary](native-summary.json),
[fixture build](fixture-native-build.json), [production build](main-native-build.json).
The production entry also passed its VM and native startup checks with an
unstarted core, confirming that anonymous startup stays independent of agent
availability; captured output is in [main-entry.log](main-entry.log).

All OAuth exchanges used the offline Alice/Bob fixture. The updated preview at
`http://127.0.0.1:3010` reopens the original catalog database; its existing project
was retained. Production real-GitHub consent and deployment are outside these
local checks.

## Visual review

Light/dark editor states were reviewed after source save, with desktop and
mobile layouts, and no horizontal overflow at 320/375/1280 px:

- [Light desktop](editor-light-1280.png), [dark desktop](editor-dark-1280.png).
- [Light mobile](editor-light-375.png), [dark mobile](editor-dark-375.png).

The source editor deliberately does not claim runtime output, rich-text editing,
board/component rendering or full project import/export. These are the next
stages; existing files and authored metadata are preserved meanwhile.
