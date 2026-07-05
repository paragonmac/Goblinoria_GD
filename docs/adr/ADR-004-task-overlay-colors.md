# ADR-004: Task Overlay Colors

Status: Accepted
Date: 2026-07-05

## Context

The player needs quick visual feedback for selected work: whether it is queued, reachable, blocked, or actively assigned to a worker. Earlier overlay behavior made colors disappear or change in ways that hid task state when a worker accepted a job.

## Decision

Task overlays use logical colors:

- Green: queued but accessibility is still unknown.
- Blue: queued and currently pathable/reachable.
- Red: queued but currently blocked/unreachable.
- Amber: assigned to a worker and that worker is moving toward or working the task.

The overlay is a world-space block overlay, not a screen-space selection rectangle. It should stay aligned to block coordinates and current render level.

## Consequences

- Assignment no longer removes task visibility; it changes the task to an assigned visual state.
- Blocked/reachable state may change as the world changes.
- Alpha and pulse are visual tuning, but the logical color meanings should stay stable.

## Guardrails

- Code pointer: `scripts/rendering/overlay_renderer.gd`, `TaskOverlayState`, `task_state_color()`, and `task_state_name()`.
- Runtime trace: `block_color_changed` and `block_color_removed` log logical color state, RGBA, task status, accessibility, assigned worker, visibility, scale, and render level.
