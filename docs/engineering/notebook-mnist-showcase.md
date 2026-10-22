# MNIST in the native macOS notebook

Implemented on 2026-10-02; board-owned chart channels added on 2026-10-13.
This is real Sputnik/LibTorch training,
not simulated progress or prerecorded plots. No Python is involved in training,
native package preparation or the MNIST verifier.

## Open the prepared project

The local build produces `build/Sputnik Notebook.app` and
`build/MNIST-Showcase.sputnikbook`. Open the project in that app, choose **Run All**
on the sheet (or **Run Sheet** on *Training dashboard*), then **Trust and Run**.
Opening/previewing the document does not execute code or load native libraries.
Native projects automatically use the isolated helper even when opened in Finder.

The settings cell controls `device`, `epochs`, `batch_size`, dataset limits and
`plot_throttle_ms`. These are ordinary notebook locals. Changing them does not
silently restart training. The training module imports the original MNIST reader,
SmallResNet, optimizer and scheduler from the linked sputniktorch directory.
Neither sputniktorch nor plot sources are copied into project modules.
Prepared SputnikTorch dependencies now use a coherent versioned package
snapshot; package preparation automatically updates registered projects.

The board defines separate live-chart components for loss and held-out accuracy.
Its **Progress** component binds to the training code cell (ID `5` in generated
projects, displayed as position **04**) and channel `mnist-training`. The
parameter cell (ID `3`, position **02**) does not
publish training progress. For an existing board, select Progress in Design and
choose the cell containing `metrics = train_mnist(...)`; set Progress ID to
`mnist-training` or leave it empty for all channels from that training cell.
The training module publishes numeric points to their channel IDs using
`notebook.ui.publish_point`; it does not construct chart objects or fix their
canvas size. The board renders each chart in its current grid bounds. Direct
`notebook.show(plot.Figure)` remains the separate static-figure path. See
[board chart details](notebook-board-live-charts.md) for the data contract.

The sheet contains editable rich-text headings and interpolated result fields.
The board shows two responsive live charts, a final accuracy value and an image
carousel with the final model's ten highest-loss validation samples. Each frame
shows its true label, predicted label, confidence and cross-entropy; the series
has its own caption. Rankings cover the entire held-out split and use dataset
index to resolve ties. See [image component API](notebook-board-images.md).
Static
figures retain the existing lightbox actions. Outputs are runtime state, not
saved checkpoints: reopening the project requires an explicit run. Training
does not write a model checkpoint.

## Rebuild from sibling repositories

From the Sputnik workspace, with LibTorch and package build prerequisites installed:

```sh
cd sputniktorch
./tools/fetch-mnist
./tools/build examples/showcase.s --prepare-notebook
cd ../sputnik-notebook
make -j2 notebook-macos build/notebook-mnist
./build/notebook-mnist prepare ../sputniktorch ../plot build/MNIST-Showcase.sputnikbook
open -a "$PWD/build/Sputnik Notebook.app" "$PWD/build/MNIST-Showcase.sputnikbook"
```

For an existing edited notebook, update it in place instead of regenerating:

```sh
cd ../sputniktorch
./tools/build --prepare-notebook --notebook-project ../sputnik-notebook/build/MNIST-Showcase.sputnikbook
```

The registration makes later successful package builds refresh its dependency
automatically. Cells/settings remain unchanged; reopen the project after an
external dependency update. New MNIST projects register automatically. See
[package update contract](../../../sputniktorch/docs/notebook-packages.md).

Preparation refuses to overwrite an existing project. Use a new output path
when regenerating. Add `--smoke` for 1 epoch, 1,024 train / 256 test images.
The full showcase uses all 60,000 / 10,000 images, five epochs and MPS.
Dataset download is explicit, separate from build/run. No automatic CPU fallback:
select `device = "cpu"` yourself if MPS is unavailable.

