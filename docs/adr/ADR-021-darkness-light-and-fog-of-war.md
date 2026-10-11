# ADR-021: Darkness, Light and Fog of War

Status: Accepted (implementation in phases)
Date: 2026-10-10

## Context

M0 scope change (user, 2026-10-10): the world gets darkness. Goblins carry a
5-block light, torches light about 15 blocks with Minecraft-style falloff, the
open sky lights the surface, and the player sees a fog of war with memory.
Design research (opus-researcher-2, probes on a generated 256^3 world, Godot
4.7.2) measured the options below.

## Decision

Player-facing rules:
- Light levels 0-15, falloff 1 per block, flooding through non-opaque cells
  only (around corners, never through walls). A torch is level 15 at its cell
  (last lit cell 14 blocks away, Minecraft-exact). A goblin is level 6 at its
  cell (lit out to 5 blocks). Displayed light is max(sky, block, goblin).
- Sky light: columns are 15 down to the first opaque block, then spill with
  falloff (shafts, cave mouths). Underground is dark.
- A cell becomes explored when any light (sky, torch, goblin) reaches it; its
  six neighbours too, so wall faces and slice caps show. The sunlit surface is
  explored at once; sealed caves stay black until lit.
- Rendering: unexplored = black (still drawn, so nothing behind shows through);
  explored but unlit = dim and desaturated; lit = full colour scaled by level.
- Unexplored cells cannot be inspected or designated, except excavation (Dig,
  Stairs), which tunnels blind into the dark; pathing is unaffected;
  darkness has no gameplay effect on goblins yet.
- Torches: a Torch tool designates a floor cell; a goblin places it as a job
  (free for now). Erase removes a torch instantly; losing its support removes
  it too.

Technical design:
- LightField (CPU): flat world-sized PackedByteArrays indexed
  (y * 256 + z) * 256 + x - a block mirror, light (sky low nibble, block light
  high nibble) and explored - so each Y layer is a contiguous slice. Minecraft
  add/remove BFS on the main thread, fed by a hook in World.set_block_raw and
  drained within a per-frame budget. Opacity comes from a table built in code
  (not a blocks.csv column, which would change the block-table hash and reject
  saves). Light is derived and recomputed on load; explored is saved.
- GPU: two Texture2DArray (256 layers of 256x256 R8: light, explored), one
  layer per world Y; only dirty layers are uploaded, within a per-frame layer
  budget, nearest the render level first. The terrain shader texelFetches the
  cell in front of each face (slice caps sample their own cell). No light is
  baked into meshes: no remesh, no mesh-cache change, greedy merging kept.
- Goblin light: a wall-aware BFS (radius 5) when a goblin changes cell, into a
  small per-goblin grid atlas plus a uniform array of goblin cells (up to 64
  nearby goblins); the shader takes the max with static light.
- Torches: an attachment store (like ItemStackStore), not a block type; new
  TaskType.TORCH appended to the enum; MultiMesh rendering.
- Save V10 introduced explored.dat and torches.dat; V11 stores torch mount
  facing. V9 saves default explored to sky-lit cells, air connected to workers,
  and pending task cells.

Rejected: per-vertex light bake (splits greedy quads, remeshes, breaks the
mesh cache, cannot carry goblin light); one ImageTexture3D (Godot 4.7 updates
replace the whole volume); analytic goblin falloff in the shader (light leaks
through 1-block walls and reveals hidden caves); torch as a block (block-table
hash, mesher, AIR checks).

## Phases

1. LightField core + world hook + light in cell details (validate_light_field).
2. GPU sync + terrain shader + F7 "Fog off" / "Light view".
3. Goblin light + explored marking.
4. Fog gating: selection, context menu, inspection, overlays (validate_fog_gating).
5. Torches: store, task, tool (key 8), rendering (validate_torch_task).
6. Save V10 + V9 migration.

## Guardrails

- tools/validate_light_field.gd: sealed room dark, shaft spill falls off by 1,
  light goes around corners not through walls, torch add then remove equals a
  full recompute, digging into a cave relights it.
- Later phases add validators as listed above.
