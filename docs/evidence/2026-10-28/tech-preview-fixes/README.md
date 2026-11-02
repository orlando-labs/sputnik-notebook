# Five tech-preview fixes — validation

Implementation and limits: `docs/engineering/notebook-tech-preview-fixes-2026-10-28.md`.

- `core-worker-remote-tests.log`: final core/worker/native CLI and 48 real remote integration tests.
- `swift-model-tests.log`: final expanded Swift model suite, including cross-document identity and remote recovery fault injection.
- `remote-ui-work-tests.log`: real Swift/native remote reconnect, actions, worker grants and server periodic work, plus app build.
- `bundle-smoke.log`: packaged AppKit/SwiftUI execution, Dock icon and appearance smoke.
- `manifest.json`: SHA-256 hashes of changed implementation/test files and the built executables.

Re-run from the repository on macOS:

```sh
make -j4 test-notebook-core test-notebook-worker test-notebook-remote notebook-macos
make build/notebook_macos_model_tests
build/notebook_macos_model_tests
make -j4 test-notebook-remote-ui test-notebook-remote-work
python3 tests/notebook_macos_ui_smoke.py 'build/Sputnik Notebook.app/Contents/MacOS/SputnikNotebook' --theme-smoke-test
```

All tests use temporary fixture notebooks/agents. The SQLite test holds only the fixture database's writer lock. No production server is contacted. Linux-specific session enumeration is implemented but was not executed in this macOS validation.
