# ADR-001: Worker Digging Level Rules

Status: Accepted
Date: 2026-07-05

## Context

Normal dig jobs were allowing workers to interact with blocks above or below their current work plane. That made workers appear to dig through floors, ramps, or vertical faces that should require controlled access first.

## Decision

Ordinary `DIG` and `PLACE` work positions must be on the target block's horizontal level. A worker may move between levels by valid ramps or later stair systems, but the actual work interaction for normal dig/place tasks stays same-level and cardinal-adjacent.

Downward excavation is a separate access problem. It should be handled by stairs, ramps, or future planned vertical access workflows, not by letting a normal dig task reach vertically.

## Consequences

- A selected block can stay queued but blocked until there is a same-level adjacent work position.
- Workers can path over ramps to reach another level, then work blocks on that level.
- This can make large dig selections open gradually as tunnels expose same-level work positions.

## Guardrails

- Code pointer: `scripts/worker.gd`, `_can_work_task_from_coord()` and `_work_level_for_task()`.
- Contract: `tools/validate_worker_path_safety.gd` checks horizontal dig work and horizontal dig paths.
- Runtime trace: `task_waiting`, `task_released_for_repath`, `assignment_bid_failed`, and `task_completed` reveal when a task cannot be worked from the current level.
