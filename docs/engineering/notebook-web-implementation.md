# Notebook web: staged implementation

27 October 2026. The web adapter reuses `notebook-core` and the macOS visual
language; it does not implement another evaluator or notebook storage format.

## Stage 1 — document workspace (implemented)

The server catalog retains its own account/project ACL and private core project
mapping. `backend/notebooks.s` authorizes every read/write before using
`notebook.core.client.Client`. The browser receives only document JSON and a
revision, never core authority, storage directories or a selectable file map.

- GET `/api/projects/:id/notebook` is inert and returns null for a catalog-only
  project. POST initializes explicitly and idempotently, without replacing a
  head. New Notebook in the UI creates the catalog project and then initializes
  the document; if initialization fails, the project can be reopened/retried.
- PUT accepts a command ID, exact base revision and authored document string.
  Core validates the normal project format, persists an immutable revision and
  applies its compare-and-swap/receipt rules. Bundled files are copied from the
  exact base via `revision.get`; the browser cannot replace the resource map.
- The Vue workspace has a Swift-style sidebar, sheet creation/rename/navigation,
  code/plain-text source cells, cell insertion/reordering/deletion and explicit
  Save / Cmd-Ctrl-S. Random canonical uint64 decimal cell IDs avoid reuse after
  deletion and stay strings throughout JS/JSON; numeric conversion never loses
  their precision.
- A conflicting save keeps the entire local draft. Reload asks before discarding
  it; JSON download offers a source-only backup. An unchanged retry after an
  uncertain network outcome retains its command ID. Unsaved navigation/sign-out
  also asks before discarding. Stage 4f.3 adds the local recovery journal and
  reviewable three-way merge described below.
- Documents in versions 1–4 retain unknown fields, boards, inputs, settings and
  bundled modules/resources. Formatted text was initially read-only; a compatible
  formatting editor was added in Stage 4f.1. This stage did not render rich components or
  execute cells. The core registry remains empty after load/save-only workflows.
- Project metadata/access are separate collapsible settings. Catalog title and
  update timestamp remain catalog fields, distinct from notebook title/revision.

There is no distributed transaction across the catalog database and core.
Explicit, replayable initialization keeps partial creation recoverable. The
production agent has a separate lifetime from the web server. Test tooling
starts its own real agent and uses disposable catalogs, with optional explicit
DB/core paths for reopening a preview. No cleanup job is added or enabled.

Validation and screenshots are in
[the stage evidence](../evidence/2026-10-27/notebook-web-documents/README.md).

## Stage 2 — explicit execution and reconnect (implemented for text results)

`backend/execution.s` exposes explicit Run / Run All / Stop / Force Stop and
runtime restart through the existing core API. Every operation authorizes the
current web account/project; run reads, Stop and receipts additionally verify
the trusted core run-to-project association. Only whitelisted public run,
worker and cell-result fields cross the boundary. Private project/runtime IDs,
worker PIDs, execution documents, presentation paths, service records and global
event counters stay server-side. Owner/editor can execute; viewer can observe.
Polling updates execution capability when membership changes during a session.

The Swift-style compact toolbar and per-cell play actions execute the exact
saved revision, with Shift+Enter for the focused code cell. Unsaved or outdated
documents cannot launch a new run. Results render escaped values, stdout/stderr,
cell errors, task failures and a compact history; earlier output retains source,
revision and epoch provenance and is marked when stale. Stop is cooperative;
Force Stop and Restart Worker are explicit destructive runtime actions. Core
owns busy-sheet checks, cancellation, epoch validation and restart gates.

The browser polls public registry/result DTOs (500 ms active, 2 s idle), pauses
when hidden and reattaches on focus/reload. It never starts work on load/save or
automatically repeats a mutation. An uncertain request retains its exact command
in per-account/project session storage. GET receipts resolve accepted commands;
an explicit retry preserves ID, payload and revision. Closing the page or
restarting the independent HTTP process leaves accepted work with the agent.
Recent history is limited to 100 runs plus all active runs.

Real-core checks cover successful and failed runs, live output, cooperative and
forced cancellation, preparation cancellation, task failure, worker crash,
explicit restart, stale epochs, current ACL/revocation, accepted-response loss,
unaccepted-command retry, browser reload/closure and independent web restart.
See [stage evidence](../evidence/2026-10-27/notebook-web-execution/README.md).

## Stage 2b — rich result presentation (implemented)

The web adapter decodes terminal/live artifacts with the existing native
presentation codec through `notebook.core.host.presentation_snapshot`; there is
no second binary decoder or runtime in the browser. Current ACL and trusted run
ownership precede every artifact read. The local client confines reads to the
configured run directory and rejects symlink artifacts. The rich DTO whitelists
table, PNG/JPEG, plot-scene and image-collection fields and stays within 32 MiB;
the browser retains at most three run-detail snapshots. Invalid/missing media
leaves text/errors visible with a notice.

Typed table values cross JSON as kind + text, preserving int64 precision. The
UI supports stable numeric sorting, filtering, row selection, paging over all
retained rows and filtered CSV/Markdown export. Empty/truncated schemas retain
their status. Published DataTableView captions/order/IDs and live replacements
come from core; failed runs retain previous successful figures marked stale.

PNG/JPEG and live collections have captions, navigation and byte-preserving
downloads. Version-1 plot scenes use the Swift closed geometry/color vocabulary
with zoom, pan, reset, keyboard controls and current-view PNG export. Unknown
scenes fall back to an available raster; 3D output stays raster. Neither scene
rendering nor table/image interaction starts work or fetches external URLs.

