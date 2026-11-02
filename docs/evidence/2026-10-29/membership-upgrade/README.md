# Membership dependent rebuild — 2026-10-29

Language `7f2665b8d1538bf6b4667920cafe752d676d8782` is pushed to `origin/main`. The commit contains only membership methods, patterns, native/runtime support, tests and canonical specifications/cheat sheets. Existing package/build work remains uncommitted.

The clean staged source snapshot passed VM and full-native membership tests. Local notebook-core, worker and remote were rebuilt from the current workspace; core API and remote graphs have full native coverage and no VM fallback. Worker, IPC, readiness, cancellation and child-run checks passed. The new remote API membership test returned 42 and preserved receipt replay.

The user explicitly authorized source transfer and deployment to slowpilot@lab.orlando-labs.com:22176. An isolated Linux release is being built and tested before the production switch.

The remote suite passed 48/49 tests. The remaining test assumed the legacy installation path for modules.index; the assertion now reads the variant advertised by the package API (and preserves the legacy path when absent). Its isolated rerun passed the full install/import/remove/runtime-retirement flow. No package runtime implementation was changed.
