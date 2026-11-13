# 2D plot views in Sputnik Notebook

Implemented 2026-10-03. This is data-coordinate zoom, not image magnification.

## User contract

```sputnik
import plot
p = plot.figure().line([[0, 0], [1, 1], [2, 4], [3, 9]])
detail = p.view(x: [1, 2.5], y: [0, 7])
notebook.show(detail, caption: "Selected interval")
```

`Figure.view(x: null, y: null)` returns a new figure. Omitted axes retain their
current domain (explicit, or computed from source data). Numeric pairs must
be finite and increasing. Dimensions, layers, styles, labels, aspect policy
and Y orientation are retained. SVG and PNG clip layers to the plot rectangle
and recalculate axes. Annotation labels are omitted if they do not fit whole;
SVG/portable PNG use a conservative text-width estimate, AppKit uses measured
native font bounds. Colorbars describe the original layer values, not a new
normalization of the selected region. `vline`/`hline` span the selected domain.

The macOS sheet and board figure viewer offer:

- Drag a rectangle inside a 2D plot to select a data interval (either direction).
- The corner **…** menu opens **Axes…** (explicit X/Y limits) or **Open…**.
  Axes settings are hidden initially; **Apply axes** or Return applies them.
  The limits editor uses an inset panel with aligned label/input rows. Fields
  and Apply axes share one height; narrow cards put X and Y on separate rows.
- **Reset axes** / double-click restores the current frame's original domain.
  The corner Reset badge appears only while a different view is selected.
- Click / **Open…** opens the lightbox. Its corner **…** menu contains axes
  settings, **Save PNG…**, and **Share…**; raster figures put image zoom there.
- Escape cancels an in-progress selection. Invalid or numerically
  indistinguishable intervals are rejected without changing the plot.

There is no persistent action toolbar or drag-instruction footer below an
unzoomed figure. The interaction hint is available as a tooltip and accessible
description; open settings expose only their active editing controls.

These controls do not invoke Sputnik, rerun a cell, or mutate its graph object.
Explicitly selected ranges survive live frame updates. Reset resumes the
latest frame's domain. An open lightbox receives new frames as well; its range
is independent of the inline viewer after opening. Panel identity currently
follows its position in the figure, so producers should keep live panel order
stable. UI ranges are session presentation state, not project content. To save
a reproducible range, express `view(...)` in a cell/module.

## Boundary and resource limits

`notebook.show` still publishes validated PNG bytes. A `plot.Figure` exposing
`notebook_scene()` additionally supplies a versioned (v1/v2) JSON scene: original data domain,
pixel transform, layout settings, a closed vocabulary of geometry/text
commands, semantic guide/annotation anchors, and colorbar decorations. It
contains no live VM handles, executable code, paths, or callbacks.

The renderer maps source pixels back to data, then into the selected domain.
It regenerates ticks and guides, and clips geometry before handing paths to
Core Graphics. Screen-pixel stroke widths, marker sizes and label offsets are
retained. PNG export uses the same AppKit renderer as the interactive canvas;
font rendering may differ from the package's portable PNG backend.

Runtime preflight accepts only inert scalars/arrays/maps, checks depth/node/
estimated JSON budgets and finite values. Scene transport is capped at 4 MiB
per panel; oversized scenes are omitted and PNG remains usable. This bounds
publication, not the allocation of the scene while Sputnik constructs it. The
host separately validates version, command arity/types/colors, geometry,
layout, node count and numeric ranges. Malformed/unsupported scenes fall back
to the raster viewer. Image and scene bytes both count against retained output
budgets, including live replacement accounting.

Worker framing is version 9; presentation schema is
`sputnik.notebook.presentation.v8`. PNG and scene replace atomically in the same
immutable output snapshot. Older workers are rejected by the normal handshake.
Older plot packages without the method, `plot.Rendered`, and `Figure3D` remain
raster-only. 3D camera manipulation, log/category axes, persistent UI ranges,
pan/history and independently editable color normalization are not in this
increment.

