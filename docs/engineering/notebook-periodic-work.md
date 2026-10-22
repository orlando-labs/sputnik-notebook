# Periodic Work and component categories

The Board Designer palette has Delphi-style category tabs: **Layout** (Tabs),
**Controls** (Input, Run Button), **Display** (Text / Value, Figure, Live Chart,
Image, Image Carousel), and **Services** (Periodic Work).

Services belong to the board, outside its row grids and tab panels. They occupy
no columns, survive row deletion, and can be added with an empty or full grid.
Select a service in the designer's service tray to edit it in the Object Inspector.
The running board shows service controls and history below its visual grid.

## Try it

Open `tools/notebook-macos/Samples/Periodic Work.sputnikbook`, choose its
**Periodic Jobs** board and press **Start**. The exported `jobs.tick()` function
increments a counter once per second. **Pause** stops future invocations after
the current run; **Run Once** invokes a stopped service without enabling it.
Changing the function to `fail` demonstrates error history and **Stop on error**.

To use another module, export a function without required arguments:

```sputnik
package jobs
def tick(): 42
export tick
```

Select `jobs` and enter `tick` in the service inspector. The binding accepts
module/function identifiers rather than arbitrary expressions. Missing modules,
missing exports, argument mismatches, compilation faults and runtime errors
produce visible diagnostics.

## Scheduling and lifecycle

- **After completion** (`fixed_delay`, default): wait the full period after the
  invocation and its child tasks finish.
- **Start to start · skip overlaps** (`fixed_rate`): deadlines follow the previous
  actual start. Ticks before completion are skipped. A busy host skips elapsed
  fixed-rate ticks; fixed-delay work waits for the host with one pending invocation.
  There is no overlap or accumulated catch-up queue.
- Periods range from 0.01 seconds to one year. Scheduling uses monotonic uptime,
  so wall-clock adjustments cannot produce a catch-up burst. A timestamp and
  elapsed duration are recorded for retained runs. App/queue load can delay starts.
- **First run immediately** is on by default. Disable it to wait one period
  following Start. **Stop on error** is off by default.
- **Pause while board is hidden** is on by default. Returning waits one period;
  missed hidden ticks are not replayed. Disable it for background board work.
  Designer sessions suspend service scheduling. Unapplied executable drafts
  also defer ticks; editing a module pauses services until an explicit Start.
- Opening, creating, saving and reopening projects never enable timers.
  Saving changed service settings pauses that service. Closing/replacing the
  project cancels all future timers before retiring its runtime owner.

Each service owns a persistent runtime, separate from the controller sheet and
other services. Module initialization runs at the first explicit invocation;
module state survives later ticks. No controller cells are executed or generated
in the saved project. Saved module changes require an explicit Start/Run Once;
automatic ticks refuse to replace their installed module generation. Unsaved
module tabs must be saved first. Project input values are snapshotted per invocation.

Calls use the host's existing serial owner queue. In isolated-worker mode each
service has its own persistent worker and uses the existing **Stop / Force Stop**
controls. Stop also pauses scheduling; a subsequent explicit Start may recover
an interrupted service. Child work is drained before completion is published,
and unobserved child failures count as invocation errors.

## History

**Store returned values** and **Store errors** are independent. The history mode
is **None**, **All runs**, or **Last N runs** (default: 100 retained records).
Tail eviction spans the selected successful/error records together. Run/error/
skipped counters continue to update when history is disabled. Clear History drops
records without changing counters or module state. Settings edits preserve
applicable history, trimming it to the new policy.

History holds immutable textual result previews and error messages in session
memory; it never retains VM heap values and is not saved to `project.json`.
Reopening starts with empty history and stopped services. All-runs retention can
grow for the life of a session; Tail is the default for long-running work.

## Manifest

Periodic Work is a version 2 board component, with settings in extension fields:

```json
{"id":"poller","kind":"periodic_work","title":"Poll",
 "module_id":"jobs","function":"tick","period_seconds":10,
 "timing":"fixed_delay","retention":"tail","tail_limit":100,
 "store_values":true,"store_errors":true,"run_immediately":true,
 "stop_on_error":false,"pause_when_hidden":true}
```

It has no row, cell, input or value binding, and cannot own tab panels.
Unknown extension metadata remains intact on save. Missing module targets remain
editable broken bindings instead of preventing project open.

## Verification

`make test-notebook-periodic` checks settings validation and roundtrip, persistent
and independent module state, untouched controller/disk source, faults, child
draining, Force Stop/recovery, deterministic scheduling/overlap boundaries,
retention policies, visibility/pause/reopen lifecycle, and native designer/runtime
rendering. Preview PNGs are written under `build/periodic-work`.
