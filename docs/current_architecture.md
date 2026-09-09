# Current Architecture

This document records the current runtime shape during housekeeping refactors. It is descriptive, not a new design target.

See [Prototype Checkpoint](prototype_checkpoint.md) for the dated feature/validation assessment and known boundaries between this implementation and the GDD's longer-term goals.

## Startup And Main Loop

`Main.gd` is the scene coordinator. It owns controller setup, menu actions, startup/load flows, and per-frame orchestration. Loading-screen UI is delegated to `MainLoadingController`; render-Y readiness, Y prewarm, and background warmup are delegated to `MainRenderLevelController`; render-level chunk target construction is delegated to `MainRenderLevelTargetBuilder`; Y-transition CSV row construction is delegated to `MainYTransitionProfiler`. The render-level controller receives explicit camera, scene-tree, stream-view, loading, and debug dependencies and exposes a small public API; `Main` no longer mirrors its private methods.

Normal frame flow is:

1. Global input handles menu toggles.
2. Gameplay input handles mode keys, debug keys, worker window toggle, and render-level changes.
3. Camera, selection, streaming, world simulation, workers, tasks, and overlays update through `Main._run_frame_updates()`.
4. Directional Y prewarm and background level warmup pump after the main update.

`ColonyUIController` owns the docked player UI, with separate code-created theme/navigation, capability catalog, management panels and read-only presentation model. It replaces the production HUD/worker window and first-stockpile-only editor. Economy mutation signals invalidate coalesced observations; collection and filtering use bounded 128-record/1 ms pumps, worker activity refreshes every 200 ms, and visible lists page at 50 rows. Completed immutable data stays available with an Updating label during rebuilds; sustained mutations can postpone fresh economy publication. No diagnostic recording is required and no decisions are rerun to explain state. Main pumps the UI once per frame and measures `Main.colony_ui_ms`. See [UI controls](colony_ui.md) and [ADR-016](adr/ADR-016-colony-management-ui.md).

`MainToolCatalog` shares the seven tool labels/modes/keys between keyboard selection, tool bar, and context menu. `MainContextMenuController` owns the script-created popup, right-click versus pan gesture and captured cell actions; its inspection uses the shared right-hand details dock. `MainCameraController` pans only through explicit begin/update/end calls. Main gates world controls for popup/text-field and GUI-origin gesture ownership, and synchronizes shortcut state without replay; simulation/streaming still run. Escape closes popups, then the most recent dock, then the menu. Loading/world replacement clears selections; runtime World epochs and exact entity identity reject reused targets without requiring diagnostics. Both context and Information inspection raycasts use `generate_missing=false`; designation behavior is unchanged.

## New World Flow

A new world starts from `Main._start_new_world_with_loading()`:

1. Hide world draw and show the loading screen.
2. `World.start_new_world()` resets state, seeds terrain, primes spawn chunks, and spawns workers.
3. If `generate_full_map_on_startup` is enabled, `WorldArenaCooker` runs a full finite-map cook.
4. The generated block and raw mesh-cache data are saved through `World.save_world()`.
5. Startup reveal prepares the camera-visible render-Y area before showing the world.
6. Optional background warmup starts from the current chunk-Y band.

Full-map arena cook is two-stage:

1. One WorkerThreadPool task runs the serial layered generation pipeline and bakes all finite chunk block buffers.
2. The main thread merges generated chunks into `World` over frames.
3. WorkerThreadPool tasks build raw mesh-cache entries from the completed block arena.
4. The main thread imports raw mesh-cache entries into `WorldRenderer` over frames.


## Layered World Generation

Full-map new-world creation uses `WorldGenerationPipeline` through `WorldGenerator` and `WorldArenaCooker`. The pipeline builds finite-world intermediate maps in world coordinates before baking final block IDs into normal chunk buffers. Current maps are elevation, moisture, temperature, biome, soil/stone region, and feature reservations.

Generation pass order is serial and explicit: climate maps, biome, geology, solid terrain fill, caves, static underground water, ores, surface blocks, ramps, flowers, cleanup, then chunk baking. Trees are no longer generated as blocks; future tree visuals should be placed as 3D assets. The result is still ordinary `ChunkData.blocks`; intermediate maps are not saved yet. Persistent saves continue to store final block data and optional raw mesh-cache entries only.

