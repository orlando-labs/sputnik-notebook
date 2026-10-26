# Remote project inputs, idle Watch and board invocations

Implemented in the current source on 25 October 2026. Both the core and worker
must be updated. The working server was updated on 25 October 2026; see the
[deployment report](../evidence/2026-10-25/remote-work-deploy-result.json). The GUI checks `project_inputs`, `board_actions` and
`server_periodic` capabilities; older servers never execute these commands locally.

## Project inputs

`GET/PUT /v1/projects/{project}/inputs` uses the same accepted-state version as
cell parameters. PUT supplies `command_id`, current `revision`, `base_version`
and `values`, a map of input names to JSON strings. The common C++ project-input
validator checks the complete batch, including range and board control constraints.
Int64 values retain their exact spelling. Invalid batches, stale revisions,
stale accepted-state versions and busy/interrupted sheet worlds leave accepted
values and run history unchanged.

The core prepares every existing sheet world before committing any input update.
Accepted values, all resulting Inputs runs, their immutable execution documents
and the command receipt commit together. Dispatch follows commit. Watch consumers
recompute; Manual consumers become stale. An uninitialized sheet remains inert.
An equal batch creates no run. Project defaults remain authored document data;
accepted values live separately in SQLite and survive reconnect/agent restart.
Invocation worlds take the latest accepted inputs at their next explicit call/tick.

Accepted-state keys are `project:<input>` and `<cell>:<input>`. Cell input API and
receipts remain compatible. CLI: `inputs`, `set_inputs --request-file ...`.
The private client journal protects recovery of input edits and board commands;
a notebook sidecar alone cannot authorize execution.

## Idle Watch

The agent polls already-created sheet workers every 100 ms using the shared
read-only Poll command. Only sheets containing Watch cells participate. Poll and
execution dispatch share the core owner lock; only one reader owns worker IPC.
Readiness starts a normal durable Watch run, with live/terminal presentations,
RunId, epoch, Stop and Force Stop. Acknowledged events become quiet; storage
conflicts defer work without destroying the idle heap.

Automatic Watch uses the last explicitly installed project revision. Uploading a
new draft does not execute it: Watch waits for explicit Run or input Apply to
install that revision. Stop pauses the worker Watch pump; Force Stop requires
Restart Worker. Neither client polling nor an open notebook is needed for Watch.

## Board actions

`POST /v1/projects/{project}/runs` accepts `action: "action_run"`, `board_id`,
`component_id`, current `revision` and `command_id`. The worker's pure
`--action-document` path uses the shared action argument compiler, captures
accepted inputs/constants and validates the module target. It creates one
synthetic invocation cell in an execution snapshot, without changing the saved
controller sheet. The GUI restores action results independently of sheet results.

Each board/component has its own persistent worker and module state. Invocation
worlds use the controller's grants, package home and managed foreign environment.
Module/function changes replace a world only after durable acceptance. Stop and
Force Stop address the run's actual runtime owner. Removing a board/component
stops and retires its world. Changing controller worker settings first requires
all its invocations to be idle, then retires them and pauses schedules too.

## Server Periodic Work

`GET/POST /v1/projects/{project}/services` lists server state or applies an
explicit `start`, `pause`, `once` or `clear` operation, with `board_id`,
`component_id`, `command_id`; Start/Once also require the current `revision`.
CLI: `services`, `configure_service --request-file ...`, and `invoke` for actions.
All mutating operations have durable receipts, including Run Once.

Deadlines belong to the agent and use monotonic time. Fixed delay waits after
completion; fixed rate skips overlaps. A service has one active invocation and
no catch-up queue. Start honors `run_immediately`; Pause prevents future calls
and lets the current call finish. Stop cancels the current call and pauses future
calls. Child tasks drain through the standard worker lifecycle; unobserved child
failures count as errors. `stop_on_error`, value/error retention and Tail limits
apply to persisted service history and counters.

Closing the app, hiding its board or restarting the HTTP gateway leaves the
server schedule running. The GUI states this explicitly; `pause_when_hidden`
continues to govern local schedules only. Editing executable service/module
configuration pauses future calls. Opening a book never enables a schedule.
After an agent restart, active runs become interrupted and schedules are paused;
resumption always requires Start. SQLite retains accepted inputs, history and
Pause state, while the process heap is not restored.

## Validation

`make test-notebook-remote` covers multi-sheet atomic inputs, Int64, immutable
snapshots, busy/stale rejection, receipts, idle Watch, isolated actions, server
schedules, gateway/agent restart, cancellation, owner removal and grant retirement.
`make test-notebook-remote-work` exercises the real Swift model and worker,
including lost input/action replies, reconnect and schedules after client close.
`make test-notebook-remote-cell-components` retains cell-parameter regressions.

Directory dependency bundles, isolated module-tab Run, environment Apply without
Restart Worker and annotation editing are separate remaining remote limitations.
