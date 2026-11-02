# Remote action audit: five fixes

2 November 2026. Implements R1–R5 from the [1 November audit](notebook-remote-actions-audit-2026-11-01.md).

## Result

- **R1 — invocation Restart:** desktop sends the exact RunId/epoch to Core. Core resolves the runtime owner, rejects cross-project/stale/busy targets and requires enabled services to be paused. Acceptance is durable before retiring the heap. The model completion reports the server result. The local external-mode C API rejects `periodic_dispose`, so a missed transport branch cannot silently succeed locally.
- **R2 — targeted Stop/Force Stop:** Execution Controls resolve each board/component independently; sheet controls address only the sheet owner. Force Stop confirmation captures the original Run/epoch. Parallel action/service statuses no longer depend on one project-wide `executingTargetID`. Global sheet Stop cannot select a controller's unrelated invocation.
- **R3 — Carousel selection:** external-mode `image_select` saves the selected index in the corresponding authored image components, including nested panels. Full snapshot upload and the next Run carry that index. Closing/reopening the desktop document preserves it.
- **R4 — Date/Time Apply:** availability follows connection, capability, busy/pending/conflict and active-work state. Calendar dates use the configured IANA timezone; timestamps serialize to UTC. Both formats go through the existing atomic project-input transaction and survive reconnect.
- **R5 — server history:** the desktop loads paginated retained runs from Core and uses server metadata CAS for Pin/Rename/Delete. A second client sees the same labels/pins/deletions after Refresh. Pinned/current presentations retain the Core's deletion protections. Snapshot inspection uses a stateless native decoder and never applies old results/sources to the editor. Interrupted runs without a terminal artifact can still expose their frozen inputs as stale snapshots.

Scalar restore is explicit per project or cell scope. It uses the current accepted-input version, rejects a stale review, preserves media/file inputs and authored defaults, and retains exact Int64 values. Watch cells may recompute through the existing input path; this is not a heap restore. A metadata refresh does not silently renew a stale parameter review.

Restart and history mutations have exact command tickets in private app storage. Lost acknowledgements recover through the durable receipt and, only when no receipt exists, replay the same signed request. A notebook sidecar alone cannot authorize their recovery.

## Protocol and compatibility

Protocol v1 remains additive. Health advertises `targeted_restart` and `desktop_history` in the updated Core. Older servers produce an explicit update requirement for these operations.

`POST /v1/projects/{project}/restart` accepts either the existing `sheet_id` or an invocation `run_id`, with `command_id` and `runtime_epoch`. The invocation path checks ownership, the actual worker epoch and the service state under the Core owner lock. Existing sheet restart requests keep their semantics.

`POST /v1/projects/{project}/runs/{run}/metadata` accepts `operation: "update" | "delete"`, `command_id`, `base_version`, and (for update) `title`/`pinned`. It forwards to the existing `run.annotate`/`run.delete` domain transactions. History pages include creation time; CLI uses the existing `runs --limit/--before` plus new `change_run` and `restart_invocation` commands.

Install the updated Core together with the desktop client to use the new negotiated operations. No live SSH deployment is part of this change.

## Regression coverage

`make test-notebook-remote-actions` builds a native Sputnik fixture/orchestrator and the real Swift model/UI sources, then runs them against an isolated native Core/worker. The new dependency chain uses Sputnik and shell, without Python. It is also part of `test-notebook-macos`.

The regression groups cover:

1. Stateful action Restart, changed epoch, lost acceptance reply and absence of duplicate reset.
2. Two parallel actions plus a sheet Run: independent status, Stop A while preserving B/sheet, Force Stop sheet while preserving B, and invocation recovery after Force Stop.
3. Periodic Work Run Once, rejection of Restart while enabled, explicit Pause and fresh worker state.
4. Carousel selection consumed by the worker and retained after document close/reopen/reconnect.
5. Date Apply availability, invalid timezone, a date crossing the UTC/local day boundary, UTC timestamps, accepted state after reconnect and actual worker output.
6. More than one 50-run history page, inert snapshot inspection, second-client metadata, stale-version rejection, protected deletion, lost Pin/Delete replies, persistent deletion and scoped restore of `9223372036854775806` without changing the other scope or dataset input.

The ordinary cross-platform `test-notebook-remote` suite additionally covers the HTTP contract for invocation restart, stale epoch, cross-project rejection, receipt replay protecting a newer world, idle enabled service protection, metadata CAS, pinned deletion and paging.

Existing remote UI/work and local history suites were rebuilt and run. The local history retention fixture now explicitly sets its 20-run policy rather than assuming that the independently configurable app default is 20.

[Logs and exact source/binary identities](../evidence/2026-11-02/remote-action-fixes/README.md).