The common evaluator resolves an installed source/bytecode notebook.ui package
before treating this hybrid namespace as native-only. Helpers share the existing
namespace merge alongside native Stopwatch. The durable worker uses its
validated project package home and requires no saved
document changes, directory dependencies or new grants. Web package management
is still a later slice; existing environments and bundled modules are reused.

Audio presentation/export was added in Stage 4g.1. Interactive inputs, boards and service controls
were added in the following stages below.
Validation and screenshots are in
[the rich-result evidence](../evidence/2026-10-27/notebook-web-rich-results/README.md).

## Stage 3 — project sources, packages and transfer (implemented)

The sidebar opens revision-bound bundled files, creates/deletes modules and
controls auto-imported exports. UTF-8 sources up to 1 MiB are editable; larger
text has a bounded preview and binary files have byte-preserving downloads.
Explicit uploads accept relative member paths and up to 16 MiB per file.
Save merges file changes into the exact base revision and commits cells,
metadata and the complete bundle with the existing CAS/receipt contract.
Untouched members, including hidden authored files, are retained through a
revision manifest. Conflicts preserve every local edit. Saved exports and
separate draft exports are available, as is source-only offline JSON recovery.
The document parser keeps oversized integer tokens exact in authored inputs
and unknown metadata when supported fields are edited.

Desktop `.sputnikbook` documents are directories. Web export wraps one such
directory in `Title.sputnikbook.zip`; browser import accepts a ZIP or an explicit
folder selection. The shared native libarchive adapter validates members in
memory, without archive extraction, rejecting links, unsafe/duplicate/colliding
paths and oversized bundles (2048 files, 64 MiB data, 7 MiB project JSON;
80 MiB ZIP transport). Inspection calls the same staging/worker validation as
project.put, without creating a catalog project, persisting a revision or
executing code. Import is a separate explicit action that creates a copy.
A durable account/command mapping and core receipt reconcile lost responses;
reselecting the original bundle resumes pending imports without duplicates.
Pending imports block unrelated empty initialization of their catalog project.
Revision history is paged and exports an exact immutable revision; importing
an old export creates a separate project. No in-place rollback is introduced.

Dependency inspection is available to readers; registry installation/removal is
owner-only. The browser sends canonical package names, versions and selected
builds, never local server paths or arbitrary registry URLs. Public status strips
server directories and logs. Operations use durable receipts with explicit exact
retry and existing core active-run/worker-retirement gates. Native installation
and builds default off, enabled only through the operator's
`--allow-native-packages` flag. Runtime grants remain unchanged. Python/Ruby
manifest files can be edited, while their environment preparation UI is a later
slice. Installed server packages remain part of the server environment and are
not silently copied into a source bundle export.

All file, history, export, package and receipt endpoints check the current
project ACL before calling core. Revoked readers cannot fetch prior revisions
or bytes. See [stage evidence](../evidence/2026-10-27/notebook-web-sources/README.md).

## Stage 4a — project/cell parameters and control authoring (implemented)

`backend/inputs.s` scopes accepted-state reads to project parameters or one
code cell and exposes explicit versioned Apply and receipt reads. Each operation
checks the current web ACL: readers inspect, owner/editor can apply. The adapter
forwards the exact scalar JSON strings to `project.inputs.set` / `cell.inputs.set`;
it does not introduce a second input store, validator or scheduler. Batches are
limited to 128 fields / 8 MiB, scoped previews to 8 MiB, and the visible browser
cache to 32 MiB. A command receipt exposes only its accepted version and verified
Inputs run IDs, never the complete private state, runtime IDs or server paths.
The registry and run DTO retain accepted-state version provenance.

Project Inputs and per-cell Components edit a local authored draft. Project
definitions use the native `default` field; cell definitions keep exact
`default_json` strings. Schema upgrades add the required native fields and cell
interfaces use v4. Saving definitions/defaults never applies runtime values or
starts a worker. Unknown definition, interface, component, option and display
metadata survives editing supported settings. The current slice authors Input
and Parameter Form components before or after code; saved display components
remain intact for their later rendering slice.

The forms implement decimal numbers, exact Int64, text, booleans, menus,
segmented/radio choices, sliders, steppers, ranges with shared/separate slider
domains and JSON/YAML/TOML config text. Apply is an explicit whole-form action.
The shared worker checks types, bounds, all authored control constraints and
config syntax before acceptance. Accepted values remain separate from saved
defaults. Uninitialized sheets stay inert; initialized Watch consumers recompute
and Manual consumers become stale, including the core's downstream dependency
diagnostics. A cell header can author Manual/Watch mode through the normal save.

Draft values survive rejected/conflicting commands; stale forms require Reset to
current before applying again. Unapplied drafts guard reload/navigation and view
changes. An uncertain command stays in per-account/project session storage;
receipt polling/focus reconnect can resolve it, while only an explicit retry
resends the exact command, revision, base version and values. Pending parameter
commands disable competing execution actions. Applying requires a saved, current
document and appropriate idle runtimes. Revocation removes read/mutation access.

See [parameter-stage evidence](../evidence/2026-10-27/notebook-web-inputs/README.md).

## Stage 4a.1 — presentation gaps (implemented)

