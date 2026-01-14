# Chunked World Storage Plan

This is the working plan for chunked storage, streaming, and persistence.

## Goals
- Chunked in-memory storage (no full-world array).
- Deterministic on-demand generation (seed + coord).
- Versioned save/load with explicit mismatch detection.
- Streaming with load priorities and unload policy.
- Render meshes tied to loaded chunk state.

## Constraints / Notes
- Block ID is the master key (u8).
- Block properties are lookup-table driven (CSV -> registry).
- Old save formats must be detectable (no silent corruption).
- No greedy meshing for now.

## Milestone 1: Chunked In-Memory Storage
- [x] Define chunk size constant (currently 8; fixed per world).
- [ ] Create `Chunk` data: `data: PackedByteArray`, `dirty`, `last_access_tick`, `mesh_state` (missing `mesh_state`).
- [x] Implement `world_to_chunk_coords()` and `chunk_to_local_coords()`.
- [x] Replace flat `blocks` with `Dictionary<Vector3i, Chunk>`.
- [x] Update `get_block()` and `set_block()` to route through chunks.
- [x] Update call sites (pathfinder, renderer, raycast, workers).

## Milestone 2: Deterministic On-Demand Generation
- [x] Use seeded generator only from `(seed, chunk_coord)`.
- [x] `generate_chunk(chunk_coord)` fills chunk data.
- [x] Hook chunk access: generate if missing.
- [ ] Test: same coord always generates identical blocks.

## Milestone 3: Chunk Serialization + Version Header
- [ ] Chunk header: `magic:u32`, `version:u16`, `chunk_size:u16`, `coord x/y/z i32`,
  `data_len:u32`, `compression:u8`, `block_table_hash:u32`.
- [ ] Data payload: blocks as `u8` (compressed or raw).
- [ ] Implement `serialize_chunk()` / `deserialize_chunk()` with version checks.
- [ ] Add migration stub (future).

## Milestone 4: Disk-Backed Cache (Save on Unload)
- [ ] File path scheme: `user://saves/<world_id>/chunks/x_y_z.chunk`.
- [ ] Track dirty flag per chunk.
- [ ] Implement `save_chunk()` (only if dirty).
- [ ] Implement `load_chunk()` (read from disk or generate).
- [ ] Implement `unload_chunk()` (save + free memory).
- [ ] Unload policy: memory budget + LRU (not distance only).
- [ ] Add periodic unload sweep (frame budget).

## Milestone 5: Load/Stream Scheduling (Priority Queue)
- [x] Chunk load queue with priority by distance to camera target (center-spiral order).
- [x] Process N loads per frame (configurable).
- [ ] Prevent starvation (age bump).
- [x] Cancel queued loads for chunks that leave range (queue reset on range change).

## Milestone 6: Render Streaming Tied to Chunk State
- [ ] Mesh state per chunk: `NONE | PENDING | READY`.
- [x] Only mesh when chunk is loaded + in render range.
- [ ] Clear mesh on unload.
- [ ] Require neighbor data before meshing to avoid seams.

## Milestone 7: Compression (Per Chunk)
- [ ] Use Godot compression or LZ4.
- [ ] Store compression flag in header.
- [ ] Benchmark CPU vs disk savings.

## Milestone 8: Async IO
- [ ] Background thread for load/save.
- [ ] Thread-safe request queue.
- [ ] Main-thread handoff for chunk data.
- [ ] Placeholder state for in-flight chunks.

## Milestone 9: Region Files (Optional)
- [ ] Decide region layout: 2D (x/z) + vertical slabs or full 3D cubes.
- [ ] Define region header + offset table.
- [ ] Implement read/write + compaction strategy.

## Milestone 10: Async Meshing (Optional)
- [ ] Snapshot chunk + neighbor data (thread-safe).
- [ ] Mesh in worker thread, apply mesh on main thread.
- [ ] Invalidate if chunk changes during mesh.

## Open Decisions
- Chunk size (current: 8).
- World size (256^3 vs 512^3 for current build).
- Render radius + sim radius.
- Memory budget limits for loaded chunks.
- Block table hash strategy (CRC32 of CSV).
