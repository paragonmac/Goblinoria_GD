# Passive Gameplay Profiling

The gameplay recorder observes normal play. It does not drive workers, generate benchmark workloads, compare different sessions automatically, or certify performance. Existing full-map generation reports remain separate and unchanged.

## Controls

- **F12:** start or stop a recording after a world exists, including from the pause menu.
- **Shift+F12:** mark a moment while recording, with detailed nearby frame data.
- A small non-interactive indicator shows recording duration, segment, and marker/error status. The timing/debug overlays do not need to be visible. Existing F2-F11 controls are unchanged.
- GUI controls and open dropdowns/context menus retain input priority. A consumed capture shortcut is not replayed when the popup closes.

Recording is off by default. A recording continues through menus, saves, loads, and world replacement. Focus loss takes precedence over the other segment labels; returning restores the current operation/menu/gameplay label. Context menus remain gameplay because the simulation continues under them.

## Reports

F1 bug capture and the opt-in live inspection bridge are separate tools; see [Live Diagnostics](live_diagnostics.md). Bug capture never starts or stops this recorder. When already recording, it adds a `bug_capture` event and the bundle references the performance recording. Diagnostic hooks and capture work have real overhead; observed frame intervals include that impact.

Each recording creates a unique directory under `user://diagnostics/gameplay/`:

| File | Contents |
|---|---|
| `summary.md` | Human-readable session results and limitations. |
| `summary.json` | Versioned summary, metadata, timing statistics, segment durations, completion and omission information. |
| `samples.csv` | One-second aggregates: named timings/counters and workload snapshots. |
| `events.jsonl` | Capture/lifecycle events, world segments, manual markers and render-level changes. |
| `spike_frames.csv` | Detailed frame windows around stalls or manual markers. |

Reports identify the engine/build, available hardware/renderer, viewport/FPS settings, world seed, and enabled diagnostics. Revision and dirty state are `unknown` unless available; the recorder does not run Git during gameplay. Reports are local files and are not uploaded. They contain performance/configuration data, not screenshots or terrain snapshots.

The initial summary is marked incomplete. Normal stop or quit finalizes it. A crash or I/O failure can leave incomplete files; do not treat an incomplete capture as a complete session. The status indicator reports recording failures without stopping gameplay.

## Reading Measurements

Frame interval is monotonic elapsed time between frame boundaries. Simulation delta is the value passed into the game update. Main update time measures Main's synchronous work, excluding recorder bookkeeping. These are different measurements: an update timer is not GPU time, and a long frame interval can include waiting outside Main's update.

In detailed rows, the timestamp is the current frame's start: its interval looks back to the previous frame start, while its Main/phase costs describe the current update. Inspect the preceding row as well when correlating a stall with work.

World and Main phase timings describe parts of the update. Parent and child timings overlap; do not add all labels together. Path and mesh timings describe completed asynchronous work and must not be added to main-thread frame cost. A result received during capture may have begun before recording; the report measures completed-job costs, not a reconstruction of thread occupancy.

Streaming detail appears in F4 timings and F12 reports independently of overlay visibility:

- `Streaming.bounds_ms`: view/band/stream bounds and change detection.
- `Streaming.reset_ms`: queue/traversal reset, including nested `Streaming.partition_ms` (spiral construction when needed and per-band partitioning).
- `Streaming.enqueue_ms` / `Streaming.process_queue_ms`: traversal/enqueue and queued chunk processing when the existing work gate allows them.
- `Streaming.render_zone_ms`: asynchronous request submission at the existing cadence, including nested `RenderZone.snapshot_ms`. It no longer includes culling or applying the view.
- `Streaming.height_anchor_ms`: renderer height-anchor update after streaming.
- `RenderZone.pump_ms`: main-thread visibility pump after Main's ordinary/loading/menu work. Nested `RenderZone.adopt_ms` and `RenderZone.apply_ms` cover result adoption and incremental reconciliation/application. `RenderZone.fallback_cull_ms` appears only for incremental main-thread fallback when worker startup fails. The combined pump uses a cooperative 1 ms/256-coordinate allowance; individual engine operations and bookkeeping can exceed a nominal time allowance.
- `RenderZone.completed.completed_ms_sum`, `cancelled_ms_sum` and `queue_wait_ms_sum`: capture-epoch-filtered worker/fallback accounting, emitted at main-thread handoff. These are batch totals, not per-frame main-thread costs; use `RenderZone.scheduler.completed` / `cancelled` counters as appropriate denominators. Replaced-result and replaced-pending counters disclose coalescing. Completed totals include work whose result was replaced later. Fallback calculation is also measured as main-thread work; do not add these overlapping figures together.
- `RenderZone.result_age_ms`: request-to-fully-applied latency, not CPU work. Once-per-second `visibility_*` workloads include queue slots, application steps remaining, requested/accepted/applied sequence IDs, fallback mode and result age.

Conditional spans have one sample per execution, not per frame; absent work is not a zero-duration sample. Visibility work can complete after its submission frame. `RenderZone.refreshes`, `candidates`, `accepted_coords`, and `hide_candidates` now count fully applied views. Interrupted partial batches have main-thread timings but do not increment completed-view counters. Hide candidates count traversed stable slots (including reusable holes and initial node reconciliation), not visibility writes or pixels. Old captures used synchronous `RenderZone.setup_ms`, `cull_show_ms`, `hide_ms` and, before set-difference updates, `cached_nodes_scanned`; their meanings must not be compared as unchanged metrics.