The shared presentation adapter now projects progress, named stopwatches, cell
timing and live chart channels alongside figures, within the existing 32 MiB
public snapshot limit. Floating-point coordinates/progress use round-trip JSON;
milliseconds and total sample counts use exact decimal strings. No worker state,
source locals or server artifact paths are added to the public DTO.

The browser displays actual runtime snapshots during live updates, reconnect
and history. A running attempt's measurements remain current while its result
is dirty; invalidated measurements in finished snapshots remain stale. Stop
preserves a partial count. Live charts preserve a manually chosen viewport,
bound drawing geometry while retaining extrema, and export all retained points
through CSV. Unsupported authored cell displays show a visible preserved-settings
notice instead of disappearing. Inputs/Watch runs have explicit history labels.
The remaining authored display bindings/inspectors are still Stage 4b.
See [verification and screenshots](../evidence/2026-10-27/notebook-web-presentation-gaps/README.md).

## Stage 4b — authored cell displays (implemented)

Cell Components now authors and renders Metric, Live Chart, Table and Image
alongside Input/Parameter Form, with pre/post placement and ordering. Settings
join the ordinary inert document draft, preserve unknown fields, and use the
same native component vocabulary and validator. The inspector supports metric
unit/precision/percentage/target/baseline/improvement; chart channels, labels,
colors, fixed/automatic bounds and up to 16 series; named/wildcard tables; image
channels, fit/fill/auto-height, captions and save controls. Large whole-valued
Float settings retain Float serialization while authored Int64 tokens stay exact.

The common host's new `presentation_bound_snapshot` projects only numeric
module-cell values requested by Metric bindings in that run's immutable execution
document. It keeps values as text, returns null for nonnumeric/uninitialized
bindings, and exposes no general locals dictionary. The prior presentation API
remains available. Web authorization and the shared snapshot budget still apply.
Adding a new binding requires an explicit saved Run before a new value is public.

The renderer resolves named sources, missing bindings and stale/history states;
claims matching automatic tables/channels without hiding unclaimed output; and
keeps a manually selected chart viewport/legend state during live updates.
Multi-series CSV retains all configured samples. Post-cell components enable
local source collapse without changing the document, applying inputs or running
code; errors and outputs remain visible. Audio was added in Stage 4g.1.
See [verification and screenshots](../evidence/2026-10-28/notebook-web-cell-displays/README.md).

## Stage 4c — existing board viewing (implemented)

Boards appear in the sidebar and select their controller sheet for execution and
input reads, without changing saved active-sheet metadata. The renderer shares
cell display/parameter/table/plot/image components and supports native rows,
spans, heights/alignment, legacy columns, nested groups/tabs/splits and responsive
stacking. Local group/tab/split state never saves or executes. Hidden panels keep
parameter drafts; leaving the board uses the existing unapplied-value guard.

Metric/Table/Result/Progress/Plot/Log and explicit Run components refer to source
cells; live chart/image channels resolve only inside the controller sheet.
Stopwatch channels, plain source text, project Input/Range/Parameter Form and
explicit Run Sheet use existing runtime contracts. Numeric bindings in nested
boards join only that run's immutable declared binding projection. Historical
runs cannot publish newly added board bindings. Current ACLs apply to every read
and Apply/Run operation; readers retain inspection/exports only.

Sheet presentation and Stop/Restart controls select only sheet Run/Run All,
Inputs and Watch records. Isolated Action/Periodic runs may appear in the
registry, but cannot replace controller results or acquire its controls. Their
The independent invocation view was added in Stage 4e below.

Services stay in a separate visible tray; controls were added in Stage 4e, and
browsing never starts a schedule. Unsupported media inputs/assets/selections and
other palette items retain explicit notices. Portable rich-text rendering was
added in Stage 4f.1; Markdown remains source with a notice and variable text
bindings are not exposed.
See [verification and screenshots](../evidence/2026-10-28/notebook-web-board-view/README.md).

## Stage 4d — board authoring (implemented)

New board, Design…, Duplicate and Delete work on notebook drafts. The Swift-style
designer has a category/search palette, twelve-column canvas, Object Inspector,
nested-panel navigation and inert preview. It authors existing supported display,
parameter, explicit Run and layout components using the shared settings controls.
Rows/cards/panels can be reordered, duplicated or removed; cards move between rows
by mouse drag or the inspector. Nested copies receive fresh structural identities
and remap known internal component references while retaining opaque metadata.

Local validation enforces native row/span/height, panel/depth and binding limits;
core validation remains authoritative on Save. Unsupported settings, formatted
text and exact integers are retained losslessly. Merely opening/cancelling does
not normalize the saved source. Undo/Redo is bounded to 100 snapshots / 16 MiB;
text edits coalesce within 500 ms. Designer changes participate in the unsaved
navigation guard, current ACL checks and explicit Save/CAS/receipt recovery.
Cmd/Ctrl+S inside the modal updates only the notebook draft. It never dispatches
Run, Apply, service configuration or package installation.

See [verification and screenshots](../evidence/2026-10-28/notebook-web-board-designer/README.md).

## Stage 4e — actions/services (implemented)

Action Button and Periodic Work invoke authored module functions through core
invocation worlds, with immutable accepted arguments/inputs and independent
worker state. Public target IDs connect registry records to board components;
private runtime owners stay internal. Execution Controls target sheets, cells,
actions or services. Invocation output and history can be inspected without
replacing controller results. Stop/Force Stop and epoch-checked Restart address
the actual owner; an enabled service must be paused before Restart.

