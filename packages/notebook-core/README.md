# notebook-core

Shared execution and document engine for Sputnik Notebook frontends. This source
package is used by the Swift application, the headless worker and the remote
service. It depends on the Sputnik compiler/runtime's notebook Session/kernel;
its durable service layer uses the SQLite package.

The package owns execution, worker supervision, immutable presentations,
project/revision persistence, durable command receipts, runtime epochs, inputs,
actions, managed environments, dependency operations and server schedules.
HTTP routing, bearer authentication, CLI parsing and Swift/AppKit views belong
to adapters outside the package.

## Sputnik service API

```sputnik
from notebook.core import Core

core = Core(state_directory, worker_executable, compiler: compiler_executable)
health = core.handle("health", {})
projects = core.handle("project.list", {})
```

`handle(method, params)` is the application boundary. It returns domain data or
raises `APIError(status, message)` from `notebook.core.common`. Existing method
names, request shapes, receipts and revisions are retained from the remote core:
`project.*`, `revision.*`, `receipt.get`, `run.*`, `runtime.restart`, `events`,
`worker.*`, `project.inputs*`, `cell.inputs*`, `service.*`, `environment.*`,
`dependency.*` and `environments.gc`. The HTTP mapping remains in the
[remote protocol](../../docs/engineering/notebook-remote-core-p01.md#http-api-v1).

Resource policies use restrictive inheritance by default. A local host (including
a future Electron adapter) can construct
`Core(..., allow_book_policy_overrides: true)` to let per-book numeric settings
replace app defaults. Explicit operator Core/user/profile/project limits remain
hard ceilings. Remote agents require the launch flag
`--allow-book-policy-overrides`; this mode cannot be set by notebook metadata or
client policy requests. See [resource policies](../../docs/engineering/notebook-resource-policies.md).

Construction opens the database and obtains the exclusive state-owner lease;
it creates no HTTP listener, IPC socket or bearer token, and executes no notebook
source. One Core owns a state directory. Applications must retain that owner
for the intended execution lifetime. A Core restart marks unfinished work
interrupted and never silently replays it.

The agent starts `schedule_work()` and optional `schedule_gc(interval, age)`;
those calls are explicit because their background tasks share the service
owner's lifetime. Loading/saving is inert. Run/Apply/inputs/actions remain
explicit operations with their existing revision and receipt checks.

For a long-lived agent, use the optional IPC client from another process:

```sputnik
from notebook.core.client import Client

core = Client(state_directory)
projects = core.handle("project.list", {})
```

Client has the same `handle` contract, uses the private Unix socket and does not
own workers. Closing the client or restarting an HTTP frontend does not cancel
accepted work. `net.connect` is required for IPC. Core itself has no transport
dependency. Orbit can use this adapter after enforcing its user/project policy;
browser authentication and application ACL are outside notebook-core.

For an authorized `run.get` record, local adapters can call
`Client.presentation_bytes(record, live: false)` to read its artifact (128 MiB
limit, confined to the configured run directory, no symlink artifacts). The
adapter must authorize the project and trusted run ownership **before** this
read. `notebook.core.host.presentation_snapshot(bytes)` decodes it with the
shared native codec into a bounded inert JSON snapshot: result table JSON,
PNG/JPEG/table/plot displays, image collections, telemetry and bounded source
diagnostics. It includes no editor document, paths, general locals dictionary or
executable handles. `presentation_bound_snapshot(bytes, bindings)` additionally
projects numeric module-cell bindings. `presentation_text_snapshot(bytes,
bindings, sources)` also projects the module-cell names declared in immutable
authored prose, respecting preceding-cell/controller scope. It bounds names,
provider records and text bytes; an incomplete projection is discarded as a
whole to preserve shadowing semantics. Values and diagnostics are inert text.
Audio files, complete retained PCM snapshots and ordered inert player requests
are projected with uint64 identities kept as strings. Audio reserves other rich
data first and caps at 64 tracks / 16 MiB raw in the 32 MiB JSON budget; omissions
set `audio_limited` without dropping the rest. There are no filesystem/device
handles or browser-selected reads in this projection. Its limits do not replace
application ACL, browser codec validation or the full artifact storage policy. The
web adapter supplies only frozen run documents and applies its own public DTO
and browser cache budgets.

The common evaluator resolves installed source/bytecode `notebook.ui` helpers
alongside its native namespace. The worker uses its configured project package
home and the normal verified package resolver. This
allows DataTableView alongside native Stopwatch without directory dependencies,
persisted document edits, automatic installation or additional native trust.

During development add only a directory override to the application's optional
configuration; imported modules are discovered without a file inventory:

```json
{"dependencies":{"notebook-core":{"path":"../sputnik-notebook/packages/notebook-core"}}}
```

The package currently uses a local path to the sibling SQLite checkout. No
package archive is published by this work.

## Native embedding API

`include/notebook/core/notebook.h` is a C header shared by Swift and other native
hosts. It exposes document open/export/snapshot/edit/save, worker execution,
thread-safe Stop/Force Stop controls and remote presentation application.
Returned UTF-8 strings are owned by the caller and freed with
`sputnik_notebook_string_free`.

Each document handle has one serial owner queue. Only independent execution
control handles may be used concurrently. Opening/editing/saving never evaluates
code. GUI hosts enable isolated execution once using
`sputnik_notebook_enable_worker`; a failed worker never silently falls back to
executing user code in the UI process. Heap values and borrowed Session pointers
do not cross the interface.

`include/notebook/core/execution.h` contains the reusable local worker supervisor.
`worker/` contains generation-qualified IPC, capability/environment policy,
presentation transfer and worker process entry. The worker executable is a thin
adapter calling `worker_main`; the worker loop lives in `native/worker.cpp`.
The wire version and project format are unchanged by extraction.

```sh
make notebook-core                   # build/core/libNotebookCore.a
make test-notebook-core              # direct API VM/native, readiness and worker-host tests
```

The archive links against the language runtime. It is built without Swift,
AppKit or ncurses. The macOS application and headless worker link this same
archive; an optional plot PNG backend is compiled once into it when present.
The process/IPC implementation currently targets POSIX (macOS/Linux). Windows
needs a platform process/IPC implementation; extracting the engine does not
claim Windows support.

Embedded local execution and durable agent hosting share the Session/kernel,
worker loop, protocol and presentation implementation. Their ownership differs:
an embedded host owns worker lifetime, while the agent owns durable receipts,
server schedules and execution independent of a connected client. The existing
Swift local scheduling UI remains an adapter; server schedules are implemented
by Core Services and must be reused by the web frontend.

## Managed media acceptance

`media.accept` commits file/audio/image bytes, native component metadata, accepted
parameters, revision and receipt together. Validation is a worker document
transaction, not evaluation. The optional Sync revision root preserves the native
message form and initialized world while updating immutable assets. See the
[remote media contract](../../docs/engineering/notebook-remote-media-inputs.md).

Image annotation acceptance uses `media.accept` with `operation: "annotations"`.
The worker validates the existing native component-data schema and exact accepted
image identity/dimensions/channel; the normal revision/receipt/storage transaction
persists it without evaluation. Browser capture produces an ordinary bounded WAV
input and requires no recorder or device handle in Core.

Stage 4g.2.3 extends the managed-media validator with native audio annotation
schema/transcript/frame/Hz checks and current completed-publication identities.
The read-authorized `media.source` method decodes a bounded audio source at its
original sample rate; its decimal-string cell DTO preserves Int64. `media.accept`
continues to use execute authorization, revision/input CAS, idle checks, storage
quotas and receipts. Neither path creates a Session or evaluates notebook code.
PCM WAV decoding is portable; other formats retain the existing system codec
requirement. See [contract](../../docs/engineering/notebook-remote-media-inputs.md).


Stage 4g.2.4 adds table sources and accepted shared selections to this same path.
The worker verifies the source table hash, unique key column/non-null keys and
the exact row, using the existing bounded protocol JSON parser and preserving
Int64. Clear stores null; no Session/evaluator is created. Date/preset Apply
continues through ordinary atomic project input acceptance. See
[verification](../../docs/evidence/2026-10-29/notebook-web-selection-controls/README.md).

Web environment preparation and worker configuration use optional saved revision
CAS in addition to the existing settings version/runtime epoch checks. Old remote
clients keep their existing contract when revision is omitted. Explicit prepare
admits the serialized receipt (including its environment spec) before scheduling
an installation; worker configuration admits receipt/event metadata before reset.
These checks use effective archive storage policies and preserve cumulative
execution counters. Installed environments remain outside archive accounting.

Run history metadata uses run.annotate / run.delete with command receipts and a
separate base_version CAS. Up to ten pinned final runs are retained. Pins share
effective archive/run quotas; active/current presentations cannot be deleted.
Drop uses the existing durable deletion queue and expires associated Run receipts
without refunding policy counters. New runs capture immutable environment,
settings and installed-package provenance, separately from mutable title/pin.
The metadata/provenance tables are included in archive accounting and purge.
Older runs have no inferred provenance. Web DTO filtering remains in the adapter.

Releasing a history pin and deleting an eligible retained run remain available
when the archive quota is exhausted, so protected history can be freed.