An unchanged view now performs no periodic visibility refresh, so its conditional snapshot/adoption/application timing labels can disappear from F4 after the two-second history expires, and an entirely stationary F12 recording may contain none of those labels. The lightweight `RenderZone.pump_ms` still runs each frame. Missing conditional labels mean work was skipped, not that the recorder stopped. Moving/changing the view or a required reconciliation brings the labels back. Workload result age keeps increasing from the originating request even after stationary convergence; use sequence IDs and backlog to distinguish an old stable view from delayed application. Streaming queue budgets, cave coverage and main-thread mesh-result processing remain unchanged.

The F4 label's leading timing holds a high sample briefly (0.5 seconds); its average and peak cover a rolling two-second window. It is not a continuously expensive frame. F12 session statistics cover the recording instead.

The readable summary lists the largest timing totals; `summary.json` and `samples.csv` retain every registered detail label. Async visibility totals appear under completed asynchronous work; visibility age is latency and excluded from CPU-contributor tables. The legacy debug timing CSV's `__TOTAL__` sums overlapping labels and latency and is not frame CPU time.

`Mesh.apply_ms` and `Mesh.sync_build_ms` are synchronous CPU-side work, not background/GPU time. `Mesh.scheduler.*_build_ms_sum` records a batch total drained from the scheduler; use the paired counter for the number of jobs, not the timing sample count. Scheduler completed/delivered/discarded categories overlap and must not be summed together or added to per-result timings. They expose work discarded before normal application. Scheduler capture epochs prevent old captures/worlds from contributing to a later recording; jobs already running when an epoch changes are excluded from its scheduler totals.

Gameplay frame statistics exclude menu, saving, loading, unfocused periods, and intervals crossing segment/world boundaries. Non-gameplay durations and events remain visible. World replacement resets workload baselines without creating a new recording.

Workload snapshots are sampled once per second using maintained counters and safe queue snapshots. Queued, completed-awaiting-application, and in-flight work are distinct where available. Missing metrics remain unavailable rather than being reported as zero. Memory is engine-reported static memory, not whole-process RAM or GPU memory; it is unavailable in release builds because [Godot exposes this measurement only in debug builds](https://docs.godotengine.org/en/stable/classes/class_os.html#class-os-method-get-static-memory-usage).

Median, p95, and p99 frame intervals are approximate, using 1 ms bins through 1,000 ms with an overflow bin. The exact maximum and counts over 33.3, 50, and 100 ms are retained. Recorder collection and file-write overhead are reported separately; observed frame intervals still include their real impact.

## Storage Bounds

- Automatic detail starts at a gameplay frame interval of at least 50 ms. Manual markers also request detail.
- History covers up to five seconds before a trigger, bounded to 4,096 frames, plus two seconds afterward. Reports disclose shortened history at high frame rates.
- Overlapping windows merge up to a ten-second cap. Automatic windows have a ten-second cooldown after closing; slow frames are still counted and manual markers still recorded during cooldown.
- Output is buffered to at most 4 MiB and drained by up to 64 KiB per ordinary frame. Detailed rows are dropped first under pressure, with omissions counted. Essential-record overflow ends capture safely.
- A capture stops at its 128 MiB limit, reserving 1 MiB for summaries. Existing captures are never deleted automatically. Review or remove old capture directories yourself when needed.

The bounds limit memory and output volume, not the latency of an individual filesystem operation. Slow storage can still affect the game; file-write cost is therefore visible in the report.

## Verification And Limitations

The core recorder regression uses explicit timestamps, small injected limits, and isolated report directories. The Main integration regression uses actual input dispatch and synthetic world phases to check controls, lifecycle, and single execution. These are correctness tests, not scripted performance benchmarks.

`tools/validate_streaming_timings.gd` exercises real streaming/visibility paths with both timing sinks independently enabled/disabled, nonempty queues, conditional spans, exact refresh counters, and report parsing. It checks unchanged queue/visibility outcomes, not a speed threshold.

Run `tools/validate_passive_recorder_core.gd`, `tools/validate_passive_gameplay_profiling.gd`, and `tools/validate_mesh_capture_accounting.gd` headlessly alongside the existing validators. The mesh test gates real background work to check cancelled/discarded build accounting and capture boundaries. Ask before graphical checks. In an approved normal-play session, verify indicator placement, shortcut behavior, useful spike windows, and readable reports; record capture-on/off observations without treating different workloads as a controlled comparison.

Implementation validation (2026-09-05, Godot 4.7.2, local uncommitted worktree): all eleven existing validators and all three new profiler regressions passed. The recorder core performed 1,105 checks; Main input/lifecycle integration performed 54 checks. Main parsing and whitespace checks passed. Existing atlas/certificate warnings and deliberately injected save failures remain distinguishable from success markers. The save-role/migration tests needed access to their isolated Godot user-data test slots. No graphical run or real-play overhead comparison was performed.

GPU timing, allocation profiling, per-worker histories, automated scenario runners, baseline comparisons, and performance pass/fail thresholds remain outside this recorder. F11 worker tracing is a separate diagnostic and can itself affect overhead. See [ADR-013](adr/ADR-013-passive-gameplay-profiling.md).
