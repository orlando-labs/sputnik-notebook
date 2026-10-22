# Cell execution time and Stopwatch

Every executed code cell shows elapsed time beside its running status. It ticks
while execution is active and retains the final duration after completion,
failure or Stop. Each Run All cell is measured separately. Timing starts when
the cell is dispatched, excluding worker preparation, and includes its result
capture. Time uses a monotonic clock. Force Stop freezes the last received live
measurement; it cannot recover an exact final timestamp from a killed process.

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
presentation schema v13. v11/v12 saved results remain readable without timings.

Try `tools/notebook-macos/Samples/Stopwatch.sputnikbook`.