The generated dependency declares a root-relative build manifest and prepared
native library, plus its SHA-256. The worker verifies root containment, artifact
size, digest and extension ABI before loading. A changed already-loaded library
requires a worker restart. Native trust grants FFI and file reads; native code
is **not sandboxed** and may access anything the user process can access.
This is local prepared-artifact loading, not an automatic arbitrary-package builder.
The hash detects changed build artifacts; it is not race-free code attestation:
do not replace a library concurrently with loading (hashing and `dlopen` are
separate operations). Only load native code from trusted directories.

## Live output contract

```sputnik
from progressbar import ProgressBar
from notebook.ui import publish_point

pb = ProgressBar(total: steps, desc: "Training", throttle: 0.1, id: "training")
publish_point("loss", step, value)
pb.inc!
pb.end
```

`publish_point` accepts a board chart channel ID and two numeric coordinates.
The host coalesces numeric deltas and the native chart view renders them at the
component's current size. Progress is separate, deliberately nontransactional
telemetry.

`array.with_progress(desc: ..., throttle: ...).each |item|: ...` is supported
after importing progressbar. The package also supplies `with_progress(source, ...)`
for custom/lazy sources and stderr rendering outside notebooks. Since `inc!`
has an optional argument, Sputnik's current syntax requires `inc!()` rather than
the bare optional-argument call. `end` can be called bare.

## Verification

```sh
make test-notebook-progress test-notebook-worker
PYTORCH_ENABLE_MPS_FALLBACK=0 ./build/notebook-mnist verify "$PWD/build/sputnik-notebook-worker" build/MNIST-Showcase.sputnikbook
PYTORCH_ENABLE_MPS_FALLBACK=0 ./build/notebook-mnist verify "$PWD/build/sputnik-notebook-worker" build/MNIST-Showcase.sputnikbook --stop
PYTORCH_ENABLE_MPS_FALLBACK=0 ./build/notebook-mnist verify "$PWD/build/sputnik-notebook-worker" build/MNIST-Showcase.sputnikbook --force-stop
```

Native AppKit/SwiftUI end-to-end harness (explicit test-only trust):

The harness verifies intermediate and completed progress through the board's
actual cell/channel bindings, so a progress event elsewhere in the sheet cannot
make a misbound board component pass.

```sh
PYTORCH_ENABLE_MPS_FALLBACK=0 'build/Sputnik Notebook.app/Contents/MacOS/SputnikNotebook' \
  --trust-native --showcase-test build/MNIST-Showcase.sputnikbook \
  --live-snapshot-png /tmp/mnist-live.png --snapshot-png /tmp/mnist-final.png
```

Earlier end-to-end showcase verification on macOS arm64 with Homebrew LibTorch
2.14.0 and MPS (CPU fallback disabled) recorded:

- 19,706 parameters, 2,345 optimizer steps, 5 full epochs.
- Test accuracy **98.69%**, test cross-entropy **0.0445108**.
- Worker verification: about **47.65 s**, 407 live snapshots and 93 distinct
  figure images (loss plus accuracy); native GUI runs: about **49–52 s**,
  90 observed changing loss frames and a real intermediate progress count.
- Cooperative cancellation and confirmed SIGKILL exit during MPS training.
- Binder/emitter/VM regressions, actual progressbar package hook and CLI receiver,
  collection wrapper, bounded replacement/throttling, transport and host tests.

Timings depend on hardware/load and include presentation overhead. The local
app bundles Homebrew libraries requiring macOS 26; this is reflected in its
Info.plist, despite the source compilation target being macOS 14.
Verification artifacts are generated locally during validation and are not kept in the source tree.

Those GUI chart-frame counts were recorded before the board-owned numeric
channel refactor. They describe the training run and previous presentation path,
not a verification of the current Live Chart view.

## Boundaries

Force Stop kills the isolated process, not a macOS kernel/GPU driver. Arbitrary
native helper process trees/device-driver recovery remain separate work.
The worker still rejects project inputs and module-tab Run; use saved module
functions invoked by a sheet. Idle runtime watch-event pumping and persistent
background-job/periodic scheduling are not implemented by this showcase.
Ordinary non-native projects retain the in-process backend unless launched with
`--isolated-worker`. Progress/live convenience APIs currently target the VM,
not standalone native code generation. The app build is ad-hoc signed, not notarized.