Board-owned Live Chart components use an asynchronous numeric channel. Code
publishes points with `notebook.ui.publish_point(channel_id, x, y)`; the board
draws them at the component's current size. The same viewer controls supply
explicit X/Y limits, the Reset axes badge and direct Save PNG. Live exports
freeze the displayed samples and selected ranges, retain all available points,
and use the display's backing scale. Static and live scenes share monospaced
font metrics for titles, ticks, axis labels, annotations and colorbars, and
the plot package's palette. See
[notebook-board-live-charts.md](notebook-board-live-charts.md). Direct
`notebook.show` plot preparation remains synchronous.

## Verification

`make test-notebook-plots` exercises the real external plot package, captures
its scene through the bridge, decodes it with the Swift renderer, checks
coordinate inverses, reversed Y, equal aspect, bad inputs, clipping, mouse
events and PNG export, and renders a temporary sheet/board in the app.

To exercise the isolated-worker route as well:

```sh
python3 tests/notebook_macos_plot_ui_smoke.py \
  'build/Sputnik Notebook.app/Contents/MacOS/SputnikNotebook' \
  ../plot/src/plot.s --isolated-worker
```

The smoke checks require a decodable interactive scene, not merely a PNG.
`notebook_worker_tests` covers scene transport/limits; `notebook_live_tests`
covers immutable replacement and budgets. The plot package selftest now
returns **53** and includes view immutability, one-axis chaining, SVG/PNG,
annotation visibility, reversed Y scene metadata and very long dashed guides.

## Graph paper and typography (plot 0.3.1)

`plot.graph_paper` now publishes an interactive scene-v2 alongside the validated
PNG. macOS and web accept both v1 and v2; existing numeric live-chart scenes
retain their v1 appearance. Old viewers reject v2 and retain the PNG fallback.
The worker framing and presentation schema do not change: scene JSON remains
an opaque bounded string in the existing transport.

V2 adds `typography: {size, color}`, `ticks: {x_step, y_step}`, and optional
`paper: {ink, spacing, width, height, rgba}`. The RGBA tile is Base64, contains
exactly `width * height * 4` bytes, and has sides `spacing * 10`, with spacing
restricted to 4–32. It is decoded once per scene, cached and repeated from the
canvas origin. No image URL, file path, script or drawing callback is accepted.
The 4 MiB scene budget and ordinary geometry/node limits still apply. Invalid
style, dimensions, pixel payloads, colors and steps reject the scene as a whole.
The SDK's built-in notebook renderer also registers `plot.decode_image` so the
same external package works when linked as a notebook dependency.

The grid is drawn as vectors in data coordinates inside the plot frame, under
data layers. Major lines and labels share one zero-anchored tick calculation;
each interval has ten minor cells and a stronger midpoint. The automatic
1/2/2.5/5 × 10ⁿ step follows viewport and frame size. Explicit steps survive
selection, pan, reset and live replacement. When a fine explicit step is zoomed
far out, the renderer coarsens by powers of ten to bound drawing work; zooming
back in restores the requested step. Equal aspect and downward Y use the same
coordinate transform. Grain and font sizes stay in screen pixels.

V2 text uses the package's size and color (16 px ticks, 18 px axis names and
26 px title by default), with font-aware margins and precision-aware numeric
labels. Geometry is never rerun in the VM during interaction. PNG export and
the lightbox use the same native/canvas drawing path as the inline view.

The real bridge fixture now uses graph paper. Native regression tests cover
validation, both scene versions, grid/tick agreement, reversed Y, equal aspect,
zoom, clipping, mouse selection, reset, live replacement and PNG export. The
web `plot-scene.spec.ts` covers the same grid contract and resource limits;
`rich-results.spec.ts` additionally exercises a real package scene through
zoom, reset and PNG download, preserving the original pixels on reset.
