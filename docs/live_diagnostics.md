# Live Diagnostics And Bug Reports

## In The Game

Development/debug builds only; off by default.

1. Open the game menu and select **Enable live diagnostics** before reproducing the problem.
2. Play normally. The bridge and recent decision history survive menus and world loads.
3. Press **F1**, or use **Capture bug report [F1]** in the menu.
4. Read the capture status, open the bundle, and fill in Problem, Expected, Steps, and Frequency in `report.md`.
5. Share the relevant bundle as bug evidence. GitHub Issues and the Goblinoria Roadmap remain the active-work tracker.

F1 works without enabling diagnostics, but that capture has current state only, not pre-enable decisions or errors. GUI controls and open popups retain key priority. Repeated key events do not recapture. F2-F12 are unchanged; F12 still controls the independent passive performance recorder.

The small status line is below the performance recorder indicator. A menu capture includes the menu in its screenshot; capture does not hide UI or pause simulation to manufacture evidence.

Status and chunk inspection expose asynchronous `visibility` / `visibility_state`: renderer-owned epoch, requested/accepted/fully-applied sequences, pending/running/result slots, application backlog, fallback mode, mixed-view flag, and ages measured from the originating requests. Ages continue increasing for an unchanged view; they are not proof of a backlog. These epochs are independent of live-diagnostics epochs. While application is partial or invalidated, `last_frustum_accepted` is unavailable; `effective_eligible` and node visibility describe current state. A last completed view is historical evidence, not proof that the current camera view has caught up. Inspection never drains results or changes the queue.

## Local Client

Run `tools/diagnostics_client.ps1` from PowerShell. It discovers local descriptors under the project's Godot user-data directory. Use `Get-Help ./tools/diagnostics_client.ps1 -Examples` or read the parameter block for discovery-root and session overrides. Multiple running games require explicit selection; stale descriptors are not trusted merely because they are newest.

```powershell
./tools/diagnostics_client.ps1 -ListSessions
./tools/diagnostics_client.ps1 -Session <session-id> -Operation status
./tools/diagnostics_client.ps1 -Session <session-id> -Operation inspect_cell -ArgsJson '{"pos":[0,10,0]}'
./tools/diagnostics_client.ps1 -Session <session-id> -Operation capture_bug -WaitCapture -TimeoutSec 60
```

The wire protocol is one UTF-8 JSON object per line:

```json
{"id":"query-1","token":"<local descriptor token>","op":"status","args":{}}
```

Successful transport responses contain `id` and `result`. Results carry `format_version`, `session_id`, `world_epoch`, `frame_id`, `monotonic_usec`, and `data`; rejected identity checks contain `error`. Transport failures instead have an `error` object with `code` and `message`. Time units are explicit: timestamps and overhead use microseconds; path timing fields ending `_ms` use milliseconds.

Read `status` first. Use its world epoch for every `inspect_*` or `list_*` operation. Do not fetch a fresh epoch automatically when following an old entity ID: a different world may reuse the ID.

| Operation | Arguments |
|---|---|
| `status` | None; application/world metadata, workload counters, view ID. |
| `inspect_cell`, `inspect_chunk`, `inspect_stockpile` | `world_epoch`, integer `pos: [x,y,z]`; chunk coordinates for `inspect_chunk`. |
| `inspect_screen` | `world_epoch`, `view_id`, viewport `point: [x,y]`. |
| `inspect_worker`, `inspect_task`, `inspect_item` | `world_epoch`, integer `id`. |
| `list_workers`, `list_tasks` | `world_epoch`, optional `limit` (1-128), returned `cursor` for next page. |
| `recent_events` | None; bounded recent history and omission counts. |
| `capture_bug` | Optional `note` and `request_key`; repeat the same nonempty key to retrieve the latest matching capture instead of duplicating it. |
| `capture_status` | None; latest capture state, ID, path/error when available. |

