# Notebook web — Stage 4g.1 audio

29 October 2026, macOS arm64. Existing unrelated changes are preserved. No
production service or deployment was changed. Browser checks use the real Core
agent/worker and disposable local OAuth/catalog/registry fixtures.

## Implemented behavior

- The common validated codec projects file audio, retained PCM and ordered player
  requests. Bytes and metadata are inert; no filesystem paths, device/VM handles
  or selectable artifact map cross into the browser. Tokens, revisions and frame
  counts remain strings. Existing run ownership, ACL, frozen source and results
  paths authorize every read, including temporary previews.
- Other rich output is reserved first. Audio is capped at 64 tracks and 16 MiB
  aggregate raw bytes within the existing 32 MiB JSON budget, plus 256 control
  records. Omission sets an explicit per-cell notice while scalars, charts,
  diagnostics and other figures remain usable. Storage quotas account for the
  full Core artifact, including output omitted from the web projection.
- One shared player serves automatic output, cell pre/post Audio, boards,
  invocation output and temporary preview. Play/Pause/Stop, seek, volume, looping,
  waveform, Save original and Export WAV work locally. Authored `audio_id` and
  `show_waveform` retain the native schema; empty channel means all source-cell
  tracks, and matching automatic duplicates are suppressed. Both palettes and
  inspectors use ordinary draft/Save/CAS and preserve exact/unknown metadata.
- Complete files use browser codecs and local Blob URLs; CSP permits Blob media
  without allowing arbitrary network media. Unsupported/corrupt files keep text
  results and original save. PCM WAV is parsed with bounded validated chunks;
  waveforms have at most 2048 peaks. WAV export preserves typed PCM rate and bytes.
- Streams accept retained s16le/f32le mono/stereo at 8–192 kHz. Full snapshots
  validate identity, format, frames, finite samples and already-published prefix.
  Replayed revisions do not enqueue data twice; growing streams schedule new
  frames after the current queue. Buffering is visible at the unfinished end.
  Reset/new run creates a new playback epoch. Decoded PCM is capped at 32 MiB,
  original/output at 16 MiB.
