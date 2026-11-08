# Cell execution time and Stopwatch

Every executed code cell shows elapsed time beside its running status. It ticks
while execution is active and retains the final duration after completion,
failure or Stop. Each Run All cell is measured separately. Timing starts when
the cell is dispatched, excluding worker preparation, and includes its result
capture. Time uses a monotonic clock. Force Stop freezes the last received live
measurement; it cannot recover an exact final timestamp from a killed process.

Sheet runs that prepare a new package/module environment show a rebuild icon beside
the cell timer. Its **Environment rebuilt** tooltip separates environment
preparation (compilation, package/native verification and module initialization)
from cell execution, in milliseconds. Preparation is shared by the cells in that
run and is excluded from their individual execution times. A subsequent cell run
that reuses the environment clears the mark for that cell. The context travels
with live results and retained run history; older results have no rebuild mark.

Add **Stopwatch** from the board designer's Display category to time a smaller
block of code. Set its **Stopwatch ID** to the channel published by the code:

```sputnik
from notebook.ui import Stopwatch
import task

value = Stopwatch.measure("training"):
  task.sleep(2000)
  42
```

The block returns its ordinary value (`42` above), propagates exceptions and
supports cooperative cancellation. It publishes a running channel before the
block starts, allowing the board to tick during silent work or sleep. The final
time remains visible. `Stopwatch.measure: …` uses channel `default`. Different
IDs support nested measurements. Reusing a completed ID starts a new measurement;
overlapping measurements with the same ID in one cell are rejected. IDs are
nonempty Str/Symbol values of at most 256 UTF-8 bytes without NUL, sharing the
run's bounded live channel budget. No extra package dependency is required.

The board binds to the controller sheet's channel, so a Stopwatch can be used
without selecting a source cell. Completed snapshots are marked stale after
editing their source. Timers stop when execution ends or the worker is killed.
Local and remote workers transport both cell timing and Stopwatch channels in
presentation schema v16, which adds environment rebuild timing. Saved v11–v15
results remain readable; v11/v12 have no cell timings.

Try `tools/notebook-macos/Samples/Stopwatch.sputnikbook`.
