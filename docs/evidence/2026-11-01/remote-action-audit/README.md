# Remote action audit evidence

1 November 2026. Scope and findings: [audit](../../../engineering/notebook-remote-actions-audit-2026-11-01.md).

## Results

- [Static inventory](inventory.json): **44/44 C API actions classified, 35 palette tools, 33 persisted kinds**. [Generator](inventory.mjs) checks for unclassified/new actions and records hashes of the inspected sources.
- [Probe observations](observations.json) / [output](probe.log): **four reproductions confirmed** using current desktop model sources and the actual local native Core/worker. Invocation Restart reports success but preserves its epoch/counter; Carousel selects index 1 but the server reads the first image; local history deletion is undone by reconnect; two active actions share a controller and the common Stop cancels the latest one without a target parameter.
- [Native integration output](native-integration.log): exit **0**. Ten functional groups cover catalog, immutable snapshots/reconnect, execution, cancellation, dependencies, worker settings, inputs/Watch, actions/schedules, durable restart and agent failure. The final suite marker passes. This is not a claim that every UI action has been executed.
- [Build/launcher log](build-and-command-tests.log): Core and test harness rebuilt with `--require-full-native`, full native graph coverage and zero VM fallback. Command launcher checks pass in VM and native modes. The subsequent integration launch in the default sandbox is denied at local `listen`; the same already-built native suite passes with local sockets allowed, as recorded separately above.
- [Desktop probe build](probe-build.log): succeeds. Existing deployment-target/dylib version warnings are emitted on this macOS host. No packaging, older-macOS or visual acceptance is inferred from successful compilation.
- [Identity](identity.json): binary hashes, repository HEADs and source inventory hash. Both repositories have pre-existing working-tree changes, so HEAD alone is insufficient to identify the implementation.

The known Date/Time Apply block and missing desktop transport integrations are established by source inspection. They are not counted as fresh dynamic UI acceptance. Web comparison uses the current source and the [31 October acceptance](../../2026-10-31/notebook-web-runtime-observations/README.md); no browser suite was rerun for this desktop audit. No production SSH target, Linux deployment, application publication or user notebook was changed.

## Reproduction

Run from the `sputnik-notebook` repository root on macOS:

```sh
node docs/evidence/2026-11-01/remote-action-audit/inventory.mjs
make remote-core
make -f Makefile -f docs/evidence/2026-11-01/remote-action-audit/probe.mk .build/remote-action-audit-probe
bash docs/evidence/2026-11-01/remote-action-audit/run-probe
```

The runner creates a short temporary path under `/tmp`, starts a service on loopback, uses an isolated package home, passes a deliberately unavailable Python executable, and removes its state/service on exit. It writes only the probe output/observations into this evidence directory. Set `AUDIT_PORT` if its default port is occupied. Local HTTP and Unix-domain sockets must be allowed by the execution sandbox. The fixture and orchestration add no Python dependency.

The probe intentionally demonstrates the recorded defects, so a corrected implementation will require updating its expectations. It drives the real Swift model, not mouse clicks in SwiftUI; UI wiring/disabled conditions are reviewed separately in the report.

Run the normal native integration suite:

```sh
make test-notebook-remote
```

For a restricted sandbox after a successful build, the integration portion alone is:

```sh
tests/run-remote-tests "$PWD/../sputnik-lang/build/sputnik" "$PWD/build" remote
```

The native suite owns and removes its separate temporary projects and processes. Neither command connects to the configured production SSH server.