On `stale_world`, `stale_view`, or `stale_cursor`, refresh deliberately and reselect the target. No silent retargeting. Unknown commands, arbitrary method calls, and file paths are rejected or unused. The bridge offers no pause, step, remesh, repair, camera, save/load, or terrain-modification commands.

TCP binds only `127.0.0.1`, with fresh credentials per activation. Descriptors contain secrets: do not attach them to bug reports. This is not a public server or protection from other programs running as your account. A sandboxed tool may need permission to connect locally. Never open firewall/public-network access to make it work.

## Bundle Contents And Interpretation

Bundles are under `user://diagnostics/bugs/`, separate from `user://diagnostics/gameplay/` performance recordings. Each contains `report.md`, `snapshot.json`, `events.jsonl`, `errors.jsonl`, and `manifest.json`. `screenshot.png` exists only when image capture succeeds. `manifest.json` must say `complete: true` before treating the bundle as finalized.

Snapshot data includes engine/build/available hardware, seed, world identity, camera, absolute and HUD-relative render levels, viewport/FPS settings, diagnostics, and an active performance-recording reference. Build revision is unknown unless supplied through `application/config/build_revision`. Capturing marks an existing performance recording but never starts one.

The focus is the visible loaded cursor hit, otherwise the camera's active-plane center. Seven chunk snapshots include loaded block IDs but no triangle dump. Nearby worker/task selection is bounded and explicitly reports incomplete searches; related item/reservation/destination records accompany tasks.

Cell inspection distinguishes unloaded/ungenerated from air. Rendering inspection separates readiness, node visibility, last render-zone/frustum selection, cache entries, and shader slice inputs. It does not claim GPU confirmation. Worker reasons describe the last actual evaluation, with age and invalidation; missing history is not proof that a worker has no reason to wait. Error timestamps are callback times, but world attribution occurs when Main drains the thread-safe queue.

Normal captures match pre-draw state to post-draw image boundaries. World/view/frame changes are labeled explicitly; headless/minimized/oversized/unavailable viewports produce metadata-only reports. Readback itself can hitch. Review screenshots and error paths before sharing; bundles are not uploaded automatically.

## Limits And Failures

History is limited to 30 seconds/4,096 events/2 MiB encoded payload; latest decisions to 4,096 records/2 MiB. Error history is bounded separately. Captures are limited to one at a time, five-second cooldown, 2 MiB structured state, eight megapixels, and 64 MiB per bundle. The 512 MiB directory quota reserves room for a full bundle before starting, so it can refuse a capture before the directory reaches exactly 512 MiB. No files are deleted automatically.

Transport requests/replies, queues, request rate, socket processing, and incomplete-client lifetimes are bounded. Collection/service totals and capture readback/file-write durations are reported, not promised to be free. A stalled main thread cannot respond, and slow storage may delay capture completion or normal quit. Filesystem errors retain partial evidence and show failure without changing gameplay.

See [ADR-014](adr/ADR-014-live-diagnostics-and-bug-capture.md) for ownership and exact limits. Headless validators check correctness, not graphical fidelity or controlled performance. Graphical checks and real-play overhead observations require separate approval.

## Implementation Validation

Validated locally on 2026-09-05 using Godot 4.7.2: all 16 existing validators passed, plus the new Main/service/capture regression (71 checks), worker/task decisions regression (221 checks), and transport/client regression (439 checks, including Windows PowerShell 5.1 and PowerShell 7). Main parsing, a headless startup/quit smoke check, and whitespace checks passed. Existing atlas/certificate-store warnings and deliberately injected filesystem/load failures are separate from success markers; no unexpected script errors remain. Two existing save validators required access to their isolated Godot user-data slots.

Two implementation agents handled transport/client and worker/task observation, then reviewed the integration read-only. No graphical session or ordinary-play overhead measurement was performed. Screenshot fidelity and status placement still require the separately approved graphical check.
