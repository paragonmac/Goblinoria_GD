# ADR-005: Worker Task Assignment Policy

Status: Accepted
Date: 2026-07-05

## Context

Workers were claiming tasks in update order, which could send a far worker to a dig block while a closer worker was available. In tunnel-first dig selections, workers can also reach the work front at different times as newly dug blocks expose more jobs.

## Decision

Task assignment uses a path-length auction across currently available workers. A task is assigned only after pending worker bids finish; the shortest valid path wins, with worker ID as the deterministic tie-breaker.

ADR-017 extends this policy with per-worker work priorities. Each worker prefers
reachable priority 1 work before 2, and so on; Off disables future claims. Equal
priorities retain cheapest-path selection and deterministic identity tie-breaking.
Edits invalidate pending decisions but never interrupt the current owned job.

Amended 2026-10-05 (responsiveness): a priority round auctions at most 24 tasks
before committing the best choices found; the next round continues from where it
stopped, so every task is still visited over successive rounds. Tasks examined
in a round are not rescanned after membership changes, winner reduction covers
all workers in one frame and commits on the next, and repeated no-path blocks
back off (2.5 s doubling to 60 s, reset by nearby terrain changes or a
successful bid). Workers on the same cell share one failed search per auction.
Choices are therefore best among recently scanned tasks rather than globally
optimal; full rounds over every pending task left workers idle for minutes with
~70 tasks and steady haul churn.

Amended 2026-10-10 (scaling): with 36 workers and digs four levels below the
surface, assignment stopped entirely. Bid searches had a budget proportional to
straight-line distance (216 iterations for a worker above a stair detour), a
capped search marked the worker unreachable, and bids ran one per frame. Now:
a capped search is inconclusive and never excludes a worker; candidates within
64 blocks (24 levels) of a task share one job that builds a navigation grid
(`scripts/pathfinding/nav_grid.gd`) over one snapshot and runs one reverse
search from the task's work positions, giving exact shortest path lengths for
all of them (farther workers keep per-worker searches); "no path" is conclusive
only when that flood never reached the snapshot edge. Each round keeps every
bid it collects and commits a greedy matching ordered by worker priority, path
length, worker ID and task ID, instead of one claim per round, since workers
that all nominate the same nearest task otherwise get one assignment per round.

If a worker reaches a work front where another worker owns a task but has not started working, task ownership may transfer to the arrived worker. If a worker is waiting on an invalid work position, it releases the task back to pending after a short retry interval so the changed world can be re-evaluated.

## Consequences

- Assignment can take longer than first-come-first-served because it waits for path bids.
- Path failures are tracked per worker so one worker's failed route does not globally block the task for every worker.
- Changing terrain can make a previously blocked task reachable, so unreachable state expires and localized terrain changes invalidate nearby tasks.

## Guardrails

- Code pointer: `scripts/task_manager.gd`, assignment auction and bid comparison.
- Code pointer: `scripts/worker.gd`, waiting repath and arrived-worker transfer paths.
- Contract: `tools/validate_assignment_depth_scaling.gd` (36 surface workers, digs four levels down behind stair flights: all assigned within 600 steps, no exclusion from inconclusive searches, sealed dig still blocked) and `tools/validate_nav_grid.gd` (grid edges equal `Pathfinder.get_neighbors`, reverse distances equal uncapped forward search).
- Contract: `tools/validate_worker_path_safety.gd` checks shortest-path bid rules, per-worker failure expiry, localized invalidation, and arrived-worker task transfer.
- Runtime trace: `assignment_auction_started`, `assignment_bid_queued`, `assignment_bid`, `assignment_bid_failed`, `task_worker_unreachable`, `task_transferred`, and `task_released_for_repath`.