- Explicit conversion of other browser-decodable files checks metadata and a
  40-second limit before decoding to 48 kHz, then checks finite mono/stereo and
  export limits. Original bytes are independent of conversion. Browser codecs
  vary. `decodeAudioData` uses complete files and resamples to the context rate;
  see [browser API behavior](https://developer.mozilla.org/en-US/docs/Web/API/BaseAudioContext/decodeAudioData).
- Playback starts with explicit Play in the current view. Saved autoplay and
  runtime Play requests do not activate sound on opening/history/reconnect.
  After activation, current source-cell/channel requests apply once in revision
  order; empty channel is accepted only for one unambiguous track. A real live
  control test uses one cell to control another cell's seek/volume/pause/play.
  Player interaction makes no server mutation and never starts another run.
  Browsers can also require user activation; see the [autoplay behavior](https://developer.mozilla.org/en-US/docs/Web/Media/Guides/Autoplay).
- Source/revision/worker staleness, hidden views and navigation pause/disarm
  playback. Unmount and ACL loss release URLs, graph nodes and contexts. UI player
  state never enters the document, source recovery journal or accepted inputs.
  Temporary preview retains its existing 60-second cumulative server budget;
  local listening/export does not dispatch worker work.

## Verification

| Check | Result |
| --- | --- |
| Focused audio, VM production | [9 passed](browser-vm-production.log) |
| Full web suite, VM production | [106 passed; one login-fixture failure](browser-full-vm-production.log) |
| That scenario, isolated recheck | [1 passed](browser-board-recheck.log) |
| Audio, native production | [9 passed](browser-native-production.log) |
| Audio, VM Vite | [9 passed](browser-vm-development.log) |
| Audio, native Vite | [9 passed](browser-native-development.log) |
| Final unmount refinement, VM/native production and VM Vite | [1 passed](browser-cleanup-vm-production.log), [1 passed](browser-cleanup-native-production.log), [1 passed](browser-cleanup-vm-development.log) |
| Existing Core audio test | [Passed](core-audio-test.log) |
| Type checking/production assets | [Passed](frontend-build.log) |

The full 107-scenario pass attempt had one transient offline OAuth sign-in
failure before the affected board-action test reached notebook setup. That exact
scenario passed in the isolated recheck. The other 106 scenarios passed,
including the complete new audio slice, resource quota/public-cap cases, text,
boards, inputs, editor recovery, imports and package installation. No test
assertions were relaxed for the login failure.

The final lifecycle refinement pauses HTML media before Vue removes its template
reference. The native Vite nine-scenario run and targeted rechecks in the other
three modes retain the old audio element and verify that navigation actually
pauses it, in addition to releasing its Blob URL. The full suite above preceded
this final refinement.

The nine real-worker audio scenarios cover:

1. Real file playback/position/volume/stop, literal captions, original/WAV byte
   identity, no extra mutations, and light/dark layouts at 1280/375/320 px.
2. Authored component ownership, board inspector settings, ordinary Save and
   preservation of exact integers/unknown metadata.
3. Live PCM growth, reconnect without autoplay/replay, complete WAV frames,
   finish and a new token on reset/run.
4. Browser-decoded 8-bit WAV conversion to float WAV at 48 kHz; corrupt media
   retains scalar output and exact original download.
5. Cross-cell runtime seek/volume/pause/play in order, followed by reconnect and
   local volume changes that polling does not overwrite.
6. Source staleness, navigation URL release, viewer playback and revoked access.
7. The 64-track aggregate cap across cells, retaining scalar/chart output.
8. Temporary audio preview/export, unchanged template and 60-second policy.
9. The 16 MiB aggregate byte cap, retaining other results for several large tracks.

Pure-code checks passed: [audio](audio-unit.log), [editor recovery](editor_recovery-unit.log),
[rich text](rich_text-unit.log), [text features](text_features-unit.log),
[board editor](board_editor-unit.log), [boards](boards-unit.log),
[displays](displays-unit.log), [inputs](inputs-unit.log), [telemetry](telemetry-unit.log).
Audio checks include exact PCM/WAV bytes, peaks, malformed files/frames/encodings,
non-finite samples, uint64 boundaries, ordered controls, replay and decode limits.
The existing Core test covers the canonical package API, file/PCM/stream,
hard component IDs, binary codec, managed local inputs and validation. Early
builds encountered an updating shared SDK (old fixture manifests and reserved
`AudioPlayer.for` parsing); web fixtures now use the current build manifest, and
the final unmodified Core audio test passed with the updated SDK.

Both native builds report 3113 native code bodies, full native body coverage and
zero VM fallback; see [native coverage](native-summary.json). Final
[source/binary/asset SHA-256 hashes](source-sha256.json) and logs are retained
alongside this document. Linux/mobile-device audio hardware was not executed;
phone widths are Chromium layout checks. No new media-input acceptance API is
claimed: file/audio/image input and annotations remain Stage 4g.2.

## Visual evidence

- [Player, light desktop](audio-player-light-1280.png)
- [Player, dark desktop](audio-player-dark-1280.png)
- [Player, light phone](audio-player-light-375.png)
- [Player, dark phone](audio-player-dark-375.png)

## Reproduce

From `apps/notebook-web/frontend`, build production assets once, then run:

```sh
npm run build
PLAYWRIGHT_BROWSERS_PATH=/private/tmp/notebook-policy-browsers npm run test:browser -- test/audio.spec.ts
ORBIT_E2E_NATIVE=1 PLAYWRIGHT_BROWSERS_PATH=/private/tmp/notebook-policy-browsers npm run test:browser -- test/audio.spec.ts
ORBIT_E2E_MODE=development PLAYWRIGHT_BROWSERS_PATH=/private/tmp/notebook-policy-browsers npm run test:browser -- test/audio.spec.ts
ORBIT_E2E_NATIVE=1 ORBIT_E2E_MODE=development PLAYWRIGHT_BROWSERS_PATH=/private/tmp/notebook-policy-browsers npm run test:browser -- test/audio.spec.ts
node ../tools/audio_test.mjs
```

`make test-notebook-audio` runs the existing Core test from the repository root.
The browser fixture bundles the canonical `audio.AudioTrack` source and reuses
native AudioCodec; it does not fabricate a presentation or add an evaluator.
Native fixture/main builds use `--require-full-native` and the same grants as the
app README. Build the worker/Core and native fixture before the native checks.
