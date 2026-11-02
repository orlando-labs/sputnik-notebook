# Notebook resource policies and temporary sessions

The shared Core owns retention, storage admission, execution time accounting and
session lifetime. Swift and the web adapter consume the same bounded registry.
Defaults retain **100 runs per project**. Policies are server configuration;
notebook documents, parameter inputs and browser request bodies cannot override
explicit operator limits. Desktop defaults can be replaced by a book locally;
remote replacement requires an explicit process option (see below). The web
workspace includes settings and an authenticated disposable preview with public
limits; an anonymous demo page is a separate task.

## Policy hierarchy

Effective project/session limits inherit Core → owning user → profile → project.
Numeric upper bounds take the minimum at child levels; a free-disk reserve takes
the maximum. `null` inherits. `persistence: "session"` is restrictive and cannot be
reverted by a child. Profiles are templates, not shared billing counters. Core
configuration establishes defaults/ceilings and can be changed by the operator.

Storage is charged to the authenticated catalog project's owner, including editor
work in a shared project. A temporary preview copy is charged to its visitor.
The adapter supplies these identities after authorization; `policy.bind` refuses
to change an existing owner/profile. Direct remote projects have Core/project
limits until an operator binds them to a user.

`total_bytes` on Core limits the archive of the entire Core. On a user it also
limits the sum across that user's projects/sessions. `project_bytes` limits each
project. User execution budgets aggregate all their projects/sessions; project
and session execution counters are independent. An operator can configure a
Core-wide execution budget as well. Counters are lifetime counters; automatic
billing-period resets are not implemented.

Start the remote agent with `--policy-file /absolute/path/policy.json`:

```json
{
  "core": {
    "run_count": 100,
    "run_age_seconds": 2592000,
    "revision_count": 50,
    "project_bytes": 2147483648,
    "total_bytes": 10737418240,
    "minimum_free_bytes": 536870912,
    "max_run_bytes": 134217728,
    "receipt_age_seconds": 2592000,
    "event_count": 10000,
    "gc_interval_seconds": 60
  },
  "users": {
    "account_id": {"run_count": 50, "total_bytes": 1073741824, "total_run_seconds": 3600}
  },
  "projects": {
    "core_project_id": {"run_count": 20, "run_seconds": 30}
  },
  "profiles": {
    "public": {
      "persistence": "session",
      "total_run_seconds": 60,
      "run_seconds": 60,
      "lease_seconds": 15,
      "session_seconds": 900,
      "project_bytes": 67108864,
      "max_run_bytes": 8388608
    }
  }
}
```

Missing sections inherit the built-in defaults. The `public` profile above is
built in. Its temporary persistence and 60-second per-run/cumulative ceilings
are also enforced independently of the profile configuration; replacing that
profile cannot raise them. Without explicit execution budgets, durable projects have no time cap.
`--storage-policy` remains an alias; a flat object configures Core limits. Positive
integer limits are required. The trusted direct/Unix Core API also supports:

- `policy.configure {scope: "core"|"user"|"project"|"profile", id, limits}`
  replaces that scope's overrides, leaving usage counters intact.
- `policy.bind {project_id, user_id, profile?}` binds immutable ownership.
- `policy.get {project_id}` returns effective limits, scope counters and mode.
- Its `defaults` field shows the same policy without authored book overrides.
- `storage.status {project_id}` returns charged bytes, disk availability and counts.
- `storage.collect {command_id, project_id?}` runs collection now.

Policy mutation/binding is deliberately absent from the remote HTTP gateway.
The authenticated web adapter calls it through its privileged Unix Core client.
A future anonymous demo must choose its template and principal on the server.
The profile name `public` grants no anonymous access by itself.

## Storage and retention

Collection protects active runs, each owner's latest attempt and latest available
presentation, every referenced revision, the current project head and revisions
still used by live workers. Other runs expire by age/count/byte pressure. The
latest failed/interrupted attempt remains visible alongside an earlier available
presentation. If protected data occupies the limit, a new Run is rejected rather
than deleting the data required to reconnect. In particular, 100 distinct protected
owners can occupy the entire default run allowance.

Deleting a run removes frozen inputs, targets, result/live JSON and both binary
artifacts. Terminal live snapshots are removed; old revisions and retired runtime
directories are collected when unreferenced. Events retain a bounded tail and
report `reset_required` when a cursor is too old. File deletion uses a durable
queue so a crash or unlink failure can be retried. Unreferenced run/revision files
left between atomic publication and database commit are swept under the Core lock.
Existing installations get timestamps at migration, avoiding immediate age expiry;
count and byte limits apply immediately.

