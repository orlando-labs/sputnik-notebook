# Tech preview audit evidence

Audit: `docs/engineering/notebook-tech-preview-audit-2026-10-28.md`.

- `manifest.json`: audited workspace revisions and source SHA-256 hashes.
- `core-remote-tests.log`: passing core/worker/native CLI and 46 remote tests.
- `swift-build.log`, `swift-model-bridge-tests.log`: rebuilt Swift model, native bridge and library checks.
- `agent_repro.py`, `agent-repro.jsonl`: actual temporary native agent; external child survives Force Stop and service stays running after SQLite BUSY. Includes a negative check which correctly reports a failed cell.
- `swift_repro.swift`, `swift-repro.jsonl`: real Swift model/controller with deterministic queue interleaving and a local fixture CLI. Demonstrates cross-document mutation, stale successful action after interruption, and discarded pending ticket after ambiguous 503.
- `swift-repro-build.log`: compilation including deployment-target warnings.
- `bundle-inspection.txt`: existing app signature, architecture and effective minimum macOS.

These are diagnostic reproductions, not fixes or installed regression tests. A result showing the defect is expected on the audited source. All agent state and notebooks are temporary. No production server is contacted. The scripts print their observations and do not assert that bugs are fixed.

From the notebook repository, with current binaries built:

```sh
make -j4 remote-core notebook-core
python3 docs/evidence/2026-10-28/tech-preview-audit/agent_repro.py
python3 docs/evidence/2026-10-28/tech-preview-audit/run_swift_repro.py
```

The Swift runner obtains the compiler invocation from the existing model test target and substitutes the diagnostic main. It uses a unique temporary directory; AppKit and the temporary agent require the usual local execution permissions. The agent test deliberately holds only its own temporary SQLite database writer lock for seven seconds. The Force Stop child exits on its own after four seconds; its post-stop marker is the evidence.
