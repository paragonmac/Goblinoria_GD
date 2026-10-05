# ADR-018: Two-cell Stair Flights

Status: Accepted
Date: 2026-09-06

## Decision

New player stairs occupy two consecutive horizontal cells, one cell wide, and
rise one level over that length. A lower and upper half encode the same cardinal
orientation. Existing single-cell player stairs and generated terrain slopes keep
their original identities and behavior; they are not automatically stretched.

The stair tools stamp one complete flight per release instead of filling a drag
rectangle with overlapping stairs. Up Stairs anchors the lower end above the
clicked floor. Down Stairs anchors the upper end in the clicked solid surface.
Mouse wheel up rotates clockwise by 90 degrees; wheel down reverses it. Rotation
is explicit rather than inferred from planned digging. This supersedes ADR-007's
automatic orientation and one-cell player-tool placement, not its legacy support.

The ghost uses the same two-half geometry as built stairs. Both halves share
placement validity; invalid ghosts remain visible in red. Preview reads existing
terrain only. GUI scrolling, popups and menus retain input ownership; the world
wheel rotates instead of zooming only while a stair tool is selected.

Valid downward ghosts use a temporary terrain-shader cutout of the two flight
cells and normal depth testing. Temporary neighboring faces reveal the excavation
walls and floor without mutating terrain, generating chunks, or remeshing caches.
Moving, rotating, cancelling, switching tools, or hiding the preview's slice
restores the terrain. Invalid ghosts remain red and visible through terrain,
without a cutout.

Queued flight designations reuse those exact half meshes and cell transforms,
including after assignment. Up/down designations use the same slice rules as
their corresponding ghosts. Downward designations retain visibility through
solid terrain until excavation; only the active valid ghost cuts terrain away.
Job-state color and pulse still follow ADR-004;
the generic assigned-box enlargement does not apply to flights. This prevents
the purple stamp and the later colored job marker from appearing offset even
when their stored cell coordinates agree.

One task owns the entire footprint. Placement validates both cells before changing
pending designations and revalidates before construction. Cancellation from either
half cancels that task. New jobs cannot claim the other half independently.
Pathfinding and live movement agree on the intermediate half-height connection,
low entry, high exit, headroom and invalidated connections. This is not two
independently climbable full-height ramps.

Normal mining uses a shared work-reach rule rather than a movement-into-target
test. A worker on the lower half may mine a solid cell adjoining the low end on
the same logical level, despite its fractional standing height. This does not
open stair side/high faces or allow ordinary vertical digging. Assignment,
accessibility, previews and live work validation must agree on these positions.

Dig preserves player stairs (including legacy stairs) and their immediate
support blocks. Natural terrain slopes remain diggable. Right-clicking either
half and choosing Remove stairs queues a worker job for the whole flight;
Erase cancels that pending job. Dismantling rechecks the captured footprint and
defers while a worker occupies or crosses it. Both halves are removed together
through ordinary terrain invalidation, without material refunds. Orphaned
halves and legacy single-cell stairs can also be removed explicitly.

## Persistence and limits

V8 adds the new block identities. V4-V7 saves remain readable through explicit
compatibility handling; old stairs retain their original geometry. Mesh caches
are versioned separately. Unfinished jobs still reset on load; this change does
not add colony-session continuation or a material-delivery construction system.

## Guardrails

- Shared StairFlight geometry, placement and traversal rules.
- validate_stair_flight, validate_stair_rendering and validate_stair_input.
- validate_stair_mining_reach and validate_stair_removal cover mining from the
  low endpoint, protected stairs/supports and explicit worker dismantling.
- validate_stair_workflow reconstructs the stair-front F1 terrain and checks a
  real worker descending, mining two blocks and dismantling the stairs through
  threaded assignment and the canonical world update path.
- validate_stair_overlay_alignment compares ghost/designation geometry, transforms,
  depth and slice rules across orientations and task states.
- validate_stair_excavation_preview covers the temporary cutout, neighboring
  faces, rotation, invalid placements, cleanup, shader modes, and unchanged terrain.
- Existing worker-path, save/load, rendering, selection and context-menu validators.
- Graphical acceptance requires separate approval: four orientations, upward and
  downward placement, level cuts, worker traversal and GUI wheel ownership.
