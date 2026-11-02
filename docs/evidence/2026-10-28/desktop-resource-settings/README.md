# Desktop resource settings — 2026-10-28

Current working tree, macOS arm64. Changes span the notebook repository and the
shared document editor in `sputnik-lang/tools/isputnik/tabs.{h,cpp}`. Pre-existing
changes in both repositories were preserved. No production server was changed.

Verification:

- Swift model: book policy persistence, independent second book, app ceiling,
  local retention, pinned snapshots, actual Force Stop at the configured time,
  cumulative usage across reopen, plus all existing model regressions.
- Native UI integration: app preferences persist in their own UserDefaults domain;
  remote execution, reconnection, grants, conflicts and receipt recovery work.
- 11 policy integrations include app/book/server ceiling composition and rejection
  of forged identity/admin fields at the desktop gateway endpoint.
- 48 existing remote integrations and remote UI/work integrations passed.
- Packaged app smoke and final UI build passed. Core direct API is checked in VM
  and full-native; see `core-api.log`.

Commands from the notebook repository:

```sh
make -j4 build/notebook_macos_model_tests
build/notebook_macos_model_tests
make -j4 test-notebook-core test-notebook-policy test-notebook-remote test-notebook-remote-ui test-notebook-remote-work notebook-macos
python3 tests/notebook_macos_ui_smoke.py 'build/Sputnik Notebook.app/Contents/MacOS/SputnikNotebook'
```

`manifest.json` fingerprints implementation and regression sources. Linux was not
executed. Existing release-signing/minimum-OS constraints from the audit remain.
