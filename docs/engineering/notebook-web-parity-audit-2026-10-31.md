# Notebook web parity and deployment audit

Follow-up: [Stage 4i.2](notebook-web-implementation.md#stage-4i2--runtime-observations-and-remaining-palette-kinds-implemented)
implements the three missing kinds and Result/Log controls described below.
Its [current inventory and acceptance](../evidence/2026-10-31/notebook-web-runtime-observations/README.md)
supersede the kind-availability rows in this Stage 4i.1 snapshot. External and
non-bundled generated artifact paths remain unavailable; public/deployment gaps
are still open.

1–2 November follow-up: [Stage 4i.3](notebook-web-implementation.md#stage-4i3--anonymous-public-notebook-lifecycle-implemented)
adds the anonymous public template/session entry and cumulative visitor budget.
[Public-mode acceptance](../evidence/2026-11-01/notebook-web-public/README.md)
supersedes the anonymous-entry gap below; external deployment acceptance is open.

31 October 2026. Stage 4i.1 is complete as an audit. Full Swift feature parity and
external production acceptance are still incomplete. This report replaces the
outdated “next audit” status after Stage 4h.2; it does not replace historical stage
evidence.

The Stage 4i.1 source inventory contains **35 Swift palette tools, 33 persisted
kinds and 30 web palette kinds**. Three kinds have no web runtime renderer:
`status`, `artifacts` and `task_monitor`. Config Editor and Image Annotator are
configurations of `input` and `image`, so the tool count differs from kind count.
Result Inspector and Log Viewer have narrower controls than their Swift peers.
The anonymous public landing/template flow is a separate remaining product gap.

## Transfer acceptance

The new acceptance fixture builds a version-4 book containing all 35 tools,
nested tabs/split/group panels, parameters, module/resource files, unknown
extension fields and computation/storage policies. A test-only C++ probe opens,
edits, saves and exports it through the same owner-queue C API used by Swift.
The browser imports the ZIP, opens the board, edits one code cell, explicitly
saves and exports the full book. The native bridge then reopens, edits and saves
that exported book.

The complete parsed document equals the original native-saved document except
for the deliberate source edits. Comparisons use the lossless document parser:
cell identity `9007199254740993` and integer `9223372036854775806` survive exactly.
Nested/unknown settings, book quotas, module bytes and a hidden binary resource
survive. Import, board display and Save create neither runs nor environments.
The three unsupported kinds show an explicit unavailable message. All four
VM/native × development/production configurations pass. Light/dark viewports at
1280 and 375 px have no document horizontal overflow; desktop/phone screenshots
were inspected.

This proves the shared native-bridge transfer contract for this authored fixture.
It does not drive SwiftUI, exercise every inspector option or establish visual
identity between the two applications. Previous stage evidence covers runtime
behavior of the implemented components; this audit's transfer check does not
execute every palette tool.

## Palette matrix

¹ “Present” records renderer/control source presence, not complete semantic or
inspector equality. The reproducible inventory reads the actual Swift palette
and web palette, and asserts the known missing kinds so drift requires review.

| Swift tool | Saved kind | Web status | Specific limit / difference |
| --- | --- | --- | --- |
| Tabs | `tabs` | Renderer / controls present¹ | — |
| Split View | `split` | Renderer / controls present¹ | — |
| Group / Accordion | `group` | Renderer / controls present¹ | — |
| Input | `input` | Renderer / controls present¹ | — |
| Config Editor | `input` | Existing-kind configuration | Uses an Input with JSON/YAML/TOML control settings, rather than a separate palette button. |
| Parameter Form | `parameter_form` | Renderer / controls present¹ | — |
| Parameter Presets | `parameter_presets` | Renderer / controls present¹ | — |
| Range Input | `range_input` | Renderer / controls present¹ | — |
| Date / Time Input | `date_input` | Renderer / controls present¹ | — |
| Audio Input / Recorder | `audio_input` | Renderer / controls present¹ | Browser microphone permission and recorder formats depend on browser support; no Safari/mobile OS acceptance. |
| File / Dataset Input | `file_input` | Renderer / controls present¹ | Managed upload and relative project members; arbitrary desktop/server file paths are not browser authority. |
| Action Button | `action` | Renderer / controls present¹ | — |
| Execution Controls | `execution_controls` | Renderer / controls present¹ | — |
| Text Cell | `rich_text` | Renderer / controls present¹ | — |
| Text / Value | `text` | Renderer / controls present¹ | — |
| Metric / KPI | `metric` | Renderer / controls present¹ | — |
| Status / Alert | `status` | **Unavailable; preserved** | Saved settings preserved; explicit unavailable component in web. |
| Log Viewer | `log` | Renderer / controls present¹ | Bounded stdout/stderr; no Swift log search/filter inspector. |
| Artifact Browser | `artifacts` | **Unavailable; preserved** | Saved settings preserved; project-file export is not an Artifact Browser equivalent. |
| Result Inspector | `result` | Renderer / controls present¹ | Text/table output; Swift Inspect/Pretty tree, Find and result search are not equivalent. |
| Data Table | `table` | Renderer / controls present¹ | — |
| Task Monitor | `task_monitor` | **Unavailable; preserved** | Saved settings preserved; task errors are surfaced, but no task telemetry monitor DTO/view. |
| Run History | `run_history` | Renderer / controls present¹ | Shared server retention/pins; scalar restore is atomic per scope, not a whole local notebook heap. |
| Experiment Compare | `experiment_compare` | Renderer / controls present¹ | Exact scalar/metric deltas and CSV; same retained-snapshot limits as Run History. |
| Image Annotator | `image` | Existing-kind configuration | Uses Image/Carousel annotation settings, rather than a separate palette button. |
| Audio Annotator | `audio_annotator` | Renderer / controls present¹ | — |
| Audio Player | `audio` | Renderer / controls present¹ | — |
| Progress | `progress` | Renderer / controls present¹ | — |
| Stopwatch | `stopwatch` | Renderer / controls present¹ | — |
| Figure | `plot` | Renderer / controls present¹ | — |
| Live Chart | `live_chart` | Renderer / controls present¹ | — |
| Image | `image` | Renderer / controls present¹ | — |
| Image Carousel | `image_carousel` | Renderer / controls present¹ | — |
| Run Button | `run` | Renderer / controls present¹ | — |
| Periodic Work | `periodic_work` | Renderer / controls present¹ | Server schedule. Desktop pause-while-hidden is intentionally preserved without controlling server lifetime. |

Source: [machine-readable inventory](../evidence/2026-10-31/notebook-web-parity/parity-inventory.json).

## Real entry and deployment contract

The new production probe uses the actual full-native `backend/main.s` binary,
an independent full-native Core/worker and a local reverse proxy implementing
the documented original-Host and one-hop HTTPS provenance contract. It seeds a
signed session in a disposable catalog using the production session codec; the
real session/authentication/CSRF middleware handles subsequent requests. No test
provider or authentication bypass is added to the application.

Five acceptance groups pass:

1. Production SSR/bootstrap/CSP, anonymous private-API rejection, direct-backend
   provenance rejection and overwriting forged forwarded headers.
2. Authenticated creation/save, missing-CSRF rejection, a 1.2 MB resource upload
   and byte-identical download through the real Core.
3. Hashed immutable assets, with manifest, source, migrations, binary and seed
   helper paths unavailable from the public origin.
4. A running command finishes while the HTTP process is stopped/restarted;
   an explicit retry with the same command returns the same run, and only one
   run exists. Effective 60-second book computation policy remains visible.
5. Core outage returns a sanitized 503; independent Core restart retains the
   completed result and charged computation time.

The [operator guide](../../apps/notebook-web/deploy/README.md) and
[nginx example](../../apps/notebook-web/deploy/nginx.conf.example) document service
working directories, the two persistent stores, grants, secret/origin settings,
original Host, replaced forwarded headers, hashed assets, safe release ordering
and a 112 MiB request envelope matching the backend's encoded import limit.
The upload test would exceed nginx's default body limit; the example sets an
explicit value. The probe itself uses a Node HTTP proxy, not nginx.

No nginx executable is installed on this acceptance host. `nginx -t`, actual
nginx routing, a TLS handshake, real GitHub consent, Linux service supervision,
production load and backup/restore drills were not executed. Signed-session
acceptance establishes authenticated application/Core integration, not live
OAuth provider interoperability. No external deployment was performed.

## Quotas and public mode

Core remains authoritative for app/book computation and storage policy. The book
policy survives the full transfer; operator-selected book override mode cannot
raise explicit owner/server/public ceilings. Existing
[resource-policy acceptance](../evidence/2026-10-28/notebook-web-resources/README.md)
checks both merge modes, storage admission and cumulative accounting. The new
production probe additionally verifies persistence across HTTP/Core restarts.

Temporary preview currently requires execution access to its source project. It
caps accumulated computation and each run at **60 seconds**, regardless of a
higher book policy. New copies still consume aggregate owner/Core budgets. This
is not yet an anonymous public app entry: server-owned template/principal
selection, anonymous session isolation and the public lifecycle remain to be
implemented and accepted before that mode can be released.

## Next implementation slices

- **4i.2 — remaining palette runtime:** Status/Alert, Artifact Browser and Task
  Monitor through bounded Core DTOs with current ACLs; Result Inspector and Log
  Viewer control gaps. Preserve inert load/Save, provenance, unsupported settings,
  exact values and quota admission; add real execution and transfer acceptance.
- **4i.3 — public app lifecycle:** server-owned template/principal selection,
  isolated anonymous sessions and expiry, with cumulative/per-run 60-second
  computation ceilings and storage admission that cannot be lifted by a book.
- **4i.4 — external deployment acceptance:** real GitHub consent, installed nginx
  syntax/routing and TLS, Linux service/restart/backup checks, then Safari/mobile
  capture and SwiftUI visual/manual comparisons. This requires an actual target
  environment and credentials; none are inferred from local fixture success.

[Evidence, logs and screenshots](../evidence/2026-10-31/notebook-web-parity/README.md) ·
[Implementation plan](notebook-web-implementation.md) ·
[Current SDK integration](../evidence/2026-10-30/notebook-web-current-sdk/README.md)
