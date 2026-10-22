# Images and image carousels

Add **Image** or **Image Carousel** in Board Designer and set its **Channel ID**.
The board owns layout and sizing; code publishes immutable image data to the
channel. Both components support **Fit**, **Fill**, and **Auto height**:

- Fit preserves the entire image inside the viewport.
- Fill preserves aspect ratio and crops the image to fill the viewport.
- Auto height derives the viewport height from its width and the current
  image's aspect ratio. Use a row without an explicit height.

An Image displays the first frame in its channel. A carousel displays one
frame at a time with Previous/Next controls and a position counter. Each frame
can have a caption; the series can have its own caption. The designer's optional
caption supplies a default when code publishes an empty series caption.

The inspector has three independent options, off by default:

- **Allow saving to a file** shows Save image, exporting the current frame's
  original PNG/JPEG bytes through a save dialog.
- **Allow loading and editing images** shows Load image (or Add images for a
  carousel) and an Edit menu. Choose one or several files; remove the current
  image or move it earlier/later. Imports are copied into `images/` inside the
  project, with their captions and order saved in the board manifest.
- **Allow reading from sheet code** enables `read_image` and `read_images`
  for the component's channel. Without this option, reads fail explicitly.

The carousel's selection is shared with the sheet and captured at the start
of a cell. Editing, selecting and importing images never runs user code.
Run the consumer cell explicitly to read the new selection or collection.

Declare a dependency on `sputnik-lang/packages/notebook_ui` and import the API:

```sputnik
from notebook.ui import image, publish_image, publish_images, add_image, clear_images, read_image, read_images

# PNG/JPEG Bytes: dimensions are inferred from the encoded header.
publish_image("photo", image(fs.read_bytes("photo.png"), caption: "A single frame"))
publish_images("gallery", [
  image(fs.read_bytes("first.png"), caption: "First image"),
  image(fs.read_bytes("second.jpg"), format: :jpeg, caption: "Second image")
], caption: "A caption for the whole series")

# Raw samples: Array<Int> or Bytes/ByteSlice/ByteBuffer, values in 0..255.
add_image("gallery", image([0, 80, 160, 255], width: 2, height: 2,
  format: :gray, caption: "Raw grayscale pixels"))
# RGB/RGBA samples are interleaved, row-major, top to bottom.

# Enable reading in the component inspector first.
current = read_image("gallery")         # current selection; null if empty
frames = read_images("gallery")         # ordered Array of image descriptors
first = read_image("gallery", index: 0) # explicit zero-based index
# Descriptors contain data: Bytes, width, height, format, caption,
# series_caption and index. They can be passed to publish_image.
clear_images("gallery")
```

`publish_image` and `publish_images` replace the channel atomically. `add_image`
appends a frame; its optional `caption:` sets the series caption, while `null`
(the default) preserves it. `clear_images` publishes an empty channel.
Image descriptors accept `format: :png` (default), `:jpeg`/`:jpg`, `:gray`, `:rgb`
or `:rgba`. Encoded images infer dimensions; explicit dimensions must agree
with their headers. Raw images require `width:` and `height:`.

Publication requires an active notebook run. A channel retains at most 64
images. Each image is bounded to 8192 pixels per side, 16 megapixels and 16 MiB
of encoded data; all retained live figures/images share a 64 MiB budget.
Captions have a 64 KiB limit and share the run's 256 KiB text budget.
Raw pixels are converted to PNG by the runtime. Only inert bytes and metadata
cross the worker boundary; ImageIO validates and decodes bounded native previews.

Code publications are runtime state. Reopening a project requires a run to
publish those outputs again. Imported/edited collections persist and are
available to both the board and sheet immediately on reopening. A code
publication replaces the visible collection, while `add_image` appends to
the current collection, including imported frames. An explicit UI edit takes
ownership of that channel and persists the edited frames, even if they were
originally produced by code. Cell reruns reset their runtime outputs;
edits/failures mark prior output stale. Progress/chart-only live updates
preserve current image channels. Partial or malformed worker transfers never
become visible.

The MNIST showcase publishes `worst-validation` after training finishes. Its
final validation pass computes unreduced cross-entropy, ranks every held-out
sample by descending loss (ties by dataset index), and selects at most ten.
Pixels are reconstructed from the dataset's normalization. Captions identify
the validation sample, true label, predicted label, prediction confidence and
loss. The split is the held-out MNIST test corpus; training never uses it.

Run `make test-notebook-images` for package/VM, store lifecycle, worker transport,
native model, PNG/JPEG decoding, board persistence and sizing checks. Native
previews of the three modes and palette are saved under `build/image-components`.

The optional annotation editor has zoom in/out, Fit, 100% (one screen point per
source pixel), Zoom to selection, and a Pan tool for moving a magnified image.
It decodes the original image resolution once for precise inspection. Zoom and
pan affect presentation only: drag coordinates are transformed back to source
pixels, with the origin at the top left. The selected point has editable X/Y
inputs; a rectangle has X1/Y1 and X2/Y2 inputs for its two corners. Changing a
corner preserves the opposite corner and keeps the rectangle inside the image.
Annotations snap to whole source pixels at every zoom level. Points address
zero-based pixel indices and are drawn at their pixel centers; rectangle corners
snap to the nearest pixel boundaries, with exclusive right/bottom edges and a
minimum size of 1×1 pixel. Coordinate fields show integers and reject fractional,
invalid or non-finite input, disabling Apply until corrected. The backend also
rejects fractional coordinates and sizes. Undo/Redo, JSON export and Apply use
the same pixel-aligned draft. Legacy fractional annotations remain available for
review: opening the editor snaps them to pixels, and consumers read null until
the corrected draft is applied.
`make test-notebook-component-data` checks viewport transforms and edits the
native coordinate fields before verifying the accepted backend snapshot.

Board Designer → image component → **Classes & attributes** owns the allowed
class list and typed secondary attributes (text, number, Boolean, choice).
Runtime annotation selects one or more configured classes per shape and fills
their values; the free-form region title is separate from class membership.
Accepted image JSON includes a `classes` schema snapshot and per-shape `classes`
IDs / `attributes` maps. Unknown classes, schema changes and invalid attribute
types/choices are rejected by the backend. Incompatible labels are retained for
review when the schema changes, but consumers read null until a valid Apply.

Verification on 2026-10-13 also completed five full MPS epochs with CPU fallback
disabled: 60,000 training samples, 10,000 validation samples, 2,345 optimizer
steps and 98.69% accuracy. The native model decoded all ten 28×28 frames;
the first was validation #2294 (true 9, predicted 6, confidence 61.2%, loss
6.6543). Native event tests exercised Next/Previous, both caption levels,
JPEG publication and image resizing. The preview is saved as
`build/image-components/mnist-worst-10.png`.
