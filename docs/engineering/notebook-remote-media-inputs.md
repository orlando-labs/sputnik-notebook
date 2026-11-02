# Managed media inputs over Core

29 October 2026. Stage 4g.2.1 extends the common remote contract and web boards
with explicit acceptance of File Input, Audio Input and Image/Carousel assets.
It uses the ordinary native input schema and worker validation; it adds no
notebook evaluator or general filesystem authority to the browser.

## Transaction and identity

The web transport is `POST /api/projects/:id/media-inputs`, with an authorized
command-receipt lookup. The backend calls `media.accept` through Core local RPC.
`media.accept` takes project/board/component IDs, exact source revision and
accepted-parameter `base_version`, a durable command ID, replace/append/clear,
file extension, display name and base64 bytes. The web adapter authorizes the
current execute role before every command, and read access before receipt or
asset inspection. It validates HTTP metadata and never accepts a server path.
The common Core checks revision/version, active work, dependency changes,
project lifetime, content size, component binding and configured extensions.

A disposable staging directory holds the existing immutable bundle and candidate
bytes. `sputnik-notebook-worker --media-input` uses the same project parser,
image/audio codecs and typed component definitions as native clients. It never
creates a Session or executes notebook code. Accepted assets have SHA-256 names
under `inputs/`, `audio/` or `images/`. The content must match its name on every
ordinary bundle save/import as well. Existing unknown metadata and exact Int64
values survive the transaction.

Core commits the complete document, files, accepted parameter state, new revision
and command receipt together through its existing revision path. File Input
requires a String project definition; its portable value/default becomes the
managed relative identity. Audio retains `audio_asset`/`audio_name`; images retain
`image_items`/revision/selection. Other authored defaults and current scalar input
values are retained. Clear is an explicit accepted empty value. An Image replaces
one image; a Carousel can replace, append one file per Apply, or clear the series.

The operation does not run code. It rejects while any project worker is active,
so an accepted revision never changes underneath an executing run. Run provenance
continues to retain its original document and asset revision. Same-command replay
returns its original receipt; changed content with the same command ID conflicts.
Rejected validation/CAS/quota requests publish neither a head nor a receipt.
Staging is removed in `ensure`; orphan staging after a crash follows Core GC.

## Runtime boundary

The existing Sync message accepts an optional immutable revision directory from
Core; native clients retain their original message form. It checks/loads assets
from that directory before publishing a synchronized input map. Content-addressed
managed data is excluded from the module environment fingerprint, so replacing
it does not force a module-world restart. Source/dependency changes retain their
existing restart semantics.

File Input values remain relative identities in persisted execution documents
and HTTP DTOs. Only the worker resolves them to its private `managed-inputs`
namespace. Read-only hard links refer to the validated immutable revision bytes
on the same Core filesystem. The world receives an fs.read grant for that empty
private namespace from its first synchronization; subsequent acceptance does not
widen its immutable grants. It grants neither fs.write nor reads outside that
namespace. Old links are removed on the next idle synchronization. The current
worker revision stays protected by existing retention; links do not copy asset
bytes or retain obsolete revisions after synchronization. Normal operator grants
remain independent.

Audio Input uses `AudioTrack.from_input`; image consumers use
`notebook.read_image(s)` and require native `image_allow_read`. Input changes
invalidate the native graph on the next explicit Run. Existing streams/player
activation behavior is unchanged. Opening a board, choosing, previewing, clearing
a draft, and Apply do not start a worker run or charge computation.

## Bounds, recovery and UI

Each file is non-empty and at most 16 MiB (except explicit Clear); the complete
bundle keeps its existing 64 MiB / 2048-file bound. Audio also retains its codec
and decoded-PCM limits. PCM16/float32 WAV validates without a system decoder;
other accepted audio encodings require the host's bounded system audio codec.
PNG/JPEG use the existing native raster contract; the browser also decodes a
chosen image before presenting its draft. A Carousel keeps native 64-image and
aggregate image/text limits. Source storage, retained revisions and disk/user/Core
ceilings are charged through the existing storage policy. A conservative staging
space reservation precedes filesystem writes. Unused prior assets stay in the
bundle and count toward its limits, matching native managed-media retention.

The board editor exposes File Input, Audio Input and image load/read settings.
Runtime controls provide choose, local preview, Discard, Clear and Apply; image
collections expose append and accepted-image choice. Accepted previews load one
selected file at a time through the existing authorized revision download route.
Audio reuses the shared player and does not autoplay after opening/reload.
Disconnect/revocation closes accepted previews and clears their cached bytes;
local unapplied drafts remain separate. A failed media journal does not disable
ordinary scalar parameter controls. Published images retain the shared renderer.

