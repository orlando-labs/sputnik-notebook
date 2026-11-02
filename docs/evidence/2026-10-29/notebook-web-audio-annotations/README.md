# Web audio annotations and completed sources — Stage 4g.2.3

29 October 2026. Implemented in the existing Sputnik Notebook web app and shared
Core. No changes to the sibling language/Orbit repositories, dependencies,
production deployment or user notebook data were made by this stage.

## Delivered

- Audio Annotator in Board Designer: owned file, Audio Input channel or completed
  cell AudioTrack; schema, waveform/spectrogram, FFT size and independent track/
  segment Allow/Require transcript policies.
- Immutable audio editor: drawn segments/reverse time-frequency rectangles,
  exact frames/seconds/Hz, selection, multi-class typed attributes with exact
  Int64, transcripts, bounded Undo/Redo, JSON export and separate Apply/Discard.
- Zoom/pan/Fit and sample-level Zoom to selection; channel/mono mix, FFT
  256–4096, 60/90/120 dBFS and canonical shared plasma LUT. A separate module
  Worker computes bounded centered Hann STFTs and source peak waveform buckets.
  DC/Nyquist and full-scale sinusoid amplitude are normalized separately.
- Explicit temporal preview, available before transcripts are complete. Opening
  the editor stops the underlying file player; close/hidden view/stale source/
  access revocation stops preview and closes its AudioContext. View/viewport
  changes cancel the previous analysis worker. No autoplay or implicit run.
- Core decodes exact source-rate f32le PCM (native mono/stereo decoded limit),
  verifies metadata and current original encoded hash, then checks native schema,
  frame/Hz regions and transcript policies on Apply. PCM WAV works portably;
  other formats use the existing host system codec. Cell DTOs are decimal strings
  and become exact Int64 JSON tokens in accepted annotation metadata.
- Image/Carousel annotation accepts the latest completed channel publication,
  with published-image selection and reopening after an annotation-only save.
  Core chooses its own controller publication; changed code, reset workers,
  invalid cells or different bytes cannot retarget an open draft.
- Read-authorized media.source and execute-authorized media.accept retain current
  revision/lifetime/idle checks, effective storage quotas, version CAS and durable
  receipts. Source replacement keeps repair metadata but invalidates readers.
  Existing public cumulative execution ceiling remains 60 seconds.

Development initially exposed the browser's same-origin Worker constructor rule.
A small static same-origin entry now imports the configured Vite audio module
under the existing application CSP. Production uses the emitted hashed worker;
no Blob-script/eval exception or browser codec resampling was introduced.

## Verification

The final source passed all nine scenarios in each mode:

| Backend | Assets | Result | Log |
| --- | --- | --- | --- |
| VM | Production | 9 passed | [log](browser-vm-production.log) |
| VM | Vite development | 9 passed | [log](browser-vm-development.log) |
| Full native | Production | 9 passed | [log](browser-native-production.log) |
| Full native | Vite development | 9 passed | [log](browser-native-development.log) |

Scenarios cover actual annotation controls, frame/Hz values, literal text,
transcripts, classes/Int64, Undo/Redo, byte identity, Apply → Run → reopen,
real reverse-pointer selection, sample zoom, rendered spectral tone pixels,
responsive themes, invalid input, JSON export, owned/input/cell sources, missing
sources, independent Core validation, receipt replay/version conflicts,
constructor persistence, stale draft export, replacement invalidation, viewer
write denial, playback resource release on revocation and published image
annotation/reopening. The file player is asserted stopped during annotation and
remains stopped on return. Tests use installed Chromium 152.0.7977.82.

Additional checks:

- [Analysis unit tests](analysis-unit.log): known 1 kHz peak for FFT 256–4096,
  0/−6.0206 dBFS, DC/Nyquist, plasma endpoints, bounded STFT, impulse waveform
  preservation, stereo cancellation, reverse frame/Hz geometry, transcript,
  schema, Int64 and invalid bounds.
- [Shared worker](worker-media.log): exact managed bytes and identity,
  source-rate decode, audio/image annotation validation, mismatched metadata,
  schema, channel, fractional frames and Nyquist bounds, Clear and size bounds.
- [Core audio contracts](core-contracts.log): native file/input/output sources,
  schema/transcript policy, immutable Apply, stale identities and reopening.
- [Board editor unit tests](board-editor-unit.log) and
  [frontend typecheck/production build](frontend-build.log) passed. The existing
  advisory about a main chunk exceeding 500 kB remains non-fatal.
- [Native build summary](native-summary.json): Core 1357/1357 native code bodies,
  fixture/main 3134/3134, zero VM fallback.
- [Adjacent regression run](browser-regressions.log): 33 passed. The 12 capture
  tests did not start because their file-specific launchOptions replaced the
  configured Chromium path. The test now preserves that path without changing
  assertions. [Capture recheck](browser-capture-recheck.log): 11 passed, including
  real fake-device capture, the complete 30-second cap, cleanup, image labels,
  exact attributes, source replacement and revoked writes; the remaining header
  test stopped during OAuth fixture login before reaching its assertions.
  Its [isolated recheck](browser-policy-recheck.log) passed. Together all 45
  adjacent scenarios passed, including public 60-second/profile ceilings,
  resource policies, file/audio inputs and board design.
- [Initial broader Core run](core-regressions-initial.log) passed worker-host
  and C++ annotation contracts; the sandboxed macOS UI test could not open the
  designer class editor. Its [system-UI recheck](macos-recheck.log) passed, covering
  native FFT/dBFS, exact fields, source snapshots, Apply, worker/history and themes.
- git diff --check and changed-file whitespace/link checks passed.

Earlier preliminary browser runs found and corrected Worker-origin loading,
preview being blocked by required transcripts, and underlying player cleanup.
One preliminary OAuth fixture sign-in also failed; final nine-test matrices above
passed with no retry loop or weakened assertion.

## Visual checks

These are final browser screenshots, visually inspected on desktop and phone.
The selected 100–101 frame interval intentionally appears as a narrow line at
Fit, after testing sample-level zoom. Dialog content scrolls vertically on a
phone without horizontal overflow.

| Light | Dark |
| --- | --- |
| [Desktop](audio-annotations-light-1280.png) | [Desktop](audio-annotations-dark-1280.png) |
| [Phone](audio-annotations-light-375.png) | [Phone](audio-annotations-dark-375.png) |

## Reproduce and scope

From apps/notebook-web/frontend, set PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH to an
installed Chromium binary, then run npm run test:browser --
test/audio-annotations.spec.ts. Repeat with ORBIT_E2E_NATIVE=1 and/or
ORBIT_E2E_MODE=development. The native fixture must be rebuilt from
apps/notebook-web/test/app_fixture.s after backend edits. Run make remote-core
from the repository and npm run build from the frontend before production tests.
Pure checks are node apps/notebook-web/tools/audio_annotations_test.mjs,
node apps/notebook-web/tools/board_editor_test.mjs and
python3 tests/notebook_media_acceptance_test.py from the repository root.

This slice edits completed encoded tracks. Active PCM streams are not annotation
sources. System-codec formats require a compatible Core host; no external codec
was bundled. Safari/physical microphone/mobile OS playback were not newly tested
in this slice. Native remote sheets and generic remote HTTP writes remain outside
this web local-RPC extension. Shared table selections, Date/time and presets are
next in Stage 4g.2.4.

[Plan](../../../engineering/notebook-web-implementation.md) ·
[Contract](../../../engineering/notebook-remote-media-inputs.md) ·
[Source/binary hashes](source-sha256.json)