Periodic Start/Once/Pause/Clear are explicit durable commands. Scheduling, overlap
skipping, retention, error policy and restart recovery belong to the independent
agent. Browser visibility does not configure schedules. The designer authors
native module/function, arguments, targets and schedule settings inertly.
The shared browser journal checks lost replies by receipt and never replays
mutations automatically. Current execution ACLs, source revisions and CSRF are
checked on every mutation; revocation clears open invocation/history data.

Public service history is paged at 50 entries with 4096-character previews and
exact string IDs/counters. Scheduler diagnostics are allowlisted, and runtime
paths/owners/config payloads stay internal. Registry windows retain active runs
and latest invocations/services for the selected board; rich output shares the
existing bounded result cache.

See [verification and screenshots](../evidence/2026-10-28/notebook-web-board-actions/README.md).

## Stage 4f.1 — portable rich text (implemented)

Text cells and board Text share a source-selection formatting editor and inert
preview using native portable formatting versions 1/2. Bold/italic/underline,
inline code, paragraph headings, bullet/numbered lists and rectangular tables
retain checked UTF-16 ranges. Preview emits literal text nodes and structural
elements, with no HTML parser or code execution. Unknown formatting falls back
to preserved source and disables edits. Preview mode alone does not rewrite data.

Source replacements remap inline and structural ranges. Table terminators and
cross-boundary edits are protected; structural commands insert/remove/resize
tables while preserving retained cell styles. List Enter/renumbering, keyboard
formatting shortcuts, per-editor bounded Undo/Redo and IME composition are
supported. Editing is a normal notebook/board draft: Save/CAS/receipt recovery,
current ACLs and exact unknown metadata retain existing semantics.

Native limits remain authoritative. Additional browser work bounds are explicit:
formatted preview at 256 Ki UTF-16 units / 4000 lines, source-preview truncation,
and list transformations at 500 changed items per edit. Complete source is kept.
No execution or runtime-variable projection changed in this frontend-only slice.

See [verification and screenshots](../evidence/2026-10-28/notebook-web-rich-text/README.md).

## Stage 4f.2 — variable text, Markdown, Sputnik syntax and diagnostics (implemented)

Text cells and board prose interpolate `{{name}}` from published module-cell
values in the immutable run document. Text cells see preceding providers; board
prose uses the controller sheet; explicit Published Text selects one source cell.
Later/uninitialized providers shadow earlier values. Failed/dirty predecessors,
source/revision/worker/environment changes and historical runs mark values stale.
Unavailable/stale values are visible, and exact Int64/string text stays literal.
The Variable picker inserts authored placeholders through the ordinary Undo/draft
contract. New names require Save and an explicit Run. No expression evaluation
or browser-selected locals query exists.

The shared codec's new `presentation_text_snapshot` accepts frozen prose, derives
requested provider/name pairs in authored order and emits a bounded projection.
The browser never supplies those queries to a public endpoint. Limits are 256
names/provider values, 4096 Unicode scalars per value and 1 MiB text; exceeding
the aggregate limit discards all text values with a notice, preserving correct
shadowing. Repeated placeholders reuse already processed provider/name pairs.

Board Text authors native `richtext`/`markdown` modes. A pinned Markdown parser
with HTML disabled feeds a closed Vue node renderer: headings, emphasis, lists,
quotes, tables, explicit links and code fences. Images render alt text without
fetches. Parsing/Sputnik fence styling precede literal substitution, so values
cannot add Markdown or HTML structure. Portable formatting is preserved and
remapped on source edits, including the existing protected table semantics.
Designer preview is inert and uses unavailable placeholders until a saved Run.

Code cells, Sputnik modules and temporary previews share a lossless lexical
overlay, line numbers and a textarea retaining native selection/Undo/IME. The
native lexical vocabulary includes Unicode, callable hashes/comments, tagged
strings, interpolation, template controls, macro splices and contextual keywords.
Coloring never changes source or evaluates it. Large/dense source falls back to
plain editing at 256 Ki UTF-16 units / 4000 lines / 20000 tokens.

Worker diagnostics retain up to 100 messages per cell, each at 4096 Unicode
scalars, and validated zero-based scalar line/column ranges. The editor converts
to UTF-16, marks current source and selects ranges from the diagnostic list.
Source/worker changes retain labelled previous messages without drawing them on
new text. Diagnostics arrive after explicit execution; styling remains useful
for incomplete source. Server file paths are not diagnostic navigation targets.
Read-only/revoked access, reconnect/history and the public 60-second budget use
the existing API/lifecycle, including the temporary preview.

Both text previews bound rendered content to 256 Ki UTF-16 units and 4096
substitutions. Markdown additionally caps 4000 source lines, nesting at 16 and
20000 structural tokens. Complete authored source and unknown fields survive
bounded fallback, Save/revision conflicts and receipt recovery.

See [verification](../evidence/2026-10-28/notebook-web-text-features/README.md).

## Stage 4f.3 — editor operations, conflicts and local draft recovery (implemented)

Sheets can be duplicated, moved and deleted from the draft. Duplication retains
unknown fields, exact integers, formatting and local component settings while
allocating fresh sheet/cell/component identities. Deletion keeps at least one
sheet and explicitly selects a replacement controller for linked boards; their
component bindings are retained for review. Existing runs remain immutable.

