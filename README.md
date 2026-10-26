# Sputnik Notebook

A standalone technical-preview graphical application for Sputnik, with a native
macOS interface. The curses console `isputnik` is built and distributed by
[`sputnik-lang`](../sputnik-lang/README.md). Both hosts use `.sputnikbook`
projects and the language-owned session/engine sources.
Modules accept `.s`, `.spu`, and `.sputnik`; newly created modules use `.s`.
The bundled compiler and isolated workers support runtime `%for` in string-tag
templates. External `.html.sv`, `.sql.sv`, and `.cmd.sv` files use `@template`
declarations and `source_formats` in a build manifest; notebook cells do not
implicitly load filesystem views. See the
[external template contract](../sputnik-lang/docs/engineering/external-templates-v1.md).

## Build

Place this application next to `sputnik-lang` and run:

```sh
make -j4
open 'build/Sputnik Notebook.app'   # macOS
```

Direct development launches via `build/notebook-macos/SputnikNotebook` also work:
the build places a `sputnik-notebook-worker` link and `AppIcon.icns` beside that
executable. Both direct launches and the `.app` bundle use the Sputnik notebook
icon in the Dock; Finder also uses it for the `.app`.

The start screen lists **Recent Notebooks** below **New Notebook** and
**Open Notebook**. Click a name to reopen its `.sputnikbook`; the folder path
distinguishes projects with the same name. The list uses the macOS recent-document
history, persists across launches, and hides packages that are no longer available.

All GUI execution uses isolated workers by default: sheets, module Run,
automatic Watch updates, board inputs and Periodic Work share live progress
and Stop / Force Stop. No execution flag is required. Opening, editing and
saving remain inert host operations.

You can switch between sheets, modules and boards during execution. A spinner
and **RUNNING** badge mark the current cell. **Show Running Cell** opens its sheet,
expands the source and scrolls to it, including when you are viewing a board.

The last successful cell result remains inspectable after edits or a failed
rerun, labelled **PREVIOUS RUN RESULT**, until the notebook or worker restarts.
Use the gear beside **Worker Settings…** to disable **Keep results from the
previous run** for this sputnikbook. The option is saved in `project.json`;
result snapshots stay in memory. See the [result viewer](docs/engineering/notebook-result-viewer.md).

Cells display a running execution timer and keep the final duration. The board
**Stopwatch** component measures a code block with `from notebook.ui import Stopwatch`
and `Stopwatch.measure("channel"): …`, preserving its return value. See the
[timing API and sample](docs/engineering/notebook-stopwatch.md).

