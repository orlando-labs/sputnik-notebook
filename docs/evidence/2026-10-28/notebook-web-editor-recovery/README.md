# Notebook web — Stage 4f.3

28 October 2026, macOS arm64. Existing unrelated working-tree changes are kept.
This slice changes the web editor; the Core evaluator, policy enforcement and
server storage format are reused. No deployment was performed.

## Behavior

- Sheets duplicate, move and delete through the ordinary draft. Copies retain
  formatting, unknown fields and exact Int64 values, with fresh sheet/cell/local
  component IDs and remapped component targets. Delete keeps at least one sheet
  and explicitly selects a replacement controller for linked boards. Existing
  component bindings and immutable history are retained for review.
- Rename or move stages both member changes with the notebook in one CAS Save.
  Binary resources retain exact bytes. Module metadata, package declaration,
  auto-imports and board action/service references follow a renamed module.
  Imports in other code and resource-path strings need manual updates. Invalid
  relative paths, module extensions, case/path-prefix/name collisions and occupied
  draft destinations are rejected. Filename maps have no prototype properties.
- Review saved changes uses the lossless document codec for a three-way merge.
  Independent fields/ID-keyed collections combine. Concurrent fields, delete/edit
  and ordering conflicts require local/saved choices; source and formatting are
  selected together for overlapping cross-editor edits. File digests identify
  overlapping member changes; either complete version can be downloaded for
  inspection. Previews show at most 4000 characters. Cancel keeps the original
  draft; Apply changes only the draft/base, and explicit Save still checks CAS.
  Core validates domain constraints on Save; incompatible metadata/binding choices
  can still require manual adjustment. Merge work caps at 512 document conflicts
  and 100000 visited nodes, with full draft export available on bounded fallback.
- A per-tab IndexedDB journal records staged document/file edits, original base
  document/revision, selected view and uncertain Save command. Copies use account
  and project scope, expire after 30 days, and are limited to 16 per project and
  96 MiB each. Invalid/expired copies are removed when their scope is read.
  The UI distinguishes an in-progress checkpoint from a confirmed local copy.
- Restore is explicit, rechecks the current session account and project write
  access, and uses the original base revision. A stale base opens the ordinary
  conflict path. Restoration and page load do not dispatch Save or Run. A
  recovered copy is removed only after a successful checkpoint; another tab's
  newer record is preserved. Sign-out and navigation retain their draft guards.
- An uncertain Save retries the original ID/payload even after newer document
  edits or reload. Its accepted revision is acknowledged without overwriting
  newer edits; those need another Save. Bundled-file mutation waits for the
  uncertain command to resolve. Storage-unavailable/quota failures retain normal
  explicit Save and export. Open modal drafts and unapplied runtime parameters
  are outside this staged source journal.

## Verification

| Configuration | Result |
| --- | --- |
| VM, production assets, complete browser suite | [98 passed](browser-vm-production.log) |
| VM, final production assets, editor/document/source checks | [22 passed](browser-final-focused-vm-production.log) |
| Native backend, final production assets | [9 passed](browser-native-production.log) |
| Native backend, Vite development | [9 passed](browser-native-development.log) |
| VM backend, Vite development | [9 passed](browser-vm-development.log) |

The complete suite passed before the final current-account restore check and
immediate checkpoint-status refinement. The final 22 focused checks cover those
changes plus all existing notebook Save/ACL/CAS, file, import and package checks;
the final 9-scenario matrix repeats the new slice across all four configurations.
The full suite includes the resource quota/public 60-second preview scenarios.
Core/native backend sources were not changed in this slice, so their prior
[resource-policy](../notebook-web-resources/README.md) and
[text-projection](../notebook-web-text-features/README.md) evidence remains separate.

The nine new real-Core browser scenarios cover:

1. Duplicate/reorder/delete, fresh identities, linked board replacement,
   formatting/exact metadata, inert edits and 1280/375/320 light/dark layouts.
2. Module rename/package/auto-imports, binary resource move, byte identity and
   rejected traversal/case destinations.
3. Independent concurrent changes, explicit rebase and another server race.
4. Overlapping source/file choices, cancel, version downloads and mobile dialogs.
5. Source/binary recovery after reload against a changed server base.
6. Accepted Save response loss, reload, exact command replay, retained newer
   edits and no duplicate revision.
7. Independent tab journals and isolation from other project scopes.
8. Same-origin account isolation, viewer/revoked access, and explicit Save when
   IndexedDB is unavailable.
9. Account switching in another tab, current role downgrade, kept local copy and
   successful restore after edit access returns.

[Build/type checking](frontend-build.log) passed. Pure-code checks also passed:
[editor/merge/journal](editor-recovery-unit.log), [rich text](rich_text-unit.log),
[board editor](board_editor-unit.log), [boards](boards-unit.log),
[displays](displays-unit.log), [inputs](inputs-unit.log),
[telemetry](telemetry-unit.log), [text/syntax/Markdown](text_features-unit.log).
The new pure-code checks include exact integers, delete/order conflicts,
formatting/source coupling, prototype keys, expiry/account/project validation,
unsafe recovery paths and a valid full 16 MiB binary edit. `git diff --check` and
source whitespace checks passed.

## Visual checks

Inspected the existing palette, line/editor spacing, native controls and dialog
layout in light/dark at desktop and phone widths. Automated overflow assertions
also cover 320 px. Screenshots:

- [Sheet operations, desktop](editor-operations-light-1280.png)
- [Sheet operations, dark phone](editor-operations-dark-375.png)
- [Save comparison, desktop light](save-conflict-light-1280.png)
- [Save comparison, desktop dark](save-conflict-dark-1280.png)
- [Save comparison, phone light](save-conflict-light-375.png)
- [Save comparison, phone dark](save-conflict-dark-375.png)
- [Local recovery and uncertain Save](draft-recovery-light-1280.png)
- [Module rename/move](move-module-light-1280.png)

## Reproduction

From `apps/notebook-web/frontend`, run `npm run build`, then:

```sh
PLAYWRIGHT_BROWSERS_PATH=/private/tmp/notebook-policy-browsers npm run test:browser
PLAYWRIGHT_BROWSERS_PATH=/private/tmp/notebook-policy-browsers npm run test:browser -- test/editor-recovery.spec.ts test/notebook.spec.ts test/sources-transfer.spec.ts
ORBIT_E2E_NATIVE=1 PLAYWRIGHT_BROWSERS_PATH=/private/tmp/notebook-policy-browsers npm run test:browser -- test/editor-recovery.spec.ts
ORBIT_E2E_MODE=development PLAYWRIGHT_BROWSERS_PATH=/private/tmp/notebook-policy-browsers npm run test:browser -- test/editor-recovery.spec.ts
ORBIT_E2E_NATIVE=1 ORBIT_E2E_MODE=development PLAYWRIGHT_BROWSERS_PATH=/private/tmp/notebook-policy-browsers npm run test:browser -- test/editor-recovery.spec.ts
node ../tools/editor_recovery_test.mjs
```

The browser harness uses disposable loopback OAuth/catalog/Core services. Native
fixture binaries must already be built as described in the app README. These
checks do not establish anonymous-public deployment readiness or Linux coverage.
Final source, fixture and asset hashes are in [source-sha256.json](source-sha256.json).
