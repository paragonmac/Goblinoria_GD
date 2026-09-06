# Chunked World Storage Plan

This is the working plan for chunked storage, streaming, and persistence.

Reading guide (2026-09-05): this mixes historical implementation steps with future proposals. [Current Architecture](current_architecture.md) and source constants describe the running prototype; [Prototype Checkpoint](prototype_checkpoint.md) distinguishes implementation from validation. The historical defaults at the end are not active configuration.

Active follow-up work is tracked in GitHub Issues. Historical completed checklist items remain here for context; open work is linked to issues instead of tracked as local TODO checkboxes.

## Goals
- Finite chunked resident storage; full-map generation temporarily uses a full-world volume before baking chunks.
- Deterministic on-demand generation (seed + coord).
- Versioned save/load with explicit mismatch detection.
- Streaming with load priorities for the current finite resident world.
- Render meshes tied to loaded chunk state.

## Constraints / Notes
- Block ID is the master key (u8).
- Block properties are lookup-table driven (CSV -> registry).
- Old save formats must be detectable (no silent corruption).
- Cube blocks use greedy meshing; ramp/stair blocks still use the face-by-face mesher.
- Renderer debug stats track emitted vertices/triangles, greedy source-vs-emitted faces, ramp faces, mesh cache hits/misses/imports, and build/upload time before higher-risk rendering changes.
- Render-level transitions write `user://diagnostics/y_transition_profile_*.csv` rows so blocked Y changes can be diagnosed before choosing a vertical prewarm strategy.
- Render-level reveal readiness is viewport-bounded to the visible view plus a 1-chunk X/Z margin; directional Y prewarm handles the broader buffered bounds in the background.
- Current scope is a finite 32x32x32 chunk world centered on origin; signed chunk coords and negative-safe coordinate math are still required for the negative half of the map.
- Hard invisible bounds prevent generation, selection, pathing, camera movement, and streaming outside the finite X/Z rectangle.
- The title-screen/menu checkbox `Generate and cache full map` controls `Main.generate_full_map_on_startup`: off keeps startup to the limited streamed view, while on runs the arena cooker to generate every finite chunk and raw full-chunk mesh cache before reveal. Layered block generation uses one background task; mesh-cache builds run in parallel.

## Phase 0: Coord Math Fixes
- [x] Add `floor_div()` and `positive_mod()` helpers for negative-safe chunk math.
- [x] Replace `%` and clamp-based chunk coord math with helpers in world and streaming code.

## Milestone 1: Chunked In-Memory Storage
- [x] Define chunk size constant (currently 8; fixed per world).
- [x] Create `Chunk` data: `data: PackedByteArray`, `dirty`, `last_access_tick`, `mesh_state`.
- [x] Implement `world_to_chunk_coords()` and `chunk_to_local_coords()`.
- [x] Replace flat `blocks` with `Dictionary<Vector3i, Chunk>`.
- [x] Update `get_block()` and `set_block()` to route through chunks.
- [x] Update call sites (pathfinder, renderer, raycast, workers).

## Milestone 2: Deterministic On-Demand Generation
- [x] Use seeded generator only from `(seed, chunk_coord)`.
- [x] `generate_chunk(chunk_coord)` fills chunk data.
- [x] Hook chunk access: generate if missing.
- [x] Test: same coord always generates identical blocks.
- [x] Verify terrain/noise works with negative coords.
- [x] Remove `seed_all_chunks()` full-world generation.

## Milestone 3: Chunk Serialization + Version Header
- [x] World meta file `world_meta.dat`:
  - `seed:u64`, `spawn_coord:Vector3i`, `top_render_y:i32`, `block_table_hash:u32`, `save_version:u16`.
- [x] Chunk header: `magic:u32`, `version:u16`, `chunk_size:u16`, `coord x/y/z i32`,
  `data_len:u32`, `compression:u8`, `block_table_hash:u32`.
