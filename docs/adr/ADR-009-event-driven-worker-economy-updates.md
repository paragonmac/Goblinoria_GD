# ADR-009: Event-Driven Worker Economy Updates

Status: Accepted
Date: 2026-07-05

## Context

Haul-task reconstruction, completed-task cleanup, and HUD text rebuilding ran every frame. Their cost scaled with tasks, loose items, stockpile cells, or UI strings even when no relevant state changed.

## Decision

Item and stockpile mutations request a coalesced haul rebuild. The normal frame update performs only an O(1) dirty check when no rebuild is pending.

`TaskQueue.complete_task()` marks a task complete and immediately removes it from all queue indexes. Production code must not leave completed tasks for later polling cleanup.

HUD status, inventory, and stockpile sections refresh through coalesced state-change signals. Generation status uses a 250 ms timer. The worker window uses a 200 ms timer that runs only while the window is open.

## Consequences

- Idle frames do not scan items, stockpile cells, or tasks to reconstruct hauling work.
- Completed tasks disappear from queue lookups in the same operation that completes them.
- HUD update latency is at most one deferred frame; timer-driven diagnostics have bounded 200-250 ms latency.
- Store mutation APIs and task completion APIs are required so change notifications are not bypassed.

## Guardrails

- Code pointer: `scripts/task_manager.gd`, `request_haul_rebuild()`.
- Code pointer: `scripts/task_queue.gd`, `complete_task()`.
- Code pointer: `scripts/Main.gd`, `request_hud_refresh()`.
- Contract: `tools/validate_stockpile_hauling.gd`.
- Contract: `tools/validate_event_driven_worker_updates.gd`.
