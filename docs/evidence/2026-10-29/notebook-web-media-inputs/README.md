# Notebook web — Stage 4g.2.1 managed media inputs

29 October 2026, macOS arm64 / Chromium. Local implementation only; no deployment.
Existing unrelated changes are preserved. Browser checks use real Core/worker
processes and disposable local OAuth/catalog fixtures.

## Delivered

File Input, Audio Input and Image/Carousel support choose, bounded local preview,
Discard, Clear and explicit Apply. Carousel can append one file per acceptance.
The designer exposes both new input kinds, String parameter/extension settings,
audio channels and image load/read permissions. Unknown metadata and exact Int64
values survive normal draft/Save and acceptance.

The shared `media.accept` Core RPC validates the current source/input versions,
component binding, idle state, typed media, extension policy and storage limits.
It commits SHA-256 assets, native input metadata, accepted values, revision and
receipt together. It starts no code. Failed validation/CAS/quota requests leave
the saved head intact. Existing retained revisions/export keep original bytes.

Worker Sync accepts the new immutable asset root while retaining its original
native-client form. File Input exposes a portable relative identity in saved
state and resolves it inside a private read-only worker input namespace. Existing
world grants stay fixed; replacement uses the same worker and does not grant
reads outside that namespace. Hard links reference existing revision bytes;
current references stay covered by revision retention/storage accounting. Audio
and image consumers use the existing native input maps/codecs. PCM WAV validates
without an OS codec; other encoded audio requires the host's bounded decoder.

The web adapter checks current project permissions and CSRF. Viewer playback is
allowed, acceptance is denied, and revocation removes the accepted audio player.
Disconnect clears accepted preview bytes while keeping unapplied local drafts.
Accepted previews load one selected asset at a time. Text preview stops at
64 KiB and is rendered as text. Saved image load/read settings coexist with the
shared published-image renderer.

Exact pending command bytes are journaled in IndexedDB by account/project before
Apply. Reload looks up its receipt; retry is explicit and never creates a second
update. Source editing is disabled during uncertain acceptance. Other parameter,
source and media drafts cannot be silently discarded by an accepted update.
Failure of media recovery storage leaves ordinary scalar controls usable.

Per-file 16 MiB, existing 64 MiB/2048-member bundle limits, native collection and
decoded-audio bounds, and storage/user/Core ceilings apply. Prior unused managed
assets remain charged in the bundle. Public preview keeps its existing cumulative
60-second server execution ceiling. Acceptance/preview/playback do not dispatch a
run. Recording, annotators and remaining palette controls are later 4g.2 slices.

[Detailed common contract](../../../engineering/notebook-remote-media-inputs.md).

## Verification

| Check | Result |
| --- | --- |
| Media matrix, VM production | [12 passed](browser-vm-production.log) |
| Media matrix, VM Vite | [12 passed](browser-vm-development.log) |
| Media matrix, native production | [12 passed](browser-native-production.log) |
| Media matrix, native Vite | [12 passed](browser-native-development.log) |
| Final integration refinements, native production | [4 passed](browser-final-integration.log) |
| Shared pure worker media transaction | [Passed](worker-media-test.log) |
| Existing Core worker-host and audio suites | [Passed](core-regressions.log) |
| Board authoring pure checks | [Passed](board-editor-unit.log) |
| Type checking and production frontend | [Passed](frontend-build.log) |
| Broader browser regression group | [37 passed; one OAuth-fixture failure](browser-regressions.log) |
| That board scenario, isolated retry | [1 passed](browser-board-recheck.log) |

The matrix covers inert drafts, exact file bytes and UTF-8 preview, first accept,
replacement in the same runtime, reload/clear, AudioTrack input, image append/
clear/readers, idempotent receipts, source/input CAS, invalid media and extension
policy, lost-response recovery, viewer/revocation, storage exhaustion with zero
compute charge, active-run source freezing, separate drafts, scoped file grants,
and actual designer authoring through Save. Audio controls do not autoplay after
load/reload. Light/dark layouts at 1280 and 375 px have no horizontal overflow.

After the matrix, two narrow UI refinements kept scalar parameters usable when
IndexedDB is unavailable and retained the existing published-image renderer on
editable image components. The final four-scenario check covers both, image
acceptance, and actual accepted-audio playback followed by membership revocation.
The matrix and broader group preceded those final two refinements.

The broader group includes media, parameters, audio, boards and resource/public
quota cases. Its one failure occurred before notebook setup during offline OAuth
sign-in; the exact existing board scenario passed in isolation. No assertions or
login behavior were relaxed. Initial implementation checks also caught and fixed
NUL metadata handling, fixed-world grant replacement, draft isolation and fixture
PNG/board-navigation assumptions before these final logs.

The pure worker check exercises file/audio/image identity and bytes, append/clear,
Int64 preservation, corrupt audio/images, malformed WAV length/rate, non-finite
float PCM, invalid extension/traversal, unsupported operations and the 16 MiB cap.
It uses no evaluator. Existing Core tests retain package API, binary media/IPC,
worker lifecycle, managed inputs and validation coverage.

[Native build summary](native-summary.json): Core has 1347 native bodies; main and
fixture each have 3128, with full native body coverage and zero VM fallback.
[SHA-256 source/binary/asset manifest](source-sha256.json) identifies the final
saved sources and executables. Linux and physical microphone/mobile hardware
were not run. The frontend build passes with Vite's main-chunk size advisory
(about 512 kB before gzip); it is retained in the log.

## Visual evidence

- [Draft file and text preview](media-file-draft.png)
- [Accepted image](media-accepted-image.png)
- [Accepted audio, light desktop](media-inputs-light-1280.png)
- [Accepted audio, dark desktop](media-inputs-dark-1280.png)
- [Accepted audio, light phone](media-inputs-light-375.png)
- [Accepted audio, dark phone](media-inputs-dark-375.png)

## Reproduce

From the repository root, build the worker/Core and run:

```sh
make -j4 build/sputnik-notebook-worker remote-core
python3 tests/notebook_media_acceptance_test.py
make -j4 test-notebook-worker-host test-notebook-audio
```

From `apps/notebook-web/frontend`, after `npm run build` and the full-native
fixture/main builds documented in the app README:

```sh
PLAYWRIGHT_BROWSERS_PATH=/private/tmp/notebook-policy-browsers npm run test:browser -- test/media-inputs.spec.ts
ORBIT_E2E_MODE=development PLAYWRIGHT_BROWSERS_PATH=/private/tmp/notebook-policy-browsers npm run test:browser -- test/media-inputs.spec.ts
ORBIT_E2E_NATIVE=1 PLAYWRIGHT_BROWSERS_PATH=/private/tmp/notebook-policy-browsers npm run test:browser -- test/media-inputs.spec.ts
ORBIT_E2E_NATIVE=1 ORBIT_E2E_MODE=development PLAYWRIGHT_BROWSERS_PATH=/private/tmp/notebook-policy-browsers npm run test:browser -- test/media-inputs.spec.ts
```

The final spec contains fourteen scenarios: the twelve matrix scenarios plus the
two final integration checks described above.
