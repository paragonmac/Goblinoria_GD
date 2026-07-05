# ADR-002: Ramp Pathing Rules

Status: Accepted
Date: 2026-07-05

## Context

Workers previously moved through ramp geometry or fell while crossing valid ramp segments. The root issue was that ramps were treated too much like ordinary non-blocking blocks instead of directional walk surfaces.

## Decision

Ramp traversal is directional. Same-level movement may enter or leave only through a ramp's low edge. Level changes require the high edge of the ramp to line up with the movement direction. Workers standing on an interpolated segment are allowed to continue if the committed path segment is still valid.

Ramps are not generic empty air and they are not generic solid cubes for worker movement. They are special walk surfaces with directional edge rules.

## Consequences

- Workers should not pass through the high face of a ramp.
- Workers should be able to climb or descend ramps when the approach direction is legal.
- Mid-segment movement is validated at path-node boundaries, not every frame, so workers do not fall while visually interpolating across a valid segment.

## Guardrails

- Code pointer: `scripts/pathfinder.gd`, `can_move_same_level()`, `can_change_level()`, and ramp edge helpers.
- Code pointer: `scripts/worker.gd`, `_has_supported_path_segment()` and `_validate_next_path_node()`.
- Contract: `tools/validate_worker_path_safety.gd` checks directional ramp traversal, blocked ramp faces, legal ramp descent interpolation, and same-level ramp support.
