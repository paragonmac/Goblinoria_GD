# Current Architecture

This document records the current runtime shape during housekeeping refactors. It is descriptive, not a new design target.

## Startup And Main Loop

`Main.gd` is the scene coordinator. It owns controller setup, menu actions, startup/load flows, and per-frame orchestration. Loading-screen UI is delegated to `MainLoadingController`; render-Y readiness, Y prewarm, and background warmup are delegated to `MainRenderLevelController`; render-level chunk target construction is delegated to `MainRenderLevelTargetBuilder`; Y-transition CSV row construction is delegated to `MainYTransitionProfiler`. The render-level controller receives explicit camera, scene-tree, stream-view, loading, and debug dependencies and exposes a small public API; `Main` no longer mirrors its private methods.

Normal frame flow is:

1. Global input handles menu toggles.
2. Gameplay input handles mode keys, debug keys, worker window toggle, and render-level changes.
3. Camera, selection, streaming, world simulation, workers, tasks, and overlays update through `Main._run_frame_updates()`.
4. Directional Y prewarm and background level warmup pump after the main update.

HUD status, inventory, and stockpile sections refresh from coalesced state-change signals. Generation status polls every 250 ms, and the worker window polls every 200 ms only while open.

## New World Flow

A new world starts from `Main._start_new_world_with_loading()`:

1. Hide world draw and show the loading screen.
2. `World.start_new_world()` resets state, seeds terrain, primes spawn chunks, and spawns workers.
3. If `generate_full_map_on_startup` is enabled, `WorldArenaCooker` runs a full finite-map cook.
4. The generated block and raw mesh-cache data are saved through `World.save_world()`.
5. Startup reveal prepares the camera-visible render-Y area before showing the world.
6. Optional background warmup starts from the current chunk-Y band.

Full-map arena cook is two-stage:

1. WorkerThreadPool tasks generate all finite chunk block buffers.
2. The main thread merges generated chunks into `World` over frames.
3. WorkerThreadPool tasks build raw mesh-cache entries from the completed block arena.
4. The main thread imports raw mesh-cache entries into `WorldRenderer` over frames.


## Layered World Generation

Full-map new-world creation uses `WorldGenerationPipeline` through `WorldGenerator` and `WorldArenaCooker`. The pipeline builds finite-world intermediate maps in world coordinates before baking final block IDs into normal chunk buffers. Current maps are elevation, moisture, temperature, biome, soil/stone region, and feature reservations.

Generation pass order is serial and explicit: climate maps, biome, geology, solid terrain fill, caves, static underground water, ores, surface blocks, ramps, flowers, cleanup, then chunk baking. Trees are no longer generated as blocks; future tree visuals should be placed as 3D assets. The result is still ordinary `ChunkData.blocks`; intermediate maps are not saved yet. Persistent saves continue to store final block data and optional raw mesh-cache entries only.

`WorldGenerationPipeline` owns configuration, pass ordering and timing, climate and biome maps, generation statistics, and final chunk baking. Deterministic generation details are split by responsibility: `WorldTerrainHeightSampler` samples terrain, `WorldRampRules` selects ramp shapes, `WorldCaveGenerator` carves caves, `WorldTerrainMaterialGenerator` applies geology and block materials, and `WorldVegetationGenerator` places flowers. Generated terrain slopes use a separate block-ID range from player stairs, while preserving the same pathing geometry; see ADR-011. Runtime fallback chunks use `WorldTerrainChunkBuilder` and `WorldTerrainRampBuilder`; `WorldGenerationJobQueue` owns asynchronous queue state.

The richer layered pipeline is used for the full-map arena cook. Runtime on-demand chunk generation remains compatible as a fallback path for non-full-map startup modes.
## Load Flow

`World.load_world()` delegates to `WorldSaveLoad.load_world()`:

1. Read metadata and item/stockpile files into validated snapshots without mutating the live world.
2. Read and validate `world_blocks.dat`, preserving the previous bulk cache if validation fails.
3. Commit metadata and physical storage only after all authoritative files pass.
4. Read optional `world_mesh_cache.dat` entries into pending mesh-cache storage.
5. Clear live chunks, reset streaming, reset renderer stats, and respawn workers.
6. Startup reveal requests the camera-visible chunks and imports valid pending mesh-cache entries as chunks load.

Mesh-cache failures are non-fatal. Missing, stale, corrupt, or version-mismatched mesh cache data falls back to normal mesh builds from block data.

## Streaming And Render-Level Readiness

`WorldStreaming` decides which finite chunks should be loaded around the camera view. X/Z are clamped to the 32x32 finite chunk map, while Y remains within world height.

The render zone normally retains the current vertical chunk band. It includes the immediately adjacent upper band only when the next connection level crosses a chunk boundary, allowing a player stair above the destination level to remain visible. Player stairs encode one-level-lower visibility; generated terrain slopes encode their physical height and clip with the rest of the terrain. See ADR-011.

Interactive render-Y changes use a viewport-bounded readiness gate in `MainRenderLevelController`:

1. Build mesh targets from camera-visible chunk bounds plus safety margin through `MainRenderLevelTargetBuilder`.
2. Build generation targets for the mesh bands and neighbor bands.
3. Request chunk generation/load and mesh builds until those bounded targets are ready.
4. Build one Y-transition CSV row through `MainYTransitionProfiler` and log it through `DebugOverlay`.

Background warmup and directional prewarm are separate from the blocking reveal gate.

## Rendering And Mesh Cache

`WorldRenderer` is the public rendering facade used by `World`, `Main`, and `WorldStreaming`.