Command identity/digest is retained after its response expires. `receipt.get` and
resubmission return **410**, so an expired command cannot execute again. Receipts
whose result run is collected also expire; active-run receipts are protected from
age expiry. Identity tombstones consume archive quota and are not silently removed.

Charged archive bytes include documents, run inputs/results, artifacts, receipt
payloads/tombstones, service histories, events and pending deletions, with metadata
allowances. This is logical archive accounting, not an exact filesystem quota:
SQLite can retain reusable pages, and installed environments, worker working
files, operator files and trusted native code are outside the archive quota.
Actual free space is checked separately. A Run reserves `max_run_bytes` before
acceptance, including simultaneous multi-sheet input runs; output is bounded by
that budget. Storage exhaustion returns **507**, with no accepted new Run. Periodic
Work pauses on rejection; idle Watch stops resubmitting until an explicit Run.
Stop/Force Stop remain available. Unexpected real ENOSPC or I/O failure can still
occur after a space check and is reported through the existing failure lifecycle.

## Polling and history

`run.registry` returns active runs and the latest attempt/presentation per owner,
current/active runtimes and relevant reset epochs. It joins compact input/target
metadata in SQL; it does not fetch or enumerate all historical run payloads.
New execution owners/services are bounded to 256 per project, and the JSON snapshot
has a 16 MiB safety ceiling. Service history in polling has both count and byte
budgets; stored service history has a hard 1000-entry/1 MiB ceiling with bounded
values even if its document requests unlimited history.

`run.list {project_id, before?, limit?}` returns compact history pages, at most 100
runs, with `next` as the next cursor. Cursors use a monotonic sequence and survive
deletion of their original boundary run. `service.history` similarly pages stored
service history. In the remote gateway these are `GET /v1/projects/:id/runs` and
`GET /v1/projects/:id/services/:board/:component/history`, with `before`/`limit` query
parameters. The CLI supports `runs --before N --limit N`, `service_history`,
`storage` and `collect_storage`. The web UI loads run history on demand through
`GET /api/projects/:id/execution/history`; polling stays a current-state snapshot.

## Execution time and temporary lifetime

Core starts its own finite supervisor when work or a temporary session exists;
no gateway, UI polling or explicit adapter scheduler is required. Wall time is
counted from accepted dispatch through completion, including preparation/waiting.
Parallel executions add their elapsed times: two one-second runs consume two
seconds. `run_seconds` caps one run; `total_run_seconds` caps accumulated scope
usage. Budget exhaustion force-stops workers and pauses periodic work. New starts
return **403**. Stop, history collection, a new command ID and agent restart do
not reset persistent user/Core counters. Accounting failures force-stop work and
block new starts until the supervisor can persist accounting again; terminal
lifecycle publication is retried after recovery. After a crash, the final unflushed
interval is conservatively accounted from its durable checkpoint.

Checks normally run every 100 ms. They are cooperative host supervision, not a
hard real-time CPU/memory sandbox: scheduling delay, storage contention and process
termination can add latency. Deliberately detached trusted native processes retain
the process-isolation limitation documented in the tech-preview fixes report.

`session.open {source_project, user_id?, profile: "public"}` creates a fresh project
copy, without inherited runtime state, results, input overrides or worker grants.
It does not alter the template. `session.touch {project_id}` renews the short lease;
`session.close {project_id}` closes it. A closed/expired session cannot be renewed.
Lease expiry or agent restart force-stops all its workers and erases its project,
runs, artifacts, revisions, inputs, receipts and service state. Physical removal
waits for worker termination; independent Core/user usage counters remain. Session
data uses temporary-lifetime storage, not a memory-only or forensic-erasure mode.
Dependency environment installation is disabled for temporary copies.

The web mode exposes authenticated, CSRF-protected endpoints:

- `POST /api/projects/:id/preview-sessions` → fresh session ID/revision/policy.
- `GET|DELETE /api/preview-sessions/:session` → read or close the private copy.
- `POST /api/preview-sessions/:session/lease` → explicit heartbeat.
- `PUT /api/preview-sessions/:session/notebook` → edit only the copy.
- `POST /api/preview-sessions/:session/runs`, `GET .../runs/:run` → execute/read.
- `POST .../runs/:run/stop`, `GET .../commands/:command` → Stop/Force Stop and receipts.

A new page/session must call Open again and discard the old session token, rather
than persisting it in local/session storage. Polling reads do not renew the lease.
There is a short grace period before an abandoned lease expires; a caller retaining
a valid token within that period can still read that live session. The future
public page should explicitly close/discard on reconnect. The implemented
authenticated Temporary preview follows that lifecycle, keeps its token only
in memory and exposes the remaining budget and saved-copy editor. The default sum budget
is 60 seconds per copy. To also cap repeated new copies, configure a persistent
user or Core-wide time budget; creating a new copy does not reset that aggregate.

