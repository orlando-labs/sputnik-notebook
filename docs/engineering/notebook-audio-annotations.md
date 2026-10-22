# Audio Annotator

20 October 2026. This component follows the accepted image-annotation draft/Apply contract. Audio annotation and spectrogram support are explicitly requested additions to the earlier P2 scope.

## Sources and publication

`audio_annotator` is a Display palette component. Board Designer configures:

- `audio_source`: `file` (default, owns a managed file), `input` (an existing Audio Input channel), or `cell` (a completed AudioTrack publication).
- `audio_id`: owned or referenced channel; default component ID. A cell source also requires `cell`.
- `annotation_id`: accepted-label channel; default `<component>_labels`.
- `audio_view`: `waveform` or `spectrogram`; `audio_fft_size`: 256, 512, 1024, 2048 or 4096.
- `annotation_classes`: the allowed class/attribute definitions, edited in the component inspector's **Classes & attributes** dialog. The same schema editor is available for image annotation components.
- `audio_transcript_allowed` (default true) and `audio_transcript_required` (default false): independent whole-track transcript permission and requirement.
- `audio_segment_transcript_allowed` (default true) and `audio_segment_transcript_required` (default false): permission and requirement for every segment transcript.

The designer has separate Allow/Require toggles for the whole track and segments. Turning Allow off clears Require. Disallowed transcript editors are hidden and their draft values cleared; required fields are marked `*`, and Apply remains disabled while any required transcript is blank. The backend validates these rules too, including callers bypassing the GUI. Definitions cannot be edited in the runtime annotator.

The file source reuses import, preview, Apply and Clear from Audio Input; it does not record automatically. File bytes stay in `audio/` in the notebook. An active PCM stream is not editable until published as a completed file/track. Mono/stereo decoding uses AVFoundation in the editor and AudioToolbox for backend validation, 8–192 kHz, at most 16 MiB decoded float PCM. Neither FFmpeg nor a bundled codec is required.

Annotate opens an immutable source snapshot. Both image and audio editors use `sheet(item:)` with the full snapshot and bindings in one identifiable presentation value; opening cannot create an empty sheet while waiting for a separate State value. Decode failures show an explicit error. Run, source replacement or board rebinding cannot silently retarget an open draft.

## Regions and metadata

Drag on the waveform to add a temporal segment. Drag on the spectrogram to add a time/frequency rectangle. Clicking an existing region or list row selects it. The inspector edits exact start/end time, optional low/high Hz, title, multiple classes, secondary class attributes and segment transcript. A separate whole-track transcript is available.

Class definitions are edited only in Board Designer → component → Classes & attributes. Each class owns up to 16 named attributes of type text, number, Boolean or choice. A segment can carry multiple classes. Values are stored under class/attribute IDs, preserving type; changing a schema removes incompatible draft values. Up to 32 classes, 1,000 regions and 512 KiB accepted JSON. Segment transcript: 8 KiB; whole-track transcript: 64 KiB. Text uses UTF-8 byte limits, and non-finite numbers are rejected.

Accepted metadata carries a frozen copy of the configured schema. Apply rejects changes to definitions, unknown classes, attributes or choices. If a designer change makes accepted metadata incompatible, consumers are invalidated and read null until the labels are reviewed and reapplied. The old raw metadata remains in the manifest for opening a repair draft. Legacy notebooks without an explicit `annotation_classes` use their previously accepted schema until the designer saves an explicit list; the annotator cannot introduce new definitions through this fallback.

The transport uses integer source frames `[start_frame, end_frame)` and optional `low_hz` / `high_hz` in Hz, not screen pixels. Bounds are validated against decoded frame count and Nyquist. Zoom in/out, timeline pan, Fit and Zoom to selection can reach individual samples. The inspector gives precise time and frequency editing at every zoom level. Frequency bounds are preserved when switching to waveform. Playback previews the segment's temporal interval; it does not apply an audio frequency filter.

Runtime Undo/Redo includes region and metadata edits; undo storage is limited to 30 edits / approximately 8 MiB. Schema changes participate in Board Designer Undo/Redo. Discard leaves accepted state untouched. Export JSON saves the current draft. Apply saves an immutable accepted snapshot, invalidates consumers and does not execute code. Original audio bytes remain unchanged.

## Spectrogram