Use **Worker Settings…** beside **Servers…** to configure explicit runtime
grants for the selected sheet and execution host, for example
`process.spawn=/usr/bin/nvidia-smi`. Enter one grant per line and choose
**Apply and Restart Worker**; the next Run uses the new policy. Remote grants
are stored on the server, local grants in private app settings. See the
[worker settings guide](docs/engineering/notebook-remote-ui.md#worker-settings-и-runtime-grants).

The icon's vector artwork and exported PNG/ICNS live in
`tools/notebook-macos/Assets`. To regenerate the exports on macOS, run:

```sh
xcrun swift -module-cache-path build/notebook-macos/swift-cache \
  tools/notebook-macos/Assets/generate-icon.swift tools/notebook-macos/Assets
```

The Makefile builds the language runtime library as a dependency and compiles
its shared session/engine sources for the GUI. macOS requires Xcode command-line tools and
macOS 14 or newer (bundled dependencies can raise the minimum OS version).
Linux builds the isolated worker; OpenSSL and LibYAML development packages are required.
The graphical application does not link ncurses. The compiler is C++17.

Override `SPUTNIK_DIR`, `SPUTNIK_BUILD_DIR` and `BUILD_DIR` for another checkout
or output directory. `make test-core` runs the headless C++ tests. Worker and
native UI checks are explicit: `make test-notebook-worker`,
`make test-notebook-macos`. Build and test the terminal console in `sputnik-lang`
with `make` and `make test-isputnik-tui`.

Choose Light or Dark in `Sputnik Notebook → Settings…` (`⌘,`). The theme
applies immediately and is remembered between launches. **Appearance → Color
Scheme** offers the original **Sputnik · Default** palette and thirteen presets
with color previews: Espresso & Coral, Sea Glass, Syrah & Blue Glow, Charlock,
Lunar Silver, Olive Leaf, Persian Plum, Tangerine & Teal, Autumn Ember, Moss &
Ivory, Blackberry & Honey, Lavender Haze and River Jade. Each works with Light
and Dark; the choice updates open notebooks immediately and is saved across
launches. Existing installations keep their current colors until a preset is chosen.

**Settings… → Code Editing → Replace Greek letter names with symbols** is on
by default. In code cells and modules, type a complete name followed by Space,
Enter, Tab or token-ending punctuation: `alpha` → `α`, `Delta` / `DELTA` → `Δ`.
The space, newline or indentation is preserved. All 24 Greek letters are
supported. Strings, comments, longer identifiers such as `alpha_value`,
pasted code and existing files keep their spelling. Undo restores the original
name. Disable the option to keep English names; the choice is saved across launches.

Map keys follow the same token rules: `{"alpha": alpha}` becomes `{"alpha": α}`,
while `{alpha: alpha}` becomes `{α: α}`. Quotes and method suffixes `?` / `!`
do not trigger replacement.

To enter `α_1`, type `alpha`, press Space, delete that space, then type `_1`.

Optional sibling packages include `plot` and `sputniktorch`. See the
[macOS guide](docs/engineering/notebook-macos-v1.md),
[project format](../sputnik-lang/docs/engineering/notebook-project-v1.md),
[directory dependencies](../sputnik-lang/docs/engineering/notebook-dependencies-v1.md), and
[MNIST showcase](docs/engineering/notebook-mnist-showcase.md).
The board palette includes [Image and Image Carousel](docs/engineering/notebook-board-images.md)
with fit/fill/auto-height sizing and captioned images published from Sputnik code.
The **Annotations** palette tab groups **Image Annotator** and **Audio Annotator**.
Image Annotator starts with image loading and annotations enabled; existing Image
and Image Carousel components also support **Enable image annotations** in the inspector.
The categorized palette also includes [Periodic Work](docs/engineering/notebook-periodic-work.md),
a nonvisual service that calls an exported module function on a schedule.
[Tabs](docs/engineering/notebook-boards-v1.md#tabs-and-panel-grids) contain independently
editable panel grids, including nested layouts.
[Shared components (P00)](docs/engineering/notebook-shared-components-p00.md)
place Result Inspector and Progress in the board grid and add Text Cell with
rich-text/Markdown source editing and rendered `{{name}}` interpolation.
[P0 components](docs/engineering/notebook-p0-components.md) add input styles,
atomic Parameter Form Apply, Data Table and subtle category colors in Design.
Try `tools/notebook-macos/Samples/Parameters and Tables.sputnikbook`.

[Config Editor](docs/engineering/notebook-config-editor.md) adds compact JSON,
YAML and TOML components with a modal source editor, validation, Import/Export
and Apply/Reset on boards, cells and Parameter Forms. Read parsed values with
`notebook.config` / `notebook.cell_config`, passing `format: :yaml` or `:toml`. Try
`tools/notebook-macos/Samples/Config Editor.sputnikbook`.

[Cell components](docs/engineering/notebook-cell-components.md) attach local Input /
Parameter Form controls and Live Chart, Metric, Image and Data Table displays to
sheet code cells. Use **Components…** in a cell header and read local parameters
with `notebook.cell_input("name")`. Explicit post-cell components enable source
collapsing. Try `tools/notebook-macos/Samples/Cell Components.sputnikbook`.
Remote execution also supports component editing and atomic cell-parameter Apply;
`tools/notebook-macos/Samples/Remote Cell Components.sputnikbook` runs without
external dependencies on an updated remote core and worker.

The Sputnik dependency editor looks up a package name in the configured registry,
selects the latest stable version and recommends a compatible build for the
execution machine. Choose another version or build before installing. Backend
and bundle settings come from the selected build; packages such as `sqlite3`
do not need a GPU backend selector. In remote mode, discovery and hardware
checks run on the server. **Choose Folder or .sputnikpkg…** installs a local
source directory or archive as an alternative; remote paths refer to the server.
Native code, source compilation and archives over 64 MiB require explicit opt-in
when the selected build needs them. Installed variants have separate rows and
can be removed independently. Worker FFI grants are configured separately.
See [native installation and exact locks](../sputnik-lang/docs/engineering/package-native-install-v1.md).

New boards use project-wide numbered names (`Board 1`, `Board 2`, …); sheets use
`Sheet 1`, `Sheet 2`, …, with a suggested stable identifier in the creation dialog.
Numbering continues after reopening and after the highest existing numbered name.
Open **Project Inputs** in the sidebar or **Manage project inputs…** in a control's
inspector to create or delete shared parameters. The type picker explicitly lists
**Number (decimal)**, **Integer (Int64)**, **Boolean** and **String (text)**.
Remove a parameter's board bindings before deleting it; deletion saves the
definition change without running cells or saving their source drafts.

Double-click a sheet cell's visible number to view, copy or edit its **Hard ID**.
This permanent numeric ID stays with the cell when it moves; board cell pickers
show it alongside the current number. Saving a new unique ID also updates existing
component bindings and keeps the cell's local parameter values.

[P1 components](docs/engineering/notebook-p1-components.md) add metrics, status,
logs, file input, actions, execution controls, groups, multiple chart series,
artifacts and Parameter Presets. Try `tools/notebook-macos/Samples/Workstation.sputnikbook`.

[P2 components](docs/engineering/notebook-p2-components.md) add run history and
comparison, live logs/tasks, worker CPU/RAM, Range/Date inputs, Split View,
shared table selection and image annotations. Try `Samples/Components P2.sputnikbook`
and `Samples/Selection and Labels.sputnikbook` under `tools/notebook-macos/`.
[Audio](docs/engineering/notebook-audio.md) uses AudioTrack, AudioPlayer, live PCM
streams and an explicit import/record/Apply input.
[Audio Annotator](docs/engineering/notebook-audio-annotations.md) adds waveform
segments, plasma spectrogram rectangles, classes/attributes and transcripts;
try `Samples/Audio Annotations.sputnikbook`. Local checks cover these examples;
remote mode retains the limitations described in the linked contracts.

The [SQLite example](docs/engineering/notebook-sqlite-example.md) connects Data Table
to an external database with read-only queries, SQL pagination, search and summaries.

[DataTableView](docs/engineering/notebook-data-table-view.md) from `notebook.ui`
publishes tables with `notebook.show(view)` independently from a cell's return value.
Objects export CSV/Markdown, and the native table menu copies or saves visible rows.
Try `tools/notebook-macos/Samples/Data Tables.sputnikbook`.

The graphical UI, isolated worker and their tests belong to this app.
The terminal console, reusable notebook engine, sessions and project format
belong to `sputnik-lang`, along with language-level display/input hooks.

The [remote core preview](docs/engineering/notebook-remote-core-p01.md) adds a
server-owned execution agent written in Sputnik, reconnectable HTTP/CLI access
through SSH, saved project revisions and run history. The [macOS interface](docs/engineering/notebook-remote-ui.md)
adds server selection, remote Run, live results and reattachment after closing the client.
Build with `make notebook-macos`; verify with `make test-notebook-remote test-notebook-remote-ui`.
Remote project inputs, idle Watch, board actions and agent-owned Periodic Work
are described in the [remote execution guide](docs/engineering/notebook-remote-inputs-watch-actions.md).
Verify their GUI lifecycle with `make test-notebook-remote-work`.

Python/Ruby worker environments, persistent remote preparation and orphan
collection are described in [Notebook foreign environments](docs/engineering/notebook-foreign-environments.md).
