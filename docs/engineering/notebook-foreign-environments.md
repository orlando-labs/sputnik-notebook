# Python and Ruby environments for notebook workers

Status: implemented, 2026-10-21. This extends the remote execution contract;
connection, project, environment generation, installation and worker have distinct
lifetimes. Disconnecting a client has no lifecycle effect on any of them.

## Local execution

At launch the supervisor discovers `.venv/pyvenv.cfg`, then `venv/pyvenv.cfg`, and
`Gemfile` in the notebook directory. Worker Settings can select a different
absolute environment directory. Discovery reads configuration without executing
Python, Ruby or the Gemfile. The supervisor passes the chosen directory and its
configuration fingerprint to the worker; the worker validates it before Ready.
The process working directory and the environment directory are independent.

The worker supplies `SPUTNIK_PYTHON_EXECUTABLE` to pycall's PyConfig initialization
and supplies `SPUTNIK_RBCALL_BUNDLE_GEMFILE` to rbcall's `bundler/setup` bootstrap.
It sets the virtualenv and Bundler variables before loading any native package.
Bundler uses the selected directory's `.bundle/config`, with frozen resolution.
Native packages remain separately installed/prepared Sputnik dependencies.

CPython is embedded, not launched to evaluate cells. A selected venv must match
the major/minor Python SDK against which pycall was built; an incompatible venv
produces a bridge error. Ruby and native gems likewise require a compatible Ruby
SDK. The worker cannot switch the already linked runtime library. It does not
source shell activation scripts. See the official [PyConfig API](https://docs.python.org/3/c-api/init_config.html)
and [Bundler setup](https://bundler.io/guides/bundler_setup.html).

A change to venv selection/configuration, Gemfile, Gemfile.lock or .bundle/config
requires Restart Worker before another Run/Apply/Watch/Inputs request. Filesystem
changes inside arbitrary installed package code are not continuously watched.
Worker settings are host policy, never inferred from executable notebook code.

## Persistent remote generations

The remote agent owns environments under:

```
state/projects/<project-id>/
  .sputnik-owner
  environments/<spec-digest>/<attempt-id>/
    spec.json
    requirements.lock | requirements.txt
    .venv/
    resolved-python.txt
    Gemfile
    Gemfile.lock
    .bundle/config
    vendor/bundle/
    stdout.log
    stderr.log
    ready.json
```

`project-id` is the existing persistent remote binding. Reconnect and worker
restart retain it. Runtime cwd remains `state/runtimes/<runtime-id>/work`.
Managed environments are shared by sheets of that project, not across projects.

The agent detects root `requirements.lock` (preferred), otherwise
`requirements.txt`, and root Gemfile with a required Gemfile.lock. It snapshots
these inputs, optional .bundle/config, wheels/ and vendor/cache/ artifacts.
Requirements.lock is installed with pip --require-hashes; requirements.txt may
resolve ranges and the resulting packages are recorded with pip freeze --all.
Use the lock form for repeatable Python inputs. Ruby uses frozen Bundler.
Local venvs and vendor/bundle installations are excluded from upload; cached
gem archives and wheels may travel as source inputs within existing file limits.

The digest includes source bytes and selected server interpreter executable,
version, platform and ABI facts. Agent options `--python` and `--ruby` select
installed interpreters (defaults: python3 and ruby). The service does not install
interpreters or operating-system build dependencies. A custom worker environment
directory explicitly opts that sheet into an existing server environment instead
of managed preparation.

A request records installation intent before making directories. An agent-owned
async task creates a venv, installs packages, checks pip/Bundler, and publishes
ready.json before marking the database row ready. Venvs are created at their
final absolute paths; moving a prepared venv could invalidate executable scripts.
stdout/stderr stream to per-attempt logs. Processes have bounded execution time.
No worker or connection owns the installation task.

The first Run requests preparation if necessary and waits in `preparing`. Two
requests for the same specification share one task. Stopping the Run stops its
wait; preparation can finish for a future Run. Different specifications create
different directories. A failed attempt preserves every previously ready version.
Workers pin their selected generation; a changed specification requires explicit
restart, without replaying cells. A new generation can be prepared while an old
worker remains alive. Agent restart preserves ready generations; unfinished
attempts become interrupted and need an explicit retry. Retries use new paths.
An existing runtime also pins its installation attempt, so a retry after a
cancelled preparation requires Restart Worker before that runtime can run again.
Interrupted attempts are conservatively retained by GC because installer death
has not been proven. Gateway restart and client reconnect do not interrupt tasks.

## API and operations

### Notebook dependency editor

Open **Notebook Settings → Manage Dependencies**, or the package button beside
**Dependencies** in the sidebar. The editor has Sputnik, Python / venv and
Ruby / Bundler tabs and follows the selected local or remote execution host.

Sputnik installations belong to the notebook: local `packages/`, or remote
`state/projects/<project-id>/packages/`. Install accepts a registry name, a
source directory or a `.sputnikpkg` artifact; remote source paths name files
on the server. Remove targets an installed name/version and leaves shared
packages and original source directories alone. Source links remain available
in the same editor. Native installation uses the compiler and ABI headers
bundled with the app; server agents accept `--sputnik /path/to/compiler`.
System C/C++ tools and the Python/Ruby SDKs must already be installed.

The Python tab edits `requirements.lock` when present, otherwise
`requirements.txt`. The Ruby tab edits Gemfile and explicitly resolves
Gemfile.lock. Removing a declaration and preparing a new environment removes
that dependency from the new generation; previous generations remain intact.
The editor shows installed Python/Ruby versions from the last ready generation,
installation states and stdout/stderr logs. It does not install interpreters.
Local interpreter executables can be selected before preparation; server
interpreter configuration remains an agent option.

Save checks the original file bytes and rejects external edits or symlinked
dependency files. Ruby resolution returns a draft lockfile without mutating an
immutable server revision; the client saves it with the same conflict check.
Prepare publishes the saved inputs to the server, or uses the same managed
installer locally under `.sputnik/dependencies/`. A successful preparation
restarts the notebook's idle workers and selects the new generation. It never
replays cells. Package mutations reject active runs and wait for idle worker
termination before changing files. Uploaded snapshots exclude installed
package versions under `packages/`, venvs and `vendor/bundle`; server-native
artifacts stay on the server. Source directory overrides under `packages/`,
wheels and cached gems remain source inputs.

Server package operations are agent-owned durable jobs. Reconnect to inspect
their status and logs; disconnect does not cancel an installation. Agent
restart marks an unfinished package operation interrupted and requires an
explicit new operation. GC protects unresolved interrupted operations.

### Protocol

Existing authenticated gateway/RPC/CLI paths carry the new operations:

- GET /v1/projects/{id}/environments lists durable records.
- POST /v1/projects/{id}/environments accepts command_id and optional retry. It
  returns the shared environment/attempt status without waiting for installation.
- GET /v1/projects/{id}/environments/{environment-id} returns metadata and tails
  of stdout/stderr (64 KiB per stream).
- PUT /v1/projects/{id}/worker-settings/{sheet} accepts environment_directory;
  empty selects automatic management. CAS version, runtime epoch, active-run
  exclusion, receipts and explicit reset apply just as for worker grants.
- CLI commands: environments and prepare_environment; the latter reads a normal
  JSON request file. Run still prepares automatically if no separate request was made.
- GET /v1/projects/{id}/dependencies returns notebook package inventory,
  environment generations, resolved package lists and recent operations.
- POST /v1/projects/{id}/dependencies accepts command_id, action
  (`install_sputnik`, `remove_sputnik`, `lock_ruby`), source and optional version.
  It returns an operation ID with the existing receipt semantics.
- GET /v1/projects/{id}/dependencies/{operation-id} returns durable status,
  result and bounded log tails. CLI: dependencies, change_dependency, dependency.

Server pycall/rbcall Sputnik packages must be installed for the server platform.
Native loading is authorized by both worker ffi.call and ffi.load grants;
no capability comes from an uploaded notebook document.

## Orphan collection

A disconnected or old registered project is still owned and cannot be collected.
Only direct children of state/projects carrying a valid agent ownership marker
are candidates. Unknown directories and symlinks are skipped. Active/deleting
projects, runtime owners, queued/installing tasks and unresolved interrupted
attempts protect the whole project directory.

The registry records when a candidate was first observed as orphaned, including
its ownership token and filesystem identity. A changed identity resets its age.
Collection checks identity again immediately before removal. Child symlinks are
removed as directory entries; their destinations are not traversed. Registration
and collection are serialized by the agent owner lock. Database errors abort
collection rather than treating the registry as empty.

POST /v1/maintenance/orphans accepts command_id, minimum_age_seconds (default
604800) and dry_run (default false). Receipts make retries idempotent. Dry run
reports eligible/pending IDs without deleting files. CLI gc_orphans submits the
same JSON request. Project tombstones and historical run records remain.

Agent options --orphan-gc-interval SECONDS and --orphan-min-age SECONDS enable
periodic collection; interval 0 (default) disables it. Scheduled and manual runs
use the same checks. Last connection/access time never authorizes deletion.
The collector currently handles orphaned project environment trees, not history,
run artifacts, arbitrary user work directories or still-owned superseded versions.

## Validation

The remote integration suite installs offline wheel and gem fixtures, imports
them from a real notebook worker, reconnects through a replacement gateway,
restarts workers and the agent, checks failed installation logs and isolated
retries, and verifies automatic preparation on first Run. It also exercises
scheduled/manual GC, ownership identity changes, protected interrupted attempts
and symlink handling. Run with `--bridges --python <matching-python> --ruby
<matching-ruby>` to include both native bridges.

Worker tests cover discovery and rejection of configuration changes. Bridge
tests exercise selected environments in VM and full native execution; compiler
tests verify foreign imports captured in notebook blocks.

`make test-notebook-dependencies` exercises the macOS editor controller: file
conflicts and symlink rejection, local package install/remove, venv preparation,
Ruby lock resolution and bundle installation, worker selection, and a native
pycall import with explicit worker grants when the configured sibling package
is available. It also renders all three editor tabs. `SPUTNIK_TEST_PYTHON` and
`SPUTNIK_TEST_RUBY` select interpreter executables for that check.
