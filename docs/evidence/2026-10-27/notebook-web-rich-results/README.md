# Notebook web — rich result presentation

27 October 2026. Added table, plot and image results through the same immutable
presentation codec and drawing vocabulary used by Swift.

## Implementation

- `Client.presentation_bytes` reads an authorized run's terminal/live artifact
  only from its configured run directory, rejecting symlink artifacts and
  applying the shared 128 MiB binary limit. No browser file map, path or download
  authority is added.
- `notebook.core.host.presentation_snapshot` uses the existing validated binary
  codec and exports only inert table/display/image fields. The public rich
  projection is bounded at 32 MiB, and the browser retains at most three run
  details. Invalid/missing/oversized media leaves text/errors available with a
  visible notice. Run/project ACL checks precede each privileged read.
- Implicit array/record results and explicit DataTableView snapshots support
  filtering, stable typed sorting, selected rows, paging and filtered CSV /
  Markdown downloads. Values cross HTTP as kind + text, preserving int64
  precision. Filtering, sorting and downloads use all retained rows, including
  rows beyond the current 100-row page. Empty/truncated schemas stay explicit.
- Named live table displays replace by ID and retain order/captions. A failed
  cell keeps the previous successful figures marked stale; a successful empty
  publication clears them. Source/revision/epoch/history provenance remains
  independent of editor drafts.
- PNG/JPEG displays and image collections have captions, navigation and
  original-byte downloads. Version-1 plot scenes use closed, bounded geometry
  and hexadecimal colors, with zoom, pan, reset, keyboard controls and PNG
  export of the current viewport. Unknown scenes retain raster fallback when
  available; 3D results remain raster previews. Rendering never evaluates
  callbacks, HTML, SVG or external figure URLs.
- The common evaluator's package detection and hybrid namespace resolution now
  include an installed source/bytecode notebook.ui package alongside native
  Stopwatch. It reuses the verified package resolver and existing linker,
  without changing saved documents, adding directory dependencies or granting
  native trust. The durable worker was rebuilt against this shared code.

Package installation/module editing UI, audio, interactive inputs, boards and
service controls remain later slices. Renderers consume already available
project environments. Plain array results and `notebook.images` work without
an imported package.

## Validation

Vue/TypeScript and Vite production build passed (33 modules), as did Node syntax
and whitespace checks. All 28 browser scenarios passed with a real core agent
and worker in each supported configuration, for **112 passing browser tests**:

| Backend | Assets | Result |
| --- | --- | --- |
| VM | Production | [28 passed](browser-vm-production.log) |
| VM | Development + HMR | [28 passed](browser-vm-development.log) |
| Rebuilt full-native fixture | Production | [28 passed](browser-native-production.log) |
| Rebuilt full-native fixture | Development + HMR | [28 passed](browser-native-development.log) |

Five new scenarios cover exact int64/boolean/null/text values, stable sorting,
escaping/filtering/selection, CSV/Markdown downloads, paging and export beyond
the visible page; live DataTableView replacement, failure retention and clear;
real plot scenes, zoom/pan/reset and PNG export; raster collections/downloads,
read-only sharing/revocation and malformed/symlinked artifact fallback. The
previous 23 document/execution/catalog/library scenarios remain green.

The package fixture installs the canonical DataTableView class source in a
disposable project's package home. The installer produces a bytecode package,
so its live publication exercises the corrected shared package path alongside
native Stopwatch. A separate scenario also runs native Stopwatch with no helper
package installed. The fixture excludes audio helpers, which are outside this
slice. Plot tests use the real bundled plot source and worker renderer.

The rebuilt production entry and fixture each compiled 2760 bodies with
`--target native --require-full-native`, full body coverage, VM independence,
no runtime bridge and zero fallback. See [native summary](native-summary.json),
[production report](main-native-build.json) and
[fixture report](fixture-native-build.json). Real entry startup passed with an
unstarted core in [VM](main-entry-vm.log) and [native](main-entry-native.log).

The shared engine passed [direct API/package boundary checks](core-api.log)
and [worker-host checks](worker-host.log). The final shared evaluator/worker
rebuild is recorded in [worker build](worker-build.log).

The preview at `http://127.0.0.1:3010` was restarted against the existing catalog
and independent agent. Browser login under Bob confirmed the retained single
catalog project, current SSR/assets, raster CSP and no JavaScript errors,
without provisioning/editing a notebook. See [preview check](preview-check.json).
All OAuth checks use the offline Alice/Bob fixture; real GitHub consent and
production deployment remain outside these local checks.

## Visual review

Reviewed both themes and narrow/desktop layouts. Browser scenarios assert no
horizontal page overflow at 320/375/1280 px; wide tables scroll internally.

| Result | Light desktop | Dark desktop | Light mobile | Dark mobile |
| --- | --- | --- | --- | --- |
| Table | [1280](table-light-1280.png) | [1280](table-dark-1280.png) | [375](table-light-375.png) | [375](table-dark-375.png) |
| Plot | [1280](plot-light-1280.png) | [1280](plot-dark-1280.png) | [375](plot-light-375.png) | [375](plot-dark-375.png) |
| Images | [1280](images-light-1280.png) | [1280](images-dark-1280.png) | [375](images-light-375.png) | [375](images-dark-375.png) |

See [the implementation plan](../../../engineering/notebook-web-implementation.md)
for the subsequent source/transfer and interactive notebook stages.
