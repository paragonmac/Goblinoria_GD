# ADR-013: Passive Gameplay Profiling

Status: Accepted
Date: 2026-09-05

## Context

Normal play needs performance evidence before the project invests in repeatable scripted benchmarks. Existing timing displays were controlled by HUD visibility and duplicated the world-update phase order. Long captures also require explicit memory/disk bounds and a way to distinguish pauses and loading from gameplay stalls.

## Decision

Main owns an opt-in passive recorder and a small input/lifecycle adapter. The recorder accepts frame boundaries, named measurements, counters, segments and markers without knowing gameplay controls. Explicit timestamps support deterministic correctness tests; they do not control the game's clock.

`World.update_world()` remains the single canonical phase sequence. Timing hooks feed the existing debug profiler and the passive recorder independently. Main finalizes measurements after prewarm. DebugOverlay delegates world updates rather than maintaining a second sequence.

All recorder state and file operations belong to the main thread. Background jobs return their existing measurements; result handoff records them without exposing recorder buffers or live world state to threads. Completed asynchronous costs are labeled separately from main-thread durations.

Mesh scheduler discard costs use bounded locked totals drained on the main thread, including completed work invalidated before publication. Capture epochs prevent later recordings/worlds inheriting old jobs. Batch totals have explicit job counters and overlapping lifecycle categories, not per-job timing-sample denominators.

Recording spans labeled gameplay/menu/saving/loading/unfocused segments and world IDs. Gameplay frame statistics exclude non-gameplay and boundary-crossing intervals. Sampling must not generate terrain, scan gameplay collections each frame, modify scheduling, or alter save semantics.

Reports use bounded aggregate statistics, a fixed-capacity recent-frame ring, capped spike windows, and bounded buffered file output. Detailed rows are expendable under pressure, essential-record loss stops capture, and omissions are visible. Capture limits never authorize deleting older captures. Failures retain partial evidence and do not interrupt gameplay.

## Consequences

- Ordinary sessions can explain stalls but are not controlled performance comparisons.
- Main update time, frame interval, simulation delta, and asynchronous job time have different meanings and must not be conflated.
- Approximate percentiles and measurement overhead are explicitly reported.
- Future workload runners or gameplay event producers can use the same recorder interface without owning the measurement implementation.
- Existing generation diagnostics, debugging keys, gameplay rules, and save formats remain unchanged.

## Guardrails

- `scripts/diagnostics/passive_performance_recorder.gd`: bounded measurement state and segment ownership.
- `scripts/diagnostics/passive_performance_writer.gd`: output limits, partial files, and failure handling.
- `scripts/main_performance_controller.gd`: manual controls, status, and lifecycle adaptation.
- `tools/validate_passive_recorder_core.gd`: report/statistics/bounds/failure contracts.
- `tools/validate_passive_gameplay_profiling.gd`: actual Main input, lifecycle, and single-update-path contracts.
- `tools/validate_mesh_capture_accounting.gd`: background completion/discard totals and capture epochs.
- [Controls and report interpretation](../gameplay_profiling.md).
