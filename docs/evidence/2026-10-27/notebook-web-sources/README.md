# Notebook web — sources, packages and transfer

27 October 2026. Stage 3 adds the actual source bundle and project transfer to
the Swift-style web workspace, through the existing shared core.

## Behavior

- Modules & Files browses exact saved revision members. Modules support source
  editing, creation, deletion and auto-imported exports. UTF-8 up to 1 MiB is
  editable; larger text has a 64 KiB preview and binary resources retain their
  original bytes. Uploads accept relative member names up to 16 MiB each.
- A Save command commits the document and file changes as one immutable revision
  using the exact base and existing CAS/receipt rules. Revision manifests retain
  hidden authored files. Conflicts keep both cell and file drafts, which can be
  downloaded separately as JSON or a complete draft ZIP. Oversized integer
  tokens in inputs/unknown metadata survive supported document edits exactly.
- Export saved and Revisions export an exact immutable bundle, wrapped as a ZIP
  containing `Notebook.sputnikbook/project.json` and its members. Draft export
  does not persist a server revision. No in-place history rollback is added.
- Import accepts a ZIP or explicit browser folder selection. Inspection uses
  the same staged validation and worker format checker as project.put; it
  creates no catalog project/revision and evaluates no code. A separate explicit
  action imports a copy. Durable account/command mappings and core receipts let
  an uncertain import resume without duplicate projects. Catalog projects with
  pending imports cannot be overwritten by empty initialization.
- The native libarchive adapter validates ZIPs in memory without extraction:
  links, unsafe/duplicate/case-colliding paths, file/parent conflicts, encryption,
  invalid UTF-8 and oversized bundles are rejected. Limits are 2048 data files,
  64 MiB total data, 7 MiB document and 80 MiB ZIP transport. Canonical Base64 is
  validated before SDK decoding, including padding/unused bits, in both adapters.
- Dependencies shows registry releases/build compatibility, installed packages
  and durable operations. Readers inspect; only owners install/remove. The web
  API accepts canonical package names and fixed options, with no browser-selected
  server paths or registries. Native installation/builds default off and require
  the server operator's `--allow-native-packages`. Worker runtime grants do not
  change. Existing core gates protect active runs and retire affected workers.
- File/history/archive/package/receipt endpoints authorize the current account
  and project before privileged core calls. Revoked readers cannot download
  previous revisions. Public DTOs omit core IDs, server paths and installation
  logs. Installed server packages/prepared environments are independent of the
  exported source archive. Python/Ruby preparation UI remains a later slice.

## Validation

The [production frontend build](frontend-build.log) passed Vue/TypeScript and
Vite checks. The full browser suite includes 35 scenarios. Seven new scenarios
cover source/binary persistence and actual module execution; conflict/draft and
historical exports; ZIP/folder/int64/hidden-member preservation and concurrent
idempotent import; unsafe archives and current ACL; registry install/remove with
accepted-response loss; import recovery across reload; file-save identity and
light/dark responsive layouts at 1280, 375 and 320 px.

| Backend | Assets | Result |
| --- | --- | --- |
| VM | Production | [35 passed](browser-vm-production.log) |
| VM | Development + HMR | [35 passed](browser-vm-development.log) |
| Full native | Production | [35 passed](browser-native-production.log) |
| Full native | Development + HMR | [35 passed](browser-native-development.log) |

**140 browser tests passed** across the four configurations. The final
[file/transfer suite](sources-vm-final.log) also passed with canonical transport
validation and simultaneous replay of an import command.

Both production and fixture compiled **2929 bodies** with
`--target native --require-full-native`: full body coverage, VM independence,
no runtime bridge and zero fallback. See [native summary](native-summary.json),
[production report](main-native-build.json) and [fixture report](fixture-native-build.json).
Real production entry startup passed in [VM](main-entry-vm.log) and
[native](main-entry-native.log). The [independent lifetime check](execution-lifecycle.log)
reattaches after HTTP restart and requires explicit recovery after worker crash.

Focused checks passed for [ZIP/UTF-8/transport codec](bundle-codec.log),
[atomic source merge and async preview](source-service.log),
[ZIP/folder identity and exact document](transfer-service.log),
[core API/package boundary](core-api.log), and [worker host](worker-host.log).
The catalog passed identity/ACL/concurrency/migration checks in
[VM](models-vm.log) and [full native](models-native.log).

The package scenario uses a disposable loopback registry serving an actual
`.sputnikpkg` produced by the SDK. It installs and removes the package through
the web UI, without requiring internet access or granting local-path authority.
Screenshots cover the actual module editor, import and dependency dialogs.

## Preview

The existing local catalog is retained at `apps/notebook-web/build/smoke-74948.sqlite`
and preview remains at http://127.0.0.1:3010. Its independent agent uses
`/private/tmp/sputnik-web-preview-74948`; normal HTTP restarts preserve its work.
No publication, background GC, new worker grants or user-project changes were
performed for validation.