`WorldGenerationPipeline` owns configuration, pass ordering and timing, climate and biome maps, generation statistics, and final chunk baking. Deterministic generation details are split by responsibility: `WorldTerrainHeightSampler` samples terrain, `WorldRampRules` selects ramp shapes, `WorldCaveGenerator` carves caves, `WorldTerrainMaterialGenerator` applies geology and block materials, and `WorldVegetationGenerator` places flowers. Generated terrain slopes use a separate block-ID range from player stairs, while preserving the same pathing geometry; see ADR-011. Runtime fallback chunks use `WorldTerrainChunkBuilder` and `WorldTerrainRampBuilder`; `WorldGenerationJobQueue` owns asynchronous queue state.

The richer layered pipeline is used for the full-map arena cook, temporarily allocating a full-world block volume before baking chunk buffers. Runtime on-demand chunk generation remains compatible with chunk/runtime interfaces as a fallback for non-full-map startup modes, but produces simpler terrain and ramps. The same seed does not imply identical content across the two generation modes. The static underground water pass exists but is currently disabled pending presentation work (issue #3); there is no fluid simulation.
## Load Flow

`World.load_world()` delegates to `WorldSaveLoad.load_world()`:

1. Recover an interrupted slot promotion if necessary, then read metadata, item/stockpile, and worker-role files into validated snapshots without mutating the live world.
2. Read and validate `world_blocks.dat`, preserving the previous bulk cache if validation fails.
3. Commit metadata and physical storage only after all authoritative files pass.
4. Read optional `world_mesh_cache.dat` entries into pending mesh-cache storage.
5. Clear live chunks, reset streaming, reset renderer stats, and respawn workers.
6. Startup reveal requests the camera-visible chunks and imports valid pending mesh-cache entries as chunks load.

Mesh-cache failures are non-fatal. Missing, stale, corrupt, or version-mismatched mesh cache data falls back to normal mesh builds from block data.

Current-format saves require terrain data: a missing bulk file is rejected unless valid legacy per-chunk terrain is available. A rejected load preserves the live world and its persistence caches.

## Streaming And Render-Level Readiness

`WorldStreaming` decides which finite chunks should be loaded around the camera view. X/Z are clamped to the 32x32 finite chunk map, while Y remains within world height.

The render zone retains lower chunk bands down to `World.get_min_render_y()` so exposed cave walls and floors do not disappear at a chunk boundary. It includes the immediately adjacent upper band only when the next connection level crosses a chunk boundary, allowing a player stair above the destination level to remain visible. Player stairs encode one-level-lower visibility; generated terrain slopes encode their physical height and clip with the rest of the terrain. See ADR-011.

Interactive render-Y changes use a viewport-bounded readiness gate in `MainRenderLevelController`:

1. Build mesh targets from each visible vertical band's projected camera footprint plus safety margin through `MainRenderLevelTargetBuilder`. Readiness and streaming share the vertical visibility bounds; a cut-plane-only footprint misses deeper surfaces under an oblique camera.
2. Build generation targets for those meshes and all six boundary neighbors, including neighbors outside the viewport.
3. Request chunk generation/load and mesh builds until those bounded targets are ready.
4. Build one Y-transition CSV row through `MainYTransitionProfiler` and log it through `DebugOverlay`.

Background warmup and directional prewarm are separate from the blocking reveal gate.

Camera motion, lead buffering, and the streaming focus use the active-slice viewport rectangle. Separate per-band rectangles describe deeper render coverage; they must not move that focus. The renderer's broad coverage spans the depth range and frustum culling still filters scene visibility. Deep layers stream their own projected render columns and a one-chunk neighbor halo, not the broad near-level offscreen buffer or the entire swept rectangle at every height. Stationary camera projections are cached. Keeping deep cave surfaces available increases the possible mesh workload compared with the previous single-band view. Queue budgets are unchanged; real-play cost and visual acceptance require a graphical check, not a claim based on headless timing.

Visibility is change-driven and asynchronous. At the existing 50 ms submission cadence, streaming compares against the last requested view, not the last applied view. `WorldRendererVisibility` snapshots camera planes/bounds for the dedicated `RenderZoneCullScheduler`, which owns one running job, one replaceable pending job and one completed-result slot. The pure incremental kernel receives no scene/world objects. Camera motion and zoom coalesce pending requests; newer completed views are accepted even if the camera has moved again. Renderer/world resets, level changes, camera replacement/removal and viewport identity/size changes invalidate an epoch without joining the worker. No ordinary frame waits for culling.

Main pumps visibility once before profiler finalization, including menus/loading. Application is show-before-hide and cooperatively limited to 1 ms or 256 coordinate steps (including membership/reconciliation scans). Eligible and actually shown coordinates use main-thread stable-slot registries; chunk-cache slots permit bounded first-view reconciliation. Mesh handoffs use effective eligibility immediately, including pooled/replacement nodes and empty meshes. Initialized-empty differs from unknown startup state. Hard cancellation keeps partially applied state for the next result to reconcile; diagnostics explicitly report mixed views and requested/accepted/applied sequences. Legacy hides inside eligibility request reconciliation; already excluded hides do not recull. Thread startup failure warns and uses the same shared budget for incremental fallback culling and application. Exit joins the worker before ownership ends.

Initial requests overlap existing terrain/mesh loading. Cached level changes accept visual catch-up and never add a loading-screen wait solely for visibility. Cave coverage, frustum padding, mesh/generation scheduling and save formats are unchanged. The synchronous culler remains the test oracle, not a runtime fallback. `validate_change_driven_visibility.gd`, `validate_render_zone_cull_scheduler.gd` and `validate_async_visibility.gd` test correctness, thread ownership and work limits, not a guaranteed FPS improvement. See [ADR-015](adr/ADR-015-asynchronous-visibility.md).

## Rendering And Mesh Cache

`WorldRenderer` is the public rendering facade used by `World`, `Main`, and `WorldStreaming`.

It currently owns:

- Chunk `MeshInstance3D` pooling through `ChunkCache`.
- Runtime mesh scheduling through `WorldRendererMeshScheduler`, which owns the job queue, result queue, prefetch records, and one dedicated mesh thread.
- Mesh job input snapshots through `ChunkMeshJobBuilder`.
- Raw mesh-cache storage and cache metrics through `WorldRendererMeshCacheStore`, keyed by chunk coord and local top.
- Lazy `ArrayMesh` creation when a cached chunk becomes visible.
- Render-height rebuild queueing through `WorldRendererRenderLevel`, plus render-zone visibility.
- Block shader material and atlas setup through `WorldRendererMaterials`.
- Draw and mesh statistics through `WorldRendererStats`.
- Overlay forwarding and renderer/debug statistic composition.

Raw mesh-cache entries store packed arrays and metrics, not `ArrayMesh` resources. `WorldRendererMeshCache` centralizes raw mesh-cache entry construction, validation, export, import shaping, and lazy `ArrayMesh` construction. `WorldRendererMeshScheduler` centralizes async mesh job ownership; `WorldRendererRenderLevel` owns render-height rebuild queue ordering. `WorldRenderer` delegates job dictionaries to `ChunkMeshJobBuilder` and still applies completed results to visible chunks. Persistent mesh cache saves those raw arrays with `store_var(..., false)` and validates them against world dimensions, chunk size, block table hash, mesher cache version, chunk block hash, and neighbor hashes.

Runtime mesh jobs build full-chunk geometry even above the selected slice; shaders handle level clipping. A hidden chunk is not marked ready merely because it is above the view. Job results carry renderer and coordinate lifetime tokens, so reset/load or coordinate cancellation rejects obsolete results before they can alter meshes, caches, readiness, or replacement job records.

Terrain shaders retain exposed cave sides even when a solid block sits above them. The covered-from-above UV2 flag is decoded for synthetic cut-top handling, not used to discard real walls. Synthetic internal top faces remain hidden below the selected cut. This is compatible with existing full-chunk mesh caches and does not change save formats. `validate_cave_rendering.gd` covers lower-band visibility, projected readiness and cache reuse; `validate_cave_shader_visibility.gd` covers real mesher encoding and shader-source contracts, not GPU fragment execution.

## Save/Load Data

`WorldSaveLoad` orchestrates persistence, with metadata, bulk block data, physical item/stockpile state, and persistent mesh-cache file handling split into small helpers:

- `world_meta.dat`: seed, spawn, top render Y, world dimensions, chunk size, block table hash, save version. Handled by `WorldMetadataSaveLoad`. V7 adds named stockpiles and per-worker work priorities. V6 role saves, V5 default rosters and V4 terrain-ramp migration remain supported.
- `world_blocks.dat`: finite-world bulk chunk block data with fill/raw/ZSTD entries. Handled by `WorldBulkChunkSaveLoad`.
- `world_mesh_cache.dat`: optional raw mesh-cache acceleration data. Handled by `WorldMeshCacheSaveLoad`.
- `items_stockpiles.dat`: physical item stacks and named stockpile zones. Handled by `WorldItemStockpileSaveLoad`; legacy unnamed zones receive `Stockpile <id>`.
- `workers.dat`: worker-ID to role-template-ID records and validated per-work priority overrides. Handled by `WorldWorkerSaveLoad`; workers still respawn at normal positions on load. Missing legacy overrides use the role defaults; Off is an explicit zero, not a missing value.

Current save formats are not changed by housekeeping refactors unless explicitly planned.

Whole-world saves stage a complete slot in a reserved `.save-stage` sibling directory. Authoritative writers check write/flush completion before promotion; unloaded legacy chunks are folded into the bulk data. Promotion renames the previous slot to a `.save-backup` sibling, then installs the stage. Failures restore the previous slot and in-memory persistence state; if rollback itself fails, the backup is retained for recovery on the next load/save. The active slot pointer and chunk dirty flags change only after promotion succeeds. Optional mesh-cache failure omits that cache without failing an otherwise valid save. The transaction mechanism is unchanged by the V7 name/priority additions.

Workers is informational; Jobs opens a movable, non-modal worker-list pop-out
(`jobs_worker_popup.gd`). Its selected worker's details edit numeric work settings through
World's validated API. The work catalog maps Hauling to HAUL, Mining to DIG and
Building to PLACE/STAIRS; future categories cannot dispatch. Lower numbers precede
cheaper routes within each worker's choices, with Off disabling new claims. Active
jobs survive edits. Stockpile renaming emits visual invalidation only, preserving
IDs, reservations and hauling state. Explicit category/row clicks toggle panels;
programmatic opens remain idempotent. See [ADR-017](adr/ADR-017-work-priorities-and-stockpile-names.md).

## Gameplay Systems

`World` is the gameplay/system hub. It owns chunks, world bounds, block access, inventory, tasks, pathfinding, workers, generator, save/load, streaming, raycasting, and renderer references.

Workers pull tasks from `TaskQueue` through `TaskManager`, pathfind with `Pathfinder`, mutate blocks through `World`, and carry physical item stacks for hauling work. Assignment and haul-delivery searches run against immutable snapshots on the path thread. `WorkerRoles` currently supplies two Miners, one Hauler, and one Fighter: Miners perform dig/build/stair tasks, Haulers perform hauling, and Fighters remain an inspectable reserve until combat work exists. See ADR-012.

Mining creates physical item stacks through `BlockDropTable` and `ItemStackStore`. Loose items are not usable inventory. Each stockpile cell stores one material with a base stack capacity of 16, and `world.inventory` is a derived compatibility view over those stored stacks.
Loose stacks use camera-facing cells from `assets/textures/fantasy_resource_icons_6x6_real_alpha.png`; materials without a mapped cell retain the colored-box fallback.

Haul-task reconstruction is dirty-driven: item and stockpile mutations request one coalesced rebuild. Completed tasks are removed from queue indexes immediately, so neither operation requires an unconditional full scan each frame.

Task accessibility is also dirty-driven. New or locally invalidated tasks enter a budgeted accessibility queue. Tasks remain unknown/green until a worker path bid succeeds, become reachable/blue after that proof, and become blocked/red after structural rejection or failed worker bids. Tasks without a work position wait for nearby terrain mutation; tasks rejected by all worker paths use individual 2.5-second retry deadlines managed by one timer.

Persistent task, item, and stockpile overlays have independent dirty flags. They synchronize after relevant state changes or render-level changes; assigned pulse animation remains shader-driven. Drag and hover previews remain input-driven.

Ordinary DIG work is horizontal-only: the worker and target block must share a Y level. Downward excavation requires the stairs workflow to establish controlled access to the next level.

New stair tools stamp a two-cell, one-level flight with a shared `StairFlight`
geometry contract. One task owns both halves; input chooses orientation explicitly
using the wheel and the renderer shows a matching ghost. Flight job designations
reuse the ghost half meshes, unit scale, and Up/Down depth and slice rules;
assignment changes color and pulse without changing the footprint. Legacy one-cell stairs
and terrain slopes retain their identities. V8 extends saved block identities;
see [ADR-018](adr/ADR-018-two-cell-stair-flights.md).

Worker activity tracing is toggled with `F11`. `WorkerTrace` writes transition, block-level movement, and task-overlay color events to timestamped CSV files under `user://diagnostics`, including worker coordinates, task targets, path progress, logical overlay colors, and renderer visibility state.

## Passive Gameplay Recording

Main owns `MainPerformanceController` and its UI-independent `PassivePerformanceRecorder`. F12 starts/stops capture and Shift+F12 marks a moment through unhandled key events, retaining GUI priority. A separate script-created status layer does not require visible debug timings. Recording is opt-in and spans labeled menu/save/load/focus/world transitions.

`World.update_world()` is the canonical update sequence for both normal and timed execution. `World.run_performance_timed()` feeds existing debug timings and passive measurements independently; `DebugOverlay.step_world()` delegates to World. Main finishes frame measurements after prewarm. Asynchronous jobs contribute measurements only at main-thread handoff. Workload snapshots use maintained counters and safe queue snapshots once per second.

The recorder writes bounded summaries, periodic samples, events and short detailed stall windows beneath `user://diagnostics/gameplay/`. It does not drive workloads or compare sessions. See [Gameplay Profiling](gameplay_profiling.md) for controls, storage bounds and interpretation, and [ADR-013](adr/ADR-013-passive-gameplay-profiling.md) for ownership and correctness guardrails.

## Live Diagnostics And Bug Capture

Main owns `MainDiagnosticsController`, independently of the passive recorder and debug overlay. A UI-independent bounded journal records actual main-thread decisions; a read-only snapshot adapter exposes existing world/render/task/item records. The controller services a token-authenticated loopback NDJSON bridge even when gameplay updates return early for menus/loading. World epochs change at initialization or successful load commit, so reused entity IDs cannot silently retarget an inspection.

F1 and a script-created menu action capture bounded state and optional viewport evidence beneath `user://diagnostics/bugs/`. The pre/post-draw adapter owns scene reads; one background writer receives only owned copies. Incomplete manifests, omission counters, and explicit unavailable states distinguish missing evidence from observed absence. No diagnostic operation generates terrain, evaluates routes, repairs state, or changes gameplay. See [Live Diagnostics](live_diagnostics.md) and [ADR-014](adr/ADR-014-live-diagnostics-and-bug-capture.md).

## Refactor Pressure Points

The largest coupling hotspots are:

- `Main.gd`: menu actions, full-map session flows, and frame orchestration still share one file. Loading UI, HUD, render-level readiness, and Y-transition profiling are split into controllers/helpers with explicit public boundaries.
- `WorldRenderer`: render-zone visibility, result application, overlays, and stat composition still share one class. Mesh-cache data contracts are split into `WorldRendererMeshCache`, cache storage into `WorldRendererMeshCacheStore`, job snapshots into `ChunkMeshJobBuilder`, runtime mesh queue/thread ownership into `WorldRendererMeshScheduler`, render-height queue ownership into `WorldRendererRenderLevel`, and material ownership into `WorldRendererMaterials`.
- `ChunkMesher`: greedy cube meshing, ramp meshing, and mesh resource fallback still share one class. Padded-buffer/index helpers, UV helpers, and color/noise/shading helpers are split into `ChunkMesherPaddedBuffer`, `ChunkMesherUv`, and `ChunkMesherVisuals`.
- `WorldSaveLoad`: legacy chunk files, block-table hashing, and migration checks still share one class. Metadata, bulk block data, inventory, and persistent mesh-cache file handling are split out.
- `DebugOverlay`: live HUD stats, CSV captures, timing logs, map exports, and ramp debug tools share one class.

Housekeeping should split these by responsibility while preserving the current external APIs and runtime behavior.
