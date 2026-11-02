# Web shared selection, date/time and presets — Stage 4g.2.4

29–30 October 2026. Implemented in the existing notebook web app and shared Core.

## Delivered

- Data Table owns selection_id / selection_key. Row choice stays local; Apply
  saves native version/source/key/row, Clear saves null and Reset is inert.
  Sort/filter retains source row/key identity and exact Int64. Core verifies its
  own completed table publication, SHA-256, the configured unique key column,
  unique/non-null keys, unique column names and the entire selected row.
  Forged row/key payloads cannot pass by copying the source hash.
- Image/Carousel and completed Audio Player use an accepted selection channel
  and asset column (default asset_id). Original encoded bytes determine identity;
  collection order is preserved. Native filenames are supported by bounded,
  sequential identity resolution, including a match after another collection
  image. A missing match shows no asset. No selection autoplays; switching away
  stops/removes the old player. Ordinary registry refreshes preserve playback.
- Date / Time Input authors a String binding, date/date_time and time zone.
  Gregorian calendar dates validate leap days. Local times use the configured
  IANA zone and ordinary atomic input acceptance stores exact UTC seconds.
  DST gaps are rejected; repeated local hours require choosing the UTC occurrence.
  Reset, source/version conflicts, saved defaults and idle uninitialized sheets
  retain the existing parameter contract.
- Parameter Presets offers scoped sets or all project parameters; exact current/
  preset JSON comparison precedes a single atomic Apply. Management supports
  Capture current, Rename, Delete, atomic JSON import (1 MiB; fresh IDs), export,
  up to 128 sets and 128 values per set, type/bounds/scope/date validation.
  Update notebook draft stages authored sets; Save persists them separately from
  runtime values/defaults. Cancel is inert. Extension fields remain preserved.
- Existing ACL, revision/input-version CAS, receipts, idle/dependency/lifetime
  checks and effective storage policies remain authoritative. Viewer writes are
  denied; revocation closes preset management and releases rendered media.
  Public computation retains its cumulative 60-second ceiling.

Table/media observers now compare stable source values rather than newly
allocated registry DTO arrays. This prevents refresh from discarding selection
UI or unmounting matching audio. Selection cannot be staged from a disabled or
loading table. Actual source changes still invalidate/reload the snapshot.

## Verification

All ten final scenarios passed in all four configurations **with compatible
web SDK 3eb0f05**; the SDK qualification below is part of this result.

| Backend | Assets | Result | Log |
| --- | --- | --- | --- |
| VM | Production | 10 passed | [log](browser-vm-production.log) |
| VM | Vite development | 10 passed | [log](browser-vm-development.log) |
| Full native | Production | 10 passed | [log](browser-native-production.log) |
| Full native | Vite development | 10 passed | [log](browser-native-development.log) |

The scenarios use actual controls and shared Core, covering sort/filter and exact
Int64 key/row, Apply → Run → reopen → Clear, forged source/row/key rejection,
duplicate/null keys, Gregorian dates, UTC display/reopening, DST gaps/repeated
hours, atomic preset publication, current capture/save/default separation,
atomic import rejection, rename/delete/Cancel, stale reviews, native designer
fields, viewer/revocation behavior, image/audio asset matching, no autoplay,
playback across a registry refresh and cleanup when the selection changes, plus
legacy carousel paths without changing stored collection order.

Additional verification:

- [Pure unit tests](selection-controls-unit.log): exact scalar/row identities,
  duplicate/null/ambiguous keys, media SHA-256, Gregorian calendar/strict UTC,
  quarter-hour offsets, DST gaps/folds, preset scope/types/Int64/limits/defaults.
- [Direct worker test](worker-selection.log): immutable native presentation codec,
  exact source row, forged row/key/hash, duplicate/null keys, ambiguous columns
  and Clear. [Core regression](core-regressions.log) also passed worker-host.
- [Existing managed-media worker tests](worker-media.log) passed.
- [Board editor tests](board-editor-unit.log) and
  [frontend typecheck/build](frontend-build.log) passed. The existing main-chunk
  size advisory remains non-fatal.