The system Accelerate real FFT computes a centered Hann-windowed STFT over the visible timeline. FFT size controls frequency resolution; Δf is shown. The color range is 60, 90 or 120 dBFS, with 0 dBFS referenced to the peak amplitude of a full-scale sinusoid. DC and Nyquist normalization are handled separately. The renderer uses the canonical 256-entry plasma LUT from [Matplotlib / BIDS colormaps](https://github.com/BIDS/colormap), available as CC0 numerical color data.

Spectrogram work runs off the main thread and cancels when display, viewport or source changes. Each visible result is bounded to 1,400 time columns and 768 frequency rows. Mono/stereo channels can be inspected separately; optional mono mix averages channels. Waveform min/max buckets preserve peaks and are recomputed from original samples at the current zoom. A time/frequency selection can be zoomed to fill the viewport; Fit restores the complete track / Nyquist range.

## Accepted API

```sputnik
from audio import AudioTrack
track = AudioTrack.from_input("clip")
notebook.player(track)
labels = notebook.audio_annotations("labels")
labels
```

A missing configured label channel is an error. An empty channel or a source-version mismatch returns null. The accepted value is an ordinary map:

```json
{
  "version": 1,
  "asset": "<sha256-of-encoded-file>",
  "source": "input",
  "channel": "clip",
  "cell": 0,
  "sample_rate": 16000,
  "channels": 1,
  "frames": 64000,
  "transcript": "Whole-track transcript",
  "classes": [{"id": "speech", "title": "Speech", "attributes": [
    {"id": "speaker", "title": "Speaker", "type": "choice", "options": ["A", "B"]}
  ]}],
  "segments": [{"id": "s1", "title": "Phrase", "start_frame": 3200, "end_frame": 20000,
    "low_hz": 300, "high_hz": 650, "classes": ["speech"],
    "attributes": {"speech": {"speaker": "A"}}, "transcript": "Hello"}]
}
```

A cell publication uses `source: "cell"` and its numerical cell ID. Backend Apply verifies the current encoded hash and decoded rate/channel/frame metadata. Kernel reading checks the current audio identity; for cell sources, publish the source channel in that run before reading its labels. Input reads capture the managed audio input dependency too. Board source rebinding invalidates old accepted metadata. Accepted labels are persisted in the manifest and included in Run History/export. Remote editing remains disabled in this preview; existing remote dependency-bundle restrictions still apply.

## Verification and example

`Samples/Audio Annotations.sputnikbook` contains a four-second tone / silence / chirp fixture, configured Speech/Noise classes and a consumer cell. Configure definitions and transcript requirements in Design → Audio Annotator. Open Annotate, drag segments/rectangles, assign classes and attributes, Apply, then Run Sheet to inspect the accepted map.

`make test-notebook-audio-annotations` covers source modes, frame/Hz boundaries, class/attribute types, immutable snapshots, source replacement, reopening, known-tone FFT bin and dBFS normalization, plasma endpoints, reverse rectangle selection, sample zoom, worker reading, history and native themes. Image and audio integration tests also click the actual Annotate controls after Run, assert full-sized sheet content, dismiss and reopen; standalone editor rendering alone does not cover presentation.

The native audio test edits Start/End in seconds and Low/High in Hz through the actual text fields in both waveform and spectrogram modes, clicks Apply, and verifies exact source-frame/frequency values in the accepted backend snapshot. Frequency bounds remain editable in waveform mode when enabled; switching display modes does not discard them.

Both native suites open the actual designer class/attribute editor, edit its fields, save the component and verify the schema survives the worker roundtrip. Audio tests exercise required whole-track and segment transcripts separately, assert empty required input blocks Apply, and check disallowed transcript editors are absent. Backend tests also cover forbidden schema changes, invalid policy combinations, stale-label invalidation and reopening.

Image and audio coordinate fields share strict whole-value parsing, accept both decimal separators, and display up to nine fractional digits. Invalid/non-finite text is highlighted and blocks Apply. Formatting an existing draft never rounds the stored coordinates or frequencies.

Verified on 20 October 2026: backend validation and native integration tests pass, including actual image/audio sheet reopening after Run. The audio integration uses the worker bundled in the finished app. Packaged application launch, theme switching, both example manifests and strict deep code-signature verification pass. Native sheet tests require a logged-in macOS desktop with access to the system view bridge; a restricted process sandbox can block sheet presentation.