The web Resource limits dialog edits book overrides through the normal document
draft/Save/CAS workflow. Its server/app defaults and saved effective columns come
from Core; the process override flag and operator scopes remain authoritative.
Execution polling exposes compact policy/time summaries as exact decimal strings.
Storage usage loads separately through authorized `GET /api/projects/:id/resources`,
without disclosing global archive usage, server free space or internal identities.
An exhausted budget blocks new UI starts while retaining Stop/Pause/history.

## Validation

Verified on macOS arm64: 48 existing remote integrations, 10 policy integrations,
direct Core VM/full-native, Swift model/remote UI/work, web preview VM/full-native,
20 browser scenarios, frontend build and packaged app smoke. The operator policy
file and read-only binding during a SQLite writer lock are covered. Linux was not
run. [Logs and source fingerprints](../evidence/2026-10-28/notebook-resource-policies/README.md).

A ready-to-edit configuration is available in
[`policy.example.json`](../../tools/notebook-remote/policy.example.json).

## Desktop app and sputnikbook settings

The desktop exposes two separate editors:

- **Settings → Resources** saves app defaults in `UserDefaults` under
  `NotebookResourcePolicy`. These limits apply separately to each opened book.
- **Notebook Settings → Resource Limits for This Notebook** saves overrides in
  `project.json.resource_policy`. An unchecked field inherits the app setting;
  the editor shows the combined app/book value. Resetting book overrides leaves
  app preferences intact. A document cannot change app preferences.

The editable limits are saved-run count, history age, history storage, snapshot
size, disk reserve, server revision tail, per-run time and cumulative book time.
App defaults retain 100 runs, 30 days, 256 MiB of local history, 32 MiB per snapshot,
512 MiB of free space and 50 server revisions. Time budgets are unlimited until
configured. For local execution, a book replaces each selected app value and can
raise or lower it, including its disk reserve. Unchecked fields inherit. History
cleanup preserves pinned snapshots; when pins occupy the quota, saving another
snapshot reports an error. Local snapshots are created by the existing Run History
and Experiment Compare components. Local snapshot policies take effect on save.

Local execution uses a monotonic meter and Force Stop. Cumulative usage is saved
in the book's private `.sputnik/resource-usage.json`, survives reopen/relaunch and
is excluded from authored remote bundles. The active run is checkpointed at least
once a second; normal completion writes its final value. This meter belongs to the
running desktop app; the remote Core owns authoritative remote metering.

For a connected remote book, the desktop sends **raw app defaults** through
`PUT /v1/projects/:id/resource-policy` (`set_resource_policy` CLI), with body
`{command_id, limits: {run_count: 100, ...}}`. Book settings come from
`resource_policy` in the current authored revision. The authenticated gateway
accepts only the eight numeric desktop fields. It exposes no general policy-admin
or identity-binding operation. App defaults are stored separately in the `desktop`
scope, so server schedules can use them after the UI disconnects. Another
authorized desktop can replace this declaration with its own app defaults.

By default, remote Core combines app and book values restrictively: minimum
upper bounds, maximum disk reserve. A book cannot raise app or built-in Core
limits. To allow the local desktop semantics, the operator must opt in **on each
agent launch**:

```sh
sputnik-notebook-remote --mode agent --root /absolute/state \
  --worker /absolute/sputnik-notebook-worker --allow-book-policy-overrides
```

In this mode, the order is built-in/Core defaults → app defaults → non-null book
values, followed by restrictive explicit operator scopes (Core, user, profile,
project). Thus a book may raise the built-in run count of 100, but a `run_count`
explicitly configured in the operator's policy file remains a hard ceiling.
Public sessions remain temporary and capped at 60 seconds even in this mode.
The option is **off by default**, is not persisted, and cannot be enabled through
a document, policy JSON, gateway request or project preference. Restarting without
the flag restores restrictive merging over the existing saved declarations.
`health` and `policy.get` expose the process boolean
`allow_book_policy_overrides`; the desktop displays the selected mode. The
`desktop_policy` capability advertises policy support; custom limits require a
supporting Core.

A local Electron/native host using the Sputnik service API can opt in with
`Core(..., allow_book_policy_overrides: true)` at construction. There is no
standalone Electron app in this checkout; the Swift app already applies local
replacement semantics independently of the remote service.

The shared C++ document editor saves policy metadata independently of unsaved
source buffers. A policy change does not restart or evaluate the notebook.