Rename or move stages a byte-preserving member move with the document in one
Save. Modules retain metadata, follow the authored path and update their package
declaration, auto-imports and board action/service module references. Source-code
imports and resource-path strings need manual changes. Relative-path, extension,
case, file/directory and module-name collisions are rejected before staging.
A file move cannot silently replace another staged destination.

Review saved changes compares the base, local and current document. Independent
fields and ID-keyed collections combine; concurrent edits, delete/edit and order
conflicts require explicit local/saved choices. Source/formatting offsets are one
content choice when changed across editors. Files compare immutable digests and
require a choice if both editors touched the same path. Unknown fields and Int64
values use the lossless codec. Cancel retains the draft. Apply updates its base
and draft only; explicit Save still uses CAS, so another race conflicts again.
Complex merges fall back visibly to draft export (512 conflicts / 100000 nodes).

A per-tab IndexedDB journal retains staged document/file edits, exact base and
uncertain Save payloads under account/project identity. Reload offers explicit
Restore/Delete; restoring rechecks the current session account and write access
before applying anything, and neither saves nor runs. A changed base requires review.
An uncertain Save always retries its original ID/payload before saving newer
edits; bundled-file mutation waits for its resolution. No command is replayed
on load. Successful Save/discard removes only that tab's journal; restoring a
copy transfers it after a successful checkpoint and does not erase newer writes
from another tab. Invalid/expired entries are removed when their scope is read.
The journal bounds copies to 30 days, 16 per project and 96 MiB per copy. Storage
failure is visible and does not block explicit Save or draft export. Open modal
and unapplied runtime parameter drafts are outside this source journal.

See [verification](../evidence/2026-10-28/notebook-web-editor-recovery/README.md).

## Stage 4g.1 — audio presentation, playback and export (implemented)

The shared presentation codec projects validated audio files, complete retained
PCM streams and ordered player requests as inert bytes/metadata. It preserves
uint64 tokens/revisions as strings and exposes no device handles or paths. Audio
uses the existing run-result ACL/provenance and previews; no media URL endpoint
or alternative binary decoder is added. The projection reserves other rich data
first, then caps audio at 64 tracks / 16 MiB raw bytes in the shared 32 MiB JSON
budget and 256 control records. Omitted audio has a visible limit notice without
dropping scalars, diagnostics, charts, tables or images. Storage policies still
account for the complete retained Core artifact, not only its web projection.

A shared player supports Play/Pause/Stop, seek, volume, loop, waveform, original
file save and WAV export. File playback uses browser codecs and locally created
Blob URLs; CSP allows Blob media only. PCM s16le/f32le at 8–192 kHz mono/stereo
uses typed frames and Web Audio scheduling. Retained prefixes/tokens/revisions
are checked; appended frames schedule after the existing buffer, gaps are visible
as buffering, and a reset establishes a new playback epoch. Waveforms have at
most 2048 peaks. Exact PCM rates and samples survive WAV export.

Encoded files retain original bytes even when the browser cannot decode them.
Explicit waveform/WAV conversion uses browser metadata, a 40-second bound and
48 kHz decode, with finite mono/stereo and decoded/export limits. PCM decoding
is bounded to 32 MiB and WAV output to 16 MiB. Unsupported/corrupt media keeps
ordinary results and original save available; browser codec support can vary.

Opening, history and reconnect do not start sound. Play explicitly arms that
player in the current view. Later runtime play/pause/stop/seek/volume requests
apply in revision order once, target the declared source cell/channel, and never
write back to the worker. An ambiguous empty channel requires a channel choice.
Source/revision/worker staleness, hidden views, navigation and ACL loss pause or
release playback. Blob URLs, graph nodes and contexts are released on unmount.

Authored Audio in cell pre/post components and boards uses native `audio_id` /
`show_waveform` settings and controller-cell selection. Blank channel means all
published tracks; authored owners suppress matching automatic duplicates. Both
inspectors and palettes preserve unknown metadata and normal draft/Save/CAS.
Designer previews remain inert. Temporary preview shares the renderer and its
existing cumulative 60-second server budget; listening/export is local.

See [verification](../evidence/2026-10-29/notebook-web-audio/README.md).

## Stage 4g.2.1 — accepted media assets (implemented)

File Input, Audio Input and Image/Carousel now have choose/preview/Discard/Clear/
Apply in web boards. Core `media.accept` validates revision/input-version CAS,
component identity, active work, codecs, limits and configured extensions, then
commits a content-addressed asset, native input metadata, accepted values,
revision and receipt together. Apply is inert. Retained runs keep their original
asset revision. Existing storage/user/Core limits cover the full bundle and
history; public preview retains its 60-second cumulative execution ceiling.

A backward-compatible worker Sync extension loads the new immutable media root.
Managed File Input reads use a private read-only namespace with a stable narrow
grant; new data invalidates consumers without replacing the initialized world.
Audio uses `AudioTrack.from_input` and images use the shared readable-input map.
Exact pending commands/bytes recover through an account/project IndexedDB journal
and receipts; reconnect never repeats Apply automatically. Multiple unsaved media
or parameter drafts cannot silently overwrite one another.

See the [common contract](notebook-remote-media-inputs.md) and
[verification](../evidence/2026-10-29/notebook-web-media-inputs/README.md).

## Stage 4g.2.2 — microphone capture and accepted-image annotations (implemented)

