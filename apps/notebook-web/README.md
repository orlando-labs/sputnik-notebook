# Sputnik Notebook web

Orbit backend and Vue/Vite frontend for the **server workspace**. All backend
code, migrations and the offline GitHub provider use Sputnik/SQL. Node is used
for frontend and development/test tooling. The backend needs no Python runtime.

The scaffold includes GitHub sign-in, an encrypted cookie session, account and
identity records, a private project catalog and project sharing. The current
project screen now opens a real notebook document through the shared core.
The workspace supports sheets, code and formatted-text cells, Markdown and
variable previews, explicit revisioned saving, Run / Run All, Stop / Force Stop,
worker restart, text/rich results and reconnect.

Optional anonymous public mode publishes an operator-selected, revision-pinned
template on the welcome page. A visitor edits/runs a disposable copy without a
GitHub account. Its encrypted browser session shares a **60-second cumulative
computation budget across copies**, with the same per-run ceiling. Book and
operator quotas may be stricter. Anonymous visitors at the same IP also share
an operator-configurable daily budget, 300 seconds by default.
See the [operator setup](deploy/README.md#anonymous-public-notebooks) and
[Stage 4i.3 acceptance](../../docs/evidence/2026-11-01/notebook-web-public/README.md).

The welcome screen follows the macOS `NotebookWelcomeView`: the same default
Sputnik light/dark palette, rounded title, notebook mark, compact actions and
expandable library rows. New Notebook creates a server project and explicitly
initializes its document from a keyboard-accessible dialog; Open Notebook
focuses the searchable library.
The library supports Last Opened, Date Created and Name sorting, refresh and
expandable project dates/IDs. Sort, collapse and last-opened history are stored
per account in this browser (and remain optional when storage is unavailable).
Last Opened is recorded only after opening a project, independently of server
update times. Shared projects use the same library and retain server ACLs.

Project pages show a Swift-style sheet sidebar and source editor. Add and rename
sheets; duplicate, reorder and delete sheets; add, reorder and delete code/text cells; save with Save Notebook
or Cmd/Ctrl+S. Cell identities remain canonical uint64 decimal strings. A save
uses the exact base revision, preserves bundled resources/modules and retains
unknown document fields. Schema versions 1–4 can be opened; portable formatted
text is editable. Modules/resources, parameters and authored cell displays
and boards are editable. Media input/capture, image/audio annotations, shared
selection, date controls, presets, environments and retained-run comparison are
implemented. The [current parity audit](../../docs/engineering/notebook-web-parity-audit-2026-10-31.md)
records the remaining component and deployment gaps.

Unsaved edits are guarded on navigation and sign-out. Review saved changes
combines independent edits from the base, draft and saved version. Overlapping
fields, deletions, order changes and file edits need an explicit choice. Text and
formatting stay together when their changes overlap. Apply updates the draft;
Save still checks the latest revision. Cancel keeps every local edit.

Staged source/file drafts and uncertain Save commands have per-tab IndexedDB
recovery copies scoped to account/project/base revision. Reload offers explicit
Restore or Delete, with no automatic Save or Run. Restore rechecks the
current account and project write access, including changes in another tab. Copies expire after 30 days;
limits are 16 copies per project and 96 MiB per copy. A restored older base needs
conflict review. An uncertain Save retries its original command before a newer
edit gets a new command; file edits wait for that response. Saved/discarded drafts
remove their own copy. Storage failure shows an export notice and leaves explicit
Save available. This journal covers committed editor drafts, not open modal or
unapplied parameter forms. Draft JSON is a recovery payload; Export draft produces
a full `.sputnikbook` bundle with resources.

Text cells and board Text use the same portable rich-text editor/preview as the
Swift document format (formatting versions 1 and 2). Select source text for Bold,
Italic, Underline, Inline code or Clear; choose Body/Heading 1–3 for paragraphs,
and bullet/numbered lists. Preview renders those styles and tables using literal
text nodes. HTML is never inserted or evaluated. `{{name}}` reads published
module-cell values from preceding code cells; board prose uses its controller
sheet. Later providers shadow earlier ones, including uninitialized providers.
Edits, failed predecessors, changed environments/workers and historical results
mark values stale; missing names show unavailable. Variable… inserts a literal
placeholder at the caret through the normal Undo/draft path. Only names declared
in the immutable saved run's prose/bindings are projected; adding a name requires
Save and an explicit Run. No expression or arbitrary locals query is evaluated.

Board Text supports portable rich text or Markdown through Text format in the
inspector. Markdown headings, emphasis, lists, quotes, tables, links and code
blocks render through a closed Vue node vocabulary. Parsing and Sputnik fence
styling happen before literal variable substitution, so values cannot introduce
Markdown/HTML structure. HTML stays text, images show alt text without a fetch,
and links permit only explicit http(s), mail and fragments. Mode changes preserve
portable metadata; Markdown source edits remap it and protect table boundaries.
Published Text also binds a named value from an explicit source cell.

The Table menu inserts a 2 × 2 table, adds/removes rows or columns, removes a
table and moves the caret after it. Tab/Shift+Tab moves between cell ranges.
Inline formatting and source edits preserve UTF-16 offsets, Unicode scalar
boundaries and table ownership. Deleting a cell terminator or crossing a table
boundary is rejected atomically with a visible reason; select the complete table
or use its structural controls. Enter continues a list and numbered items are
renumbered. Source edits support IME composition and plain-text clipboard input.

Undo/Redo (including Cmd/Ctrl+Z) stays local to each text editor, bounded to 100
snapshots / 16 MiB with 500 ms typing coalescing. Preview is inert and does not
rewrite formatting. Save, revision conflicts, retry receipts and unknown source
metadata use the existing notebook draft contract. Readers get the rendered
preview. Unsupported formatting remains preserved and read-only with a notice.
Formatted preview is limited to 256 Ki UTF-16 units and 4000 lines; larger text
uses a bounded source preview and remains fully editable/saveable within normal
document limits. List formatting/renumbering permits at most 500 changed items
per operation; table limits match native: twelve columns / 240 cells / 100 tables.

Published text is bounded to 256 names/provider records, 4096 Unicode scalars per
value and 1 MiB of projected text. Exceeding the aggregate projection limit drops
the complete text projection with a notice, avoiding partial shadow resolution.
Both previews share a 256 Ki UTF-16 rendered budget and 4096 placeholders.
Markdown parsing caps nesting at 16 and structural tokens at 20000.

Code cells, Sputnik modules and temporary previews share a source editor with
the native lexical palette: Unicode identifiers, comments and callable `#`, tagged
and interpolated strings, template controls, numeric forms, macro splices and
contextual `then`/`next`. The textarea retains browser selection, Undo and IME;
coloring and line numbers do not rewrite source. Highlighting caps at 256 Ki
UTF-16 units / 4000 lines / 20000 tokens, then leaves complete source editable.
Native compile/runtime diagnostics arrive after explicit execution with bounded
messages and Unicode-scalar ranges. Click a message to select its source; editing
or changing worker/revision retains a previous diagnostic without underlining
the new source. Module files have styling; the diagnostic ranges belong to the
saved controller cells, rather than private server file paths.

Execution uses the saved revision: save changes before Run All, a cell's play
button or Shift+Enter. A sheet retains its worker variables between runs.
Results show values, stdout/stderr, cell errors and background-task failures.
Previous results are marked when the source, revision or worker changes; the
compact run history opens earlier results without replacing the current source.
Stop requests cooperative cancellation. Force Stop and Restart Worker require
an explicit confirmation; a force-stopped/interrupted worker must be restarted.

Arrays/records render as typed tables, with exact int64 values, stable sorting,
filtering, row selection and CSV/Markdown downloads of the filtered snapshot.
Published `DataTableView` tables retain their captions, ordering and named live
replacement. Tables render at most 100 rows per page; sorting/filtering/export
operate over all retained rows. A truncated snapshot is explicitly labelled.

PNG/JPEG figures and live image collections support captions, previous/next and
original-byte downloads. Version-1 plot scenes use the same closed drawing
vocabulary as Swift: axes, lines/points, polygons, guides, annotations and color
scales. Drag to zoom, Shift-drag to pan, Ctrl-scroll or use +/−; Reset / 0 restores
the original viewport, and Save PNG exports the current view. Unsupported scenes
retain a raster fallback when present; 3D figures remain raster previews.

Progress, named stopwatches, cell execution time and live chart channels are
visible during execution and in saved run results. Stop keeps a partial bar at
its last count. Milliseconds and total sample counters cross JSON as exact
strings. Charts follow new samples until manually zoomed; live updates retain
a chosen viewport. The chart samples bounded geometry for display and exports
every retained point through CSV. Unavailable authored cell components show an
explicit notice while preserving their settings.

Cell Components… authors Input/Parameter Form, Metric, Live Chart, Table and
Image before or after code, with the native settings vocabulary. Metric binds
a published numeric variable or the cell result; Int64 values remain exact and
decimal formatting uses Swift-compatible half-even rounding. Charts support
axis labels/bounds, colors and multiple named series with a local legend. Tables
select a named published table, or all published tables with implicit-result
fallback. Images select a channel, sizing mode, caption and save controls.
Claimed tables/channels render once; unclaimed results stay visible. Post-cell
components enable Hide/Show Code without changing the saved document.

Numeric bindings are scoped to the immutable execution document, not arbitrary
browser queries. A newly authored binding becomes available after saving and
explicitly running the cell. History reads its original declared values; missing
or nonnumeric bindings remain unavailable, with stale values clearly marked.

Existing boards use the Swift twelve-column rows/spans, authored heights and
alignment, nested groups, tabs and split panels. Legacy column layouts convert
only for display, without rewriting the document. Narrow grids stack cards.
Panel selection, group expansion and split ratio are local view state; hidden
panels keep unapplied parameter drafts, and leaving the board guards them.
Open Sheet returns to the controller; Run Sheet and Run components explicitly
run saved code through the existing execution/receipt contract.

New board and Design… open a Swift-style Board Designer with the component
palette, canvas and Object Inspector. Set the controller sheet, row height,
card width/alignment and source bindings; add nested groups/tabs/splits; reorder,
move between rows by drag or the inspector, duplicate and remove items. Preview
shows the layout with runtime controls disabled. Undo/Redo keeps up to 100
snapshots within a shared 16 MiB UTF-8 budget. Grid edits respect the core limits:
12 columns per row, 256 rows/components, 128 panels and eight nesting levels.
Row heights are automatic or 48–4096 points.

Update notebook draft (also Cmd/Ctrl+S inside the designer) returns changes to
the notebook; Save notebook then persists through the existing revision/receipt
contract. Cancel discards only the designer copy. Duplicate/Delete board also
change the notebook draft first. No editor operation runs code or applies
parameters. Opening a legacy board normalizes only that designer copy; Cancel
leaves the original intact. Unknown settings and exact integers survive editing
and nested duplication. Unsupported component configurations remain preserved;
the palette offers only components with implemented web behavior. Its Text
inspector shares the rich-text editor. Viewer/revoked editors cannot commit a board.

Board Metric/Table/Result/Progress/Plot/Log refer to controller cells. Named
charts and image collections resolve within that controller's sheet, using
reverse authored cell order for shared channels. Stopwatches use the declared
channel. Board Input/Parameter Form/Range controls apply project parameters
explicitly, with existing Watch/Manual, version and permission checks. Numeric
Metric bindings inside nested panels come from the immutable run document.
Opening or browsing never starts a worker or schedule. Audio refers to a
controller cell and published channel. Managed input assets/shared selections
remain explicitly unavailable. Portable text and
Markdown render saved source with declared published-variable bindings.

Action Button calls an exported notebook module function in its own persistent
invocation world. Positional/named arguments freeze accepted project parameters
and exact scalar JSON constants at acceptance. Execution Controls target the
controller sheet, a cell, an action or a service. View output and Run history open
isolated text/live/rich results separately from controller results. Stop/Force
Stop and Restart address the invocation's own worker; restart requires an idle,
paused service. Modified source, inputs or reset workers mark previous output.

Periodic Work has explicit Start, Run Once, Pause and Clear history controls.
Scheduling belongs to the independent core agent and continues after hiding a
board, closing the browser or restarting the web gateway. Fixed delay waits
after completion; fixed rate skips overlapping ticks. Pause lets current work
finish; Stop cancels it and pauses future calls. Changing executable service or
module settings pauses future calls. After a core-agent restart, Start is needed
again. The desktop-only pause-while-hidden setting is preserved and does not
pause a server schedule. Retention (None / Tail / All), returned values/errors,
first-run timing and stop-on-error use the native document settings.

History reads page 50 retained entries at a time and cap each value/error preview
at 4096 characters, with a visible truncation notice. Counters and history IDs
cross JSON as exact decimal strings. The palette/inspector authors these command
components without running them. Start/Run Once require the current saved
revision; Pause/Stop remain available with unsaved edits. Readers can inspect
results/history; mutations require execution access and CSRF. Lost action/service
responses use the same checked command journal, with explicit retry only.

Rendering never evaluates code or fetches a figure URL. `plot` / `notebook.ui`
must already be available in the project's execution environment to run code
that imports them; use Dependencies or bundled modules to provide those packages.
Plain array results, progress and `notebook.images` need no package import.

Reloading or closing a tab leaves accepted work with the core agent. Reopening
reads the registry and existing results, without resending Run. An uncertain
command is kept per account/project in session storage and checked by receipt;
only an explicit retry resends its original ID, payload and revision. No command
is replayed automatically. Polling pauses in hidden tabs and resumes on focus.

Project metadata and owner-only access controls live in the expandable Project
details & access section. ZIP/folder notebook import/export and project/cell
parameters, cell displays, board viewing/designer and Audio output are
implemented. Managed media inputs, microphone capture and image/audio annotations
are implemented. Status/Alert, Artifact Browser and Task Monitor are implemented. Result Inspector
has captured Inspect/Pretty/table and literal Find; Log Viewer has search, stream
filters, copy and export. Artifact reads are limited to the captured saved bundle. The UI supports narrow screens and
the system color scheme. See the [palette matrix](../../docs/engineering/notebook-web-parity-audit-2026-10-31.md#palette-matrix).

## Audio output

Audio in cells, boards, invocation results and temporary previews has local
Play/Pause/Stop, seeking, volume, looping, waveforms, Save original and Export WAV.
Audio channel ID and waveform visibility are editable in the cell/board
inspectors; an empty channel shows all tracks from its source cell. Matching
automatic outputs are suppressed. Viewing or designing does not execute code.

The shared codec projects at most 64 tracks / 16 MiB raw audio into the existing
32 MiB rich-result budget, reserving other result data first. A visible notice
marks omitted tracks. Core storage/computation quotas remain authoritative;
retained artifacts are charged in full. Public preview still has a cumulative
60-second server execution ceiling. Playback and conversion happen in-browser.

PCM streams retain typed s16le/f32le frames at 8–192 kHz mono/stereo, exact string
tokens/revisions and complete reconnect snapshots. Appends continue the buffered
queue; unfinished streams show Buffering at the available end. WAV exports keep
PCM rate/sample bytes. File playback uses local Blob URLs and browser codecs;
unsupported/corrupt files keep their original download. PCM WAV waveforms have
up to 2048 peaks; explicit browser conversion of other encoded files is bounded
to 40 seconds at 48 kHz and 16 MiB exported WAV. Browser codec support can vary.

Play arms only the current player/view. Saved autoplay and runtime Play requests
do not start sound on load/history/reconnect. Ordered runtime requests apply
once after activation, target their source cell/channel and never trigger a new
run or change runtime inputs. Empty channel commands need a single unambiguous
track. Source/worker changes, leaving/hiding the view and lost access stop local
playback; unmount releases Blob URLs and audio contexts. Managed media inputs, recording and accepted-image annotations are implemented
below, together with audio annotations and annotation editing against completed
cell publications.

[Audio verification and screenshots](../../docs/evidence/2026-10-29/notebook-web-audio/README.md).

## Managed media inputs

Web boards support File Input, Audio Input and Image/Carousel choose, local
preview, Discard, Clear and Apply. Apply accepts versioned bytes through Core,
commits their native input metadata and advances the saved revision; it does not
execute code. Run explicitly to consume the new input. File Input targets a
String project parameter; audio uses `AudioTrack.from_input`, and image consumers
require Allow runtime image reads. Designer settings expose both new input kinds
and image load/read permissions. Carousel supports replace, append and clear.

Requests authorize current execute access and compare both saved revision and
accepted input version. Same-ID retries use durable receipts. The exact pending
media command/bytes are recovered from an account/project IndexedDB journal;
reconnect checks status and never posts Apply automatically. Finish other drafts
before applying media; source editing is disabled while acceptance is uncertain.

Files are at most 16 MiB; full bundled data keeps the existing 64 MiB / 2048-file
limit and storage quotas, including old managed assets retained in the bundle.
Images retain the native 64-item/aggregate limits. Portable PCM WAV is validated
without an OS decoder; other audio formats require the server's system codec.
The worker receives only scoped read access to accepted File Input data. Public
preview remains limited to 60 cumulative seconds of server computation.
Microphone recording and accepted-image annotation editing are implemented below.

[Common contract](../../docs/engineering/notebook-remote-media-inputs.md) ·
[Verification](../../docs/evidence/2026-10-29/notebook-web-media-inputs/README.md).

## Microphone recording and image annotations

Audio Input has explicit Record, Stop recording and Cancel recording, plus device
choice after Refresh microphones or a successful permission grant. Recording
requires HTTPS or localhost and AudioWorklet support. Its own-origin microphone
permission policy retains the browser prompt and blocks cross-origin capture.
Audio is not monitored through the speakers. Stop creates a local 48 kHz PCM16
WAV draft; only Apply media accepts it. Capture stops at 30 seconds or the
16 MiB decoded-PCM bound. Cancel, hidden view, changed source, device interruption
and revoked access release tracks/contexts and keep any prior local draft.

Enable image annotations in Board Designer for an Image/Carousel, choose its
annotation channel and edit Classes & attributes there. Annotate image opens the
selected accepted asset as a frozen source snapshot. Draw points/rectangles or
edit exact whole-pixel coordinates; zoom/scroll, labels, multiple classes,
text/number/Boolean/choice attributes, Undo/Redo and JSON export are available.
Apply annotations uses the captured revision/input version and the common
managed-media receipt path. The worker revalidates the hash/dimensions/channel,
geometry and frozen class schema before acceptance. Run explicitly to consume
`notebook.annotations(channel)`. Replacing a source makes its old labels null
for runtime readers while preserving their repair data. A viewer cannot record
or apply annotations. No microphone is opened by viewing/designing a board.

[Verification and screenshots](../../docs/evidence/2026-10-29/notebook-web-capture-annotations/README.md).
Audio annotations, spectrograms and editing annotations against completed cell
publications are described in the Audio annotations section below.

## Run from this directory

Keep the sibling `sputnik-lang`, `orbit`, `orm` and `sqlite3` checkouts beside
`sputnik-notebook`. `sputnik.build.json` contains local package overrides and the
HTML view format; it does not enumerate application source files. The backend
entry is simply `backend/main.s` and the frontend is `./frontend`.

```sh
npm ci --prefix frontend
export GITHUB_CLIENT_ID=...
export GITHUB_CLIENT_SECRET=...
# Start the durable core agent separately (see Shared core below).
export NOTEBOOK_CORE_ROOT=/absolute/short/path/to/core-state
node tools/dev.mjs
```

Create a GitHub OAuth App with callback
`http://127.0.0.1:3000/auth/github/callback`. Development uses Orbit on port 3000
and Vite on port 5173. `ORBIT_ORIGIN`, `ORBIT_PORT` and `VITE_ORIGIN` override
these values together. Dev session/CSRF secrets are generated once in
`build/dev-secrets.json` (mode 0600); explicit environment values override them.
Backend/view/package-source changes restart the VM backend. The Vite server
handles frontend HMR. The DB persists at `data/notebook-web.sqlite` unless
`NOTEBOOK_WEB_DATABASE` is set.

For a manual offline preview, without GitHub credentials:

```sh
npm run build --prefix frontend
node tools/smoke_server.mjs --mode production --port 3010
```

The test provider offers Alice/Bob identities and explicitly identifies itself
as a fixture. The runner starts a real local notebook-core agent and requires
`build/sputnik-notebook-remote` / `build/sputnik-notebook-worker` (build these
from the repository root with `make remote-core` when absent). By default it
uses a fresh catalog DB and a short temporary core state path for each run.
Pass `--database /absolute/path/catalog.sqlite --core-root /absolute/short/core`
to reopen the same test workspace; `--without-core` exercises unavailable-service
behavior. For testing independent web restarts, start the agent separately and
add `--external-core`; the runner then connects without owning its lifetime.
On macOS use a real short path such as `/private/tmp/my-notebook-core`,
not the `/tmp` symlink: core uses durable directory sync and Unix socket paths
must fit the platform limit. `backend/main.s` always uses
GitHub's real endpoints. Real GitHub consent still needs configured credentials
and a separate live check.

## Application boundary

- `backend/models.s`: Account, Identity, Project, Membership and domain errors.
- `backend/catalog.s`: identity resolution, private catalog and authorization.
- `backend/database.s`, `schema.s`, `db/migrations`: ORM pool and versioned SQL.
- `backend/app.s`: same-origin Orbit controllers, params, sessions, CSRF and ACL.
- `backend/layouts.s`, `views.s`, `views/**/*.html.sv`: reusable SSR layout and
  page fragment. `Assets.tags` injects Vite dev entry or production JS/CSS from
  the manifest; the escaped JSON bootstrap is separate from executable script.
- `frontend/src`: Vue workspace, HTTP client and browser DTOs.

GitHub identity is uniquely `(provider, uid)`, with UID stored as a string.
Changing a GitHub login never changes account identity; matching display names,
logins or emails never merges accounts. The only durable application field in
the cookie session is `account_id`; OAuth tokens and user profiles are not
stored there. An active Account is reloaded for authorized requests, so disabling
an account applies to existing sessions as well.

A Project has an immutable owner and a private, unique `core_project_id` reserved
for the shared core. At this stage creating a Project creates **only catalog
metadata** in the catalog. The UI then explicitly POSTs notebook initialization;
if core is unavailable, the catalog project remains available for retry. Existing
metadata-only projects offer Create Notebook. GET never provisions a notebook.
Initialization is idempotent and cannot replace an existing head. Server storage
uses core's immutable revisions of the normal `project.json` document plus its
file bundle. The private core ID and filesystem paths are not included in
browser DTOs. Membership is
unique for `(project_id, account_id)`; owner access comes from the Project and
cannot be assigned through membership roles.

| Role | Read | Edit / execute policy | Manage access |
| --- | --- | --- | --- |
| owner | yes | yes | yes |
| editor | yes | yes | no |
| viewer | yes | no | no |

Execution uses the same current owner/editor/viewer policy. The registry also
refreshes the browser's execution capability after a live membership change.
Unknown and inaccessible projects both return 404; a visible project
with an insufficient role returns 403. Only owners can list, grant or revoke
memberships. Sharing accepts an existing active account ID. Ownership transfer,
project deletion, invitations and account administration have no public API yet.

All identity and catalog mutations run in short `Model.with_lock` transactions;
OAuth network I/O finishes before opening the sign-in transaction. SQLite uses
WAL, foreign keys and a bounded ORM pool. Startup applies numbered migrations
atomically and stores SHA-256 digests; modifying an already applied migration
fails startup. Schema changes go in new numbered files.

## HTTP API

`/` and `/projects/:id` negotiate HTML and JSON. API requests use
`Accept: application/json`; a protected HTML page redirects guests to `/`.

| Method | Path | Result |
| --- | --- | --- |
| GET | `/api/session` | account / visible projects bootstrap; anonymous is allowed |
| GET / POST | `/api/projects` | visible catalog / create `{title}` (201) |
| GET / PATCH | `/api/projects/:id` | metadata / rename `{title}` |
| GET | `/api/projects/:id/notebook` | `{notebook: {revision, document}}` or null when not initialized |
| POST | `/api/projects/:id/notebook` | initialize with `{}`; owner/editor only, idempotent |
| PUT | `/api/projects/:id/notebook` | save `{command_id, base_revision, document}`; owner/editor only |
| GET | `/api/projects/:id/execution` | saved head, recent 100 runs plus active runs, public worker state and execution capability |
| POST | `/api/projects/:id/execution/invocations` | `{command_id, revision, board_id, component_id}`; invoke an authored Action |
| GET / POST | `/api/projects/:id/execution/services` | public service states / configure `{command_id, revision, board_id, component_id, operation: "start" \| "pause" \| "once" \| "clear"}` |
| GET | `/api/projects/:id/execution/services/:board/:component` | service state and bounded history; optional `before` cursor |
| POST | `/api/projects/:id/execution/runs/:run_id/restart` | `{command_id, runtime_epoch}`; restart an idle invocation worker |
| POST | `/api/projects/:id/execution/runs` | `{command_id, revision, sheet_id, cell_id, action: "run" \| "run_all"}`; owner/editor only |
| GET | `/api/projects/:id/execution/runs/:run_id` | owned run, text/live/rich cell results and sanitized lifecycle errors |
| POST | `/api/projects/:id/execution/runs/:run_id/stop` | `{command_id, runtime_epoch, force}`; owner/editor only |
| POST | `/api/projects/:id/execution/restart` | `{command_id, sheet_id, runtime_epoch}`; epoch may be null for no worker |
| GET | `/api/projects/:id/execution/commands/:command_id` | accepted execution receipt or unknown |
| GET / POST | `/api/projects/:id/memberships` | list / grant or update `{account_id, role}` |
| DELETE | `/api/projects/:id/memberships/:account_id` | revoke (204) |
| POST | `/auth/github` | GitHub authorization URL, or HTML redirect |
| GET | `/auth/github/callback` | resolve account, rotate session, redirect |
| POST | `/auth/logout` | destroy session (JSON 204, HTML redirect) |

Unsafe requests require the same origin and `X-CSRF-Token` from the readable
`orbit-csrf` cookie. Parameter schemas reject unknown fields (400); domain input
validation returns 422. Cookie sessions/bootstrap/API responses remain private
and uncacheable. Application assets stream through Orbit's `StaticFiles`.

## Shared core and desktop

The path dependency is `../../packages/notebook-core`. An optional
`NOTEBOOK_CORE_ROOT` constructs `notebook.core.client.Client` for the local agent
socket. `backend/notebooks.s` enforces the current account/project ACL before
every privileged call, supplies the internal core ID and returns only browser
DTOs. It reuses `project.get`, `project.put` and `revision.get`; no second document
store or evaluator is implemented. Missing/unreachable core returns a sanitized
503; a stale revision returns 409 without overwriting the saved document. HTTP
bodies are bounded at 112 MiB for encoded imports and the document at 7 MiB.
Saves preserve files from the exact base revision and apply validated member
changes within the bundle limits; the browser cannot select server paths.

`backend/execution.s` applies project ACL before every execution call and verifies
each run's trusted core project before read/Stop/receipt presentation. It reuses
`run.start`, `run.stop`, `run.get`, `run.registry`, `runtime.restart` and
`receipt.get`; exact revision and epoch checks remain in core. Responses whitelist
public fields, excluding core project/runtime IDs, worker PIDs, execution
documents, presentation paths, services and agent-global event counters. Cell
output is escaped text, never rendered as HTML. There is no new evaluator,
worker scheduler, filesystem route or grant escalation in the web adapter.

After authorization, `Client.presentation_bytes` reads only that run's terminal
or live artifact under its configured core root, rejects symlinks and applies
the shared 128 MiB binary limit. `notebook.core.host.presentation_snapshot` uses
the existing validated native codec and exports only inert rich fields.
`backend/results.s` validates and projects tables into typed text (including int64),
whitelists PNG/JPEG/table/plot output and bounds the rich DTO at 32 MiB. The
browser retains at most three run-detail snapshots. Missing/corrupt/oversized
rich data leaves text and cell errors available with a visible notice. All
reads still check current project/run ownership; no artifact paths cross HTTP.

The common evaluator also resolves installed source/bytecode `notebook.ui`
helpers alongside its native Stopwatch namespace, using the configured package
resolver. The durable worker uses the project's installed package home;
opening/loading/saving never installs packages or grants native trust. This
fixes DataTableView execution in durable server projects without editing their
saved documents or adding directory dependencies.

Start the durable agent independently from the repository root, then point the
web backend at the same absolute, short state directory:

```sh
build/sputnik-notebook-remote --mode agent --root /absolute/short/core-state \
  --worker "$PWD/build/sputnik-notebook-worker" \
  --sputnik "$PWD/../sputnik-lang/build/sputnik"
```

The web application never starts scheduling, cleanup or execution on load/save.
The existing agent owns its services and worker lifetime; restarting the web
backend does not own or terminate that agent. Catalog metadata and core revisions
are separate stores, so initialization is an explicit recoverable operation.
Catalog project titles/timestamps remain catalog metadata; document title and
revision belong to the notebook itself.

Electron/native local mode opens local `.sputnikbook` documents directly through
the common core. It does not require this web Account, a server Project, GitHub
login or automatic upload. Import Notebook explicitly uploads a copy of a chosen `.sputnikbook` folder or
ZIP into a new server project. Export saved / Export draft download a
`.sputnikbook.zip`; extract it to open the enclosed directory in the desktop app. Orphan cleanup belongs to a separate future
background process; this application starts no GC and does not alter the
existing remote agent's optional cleanup.

## Production and checks

```sh
npm run build --prefix frontend
../../../sputnik-lang/build/sputnik build backend/main.s -o build/native/notebook-web \
  --target native --require-full-native \
  --grant net.listen --grant net.connect --grant random.secure --grant time.now \
  --grant fs.read --grant fs.write --grant fs.metadata --grant ffi
```

Run the binary **from this directory** with independent persistent
`ORBIT_SESSION_SECRET` / `ORBIT_CSRF_SECRET` of at least 32 bytes, GitHub credentials,
`ORBIT_ORIGIN=https://your-host`, and a writable `NOTEBOOK_WEB_DATABASE` path.
`--behind-proxy` explicitly trusts one loopback forwarding hop. Serve
`frontend/dist/assets` at `/assets/` through the reverse proxy, keep the Vite
manifest private, and proxy other requests to Orbit. The Node edge in
`tools/smoke_server.mjs` is test tooling, not a production deployment server.
The [operator guide and nginx example](deploy/README.md) include the required
Host/provenance rules, upload envelope, independent Core lifetime, persistent
stores and release ordering. The [production probe](tools/production_probe.mjs)
checks the actual main/Core pair locally with a disposable signed session; live
GitHub consent, nginx/TLS and external deployment still need acceptance.
The palette-transfer browser check uses the test-only native probe built below
and Python 3's standard-library ZIP tooling; neither is a production dependency.

```sh
node tools/models_test.mjs
node tools/models_test.mjs --native
node tools/main_test.mjs
node tools/main_test.mjs --native
node tools/inputs_test.mjs
node tools/telemetry_test.mjs
node tools/displays_test.mjs
node tools/boards_test.mjs
node tools/board_editor_test.mjs
node tools/rich_text_test.mjs
node tools/runtime_observation_test.mjs
node tools/process_cleanup_test.mjs
make -C ../.. build/notebook_web_transfer_probe
node tools/parity_inventory.mjs
../../../sputnik-lang/build/sputnik run test/board_execution_test.s --grant ffi
cd frontend
npx playwright install chromium
npm run test:browser
ORBIT_E2E_MODE=development npm run test:browser
cd ..
node tools/execution_lifecycle_test.mjs
```

For full-native browser tests, first build `test/app_fixture.s` with the same
flags into `build/fixture-native/fixture`, then run
`ORBIT_E2E_NATIVE=1 npm run test:browser` from `frontend`. Set
`PLAYWRIGHT_BROWSERS_PATH` if using a shared browser installation. An existing
Chromium executable can also be selected with `PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH`. The fixture is
test-only and must not be deployed. Tests cover concurrent first sign-in,
identity precision, database constraints/rollback, reopening/migration integrity,
SSR/Vite assets, project UI, two-account ACL, revocation, CSRF and logout.
`frontend/test/notebook.spec.ts` adds real-core coverage for inert initialization,
cell/sheet editing and persistence, concurrent editors, lost-response replay,
ACL/validation, preservation of bundled files/formatting/extra fields and
responsive editor/unsaved-navigation behavior.
`frontend/test/execution.spec.ts` adds real execution, live output, history and
source provenance, cancellation/restart/epoch protection, reload/closed-tab
reattachment, accepted-response loss and exact explicit retry, runtime ACL,
live role changes, DTO boundaries and background-task failure. The standalone
lifecycle check restarts only the HTTP process during a run, then kills its own
disposable worker to verify interruption and explicit restart recovery.
`frontend/test/rich-results.spec.ts` checks exact int64 sorting/exports, live
table replacement and failure preservation, real plot zoom/pan/PNG export,
responsive tables/plots, raster collections, viewer ACL and corrupt/symlinked
artifact fallback. Its DataTableView fixture installs the canonical table class
source into a disposable project; audio helpers are outside this slice.

Path dependencies remain editable; `sputnik pkg lock backend/main.s` records
the package graph without freezing local source files. Nothing in this scaffold
publishes packages or changes remote core deployment.

Backend test entries live in `test/`: `model_test.s` exercises the catalog and
`app_fixture.s` starts the application with the offline OAuth provider. They use
relative source imports (`from "../backend/models" import Account`), so tests
need no copied application files or separate module manifest.

## Modules, files, imports and packages

Modules & Files in the notebook sidebar opens bundled sources and resources.
New module creates `modules/name.s`; Auto-import imports its exported names
into sheets. Save commits file edits together with cells. Save module changes
and restart a previously used sheet worker before executing them. Resource
uploads accept project-relative paths; editable UTF-8 is limited to 1 MiB,
individual members to 16 MiB, and the bundle to 2048 members / 64 MiB of data.
Unknown document fields and int64 metadata are retained. Rename or move keeps
binary bytes, rejects destination collisions and stages both member changes in
one Save. Renaming a module derives its filename from the new name, replacing
spaces and hyphens with underscores. It updates its package declaration, auto-imports and
board action/service references; imports in other source and resource paths need
manual updates. Deleting a sheet asks for a replacement controller for linked
boards and preserves their component bindings for review.

Import Notebook inspects a chosen `.sputnikbook` folder or ZIP before the
explicit Import as new notebook action. It never executes imported code.
If a response is lost, Check import status or reselect the same original file;
the command resumes the same catalog project. Saved exports include all bundled
members, including authored hidden files, and a `project.json`. Revisions lets
readers export older immutable revisions. Export draft keeps unsaved source/file
changes separate from the current server head. Installed server packages and
prepared environments are independent of the source archive.

Dependencies lists installed Sputnik packages and operation history. Only the
owner can install/remove packages using the server-configured registry. Shared
server storage is the default. A matching installed build can be reused without
downloading it. Choose **This notebook only** to install a private copy. Native
installation/build flags require the operator to start `backend/main.s` with
`--allow-native-packages`; the default is disabled. The package build shows its
declared worker grants and the grants needed for native loading. **Add package
grants…** opens a draft for the current sheet with the operator-allowed grants
selected. Worker settings support searching the operator's grant catalogue and
require confirmation before resetting the worker. Python/Ruby manifests can be edited as bundled files;
environment preparation and per-sheet worker settings are available in Environments… (see below).

The notebook-core host extension requires libarchive headers and `-larchive`
(install libarchive through the host package manager when building). Archive
validation never extracts user ZIPs onto the server filesystem.

`frontend/test/sources-transfer.spec.ts` exercises atomic source/binary changes,
module execution, immutable history, draft export, ZIP/folder validation,
int64/hidden-member preservation, current ACL, import/save/package lost-response
recovery and responsive themes. Its registry is a disposable loopback fixture,
enabled only by browser test configuration. `test/bundle_test.s`,
`test/sources_test.s` and `test/transfer_test.s` provide focused codec and
service checks. They require `fs.read`, `fs.metadata`, and `ffi` grants.

## Project and cell parameters

Project Inputs… edits shared definitions read by `notebook.input("name")`.
Components… in a code-cell header edits local definitions read by
`notebook.cell_input("name")`, with Input or Parameter Form controls before/after
code. Update notebook draft stages these settings; Save notebook persists them
without executing code. Cell interfaces upgrade to schema 4 and keep unknown
metadata and existing display settings. Use the cell's Manual/Watch selector to
save its execution mode.

The parameter panels show accepted values independently from saved defaults.
Edit a form and choose Apply to publish its complete batch. Watch consumers in
already initialized sheet workers recompute; Manual consumers become stale until
Run. Apply to an uninitialized sheet stores values without creating a runtime.
Defaults stages saved defaults, while Reset to current discards the form draft.
Conflicting or invalid changes keep drafts. Config controls submit exact text;
the shared core validates JSON/YAML/TOML syntax and constraints atomically.
Int64 values and typed Range endpoints do not pass through JS floating-point
conversion. Native controls for choices, steppers and range slider domains are
supported. All web controls use explicit Apply.

Accepted-state reads and receipts require current project read access; Apply
requires execution access. Updates carry the saved revision and accepted-state
version. Active/interrupted runtimes, stale versions and unsaved source changes
block application. Pending commands survive reload in per-account/project
session storage and are checked through server receipts. Only Retry pending
input command repeats an unaccepted command; no automatic mutation is performed.
Runtime values persist with the independent agent and do not overwrite authored
defaults or source exports.

Each Apply accepts up to 128 values / 8 MiB. Project panels page larger definition
lists in batches of 128. A scoped preview is limited to 8 MiB and the visible
browser parameter cache to 32 MiB. Authored Metric/Live Chart/Table/Image rendering
and settings, board viewing/designer and actions/services are implemented;
Audio output, managed file/audio/image acceptance, microphone capture and image/
audio annotations are implemented, together with shared selection, dates and presets.
Unsupported saved configuration is retained.

`frontend/test/inputs.spec.ts` covers real Watch/Manual behavior, cold Apply,
Int64, local scope, stale versions, frozen run provenance, busy workers, current
ACL/revocation, lost responses/reload/explicit retry, inert definition editing,
typed controls/config batches, metadata retention and responsive themes.
`node tools/inputs_test.mjs` checks exact value conversion, Int64 stepping and
integer/decimal Range round trips.

## Hierarchical resource policy and temporary previews

The catalog binds each core project to its authenticated owner. The server applies
Core → user → profile → project/session ceilings, with 100 retained runs by default.
Resource limits… edits the eight native `resource_policy` fields in the notebook
draft: run count/age, notebook and snapshot storage, disk reserve, revision tail,
per-run time and cumulative notebook time. Unchecked fields inherit. Update notebook
draft and Save notebook use the existing revision/conflict/receipt path, preserve
other authored data and never start code. Cancel leaves the original intact.
Defaults and saved effective limits appear separately. The server's launch option
determines whether book values replace app defaults or combine restrictively;
explicit operator limits always apply. The web editor does not change server/app
defaults or enable the override mode.

Execution status shows authoritative consumed/remaining time, including tighter
owner/Core budgets. Exhaustion disables new Run/Action/Periodic starts; Stop,
Pause and result inspection remain available. Storage usage and retained counts
load on demand in Resource limits…; expensive archive accounting is not added to
execution polling. `GET /api/projects/:id/resources` authorizes readers and emits
only project storage and public limits. Numeric limits/counters cross as exact
decimal strings, with no private Core identities, paths or other projects' storage.

Temporary preview… explicitly opens an isolated, disposable copy of the saved
notebook with public limits: **at most 60 seconds accumulated wall time**, also
capping any one run at 60 seconds. Book settings, app defaults and a replaced
public profile cannot lift this ceiling. Owner/server quotas may reduce it.
The preview supports sheet code/text edits, explicit Save copy/Run All, Stop/
Force Stop and text/rich results. Existing bundles supply dependencies; boards,
parameter controls and installation remain in the full workspace. Accepted work
and uncertain Save/Run/Stop replies use receipts and explicit retries, without
automatic replay. Closing, hiding or losing the connection discards/freezes the
copy; reconnect requires Open fresh preview. Tokens are kept only in memory,
and a short independent Core lease cleans abandoned data. Opening a new copy
does not reset persistent owner/Core counters.

This preview uses the current authenticated template ACL. The public entry
opens the full notebook editor on a temporary copy of an operator-pinned
publication. Guest copies share cookie and IP budgets and can be exported
before closing. See the operator setup linked above.
See [policy configuration and API](../../docs/engineering/notebook-resource-policies.md).
Run `node tools/preview_test.mjs` and `node tools/preview_test.mjs --native` for the
real-core authorization, isolation, template preservation and visitor quota tests.
`node tools/resource_policy_test.mjs` and `frontend/test/resources.spec.ts` cover
exact quota editing, inheritance, actual time/storage rejection, preview isolation,
receipt recovery, Stop, CSRF and account boundaries.


### Audio annotations and completed publications (Stage 4g.2.3)

Audio Annotator in Board Designer supports an owned file, an Audio Input channel,
or a completed cell AudioTrack. Native class/attribute definitions and separate
track/segment transcript Allow/Require settings are editable. The runtime dialog
provides frame/second/Hz segments, waveform, plasma STFT spectrogram, channel/mix,
FFT/dB range, sample zoom/pan, selection playback, Undo/Redo, JSON export and
separate Apply/Discard. Core supplies exact source-rate PCM; browsers do not
resample annotation identities. PCM WAV works portably; other formats use the
Core host's bounded system decoder. Active streams remain read-only.

Image/Carousel also annotate their latest completed published channel. The source
snapshot stays frozen while editing, and Core rechecks current source identity,
schema, revision/input version and permissions on Apply. Neither capture,
annotation, decoding nor Apply starts notebook code; Run remains explicit.
Existing effective storage policies and public cumulative 60-second execution
limits remain in force. Shared table selections, Date/time and presets follow in
Stage 4g.2.4. See [verification](../../docs/evidence/2026-10-29/notebook-web-audio-annotations/README.md).


### Shared selections, dates and presets (Stage 4g.2.4)

Data Table can publish an explicit accepted selection using a unique key column.
Apply preserves the original typed key, full row and source-table SHA-256; sorting
and filtering do not change identity. Clear and Reset are explicit. Core rejects
forged/mismatched rows, duplicate/null keys and stale sources. Bound image/audio
components match original encoded asset_id, retain collection contents and never
autoplay a newly selected asset.

Date / Time Input authors a String binding, date/date_time and IANA zone. Runtime
calendar validation includes leap days. Local date/time is converted to UTC;
DST gaps are rejected and repeated hours require an explicit occurrence.
Parameter Presets supports scoped sets, exact comparison and atomic Apply, plus
Capture current, Rename, Delete and bounded JSON import/export. Management stages
a notebook draft; Save persists sets separately from accepted values/defaults.

Initial Stage 4g.2.4 verification used isolated SDK 3eb0f05 because of the then
unresolved namespace/callback compatibility gate. Those historical results remain
in [the original report](../../docs/evidence/2026-10-29/notebook-web-selection-controls/README.md).
The follow-up now runs on the default current SDK b3ed894, with the ORM record
factory retained as an explicit callable reference. No old SPUTNIK override is
needed. Smoke caches include the compiler binary hash; concurrent native builds
should use distinct SPUTNIK_VM_CACHE directories. See the
[current SDK integration verification](../../docs/evidence/2026-10-30/notebook-web-current-sdk/README.md).


## Environments and worker settings — Stage 4h.1

Environments… lists up to 100 saved Python/Ruby environment generations. Opening
it does not install packages, execute cells or reset a worker. Only the owner can
prepare/retry the saved manifests or change a sheet's settings. Preparation is
disabled by default; the operator enables it with --allow-environment-preparation.
Dependencies and source files remain in their existing dialogs.

The operator's --web-worker-grants comma-separated capability names define the
editable grant list (empty by default). For example time.now,random.secure permits
those two wildcard grants. The browser cannot author grant targets or absolute
server paths. Other operator-configured grants remain private and are preserved.
Environment choices resolve saved manifests or a ready generation belonging to
this project. An existing custom server directory can be kept without exposing it.

Review settings and reset… requires explicit confirmation. Core checks the saved
revision, settings version and runtime epoch, refuses an active controller/action/
service run, pauses services and discards the worker's variables. The next Run is
explicit. Polling preserves drafts; Reload settings explicitly rebases them.
Preparation creates an immutable generation and does not change existing workers.
Retries use Core's retry contract. Lost responses check durable receipts; a manual
retry reuses the exact command ID. Read access loss closes the dialog.

Browser DTOs contain generation IDs, language flags, state and fixed diagnostic
summaries. Installer output, interpreter paths, resolved URLs, specs and private
Core IDs are not exposed. Full installer logs remain operator-only. Archive
storage admission applies to new preparation/settings receipts; installed
environments remain outside the logical archive quota, as documented in the
shared resource policy. Actual filesystem free-space checks remain authoritative.
Worker reset never resets cumulative execution accounting. Public temporary
copies cannot install environments or change worker privileges and keep the
60-second cumulative/per-run ceilings.

| Method | Route | Purpose |
| --- | --- | --- |
| GET / POST | /api/projects/:id/environments | Safe generations / explicit saved preparation |
| GET | /api/projects/:id/environments/:environment | Safe diagnostics |
| GET / PUT | /api/projects/:id/worker-settings | Read settings / confirmed reset with CAS |
| GET | /api/projects/:id/runtime-commands/:command | Durable command status without private payloads |

[Verification](../../docs/evidence/2026-10-30/notebook-web-environments/README.md).
That stage report records the original SDK baseline; the later
[current SDK follow-up](../../docs/evidence/2026-10-30/notebook-web-current-sdk/README.md) supersedes its startup qualification. Expanded run inspection/comparison is implemented below as Stage 4h.2.


## Run snapshots and experiments — Stage 4h.2

Snapshots and experiments… opens from Run history; Run History and Experiment
Compare board components open the same inspector. The paginated list includes
retained runs from removed sheets through All retained sheets. Opening, comparing,
exporting and reviewing never starts execution. Active runs cannot be read as
immutable snapshots. Final failures, force-stop and interrupted states remain
inspectable while their retained record exists.

The public snapshot contains exact project/local scalar JSON, executed cell
sources, module/revision references, bounded rich output, and frozen opaque
source/environment/settings fingerprints plus installed package identities.
Private worker directories, grants, PIDs, Core project IDs and installer logs stay
on the server. Module contents/input assets are in the retained revision export;
a snapshot does not restore an environment or a worker heap. Pre-existing runs
without frozen provenance show that it is unavailable. Web snapshots fit 48 MiB.

Title and Pin are separate mutable metadata. Writes require source write access,
a fresh metadata version and durable command ID. Up to ten pins are supported.
Pins and current presentations survive retention and consume the same effective
archive/run quotas; they can prevent a new Run at quota exhaustion. Delete needs
explicit confirmation and refuses active, pinned and current presentations.
Deletion expires associated Run receipts without allowing replay; cumulative
execution usage stays charged. Lost metadata replies use receipt inspection and
an explicit retry with the same command ID. Revocation removes inspected content.

Compare selects baseline/candidate and compares project/local inputs, metrics and
elapsed time. Deltas use exact decimal/Int64 arithmetic, including exponent tokens.
CSV exports quote text and neutralize spreadsheet formula prefixes. Source and
module/resource fingerprints identify changed inputs to the experiment.

Restore scalar parameters reviews one project or cell scope. File/media bindings
are excluded. Current definitions/types/bounds/date controls are validated before
the existing atomic Apply, revision/input-version CAS and receipt recovery. This
can trigger Watch in initialized workers; the review says so before acceptance.
Stale reviews retain their values and require reset. Authored defaults and source
text are separate. Cell scopes outside the active sheet require switching to that
sheet so its current accepted values can be loaded. Viewer inspection/export is
allowed; metadata mutation and restore are denied.

| Method | Route | Purpose |
| --- | --- | --- |
| GET | /api/projects/:id/execution/runs/:run_id/snapshot | Retained immutable public snapshot |
| POST | /api/projects/:id/execution/runs/:run_id/history | Update labels/pin or confirmed delete with metadata CAS |
| GET | /api/projects/:id/history-commands/:command | History command receipt status |

[Verification](../../docs/evidence/2026-10-30/notebook-web-run-history/README.md).
The [current SDK follow-up](../../docs/evidence/2026-10-30/notebook-web-current-sdk/README.md) supersedes that report’s historical web SDK qualification. The next plan slice is the
cross-platform example/parity and deployment-readiness audit.

Releasing a history pin and deleting an eligible retained run remain available
when the archive quota is exhausted, so protected history can be freed.


## Runtime observations — Stage 4i.2

All 33 persisted Swift palette kinds now have web renderers. Config Editor and
Image Annotator remain configurations of Input and Image. This records kind
coverage; browser authority and bounded snapshot semantics still differ from a
local Swift process.

Status / Alert targets the controller sheet, a cell, an Action, a Periodic Work
service or the runtime. It displays accepted server state, errors, stale results,
restart requirements and authoritative computation exhaustion. Runtime status
shows exact charged/remaining time and the effective per-run ceiling. Restart
does not clear computation accounting. Open source uses known controller cells
or the target's authored module, without executing anything.

Task Monitor reads the same validated binary presentation as Swift. At most 512
records expose exact string identities/parents, state, errors, elapsed time and
trusted cell/line references, plus CPU/resident-memory samples and omission
counts. Worker file names, paths and process IDs are omitted. Errors only is a
local filter. Historical/source/environment/worker changes mark observations
stale; loss of project access clears loaded results. A worker without telemetry
shows unavailable rather than inventing task state.

Artifact Browser accepts captured result records with path, name and optional
caption, bounded to 128 references. Preview and Save copy read only a validated
relative member of that result's immutable saved revision through the existing
ACL-checked Core file API. A newer source bundle does not retarget old artifacts.
External paths, traversal and files created outside the saved bundle are
unavailable. Preview is bounded text; Save copy preserves the original bytes.
No generated-file capture or server filesystem browsing is implied.

Result Inspector uses native captured Inspect/Pretty formats, preserving Int64
text. Table mode retains table search/sort/export. Find performs literal,
non-overlapping Unicode matches with case selection, previous/next navigation
and a 4,096-match bound; wrapping, clipboard and text download are local. Search
covers captured text only, with native truncation notices. Log Viewer coalesces
adjacent streams within 64 KiB, filters by stream/substring and copies/exports
captured matching events. Rendering is bounded to 4,096 log events; original
omission markers remain visible. Neither inspector queries arbitrary worker
locals or evaluates source.

The palette/designer stages these tools through ordinary notebook Save and
preserves unknown settings. Viewing, changing filters, copying, exporting and
previewing never starts a run, worker or environment.

The current SDK reports Sputnik 1.0.0. Existing legacy locks need an explicit
language-version migration using sputnik pkg lock backend/main.s here and
sputnik pkg lock sputnik.build.json from tools/notebook-remote. Normal builds
and test runners use the sibling SDK without a compiler override.

The Playwright smoke runner keeps its owned provider/Vite/backend/Core services
in the runner process group and requests graceful SIGTERM before forced teardown.
An interrupted group is terminated together; Core workers exit when the agent's
channels close. `node tools/process_cleanup_test.mjs` checks both SIGTERM and
SIGKILL with an active real worker in VM/development and native/production.
This applies to test-owned services. Production Core keeps its independent
lifetime when only the HTTP process restarts.

[Verification](../../docs/evidence/2026-10-31/notebook-web-runtime-observations/README.md).
