# Template-enabled notebook/core, 2026-10-26

`release.json` pins the source commits and archive hashes. The notebook source
snapshot is `a877de6`; the following notebook commit records documentation and
verification evidence. SDK `2622f9d` adds template loops/external sources;
`28fe1f0` fixes the large Watch timeout overflow found on the Linux host.

- `local-build.json` records the final macOS bundle hashes and checks.
- `bundled-template-smoke.log` checks external sources through the bundled compiler.
- `rbcall-tests.log` checks the retained-callback LocalJumpError regression in VM/full-native.
- `local-remote-tests.log` covers all 45 remote integration tests on macOS.
- `template-ui-smoke.log` exercises a template loop through the bundled isolated worker.
- `language-tests.log` covers parser/VM/session and template VM/full-native checks on Linux.
- `remote-tests.log` covers all 45 remote integrations on Linux.
- `orbit-template-tests.log` and `orbit-native-build.json` cover external HTML/SQL/cmd sources.
- `source-verification.json` compares the release source files against the Git archives.
- `build-result.json` pins Linux binaries after validation.
- `deploy-result.json`, `production-smoke.json`, and `final-health.json` record the release switch and live API check.

`build_remote.sh` and `validate_remote.sh` reproduce the server build/checks.
The validation harness uses `/usr/bin/python3.11`; the host default Python 3.6
is too old for these tests. `deploy_remote.py` refuses active runs/runtimes or
enabled services, preserves the existing launcher/environment/token, backs up
SQLite, and restores the previous launcher on switch failure. Its backup stays
on the server. `production_smoke.py` uses the token file privately and removes
its temporary project through the API after checking result/receipt replay.

External `.sv` files are compile-time build-manifest inputs, not implicit
filesystem views available to arbitrary notebook cells. The worker smoke
checks runtime `%for` and preserves command argument boundaries.