Audio Input now supports explicit microphone choice/Record/Stop/Cancel. A separate
AudioWorklet captures finite mono/stereo PCM without audible monitoring; the
browser builds a bounded 48 kHz PCM16 WAV draft. Recording stops after 30 seconds,
at the decoded-PCM cap, on hidden view, cancellation, source change, interrupted
device or loss of access. Late permission results release tracks. The previous
local draft survives cancellation/failure. Only Apply media sends the WAV through
the existing accepted-asset/receipt/quota path; capture starts no notebook run.
The application permits microphone requests only from its own origin while
retaining other Orbit security headers and the browser's permission requirement.

Accepted Image/Carousel assets can open an immutable annotation snapshot. The
editor supports drawn points/reverse rectangles, precise whole source pixels,
selection, zoom/scroll, labels, multiple configured classes and typed attributes,
Undo/Redo, JSON export and separate Apply/Discard. Class/attribute definitions
are authored in Board Designer, including text/number/Boolean/choice, exact Int64
values and native bounds. Apply uses the source revision/input version captured
when the editor opened. Core validates native geometry/schema and the accepted
image hash/channel/dimensions in the same managed-media transaction. It starts
no code; `notebook.annotations` reads the new metadata on the next Run. Replaced
sources invalidate old labels while retaining their raw data for repair. Viewer
writes are denied; revocation closes the modal/capture and clears preview bytes.

This slice covers managed accepted images. Editing annotations on live published
cell images remains with the next source-binding extension. See
[verification](../evidence/2026-10-29/notebook-web-capture-annotations/README.md).

## Stage 4g.2.3 — audio annotations and completed publication bindings (implemented)

Audio Annotator is available in Board Designer with owned file, existing Audio
Input channel and completed cell AudioTrack sources. Its inspector configures the
native class/attribute schema, waveform/spectrogram, FFT size, independent Allow/
Require transcript policies and annotation channel. Disallowed transcript fields
are cleared from repair drafts and hidden; required empty text blocks Apply.

The runtime editor captures immutable identity, decoded source frames, schema,
revision and accepted input version on open. Core decodes PCM at the original
sample rate, avoiding browser resampling. Mono/stereo float PCM remains bounded
to the native 16 MiB limit. PCM16/float WAV decoding works without a platform
codec; other formats retain the host's existing bounded system codec contract.
Source cell IDs cross the source DTO as decimal strings and become exact Int64
JSON tokens in accepted metadata.

Draw temporal segments or time/frequency rectangles, edit exact frames or seconds
and Hz, label, assign multiple classes and typed attributes, edit track/segment
transcripts, Undo/Redo, export JSON, Discard and Apply independently. Preview plays
the temporal selection explicitly and stops on close, hidden view, source change
or revoked access. Required transcript completion affects Apply, not preview.
Zoom/pan/Fit and Zoom to selection reach individual source frames; frequency
bounds survive switching to waveform.

An external module Worker computes centered Hann STFTs (FFT 256–4096), coherent
full-scale sinusoid dBFS normalization, DC/Nyquist handling, 60/90/120 dB ranges,
canonical shared plasma LUT and peak-preserving waveform buckets. Rendering is
bounded to 1,400 columns / 768 spectral rows and replaces/cancels the worker on
viewport/display/source closure. Development uses a small same-origin static
entry that imports the configured Vite module under the existing CSP; production
uses the emitted hashed module. Neither needs Blob scripts or eval.

The common managed-media transaction now validates audio_annotations against
native source/frame/Hz/schema/transcript rules and the current original asset
hash. A read-authorized media.source path uses a disposable, quota-checked bundle
and the same decoder. Apply continues through execute ACL, revision/input CAS,
idle/dependency/lifetime checks, storage policy and durable receipt, without code
execution. Audio file replacement keeps old raw metadata for repair and makes
readers return null until reapplied.

Image/Carousel annotation also resolves the latest completed published channel,
including a chosen published collection image. Core obtains publication bytes
from its own current controller run, never from a browser-provided path or blob;
changed controller code, reset workers, invalid cells or different assets cannot
retarget Apply. Annotation-only saves can reopen an unchanged completed source.
See [verification](../evidence/2026-10-29/notebook-web-audio-annotations/README.md).

## Stage 4g.2.4 — shared selection, dates and parameter presets (implemented)

A board Data Table can own a selection_id and a unique selection_key column
(name or ID). Choosing a retained row is a local draft; sorting/filtering never
changes its typed key. Apply selection stores the native {version, source, key,
row} snapshot, Clear stores null, and Reset is inert. Exact Int64 survives the
browser and the next explicit Run through notebook.selection. Core resolves its
own completed controller publication, verifies SHA-256, unique/non-null keys,
unique column names, and the entire selected key/row against the source table.
Forged rows cannot be accepted just by copying the source hash. Existing revision/
input CAS, idle checks, receipt recovery and storage quotas remain authoritative.

Image/Carousel and completed Audio Player bindings resolve the accepted selection
channel and asset column (default asset_id). They filter by SHA-256 of original
encoded bytes, never row order or collection index. An empty/mismatched selection
shows no matching asset and preserves authored collection contents. Selecting a
different asset unmounts/stops the previous audio player; no selection autoplays.

Date / Time Input binds a String project input and authors date/date_time plus
a time zone. Calendar dates strictly validate Gregorian YYYY-MM-DD (including
leap years); date_time displays in the configured IANA zone and accepts exact
YYYY-MM-DDTHH:MM:SSZ UTC through the existing parameter transaction. Invalid local
times in DST gaps are rejected; repeated local hours require an explicit UTC
occurrence. Edits are local, Reset is inert, version conflicts keep the draft,
Apply never changes authored defaults, and an uninitialized sheet stays idle.