It currently owns:

- Chunk `MeshInstance3D` pooling through `ChunkCache`.
- Runtime mesh scheduling through `WorldRendererMeshScheduler`, which owns the job queue, result queue, prefetch records, and one dedicated mesh thread.
- Raw mesh-cache storage keyed by chunk coord and local top.
- Lazy `ArrayMesh` creation when a cached chunk becomes visible.
- Render-height rebuild queueing through `WorldRendererRenderLevel`, plus render-zone visibility.
- Block shader material and atlas setup through `WorldRendererMaterials`.
- Draw and mesh statistics through `WorldRendererStats`.
- Overlay forwarding and renderer/debug statistic composition.

Raw mesh-cache entries store packed arrays and metrics, not `ArrayMesh` resources. `WorldRendererMeshCache` centralizes raw mesh-cache entry construction, validation, export, import shaping, and lazy `ArrayMesh` construction. `WorldRendererMeshScheduler` centralizes async mesh job ownership; `WorldRendererRenderLevel` owns render-height rebuild queue ordering. `WorldRenderer` still builds job dictionaries and applies completed results to visible chunks. Persistent mesh cache saves those raw arrays with `store_var(..., false)` and validates them against world dimensions, chunk size, block table hash, mesher cache version, chunk block hash, and neighbor hashes.

## Save/Load Data

`WorldSaveLoad` orchestrates persistence, with metadata, bulk block data, physical item/stockpile state, and persistent mesh-cache file handling split into small helpers:

- `world_meta.dat`: seed, spawn, top render Y, world dimensions, chunk size, block table hash, save version. Handled by `WorldMetadataSaveLoad`. V5 adds separate terrain-slope IDs and migrates compatible V4 terrain ramps during load.
- `world_blocks.dat`: finite-world bulk chunk block data with fill/raw/ZSTD entries. Handled by `WorldBulkChunkSaveLoad`.
- `world_mesh_cache.dat`: optional raw mesh-cache acceleration data. Handled by `WorldMeshCacheSaveLoad`.
- `items_stockpiles.dat`: physical item stacks and stockpile zones. Handled by `WorldItemStockpileSaveLoad`.

Current save formats are not changed by housekeeping refactors unless explicitly planned.

## Gameplay Systems

`World` is the gameplay/system hub. It owns chunks, world bounds, block access, inventory, tasks, pathfinding, workers, generator, save/load, streaming, raycasting, and renderer references.

Workers pull tasks from `TaskQueue` through `TaskManager`, pathfind with `Pathfinder`, mutate blocks through `World`, and carry physical item stacks for hauling work. Assignment and haul-delivery searches run against immutable snapshots on the path thread.

Mining creates physical item stacks through `BlockDropTable` and `ItemStackStore`. Loose items are not usable inventory. Each stockpile cell stores one material with a base stack capacity of 16, and `world.inventory` is a derived compatibility view over those stored stacks.
Loose stacks use camera-facing cells from `assets/textures/fantasy_resource_icons_6x6_real_alpha.png`; materials without a mapped cell retain the colored-box fallback.

Haul-task reconstruction is dirty-driven: item and stockpile mutations request one coalesced rebuild. Completed tasks are removed from queue indexes immediately, so neither operation requires an unconditional full scan each frame.

Task accessibility is also dirty-driven. New or locally invalidated tasks enter a budgeted accessibility queue. Tasks remain unknown/green until a worker path bid succeeds, become reachable/blue after that proof, and become blocked/red after structural rejection or failed worker bids. Tasks without a work position wait for nearby terrain mutation; tasks rejected by all worker paths use individual 2.5-second retry deadlines managed by one timer.

Persistent task, item, and stockpile overlays have independent dirty flags. They synchronize after relevant state changes or render-level changes; assigned pulse animation remains shader-driven. Drag and hover previews remain input-driven.

Ordinary DIG work is horizontal-only: the worker and target block must share a Y level. Downward excavation requires the stairs workflow to establish controlled access to the next level.

Worker activity tracing is toggled with `F11`. `WorkerTrace` writes transition, block-level movement, and task-overlay color events to timestamped CSV files under `user://diagnostics`, including worker coordinates, task targets, path progress, logical overlay colors, and renderer visibility state.

## Refactor Pressure Points

The largest coupling hotspots are:

- `Main.gd`: menu actions, full-map session flows, and frame orchestration still share one file. Loading UI, HUD, render-level readiness, and Y-transition profiling are split into controllers/helpers with explicit public boundaries.
- `WorldRenderer`: render-zone visibility, overlays, and stat composition still share one class. Mesh-cache data contracts are split into `WorldRendererMeshCache`, runtime mesh queue/thread ownership is split into `WorldRendererMeshScheduler`, render-height queue ownership is split into `WorldRendererRenderLevel`, and material ownership is split into `WorldRendererMaterials`.
- `ChunkMesher`: greedy cube meshing, ramp meshing, and mesh resource fallback still share one class. Padded-buffer/index helpers, UV helpers, and color/noise/shading helpers are split into `ChunkMesherPaddedBuffer`, `ChunkMesherUv`, and `ChunkMesherVisuals`.
- `WorldSaveLoad`: legacy chunk files, block-table hashing, and migration checks still share one class. Metadata, bulk block data, inventory, and persistent mesh-cache file handling are split out.
- `DebugOverlay`: live HUD stats, CSV captures, timing logs, map exports, and ramp debug tools share one class.

Housekeeping should split these by responsibility while preserving the current external APIs and runtime behavior.
