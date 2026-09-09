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

Queued flight designations reuse those exact half meshes and cell transforms,
including after assignment. Up/down designations use the same slice and depth
rules as their corresponding ghosts (downward excavation remains visible through
the existing solid terrain). Job-state color and pulse still follow ADR-004;
the generic assigned-box enlargement does not apply to flights. This prevents
the purple stamp and the later colored job marker from appearing offset even
when their stored cell coordinates agree.

One task owns the entire footprint. Placement validates both cells before changing
pending designations and revalidates before construction. Cancellation from either
half cancels that task. New jobs cannot claim the other half independently.
Pathfinding and live movement agree on the intermediate half-height connection,
low entry, high exit, headroom and invalidated connections. This is not two
independently climbable full-height ramps.

## Persistence and limits

V8 adds the new block identities. V4-V7 saves remain readable through explicit
compatibility handling; old stairs retain their original geometry. Mesh caches
are versioned separately. Unfinished jobs still reset on load; this change does
not add colony-session continuation or a material-delivery construction system.

## Guardrails

- Shared StairFlight geometry, placement and traversal rules.
- validate_stair_flight, validate_stair_rendering and validate_stair_input.
- validate_stair_overlay_alignment compares ghost/designation geometry, transforms,
  depth and slice rules across orientations and task states.
- Existing worker-path, save/load, rendering, selection and context-menu validators.
- Graphical acceptance requires separate approval: four orientations, upward and
  downward placement, level cuts, worker traversal and GUI wheel ownership.
