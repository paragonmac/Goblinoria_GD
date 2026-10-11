# ADR-022: Wider Finite World (512 x 512, Same Depth)

Status: Accepted (implementation in phases)
Date: 2026-10-11

## Context

The map is a finite 256 x 256 x 256 block world (World.CHUNK_SIZE 8,
WORLD_CHUNKS_X/Y/Z 32). The user asked for a wider world, same depth, finite
(no infinite world for now). Evidence:

- Code inventory (opus-researcher-3): most code already reads the size from
  World constants and WorldChunkSpace; save headers already store chunk
  counts but reject anything but 32. Hard-coded 256 assumptions sit in
  LightField indexing (&255, >>8, >>16), GoblinLight strides, the light
  Texture2DArray width and shader bounds, explored.dat (fixed 256^3 payload),
  and two validators. Streaming, camera, NavGrid, path snapshots and
  assignment radii are bounded by the view or local boxes, not the world.
- Measured spike (Luna-22, throwaway copy widened to 64 x 64 chunks):

  | Stage | 256^2 | 512^2 |
  |---|---|---|
  | Generation | 30.0 s | 119.5 s |
  | Arena merge + trees | 2.2 s | 8.6 s |
  | Full mesh pre-cook | 379 s | > 1,670 s (timed out at 30 min) |
  | Light build | 0.46 s | not reached |
  | Process memory (sampled) | ~0.97 GB peak | 1.65 GB at timeout, rising |
  | Save size | 98.7 MB (96.1 MB mesh cache) | not reached |

  70 of 75 validators passed at 512^2; the failures were size/version pins.

The full-map mesh pre-cook and the whole-map mesh cache, not the block
data, are what make a wider world impractical today.

## Decision

- The horizontal size becomes a world setting chosen at creation: 256 (default)
  or 512. Height stays 256. 1024 is a later, separate step (phase 5).
- The size is stored in the save (existing chunks_x/z header fields, read and
  adopted instead of rejected). Existing 256 saves load unchanged.
- World dimensions move from consts to static values set before any world or
  thread work starts (drained/epoch-guarded on world switch).
- At 512 the light, explored, display and mirror arrays stay flat (about
  256 MiB CPU, 128 MiB GPU for two R8 Texture2DArrays); indexing uses the
  world width; shaders get the width as a uniform instead of a literal 256.
- No full mesh pre-cook above 256: chunks mesh on demand through the existing
  streaming path, and the mesh cache becomes per-region files loaded on
  demand.
- Generation runs as region jobs (in parallel where passes only read their
  own columns; caves plan globally and apply per region), spawn first, the
  rest in the background.
- 512 is offered in the New World screen only once phase 3 meets its
  acceptance (new world playable in under 60 s).

Rejected: going region-sparse (1024-ready) storage first - puts the riskiest
work (region light BFS, GPU window) before any playable wider map; revisit if
flat 512 light is unacceptable (build > 3 s off-thread, RAM > 1.5 GB, or
upload hitches) or 1024 is committed to. Infinite world - out of scope.

## Phases

1. Dimension plumbing: static dims; metadata, bulk-chunk and mesh-cache
   headers adopt dims; LightField / GoblinLight width-based indexing; shader
   width uniform; explored.dat sized from dims; SAVE_VERSION 13 (V12
   readable); size-agnostic validators. Acceptance: full suite green at 256;
   existing 256 saves load identically; headless 512 create (blocks + light,
   no mesh pre-cook) -> save -> load round trip with measured RAM/time.
2. Whole-volume GDScript loops out of load/save (explored apply/validate via
   native PackedByteArray ops); light build off the main thread behind the
   loading screen. Acceptance: no light-work frame over 100 ms; 512 load
   measured.
3. On-demand meshing above 256 (no full pre-cook), region-parallel
   generation with spawn-first streaming and progress; New World size
   selector. Acceptance: 512 new world playable in under 60 s; generation
   output identical to the serial pipeline at 256 (hash).
4. Residency: mesh cache as on-demand region files; evict mesh nodes and
   ArrayMeshes outside the render zone plus margin; per-region tree
   MultiMeshes; bulk save without the full in-memory duplicate. Acceptance:
   RAM bounded after panning the whole 512 map; load does not read the whole
   cache.
5. (1024, later) depth-limited visibility, region-sparse LightField, GPU light
   window, uniform (fill-only) chunks, region explored.dat.

Independent of the phases (recommended anyway): depth-limited visibility
culling - every view currently considers all chunk layers down to y = 0
(World.DEPTH_VISIBILITY_LIMIT_ENABLED is false); a prerequisite for phase 5.

## Guardrails

- Every phase: full validator suite, an independent review, and existing 256
  saves (V12) still loading identically.
- 512 measurements use isolated user data (a separate project name), never the
  player's saves.
- Risks to watch: static-dimension races with worker threads on world switch;
  cave determinism across regions; GDScript BFS speed; GPU upload hitches for
  512-wide layers (256 KB each).
