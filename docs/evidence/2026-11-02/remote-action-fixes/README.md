# Remote action fixes — verification

2 November 2026. [Implementation and contracts](../../../engineering/notebook-remote-actions-fixes-2026-11-02.md) · [original audit](../../../engineering/notebook-remote-actions-audit-2026-11-01.md).

## Checks

- `actions.log`: new native Sputnik fixture + actual Swift model/UI sources + independent native Core/worker. Covers all five fixes, six functional groups, lost replies, concurrent jobs, service restart, carousel reconnect, dates, two history clients, more than 50 runs, exact/scoped restore and permanent deletion. Includes direct rejection of local `periodic_dispose` in external mode and inert decoding without a terminal artifact.
- `integration.log`: ordinary native remote suite plus the new cross-platform HTTP contract checks for restart ownership/epoch/service state, receipt replay, history CAS, pinned deletion and pagination.
- `legacy-ui.log`: existing server selection/source/media/live/reconnect/cancellation/draft/conflict/grant and private-command recovery regressions.
- `legacy-work.log`: existing remote project inputs, idle Watch, action receipt recovery, server periodic close/reconnect/pause and history.
- `local-history.log`: local snapshot/output, pin/rename, inert scalar restore, failed/Stop status, explicit retention policy and reopen regression. The fixture sets the 20-run policy explicitly rather than assuming the current app default is 20.
- `app-build.log`: `make notebook-macos`, including full-native Core, app packaging and `codesign --verify --deep --strict`. This host's bundled dependencies set minimum macOS 26.0 for the resulting development app.
- `regression-build.log`: current Swift regression executable build. Native/Swift toolchain deprecation/deployment-target warnings are present; they do not fail the builds.
- `identity.json`: exact source/test/binary SHA-256, repository HEADs and embedded build identity. Both repositories already contained working-tree changes; HEAD is not a complete source identity.

The remote checks use disposable loopback/Unix-socket services and isolated package homes. The new regression harness sets the optional Python executable to an unavailable path and adds no Python dependency. Existing UI/work checks use their pre-existing runner unchanged. Restricted execution sandboxes must allow the temporary local sockets.

## Reproduce

From the `sputnik-notebook` repository root on macOS:

```sh
make test-notebook-remote-actions
make test-notebook-remote
make test-notebook-remote-ui
make test-notebook-remote-work
make test-notebook-history
make notebook-macos
```

For already-built binaries, the two native remote commands are:

```sh
tests/run-remote-tests "$PWD/../sputnik-lang/build/sputnik" "$PWD/build" desktop-actions --ui-test "$PWD/build/notebook_macos_remote_actions_tests"
tests/run-remote-tests "$PWD/../sputnik-lang/build/sputnik" "$PWD/build" remote
```

The new Swift tests drive real model entrypoints and compile the shared SwiftUI sources. They do not claim complete mouse/keyboard or visual acceptance for every component. No Linux/SSH production deployment or server upgrade is claimed by these local macOS checks.
