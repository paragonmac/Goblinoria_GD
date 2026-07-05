# ADR-007: Up And Down Stairs Access

Status: Accepted
Date: 2026-07-05

## Context

Normal dig work is horizontal-only, so downward excavation needs an explicit access designation. Players should be able to plan blocked dig zones first, then add a stair/ramp designation that opens same-level access to those planned blocks. Players also need to build upward ramps on top of existing solid support, so stair placement cannot only mean "replace this solid block."

## Decision

`UP_STAIRS` and `DOWN_STAIRS` player modes both create `STAIRS` task designations, and those tasks create ramp blocks. The task type stays shared because worker execution is the same: travel to the target, then place the chosen ramp material.

`UP_STAIRS` targets the empty, supported cell above the clicked block. It is only valid when the target cell is empty and `World.can_place_stairs_at()` accepts it. This keeps upward ramp construction aligned with normal "place on top" behavior.

`DOWN_STAIRS` targets the clicked solid block. A down-stairs designation may replace a pending `DIG` designation on the same block, because the player is converting that planned cell into the access point. It must not silently stack with the pending dig task on the same block.

Ramp orientation is selected from the planned lower-side dig context when possible: prefer an adjacent planned `DIG` cell on the low side and a walkable upper-side cell opposite it. If no planned lower-side context exists, choose any walkable upper-side connection and fall back to the default north ramp only when needed.

## Consequences

- Players can draw a room first, then mark one cell as stairs to open access.
- Players can build stairs upward by clicking the supporting block below the desired ramp cell.
- The player chooses up or down intent explicitly instead of relying on context-sensitive stair targeting.
- The stair cell becomes access infrastructure instead of also being mined as a normal dig task.
- The resulting ramp should connect workers from the current upper level into same-level work positions for planned lower-level digs.

## Guardrails

- Code pointer: `scripts/main_selection_controller.gd`, `_stair_material_for()`.
- Code pointer: `scripts/main_selection_controller.gd`, `_up_stair_target_from_hit()` and `_down_stair_target_from_hit()`.
- Code pointer: `scripts/task_manager.gd`, `queue_task_request()`.
- Contract: `tools/validate_worker_path_safety.gd` checks pending dig replacement when stairs are queued, and checks that stairs can be placed in an empty cell above solid support.
