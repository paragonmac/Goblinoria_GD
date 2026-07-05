# ADR-005: Worker Task Assignment Policy

Status: Accepted
Date: 2026-07-05

## Context

Workers were claiming tasks in update order, which could send a far worker to a dig block while a closer worker was available. In tunnel-first dig selections, workers can also reach the work front at different times as newly dug blocks expose more jobs.

## Decision

Task assignment uses a path-length auction across currently available workers. A task is assigned only after pending worker bids finish; the shortest valid path wins, with worker ID as the deterministic tie-breaker.

If a worker reaches a work front where another worker owns a task but has not started working, task ownership may transfer to the arrived worker. If a worker is waiting on an invalid work position, it releases the task back to pending after a short retry interval so the changed world can be re-evaluated.

## Consequences

- Assignment can take longer than first-come-first-served because it waits for path bids.
- Path failures are tracked per worker so one worker's failed route does not globally block the task for every worker.
- Changing terrain can make a previously blocked task reachable, so unreachable state expires and localized terrain changes invalidate nearby tasks.

## Guardrails

- Code pointer: `scripts/task_manager.gd`, assignment auction and bid comparison.
- Code pointer: `scripts/worker.gd`, waiting repath and arrived-worker transfer paths.
- Contract: `tools/validate_worker_path_safety.gd` checks shortest-path bid rules, per-worker failure expiry, localized invalidation, and arrived-worker task transfer.
- Runtime trace: `assignment_auction_started`, `assignment_bid_queued`, `assignment_bid`, `assignment_bid_failed`, `task_worker_unreachable`, `task_transferred`, and `task_released_for_repath`.
