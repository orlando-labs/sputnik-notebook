# Sputnik Notebook

A standalone technical-preview application for Sputnik, with a native macOS
interface and a terminal frontend (`isputnik`). Projects use `.sputnikbook`.
Modules accept `.s`, `.spu`, and `.sputnik`; newly created modules use `.s`.

## Build

Place this application next to `sputnik-lang` and run:

```sh
make -j4
open 'build/Sputnik Notebook.app'   # macOS
build/isputnik --help             # terminal frontend
```

The Makefile builds the language runtime library as a dependency. It does not
build the language test suite. macOS requires Xcode command-line tools and
macOS 14 or newer (bundled dependencies can raise the minimum OS version).
Linux builds the terminal frontend and isolated worker; ncurses and OpenSSL
development packages are required. The compiler is C++17.

Override `SPUTNIK_DIR`, `SPUTNIK_BUILD_DIR` and `BUILD_DIR` for another checkout
or output directory. `make test-core` runs the headless C++ tests. Worker and
native UI checks are explicit: `make test-notebook-worker`,
`make test-notebook-macos`, `make test-isputnik-tui`.

Optional sibling packages include `sputnik-plot` and `sputniktorch`. See the
[macOS guide](docs/engineering/notebook-macos-v1.md),
[project format](docs/engineering/notebook-project-v1.md),
[directory dependencies](docs/engineering/notebook-dependencies-v1.md), and
[MNIST showcase](docs/engineering/notebook-mnist-showcase.md).

The UI, notebook engine, worker, tests and documentation belong to this app.
Language-level display/input hooks remain in the Sputnik runtime.
