# Notebook web — Stage 4g.2.2 capture and accepted-image annotations

29 October 2026, macOS arm64 / Chromium. Local implementation only; no deployment
or external service changed. Existing unrelated work is preserved. Tests use the
real Core/worker with disposable local OAuth/catalog fixtures. Microphone tests
use Chromium's artificial media device and permission UI, never physical capture.

## Delivered behavior

Audio Input supports explicit microphone choice/Record/Stop/Cancel. An external
static AudioWorklet module captures finite mono/stereo PCM, with a silent graph
output. Stop produces a local 48 kHz PCM16 WAV draft; only Apply media sends it to
the existing managed-asset/receipt/quota transaction. Peak, RMS and clipping are
visible. Sample quantization clips to PCM16 bounds, while invalid samples fail.
Thirty seconds and less than 16 MiB decoded float PCM are hard limits in both
processor and accumulator; the output stays below the existing file limit.

No device is requested on page load or in Board Designer. Record requires a
secure context and a browser permission grant. The app's SecurityPolicy subclass
retains Orbit's standard protections and changes only microphone permission to
`(self)`. The worklet is a normal hashed JS asset; no Blob script, eval or general
network exception is added to CSP. The browser prompt may remain unanswered;
Cancel invalidates the request, and late streams release their tracks. See
[getUserMedia](https://developer.mozilla.org/en-US/docs/Web/API/MediaDevices/getUserMedia)
and [AudioWorkletNode](https://developer.mozilla.org/en-US/docs/Web/API/AudioWorkletNode)
for the browser secure-context/permission and rendering-thread contracts.

Cancel, hidden view/tab, changed source, unmount, device interruption or revoked
access close tracks, ports, graph nodes, timers and AudioContext. A canceled or
failed recording keeps the previous draft. Starting capture closes the old audio
preview; capture is not monitored through speakers. Device refresh enumerates
without requesting capture. Browser/device support can vary; file import remains
available.

Accepted Image/Carousel assets can open a frozen annotation snapshot with points,
reverse rectangles, whole source-pixel coordinates/sizes, selection, zoom/scroll,
labels, multiple configured classes, typed attributes, Undo/Redo and JSON export.
The existing palette and themes are reused. Definitions are edited only in Board
Designer, including text/number/Boolean/choice attributes and exact Int64 values.
Native bounds remain 32 classes, 16 attributes each, 500 image regions and
256 KiB accepted JSON. Undo retains up to 30 text snapshots with an approximately
8 MiB string-storage bound. Discard never changes accepted state.

Apply uses the revision/input version captured when the editor opened, through
the same exact-command journal and receipt path as managed media. The worker
checks `image_annotator`, native schema/coordinate validation and source hash,
channel and dimensions against an accepted image in that controller sheet. It
commits only metadata in the ordinary Core revision/storage transaction and
starts no code. The next explicit Run consumes `notebook.annotations(channel)`.
A saved-source conflict keeps the original draft/export; it cannot retarget a
new asset. Source replacement invalidates runtime labels while retaining their
old raw metadata for repair. Viewer writes are denied, and revocation closes
capture/editor and clears accepted preview bytes.

The existing storage/user/Core ceilings remain authoritative. Public preview
keeps its 60-second cumulative server-computation ceiling. Browser capture,
annotation editing and Apply dispatch no notebook run. Audio annotation editors,
spectrograms, completed cell-publication sources and remaining selection/input
bindings are subsequent Stage 4g.2.3 work; they are not claimed by this slice.

## Verification

| Check | Result |
| --- | --- |
| Capture/annotation matrix, VM production | [11 passed](browser-vm-production.log) |
| Capture/annotation matrix, VM Vite | [11 passed](browser-vm-development.log) |
| Capture/annotation matrix, native production | [11 passed](browser-native-production.log) |
| Capture/annotation matrix, native Vite | [11 passed](browser-native-development.log) |
| Native HTTP permission/CSP regression | [1 passed](browser-policy.log) |
| Final annotation toolbar/theme layout | [1 passed](browser-final-layout.log) |
| Pure recording/worklet/geometry/schema checks | [Passed](capture-unit.log) |
| Shared worker media + annotation validation | [Passed](worker-media-test.log) |
| Existing Core worker-host/audio suites | [Passed](core-regressions.log) |
| Board editor pure checks | [Passed](board-editor-unit.log) |
| Type checking/production assets | [Passed](frontend-build.log) |
| Adjacent browser regression group | [49 passed; one OAuth-fixture failure](browser-regressions.log) |
| Isolated OAuth-fixture recheck | [1 passed](browser-regression-recheck.log) |

The adjacent 50-scenario group had one transient offline OAuth sign-in failure
before notebook setup in the existing board-creation scenario. The other 49
scenarios passed, including media/parameters/audio, resource/public quota cases,
board editing and workspace flows. Its exact isolated recheck is linked above;
no assertions or sign-in behavior were relaxed.

The eleven matrix scenarios cover:

1. Actual AudioWorklet capture from Chromium's artificial microphone, PCM WAV
   bytes, inert preview/acceptance and exact worker publication after Apply/Run.
2. Cancel, hidden view and interrupted tracks, preserving the prior draft.
3. Permission denial and a late permission result after cancellation.
4. Exact image geometry, literal labels, typed configured attributes/Int64,
   independent Undo/Redo, acceptance, runtime read and editor reopening.
5. Real pointer drawing of a reverse rectangle at a zoomed scale, invalid pixel
   coordinates blocking Apply, and inert Discard.
6. Direct Core rejection of wrong hash, dimensions, channel, schema and fractional
   pixels, plus exact receipt replay and obsolete source CAS.
7. A stale source rejecting Apply while the original draft can still be exported.
8. Source replacement making runtime labels null and retaining old repair data.
9. Designer schema/recording settings saved without opening any microphone.
10. Live microphone release on revocation and viewer write restrictions.
11. A full 30-second capture automatically stopping, closing its tracks and
    producing exactly 30 seconds of bounded WAV frames without a notebook run.

The matrix runs the full 30-second scenario in every mode. The final layout
refinement only prevents the toolbar label from wrapping inside the selector;
its targeted check refreshes the layout screenshots. The separate native header
check confirms `(self)` microphone, denied camera/geolocation, unchanged frame/
MIME/opener protections and CSP without `unsafe-eval`.

Pure checks validate PCM quantization/clipping, finite samples and layouts,
worklet flush and 30-second limits, exact WAV frames, reversed drawing, class/
attribute schema, exact integers and geometry bounds. The shared worker check
additionally rejects stale/forged source identities and schema, wrong component,
invalid media, non-finite PCM and size/traversal errors without creating a VM.
Core regressions retain the native package API, binary IPC, managed media and
worker lifecycle checks.

[Native build summary](native-summary.json) records full body coverage with zero
VM fallback. [Final SHA-256 manifest](source-sha256.json) identifies source,
executables and production assets. Vite's main-chunk size advisory is retained in
the passing build log. Linux, physical microphones and physical mobile devices
were not exercised; narrow widths are browser layout checks.

## Visual evidence

- [Recording, light desktop](audio-recording-light.png)
- [Recording, dark phone width](audio-recording-dark.png)
- [Image annotations, light desktop](image-annotations-light-1280.png)
- [Image annotations, dark desktop](image-annotations-dark-1280.png)
- [Image annotations, light phone](image-annotations-light-375.png)
- [Image annotations, dark phone](image-annotations-dark-375.png)

## Reproduce

Build worker/Core and full-native main/fixture as documented in the app README,
then build production assets once. From `apps/notebook-web/frontend`:

```sh
npm run build
PLAYWRIGHT_BROWSERS_PATH=/private/tmp/notebook-policy-browsers npm run test:browser -- test/capture-annotations.spec.ts
ORBIT_E2E_MODE=development PLAYWRIGHT_BROWSERS_PATH=/private/tmp/notebook-policy-browsers npm run test:browser -- test/capture-annotations.spec.ts
ORBIT_E2E_NATIVE=1 PLAYWRIGHT_BROWSERS_PATH=/private/tmp/notebook-policy-browsers npm run test:browser -- test/capture-annotations.spec.ts
ORBIT_E2E_NATIVE=1 ORBIT_E2E_MODE=development PLAYWRIGHT_BROWSERS_PATH=/private/tmp/notebook-policy-browsers npm run test:browser -- test/capture-annotations.spec.ts
node ../tools/capture_test.mjs
```

The final spec includes the separate header scenario in addition to the eleven
matrix scenarios. The worker validation test is
`python3 tests/notebook_media_acceptance_test.py` from the repository root.
