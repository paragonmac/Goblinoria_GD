# ADR-010: Event-Driven Task Accessibility And Overlays

Status: Accepted
Date: 2026-07-05

## Context

Task accessibility previously rescanned queued tasks every 100 ms, and persistent task, item, and stockpile overlays synchronized every frame. The legacy `blocked_tasks` collection had no producer; real blocked state already lived on queued tasks.

## Decision

Queued tasks use explicit block reasons:

- `NO_WORK_POSITION`: no adjacent walkable work position exists. Retry only after localized terrain invalidation.
- `NO_WORKER_PATH`: all assignment candidates failed pathfinding. Retry at an individual 2.5-second deadline.

Accessibility checks use a deduplicated task-ID queue with an eight-task update budget. Terrain changes query the task queue's position index within the existing one-block radius. One timer wakes for the earliest worker-path retry deadline and stops when no timed retries remain.

Task status, accessibility, block reason, and assigned-worker properties emit visual-state changes. Persistent task, item, and stockpile overlays use separate dirty flags and synchronize only after relevant mutations. Render-level changes dirty all persistent overlay sections. Drag previews remain input-driven.

## Consequences

- Idle frames do not scan task collections for blocked-state expiry.
- Structurally blocked planned work remains red without periodic retries.
- Worker-path failures retain the established 2.5-second reroute behavior.
- Assigned pulse animation remains shader-driven without repeated CPU synchronization.
- Task state mutations must use notifying task properties or queue APIs.

## Guardrails

- Code pointer: `scripts/task_manager.gd`, `request_accessibility_check()` and path retry scheduling.
- Code pointer: `scripts/world.gd`, `request_overlay_refresh()`.
- Code pointer: `scripts/task_queue.gd`, task visual-state properties and position index.
- Contract: `tools/validate_worker_path_safety.gd`.
- Contract: `tools/validate_event_driven_worker_updates.gd`.