- [Native build summary](native-summary.json): Core 1357/1357 native bodies,
  web fixture/main 3134/3134, zero VM fallback. Core/worker use the current SDK;
  web fixture/main use the explicitly selected compatible compiler.
- [Adjacent Vite regressions](browser-regressions.log): all 40 passed, covering
  parameter semantics, source conflicts, Board Designer, accepted media,
  audio annotations, resource settings, storage rejection, cumulative compute
  exhaustion and the public 60-second/profile ceiling.
- [Final native media/audio regressions](browser-final-media.log): 21 passed;
  one existing file-player test paused during the live/terminal UI transition
  and timed out waiting for Pause; the following test failed during OAuth fixture
  sign-in. Their [isolated recheck](browser-audio-recheck.log) passed both unchanged tests.
- [Final visual check](browser-visual.log): two scenarios passed, including exact
  accepted-key display, preset comparison and no horizontal overflow at phone
  width. Desktop and phone screenshots were visually inspected.
- git diff --check and changed-file whitespace/link checks passed.

Preliminary runs exposed and corrected unstable source observers, local draft
version reactivity, and registry-refresh playback reset. Tests wait for editable
source readiness before staging a selection; no arbitrary delay, sign-in retry
loop, assertion removal or validation bypass was introduced.

## Current SDK compatibility gate

The workspace SDK is now d86d41e. Its recent namespace/bare-call changes prevent
unchanged Orbit/provider code from starting: orbit.Target reads fail before any
notebook route or new component runs. This reproduces with a fresh VM cache and
also occurred in a full-native web application. See the
[current SDK probe](current-sdk-gate.log) and
[compiler/commit identities](sdk-compatibility.json).

A narrow SDK experiment confirmed that resolving class constants alone then
exposes incompatible callable forwarding in Orbit. That experiment was reverted;
current SDK sources are clean. No sibling Orbit sources were edited by this
stage. The application was verified with isolated SDK **3eb0f05**, which supports
unified manifests but precedes the incompatible callable changes. The existing
SPUTNIK override selects that compiler explicitly; no silent default compiler
replacement or production deployment was made. Smoke VM caches now include the
compiler binary SHA-256 to keep compiler versions separate.

Therefore the latest SDK is **not** reported as compatible. Orbit namespace/
callback migration remains a release gate. This evidence proves the new web
features against the explicitly recorded compatible SDK, not a resolution of that
separate upstream compatibility problem.

## Reproduce

Create an isolated SDK checkout/archive of 3eb0f05 from the sibling repository
and build its build/sputnik with make. Set SPUTNIK to that absolute executable.
Build Core/worker from the notebook repository with make remote-core. Build the
native web fixture/main with the selected compiler, --target native and
--require-full-native, using the ordinary grants documented in the app README.
Run npm run build from apps/notebook-web/frontend.

From that frontend run npm run test:browser -- test/selection-controls.spec.ts
with PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH pointing to installed Chromium. Repeat
with ORBIT_E2E_NATIVE=1 and/or ORBIT_E2E_MODE=development. Verification used local
Chromium 152.0.7977.82. Pure checks from the repository are:

- node apps/notebook-web/tools/selection_controls_test.mjs
- node apps/notebook-web/tools/board_editor_test.mjs
- make test-notebook-selection-acceptance
- python3 tests/notebook_media_acceptance_test.py

No Safari/mobile OS verification or deployment was performed. Selection uses
bounded retained table rows; it does not infer keys from rows omitted by the
native snapshot limit. Shared selection is a board binding, not an arbitrary
browser filesystem/VM capability. Environments/worker settings and expanded
history remain Stage 4h, after the SDK/Orbit release gate.

## Screenshots

| Light | Dark |
| --- | --- |
| [Desktop](controls-light-1280.png) | [Desktop](controls-dark-1280.png) |
| [Phone](controls-light-375.png) | [Phone](controls-dark-375.png) |

[Accepted selection / exact Int64](shared-selection-accepted.png) ·
[Preset comparison](preset-review.png) ·
[Source and binary hashes](source-sha256.json) ·
[Plan](../../../engineering/notebook-web-implementation.md) ·
[Contract](../../../engineering/notebook-remote-media-inputs.md)
