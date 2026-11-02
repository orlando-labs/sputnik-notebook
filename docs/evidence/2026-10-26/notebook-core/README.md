# notebook-core extraction — 2026-10-26

Uncommitted local development snapshot. No package publication or remote deploy.

- Shared archive and worker build without Swift/AppKit. Native archive objects
  retain the macOS 14 deployment target; this host's third-party Homebrew
  libraries require newer macOS, so OS 14 execution is not claimed.
- Swift application built using notebook-core C header and the shared archive.
  Existing C API and Swift model tests passed with the real isolated worker.
- Worker lifecycle/IPC/Watch/inputs/presentations, worker-host Stop/Force Stop,
  cancellation, child task membership, project and Session regressions passed.
- Direct package API passed VM and strict full-native: no HTTP/IPC/token on Core
  construction, inert load, save/run idempotency, receipt reattach, worker result
  and project/runtime retirement. Core API is 1070/1070 native; remote adapter
  is 1114/1114 native. Both have zero fallback and no VM bridge.
- Existing remote protocol suite passed all 45 tests after the extraction.
  This includes native CLI, agent/gateway restart, lost replies, durable receipts,
  inputs, Watch, schedules, dependency/environment operations and Stop.
- Initial runs exposed a reproducible stale-wakeup race after input application:
  a mailbox hint could cause an empty durable Watch run. A read-only Session
  event-cursor probe now guards worker Poll. Deterministic readiness and worker
  regressions pass; the original input/Watch/receipt case passed five consecutive
  independent-agent rechecks, followed by the full 45-test suite.
- Existing literal cwd/argv/environment launcher tests passed VM/full-native.
- Core package has no Orbit/HTTP/CLI or Swift/AppKit import. Optional Client
  provides private IPC with the same handle(method, params) API as Core.
- Documentation links and git diff whitespace checks passed. New backend/test
  code introduces no Python dependency; existing remote regression runners were
  reused as-is except for package import/path configuration.

User notebook code still runs inside its VM worker, as before. Full-native
coverage above describes the Sputnik coordination/service API, not compilation
of arbitrary notebook cells. Windows process/IPC support remains future work.