Unapplied media bytes stay in component memory. Apply first stores the exact
command/bytes in an IndexedDB journal scoped by account/project. A lost response
keeps that command for receipt lookup after reload; retry is explicit and reuses
its exact ID/content. Nothing is posted automatically on reconnect. Successful
acceptance refreshes the saved notebook, inputs and registry. Source editing is
disabled during an unresolved media mutation, and concurrent parameter/source/
other media drafts must be saved or discarded explicitly before acceptance can
replace the displayed source snapshot.

Public temporary preview continues to use its existing cumulative 60-second
server budget. This slice adds no anonymous upload endpoint or recording API.
Stage 4g.2.2 below adds microphone capture and accepted-image annotations. Audio
annotation editors, date/time, presets and shared selection bindings remain
subsequent slices of 4g.2.

[Verification](../evidence/2026-10-29/notebook-web-media-inputs/README.md).

## Accepted-image annotation transaction (4g.2.2)

`media.accept` also accepts `operation: "annotations"`, `extension: "json"` and
base64-encoded native annotation JSON. It uses the same ACL, idle requirement,
revision/input-version CAS, storage accounting and command receipt. The worker
checks `image_annotator`, native geometry/schema, channel, hash and dimensions
against a managed accepted image in that controller sheet. This operation stores
metadata without changing image bytes or running code. Browser drafts capture
the original revision/version on open, so later source edits cannot silently
retarget acceptance. Completed publication and audio annotation support is described below.

Audio capture stays entirely in the browser until the ordinary replace/Apply
transaction. An external static AudioWorklet module captures bounded PCM; no Blob
script or eval exception is added to CSP. The web app's SecurityPolicy subclass
keeps Orbit's standard headers and changes microphone permission to `(self)`.
Browser permission remains mandatory, with no request on page load. Hidden or
revoked views and canceled/late permission attempts release resources.

[Capture/annotation verification](../evidence/2026-10-29/notebook-web-capture-annotations/README.md).

## Audio annotation and completed publication extension (Stage 4g.2.3)

GET `/api/projects/:id/media-inputs/source?revision=…&board=…&component=…`
requires read access and calls `media.source`. Core checks current revision,
lifetime and idle runtime, charges disposable bundle storage against effective
quotas, then asks `--annotation-source` for immutable identity and bounded f32le
PCM at the original rate. Encoded hash/source/channel/cell/rate/channels/frames
are authoritative; the source DTO cell is a decimal string to preserve Int64.
No browser-supplied server path or encoded identity is trusted. PCM WAV is decoded
portably; other codecs use the existing system backend. No run is started.

The existing `operation: annotations` chooses `audio_annotations` for an Audio
Annotator and `annotations` for an enabled Image/Carousel. Audio Apply additionally
checks the configured file/input/cell binding, original encoded SHA-256, exact
decoded metadata, frame/Hz regions, configured classes/attributes and transcript
policies. Clearing accepted labels uses JSON null. Input source changes invalidate
labels without dropping persisted repair metadata.

For completed cell sources, Core selects the controller's own retained current
presentation, verifies unchanged authored code and no runtime/dependency reset,
and passes that private binary to the existing native presentation decoder.
Active streams cannot be annotated. Image channels use the latest authored cell
publication over an accepted input, matching native precedence. Source hash and
metadata are checked again during Apply. The same receipt/CAS/ACL/storage path
commits labels. An annotation-only revision does not prevent reopening an
unchanged completed publication. Replaced audio/images invalidate old labels.

The web waveform/spectrogram runs locally in a bounded module Worker. Vite
requires a same-origin starter module; the static development starter imports
only the audio worker entry and retains Orbit's existing configured-origin CSP.
Production uses its emitted hashed worker. No CSP eval/Blob-script permission is
added. Public notebook execution retains its cumulative 60-second ceiling.

[Verification](../evidence/2026-10-29/notebook-web-audio-annotations/README.md).

## Shared table selection (Stage 4g.2.4)

A table owner configures selection_id and selection_key. The existing read-only
media.source method returns the raw bounded native table JSON plus its SHA-256;
it uses only the retained completed publication selected by Core. The browser
preserves raw Int64 tokens and uses the typed snapshot for sorting/filtering.

The existing operation annotations selects native kind selection for a table
owner, validating its configured channel and native 256 KiB scalar row schema.
Core checks source hash, exact configured key column, unique/non-null keys,
unique column names and equality of the entire key/row with a retained source
row. JSON null explicitly clears selection. This reuses execute ACL, source
revision/input-version CAS, idle/dependency checks, effective storage quotas and
receipts, and never evaluates notebook code. Media bindings read the accepted
selection row's configured asset column and match original encoded SHA-256.

Date and preset runtime Apply use the existing atomic project.inputs.set path;
authored preset changes use ordinary notebook Save and retain source conflict/
receipt semantics. Public computation remains capped at 60 cumulative seconds.

[Verification and SDK compatibility](../evidence/2026-10-29/notebook-web-selection-controls/README.md).