- [x] Data payload: blocks as `u8` (compressed or raw).
- [x] Implement `serialize_chunk()` / `deserialize_chunk()` with version checks.
- Tracked in [#6](https://github.com/paragonmac/Goblinoria_GD/issues/6): Add migration stub (future).
- [x] Bulk save compression: `world_blocks.dat` v2 stores fill chunks, raw chunks, or ZSTD-compressed chunks and still reads the previous raw bulk layout.

## Milestone 4: Disk-Backed Cache
- [x] File path scheme: `user://saves/<world_id>/chunks/x_y_z.chunk`.
- [x] Track dirty flag per chunk.
- [x] Implement `save_chunk()` (only if dirty).
- [x] Implement `load_chunk()` (read from disk or generate).
- Tracked in [#4](https://github.com/paragonmac/Goblinoria_GD/issues/4): Add explicit destructive chunk handling if gameplay needs whole-chunk removal, such as explosions.
- Tracked in [#7](https://github.com/paragonmac/Goblinoria_GD/issues/7): Decide whether runtime cache eviction is needed for worlds larger than the current finite map.

## Milestone 5: Load/Stream Scheduling (Priority Queue)
- [x] Chunk load queue with priority by distance to camera target (center-spiral order).
- [x] Process N loads per frame (configurable).
- [x] Prioritize render zone loads before buffer zone loads.
- Tracked in [#8](https://github.com/paragonmac/Goblinoria_GD/issues/8): Prevent starvation (age bump).
- [x] Cancel queued loads for chunks that leave range (queue reset on range change).
- [x] Clamp X/Z streaming and world access to the finite 32x32 chunk map scope.
- [x] Add a user-settable startup flag to choose limited streaming or whole finite-map generation.

## Zone Configuration
- [x] Define constants: render radius and buffer (base/max).
- [x] Render zone: actively drawn chunks.
- [x] Buffer zone: meshed and cached, but `visible = false`.
- Tracked in [#7](https://github.com/paragonmac/Goblinoria_GD/issues/7): Decide whether runtime cache eviction is needed for worlds larger than the current finite map.
- [x] View-scaled buffer expansion for stream/render bounds.
- [x] Render visibility retains cave surfaces from the selected level down to the world's minimum render Y, plus the adjacent upper connection band when required for player stairs. Readiness uses per-band camera footprints and generation-neighbor halos; see `current_architecture.md` and ADR-011. Cave GPU appearance and the increased visible-depth cost still need graphical validation.
- [x] Y-level reveal gate prepares only the camera-visible bounds plus a 1-chunk X/Z safety margin.
- [x] Directional Y prewarm queues the next chunk-height ahead using broader buffered render bounds.
- [x] New-world full-map mode uses the arena cooker: serial layered generation on one background task, parallel raw mesh-cache builds, frame-budgeted merge, and a diagnostics CSV under `user://diagnostics`.
- Tracked in [#9](https://github.com/paragonmac/Goblinoria_GD/issues/9): Tighten the blocking Y-level reveal gate to the actual visible chunk set, targeting roughly 100 chunks at max zoom instead of the current axis-aligned camera rectangle.

## Milestone 6: Render Streaming Tied to Chunk State
- [x] Mesh state per chunk: `NONE | PENDING | READY`.
- [x] Only mesh when chunk is loaded + in stream range (render + buffer).
- Tracked in [#10](https://github.com/paragonmac/Goblinoria_GD/issues/10): Clear mesh when chunks are explicitly destroyed or reloaded.
- [x] Rebuild neighbor meshes when block edits hit chunk edges.
- [x] Track missing neighbor data when meshing and remesh affected chunks when those neighbors load.
- [x] Track neighbor-triggered remesh in `pending_neighbor_remesh: Dictionary`.
- Tracked in [#10](https://github.com/paragonmac/Goblinoria_GD/issues/10): Decide whether to delay visible meshing until all valid neighbors are loaded, or keep current quick mesh + refresh behavior.

## Milestone 7: Compression (Per Chunk)
- [x] Use Godot ZSTD compression for normal bulk chunk payloads when it beats raw storage.
- [x] Store per-entry kind/compression flags in the bulk block file.
- Tracked in [#11](https://github.com/paragonmac/Goblinoria_GD/issues/11): Benchmark CPU vs disk savings.

## Milestone 8: Async IO
- Tracked in [#12](https://github.com/paragonmac/Goblinoria_GD/issues/12): Background thread for load/save.
- [x] Thread-safe request queue.
- [x] Main-thread handoff for chunk data.
- [x] Placeholder state for in-flight chunks.

## Milestone 9: Region Files (Optional)
- Tracked in [#13](https://github.com/paragonmac/Goblinoria_GD/issues/13): Decide region layout: 2D (x/z) + vertical slabs or full 3D cubes.
- Tracked in [#13](https://github.com/paragonmac/Goblinoria_GD/issues/13): Define region header + offset table.
- Tracked in [#13](https://github.com/paragonmac/Goblinoria_GD/issues/13): Implement read/write + compaction strategy.

## Milestone 10: Async Meshing (Optional)
- [x] Snapshot chunk + neighbor data (thread-safe).
- [x] Mesh in worker thread, apply mesh on main thread.
- [x] Invalidate if chunk changes during mesh.
- [x] Build mesh jobs from a padded chunk-plus-border block buffer.
- [x] Greedy mesh normal cube blocks first; keep ramp/stair blocks on the existing face path.
- [x] Preserve per-block atlas tiling on greedy quads through shader-side repeat UV decoding.
- [x] Expose mesh geometry and cache metrics through the debug streaming HUD and CSV capture.
- [x] Store mesh cache as raw packed arrays and create `ArrayMesh` lazily only when a chunk becomes visible.

## Milestone 11: Higher-Risk Rendering Optimizations
- Tracked in [#14](https://github.com/paragonmac/Goblinoria_GD/issues/14): Use debug metrics to decide whether packed custom vertex data is worth the shader complexity.
- [x] Add bounded chunk `MeshInstance3D` pooling to reduce allocation/free churn during streaming.
- Tracked in [#14](https://github.com/paragonmac/Goblinoria_GD/issues/14): Use debug metrics and chunk node pool stats to decide whether SceneTree chunk instance overhead justifies a RenderingServer migration.
- Tracked in [#14](https://github.com/paragonmac/Goblinoria_GD/issues/14): Keep current ArrayMesh output path until vertex count, triangle count, upload time, or node overhead is measured as the next bottleneck.

## Future Scale Decisions (Not Current Configuration)
- Revisit chunk size only with explicit save-version implications (current: 8).
- Revisit world size beyond the current 256^3 blocks / 32x32x32 chunks only with an explicit scale decision.
- Render radius + sim radius.
- Memory budget limits for loaded chunks.
- Block table hash strategy (CRC32 of CSV).
- Spawn anchor format and migration rules.

## Historical Suggested Defaults (Not Applied)

These earlier tuning proposals are retained as background, not instructions to change the current world or introduce cache eviction. In particular, the active chunk size is 8, not the proposed 16 below. Larger-world cache policy remains tracked in issue #7.

- Chunk size: 16 (balances mesh granularity vs overhead).
- Zone radii: `RENDER_RADIUS = 8`, `BUFFER_RADIUS = 10` (chunks).
- Memory budget: soft cap 2000 chunks, hard cap 2500 chunks.
