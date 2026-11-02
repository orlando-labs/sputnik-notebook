# Desktop defaults and explicit remote override mode — 2026-10-28

Current working tree, macOS arm64. This supersedes the app-ceiling semantics in
`../desktop-resource-settings/`. Pre-existing changes were preserved. No production
service or user notebook was modified by the tests.

The Swift app stores defaults independently from book overrides; a local book can
raise or lower selected values. Remote Core remains restrictive by default. Only
`--allow-book-policy-overrides` on agent startup, or the explicit Core constructor
option for a local adapter, permits replacement of app/built-in defaults. Explicit
operator Core/user/profile/project quotas remain hard ceilings, including the
public profile's temporary persistence and 60-second budget. Desktop transport
sends raw app defaults, with book policy read from the current authored revision.
The process mode is advertised in health/status and cleared in the UI on detach.

Verified:

- 12 real-core policy integrations passed: flag off/on/off over the same durable
  state, existing declarations after restart, count/free-space/run-time inheritance,
  rejection of unsupported desktop fields and retained operator/public bounds.
- Direct Core API passed in VM and full-native, including a local run beyond the
  app's 1-second default under the book's 5-second limit.
- Swift model suite passed: independent books/preferences, saved raised limits,
  disk reserve replacement, actual execution beyond app defaults, inherited time
  limit Force Stop, pinned history and cumulative usage across reopen.
- 48 remote regressions passed.
- Swift remote UI suite passed twice, with the startup flag off and on. It checks
  raw app/book transport, displayed server mode and clearing that mode on detach,
  plus reconnect, conflicts, grants and receipt recovery. Explicit policy editing
  preserves unrelated large-integer metadata; later Run/reconnect preserves the
  saved post-settings document byte-for-byte.
- Remote work integration and packaged-app Dock/UI smoke passed.
- Native remote, Swift test executables and `build/Sputnik Notebook.app` built.

Core checks:

```sh
node tests/notebook_core_test.mjs --native
python3 tests/notebook_policy_tests.py --core "$PWD/build/sputnik-notebook-remote" --worker "$PWD/build/sputnik-notebook-worker"
python3 tests/notebook_remote_tests.py --core "$PWD/build/sputnik-notebook-remote" --worker "$PWD/build/sputnik-notebook-worker"
build/notebook_macos_model_tests "$PWD/build/sputnik-notebook-worker"
python3 tests/notebook_remote_ui_tests.py --test "$PWD/build/notebook_macos_remote_tests" --core "$PWD/build/sputnik-notebook-remote" --worker "$PWD/build/sputnik-notebook-worker"
python3 tests/notebook_remote_ui_tests.py --test "$PWD/build/notebook_macos_remote_tests" --core "$PWD/build/sputnik-notebook-remote" --worker "$PWD/build/sputnik-notebook-worker" --allow-book-policy-overrides
python3 tests/notebook_remote_ui_tests.py --test "$PWD/build/notebook_macos_remote_work_tests" --core "$PWD/build/sputnik-notebook-remote" --worker "$PWD/build/sputnik-notebook-worker"
python3 tests/notebook_macos_ui_smoke.py 'build/Sputnik Notebook.app/Contents/MacOS/SputnikNotebook'
```

There is no standalone Electron application in this checkout; its supported Core
construction mode is covered directly. Linux was not run. Existing packaging
minimum-OS/signing constraints remain outside this follow-up.

`manifest.json` fingerprints the 17 implementation, regression and documentation
sources. Adjacent logs contain successful final checks and builds.