Parameter Presets authors a selected-input scope, or all project parameters.
Review compares exact current and preset JSON before one atomic ordinary input
Apply. A separate management dialog captures current values, renames/deletes,
imports a bounded 1 MiB JSON array atomically, assigns imported sets new IDs and
exports exact scalar JSON strings. It accepts at most 128 sets/128 values per
set, validates types/bounds/scope/date bindings and preserves extension metadata.
Update notebook draft stages the authored sets; Save persists them without
changing defaults or executing code. Cancel leaves the saved document untouched.
Viewer writes are denied and revoked access closes the management draft.

[Verification and SDK compatibility](../evidence/2026-10-29/notebook-web-selection-controls/README.md).
The original browser/native checks used isolated SDK 3eb0f05. Their namespace/
callback startup qualification is superseded by the
[current SDK b3ed894 follow-up](../evidence/2026-10-30/notebook-web-current-sdk/README.md),
including explicit retention of the ORM record factory. SDK sources stay clean;
the web runner uses the default current compiler without the old override.

## Stage 4h — environments, worker settings and expanded history

Stage 4h.1 implements the existing Core environment preparation/generation/status
and per-sheet worker settings contracts. The owner explicitly prepares saved
manifests; operator flags control preparation and editable grants. The adapter
maps ready project generations to private paths, preserves private grants and
returns fixed diagnostic summaries. Review/confirmation, revision/settings/epoch
CAS, idle checks, storage admission and durable receipts govern resets; no cells
run implicitly. Temporary sessions cannot install or change worker privileges.
[Verification](../evidence/2026-10-30/notebook-web-environments/README.md).

Stage 4h.2 implements retained immutable run inspection and experiment comparison.
Snapshots expose exact project/local scalar JSON, executed cell sources, revision/
module references, bounded rich output and frozen environment/settings/package
provenance. Mutable title/pin metadata is separate and uses its own version CAS.
Up to ten pinned runs survive retention but consume effective storage/run quotas.
Delete refuses active, pinned and current presentations and preserves cumulative
execution accounting and command tombstones.

Snapshots and experiments… is available from Run history and Run History /
Experiment Compare board components. Comparison preserves exact Int64/decimal
deltas and exports CSV. Restore reviews one scalar scope, excludes file/media
references, uses the existing atomic input Apply/version/receipt path and warns
that initialized Watch cells may execute. Sources and authored defaults stay
separate. Permission loss closes the inspector. Environment provenance is marked
unavailable for older records that predate capture.
[Verification](../evidence/2026-10-30/notebook-web-run-history/README.md).

## Stage 4i.1 — parity and deployment-readiness audit (completed)

31 October 2026. The source inventory records 35 Swift tools / 33 persisted kinds
and 30 web palette kinds. A complete version-4 fixture crosses the native C API
used by Swift → web import/edit/save/export → native reopen/edit/save. All authored
fields except the deliberate source edit, exact integers, unknown settings,
computation/storage policy and bundled bytes survive. Loading/saving remains
inert. The browser check passes in VM/native × development/production, with
light/dark desktop/phone captures. This is bridge acceptance, not automated
SwiftUI visual equivalence or execution of every tool.

The real native backend/main and independent Core pass local signed-session
acceptance through the documented proxy contract: CSRF, >1 MiB upload/download,
public assets/private paths, HTTP restart during work, duplicate command identity
and Core outage/restart with retained results/accounting. An operator guide and
nginx example are included. Actual nginx/TLS, live GitHub consent and Linux
deployment are not exercised; no external deployment is claimed.

The [audit matrix](notebook-web-parity-audit-2026-10-31.md) records the remaining
Status/Artifact Browser/Task Monitor renderers, partial Result/Log controls and
the authenticated-only temporary preview. **4i.2** below implements the remaining
palette kinds; **4i.3** adds anonymous public lifecycle and **4i.4** is external
deployment acceptance. Preserve book override semantics, storage admission,
cumulative accounting and the public 60-second cap throughout.
[Verification](../evidence/2026-10-31/notebook-web-parity/README.md).

The current SDK startup follow-up is recorded above; historical 3eb0f05 evidence
remains a record of the earlier implementation stages.

## Stage 4i.2 — runtime observations and remaining palette kinds (implemented)

Status/Alert, Artifact Browser and Task Monitor now render and can be authored
through the ordinary designer/draft/Save flow. All 33 persisted Swift palette
kinds have web renderers; kind coverage does not imply identical local filesystem
authority or every desktop interaction.

The shared validated presentation codec projects captured Inspect/Pretty formats
and bounded task telemetry. Task identities/parents/counters stay exact strings;
only source cells from the immutable execution document receive navigation links.
Private worker file names are not exported. Task Monitor shows hierarchy, state,
errors, duration, CPU/memory and omissions, with an Errors only filter. Status
targets sheet/cell/action/service/runtime and includes authoritative quota status.
Exhaustion takes precedence over restart advice; restarting cannot renew time.

Artifact Browser decodes the result's path/name/caption records and reads only
validated relative members of that run's immutable saved revision through existing
ACL-checked Core file APIs. At most 128 references are displayed. Preview is
bounded text and download preserves bytes. New source revisions do not retarget
older artifacts. External desktop paths and newly generated files outside the
saved bundle remain explicitly unavailable; no generic server filesystem route
or generated-file capture contract is added.

