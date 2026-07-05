# ADR-007: Stairs Downward Access

Status: Accepted
Date: 2026-07-05

## Context

Normal dig work is horizontal-only, so downward excavation needs an explicit access designation. Players should be able to plan blocked dig zones first, then add a stair/ramp designation that opens same-level access to those planned blocks. Players also need to build upward ramps on top of existing solid support, so stair placement cannot only mean "replace this solid block."

## Decision

`STAIRS` designations create ramp blocks. A stair designation may replace a pending `DIG` designation on the same block, because the player is converting that planned cell into the access point. It must not silently stack with the pending dig task on the same block.

When the player clicks an ordinary solid block in stairs mode and the cell above it is empty, supported, and stair-placeable, the designation targets the cell above the clicked block. This keeps upward ramp construction aligned with normal "place on top" behavior. If the clicked solid block already has a pending `DIG` designation, stairs mode targets the clicked cell instead so the planned dig can be converted into downward access.

Ramp orientation is selected from the planned lower-side dig context when possible: prefer an adjacent planned `DIG` cell on the low side and a walkable upper-side cell opposite it. If no planned lower-side context exists, choose any walkable upper-side connection and fall back to the default north ramp only when needed.

## Consequences

- Players can draw a room first, then mark one cell as stairs to open access.
- Players can build stairs upward by clicking the supporting block below the desired ramp cell.
- The stair cell becomes access infrastructure instead of also being mined as a normal dig task.
- The resulting ramp should connect workers from the current upper level into same-level work positions for planned lower-level digs.

## Guardrails

- Code pointer: `scripts/main_selection_controller.gd`, `_stair_material_for()`.
- Code pointer: `scripts/main_selection_controller.gd`, `_stair_target_from_hit()`.
- Code pointer: `scripts/task_manager.gd`, `queue_task_request()`.
- Contract: `tools/validate_worker_path_safety.gd` checks pending dig replacement when stairs are queued, and checks that stairs can be placed in an empty cell above solid support.
