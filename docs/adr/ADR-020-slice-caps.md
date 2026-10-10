# ADR-020: Slice Caps Instead of Baked Cut Floors

Status: Accepted
Date: 2026-10-10

## Context

The render level is a shader slice: faces above `top_render_y` are discarded and
covered top faces ("cut faces", hatched) show the inside of the ground at the
level. The mesher baked a cut face into every covered block layer so any level
would work without remeshing. Measured at spawn (4x4 chunk column, 464 chunks):
3,723 of 4,129 quads (90%) were hidden cut sheets, every buried chunk had a mesh
and a draw call (F7: 3,400 chunks shown, 5,000 draws), and the shader's
`discard` disables early depth rejection, so the stacked sheets also cost fill.

## Decision

Chunk meshes contain only exposed faces. The cut floor is a per-level slice cap:
a child `SliceCap` MeshInstance3D of each chunk node in the render level's chunk
layer, holding the covered tops of that single block layer (greedy-merged per
material, same encoding and material as chunk meshes). On a level change caps
are rebuilt for the render zone's columns only (under 1 ms for 16 columns; a
full 32x32 layer would be ~45 ms); columns entering the zone as the camera
moves are filled in once per level, and one column is rebuilt when its slice
chunk or the chunk above is remeshed (all mesh apply paths share
`_after_chunk_mesh_applied`). A chunk with only a cap counts as visible; pooled
chunk nodes drop their cap. Ramps keep their own covered-top faces.

Mesher cache version 10. Version 9 caches are migrated on load by stripping the
baked cut tops (`ChunkMesher.strip_legacy_cut_faces`), both when entries are
imported and when never-imported entries are written to a new save, so no
remesh is needed and no v10 file carries cut sheets. The void meter and the
anomaly watchdog count cap-only chunks as having geometry.

## Consequences

The spawn column drops to 406 quads (-90%) and 32 meshed chunks; buried chunks
are empty and draw nothing. A level change now does main-thread cap work. Walls
are still one block tall because the slice test uses the per-row `UV2.x`.

## Guardrails

- `tools/validate_slice_caps.gd`: caps only at the level, rebuild on level change and remesh, cap-only visibility, pooling.
- `tools/validate_cave_shader_visibility.gd` and `tools/validate_rendering_contract.gd`: chunk meshes carry no cut tops, cap encoding, v9 migration.