Result Inspector adds captured Inspect/Pretty/table modes, literal Unicode Find,
case selection, match navigation, wrapping, copy and export, with captured-text
truncation and search bounds. Log Viewer adds substring/stream filtering, bounded
adjacent-event coalescing, copy/export and omission markers. These controls are
local and inert. Historical/changed sources and workers show stale data; current
ACL loss clears observations and pending artifact previews.

Verification uses the current workspace Sputnik **1.0.0**, without the earlier
isolated compiler. App/Core locks were explicitly regenerated with the language
version. [Evidence](../evidence/2026-10-31/notebook-web-runtime-observations/README.md)
records native coverage, real-worker browser cases, transfer, policy and regression
checks. The test runner also keeps child services in its process group, requests
graceful teardown and verifies SIGTERM/SIGKILL cleanup with active real workers.
This fixes orphaned test services without coupling production HTTP/Core lifetime.
Stage 4i.3 below adds the anonymous public app lifecycle, retaining computation/
storage admission, book override semantics and the public cumulative/per-run
60-second ceiling. External deployment acceptance remains 4i.4.

## Stage 4i.3 — anonymous public notebook lifecycle (implemented)

1–2 November 2026. An operator-only allowlist publishes at most sixteen id/title/
Core source/pinned revision entries. Guests see only id/title and explicitly open
an isolated copy from the welcome page. Templates, policy profiles, worker grants
and billing identities are selected server-side. An encrypted visitor cookie and
copy token are both required; normal same-origin/CSRF checks remain in force.
No Account, Identity, Project or Membership record is created for anonymous use.

Core supports a trusted pinned source revision and stable session project identity
so an uncertain open returns the same copy rather than resetting its lifetime.
The anonymous principal shares a persistent **60-second** execution ledger across
copies, HTTP restarts and Core restarts; concurrent sheets add time. Core clamps
anonymous user limits restrictively, preserving tighter operator ceilings rather
than replacing them. Per-run/public computation, storage admission, 64 MiB copy/
visitor archive bounds, 8 MiB snapshot reservation, a fifteen-second lease and
fifteen-minute maximum lifetime remain authoritative even with book overrides.

The catalog serializes admission: one active copy per visitor, sixteen globally,
ten openings per visitor/hour and 120 globally/hour. Opening receipts are scoped
to the visitor and publication fingerprint, retained for 24 hours. Retries use
the same reserved copy identity. Reads, saved source edits, Run All, Stop/Force
Stop and result/receipt inspection reuse the shared preview adapter without
exposing private workspace, environment installation or arbitrary server files.
The UI keeps tokens/uncertain commands in memory, never automatically mutates
on reload, and stops heartbeats when closed, hidden or offline.

OAuth exchanges use a request-owned transport client. A private login after a
long anonymous computation cannot reuse a provider socket closed during idle;
authorization codes are never retried automatically.

Cookie loss/new browsers represent new anonymous visitors; global admission and
operator Core-wide quotas still bound the service. This does not identify a
physical person. Publication uses a separate Core-only source project; retaining
the pinned revision is an operator responsibility. Removing/changing publication
configuration revokes existing access; the independent Core lease expires copies.

[Operator setup](../../apps/notebook-web/deploy/README.md#anonymous-public-notebooks) ·
[Acceptance](../evidence/2026-11-01/notebook-web-public/README.md).
The next stage is **4i.4 — external deployment acceptance**: actual proxy/TLS,
GitHub consent for private workspaces, Linux operation and browser/platform checks.

## Resource-policy slice — web settings and public-limit previews (implemented)

28 October 2026. The newly shared computation/storage policies are integrated
before the Stage 4f.2 text work above. Resource limits… edits the same eight book
`resource_policy` fields as Swift, with inherited defaults and saved effective
values shown separately. Update notebook draft stages changes; ordinary Save
retains revision/conflict/receipt behavior. Cancel is inert. The server's explicit
override mode decides replacement versus restrictive merging; operator ceilings
always remain in force. No browser setting can switch that process mode.

The execution registry includes a compact, sanitized policy/time summary with
exact string counters and remaining time across project/owner/Core budgets.
New execution controls stop offering starts at exhaustion; Stop/Pause/results
remain usable. An authorized resources endpoint provides project storage usage
on demand, avoiding a full archive scan on each registry poll. Core retains
ownership, identities, global storage totals and free-space details.

Temporary preview… explicitly opens a new saved-notebook copy with the public
profile. The 60-second cumulative wall-time and per-run ceilings, plus temporary
persistence, are now invariants even if a profile is replaced or book/app limits
are raised. Preview edits, Save copy, Run All, Stop/Force Stop and rich/text
results use existing Core worlds/receipts. Uncertain commands are checked and
only explicitly retried. Close/hide/offline discards the token; a disconnected
copy cannot silently reattach. Tokens stay in memory and abandoned copies
expire through the independent Core lease. Aggregate owner/Core usage persists.

The preview remains authenticated against its source project's execution ACL.
Stage 4i.3 adds the separate anonymous landing/template flow above. Boards/
parameters/dependency installation stay in the full workspace. Stage 4f.2 builds
on this quota integration; Stage 4f.3 and 4i.1–4i.3 are implemented above. The next
slice is external deployment acceptance in 4i.4.

See [verification](../evidence/2026-10-28/notebook-web-resources/README.md).

Releasing a history pin and deleting an eligible retained run remain available
when the archive quota is exhausted, so protected history can be freed.
