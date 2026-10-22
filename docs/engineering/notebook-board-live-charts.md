# Board-owned live charts

A live chart is a saved board component. The board owns its identity, title, caption,
axis labels, color, optional X/Y limits and position. Notebook code publishes numeric points to its
channel ID:

```sputnik
from notebook.ui import publish_point

publish_point("loss", step, cross_entropy)
```

Add a **Live Chart** in Board Designer, then use its Channel ID in
`publish_point`. For the MNIST showcase the board declares channels `loss` and
`accuracy`; `train_mnist` only sends samples. It does not instantiate chart
objects or choose figure dimensions in the training module.

The designer's **Caption** field saves descriptive text below the chart,
separate from the title and axis labels. Captions use monospaced text, wrap
at the card width and reserve space within fixed-height rows. They remain
visible while waiting for points. Numeric channels do not carry the captions
from `notebook.show`; the MNIST board supplies the original loss/accuracy
descriptions itself.

The runtime retains a rolling window of at most 65,536 points per chart and
coalesces point deltas for the host. A run can retain up to 524,288 live points
across up to 64 channels. Points are finite numeric pairs; chart history is
runtime display state, not a saved training artifact. The board renders the
series with the same native scene renderer as `plot.Figure`: white paper,
fine gray grid, left-hand Y ticks, horizontal Y label and centered title.
Static and live charts use monospaced system fonts throughout: a 20-point
semibold title, 11-point regular ticks, 13-point regular axis labels and
monospaced annotations/colorbar labels at their specified sizes. This carries
the plot package's portable PNG aesthetic into the native viewer, with the same
explicit text/grid/border colors. Measurement, drawing and PNG export share
these font metrics.
Layout is resolved in the current card bounds, so typography and stroke widths
use normal UI point sizes as the grid changes. Dense data is sampled for drawing
while retaining local extrema and the complete bounded numeric history.

Live paints are coalesced to one every 500 ms. Progress updates or unchanged
samples do not rebuild the scene. Completing/stopping a run flushes the newest
samples immediately. This cadence applies to board live charts;
`plot_throttle_ms` in the MNIST function applies to its `:plot` compatibility mode.
The native canvas shares drag-to-zoom and double-click reset with static plots.
Their common viewer controls provide **Axes…** (explicit X/Y limits),
**Save PNG…**, and a visible **Reset axes** badge after selecting a range.
Explicit viewer ranges remain selected as new points arrive. Reset returns to
the current automatic/board-defined range. PNG export freezes the displayed
data and chosen axes before showing the save dialog, includes all retained
points, and rasterizes at the display's backing scale with the on-screen
layout and typography.
Board Designer can set `x_min` / `x_max` and `y_min` / `y_max` independently;
clearing a limit restores its automatic value. The channel, labels, color and
each range limit have persistent visible field labels in the designer; the
viewer's axis editor also labels all four bounds. MNIST accuracy declares
epochs 1–5 and 0–100%, and integral X data uses integer tick labels.

This is separate from static figures. A **Figure** component still selects a
sheet cell and displays its `notebook.show(plot.Figure)` output batch. Static
figures retain the existing PNG/scene viewer, lightbox, zoom, save and share
actions. Live charts transfer numeric samples and render in the board.

The worker protocol carries bounded numeric point deltas and an explicit cell
reset when a cell begins a new run. Rolling windows append new samples and
retire the oldest samples at the host without retransmitting the whole history.
The UI merges those deltas away from the execution thread. Cancellation retains
the last received samples as nontransactional telemetry, labelled stale.
Single-sample series render as a point, and display sampling preserves local
minima and maxima so narrow charts retain training-loss spikes.

Regression checks cover project opening and board editing through the native
bridge, chart resets and delta merging across worker/UI polling batches,
long-running point windows, single-sample series, selected-axis synchronization,
shared font weights/sizes and Retina PNG exports from displayed snapshots.
The MNIST verifier also
requires final samples for both the loss and accuracy channels. A 2026-10-13
MPS smoke run used 1,024 train / 256 test images for one epoch. The later style
and performance check also ran five full epochs with 60,000 train / 10,000
test images, comparing two runs each after warmup with a real visible window.

| Presentation | Mean complete training/evaluation time |
| --- | ---: |
| None | 47.98 s |
| Previous Swift Charts | 50.22 s |
| Responsive native plot canvas | 49.42 s |

The native canvas added approximately 3.0% to this baseline; the previous view
added 4.7%. These wall times include evaluation, and are not instantaneous
optimizer throughput. The reported 80→60 it/s reduction was not reproduced in
this controlled comparison. A separate producer/IPC comparison measured
85.4 optimizer steps/s for point channels and 85.5 without visualization.

To repeat the visible-window comparison:

```sh
make build/notebook_macos_live_chart_tests
PYTORCH_ENABLE_MPS_FALLBACK=0 build/notebook_macos_live_chart_tests \
  --training-benchmark "$PWD/build/sputnik-notebook-worker" \
  "$PWD/build/MNIST-Showcase.sputnikbook" --epochs 5 --test-limit 10000 --trust-native
```

The benchmark changes executable cell sources in worker memory and exports
PNG previews from the actual completed numeric series; it does not save its
benchmark sources over the notebook.

The final 2026-10-13 UI walkthrough opened the main showcase in the packaged
app and completed five full MPS epochs (2,345 loss samples, five accuracy
samples, final accuracy 98.69%). While the run was active, the viewer applied
X=100…400 and Y=0…1 and kept these limits as new samples arrived. Mouse
selection displayed the Reset axes badge; clicking it and double-clicking the
canvas restored the automatic range. Save PNG opened the native save dialog
and wrote a 1,786 × 720 pixel Retina image of the selected interval to
`build/mnist-live-loss-ui-export.png`.
