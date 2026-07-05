# ADR-003: Threaded Path Search Snapshots

Status: Accepted
Date: 2026-07-05

## Context

Path searches caused frame spikes when multiple workers evaluated queued dig jobs. Moving the search to a thread helps, but live `World` and chunk data cannot be read freely from a background thread because the main thread can mutate terrain, chunks, and render state.

## Decision

Background path searches run against immutable `PathWorldSnapshot` data captured on the main thread. The worker thread owns its private `Pathfinder`, reads only the snapshot, and returns path results plus timing/stat fields. The main thread accepts a result only if the captured chunk revisions still match.

The path scheduler currently uses one dedicated search thread. Algorithm changes can happen behind the scheduler boundary without changing task assignment callers.

## Consequences

- Snapshot capture cost still happens on the main thread and should stay visible in logs as `snapshot_ms`.
- Search cost moves off the main frame and is visible as `queue_wait_ms` and `search_ms`.
- Stale results are discarded when terrain changed under the snapshot.
- The snapshot margin controls how much area a search can see.

## Guardrails

- Code pointer: `scripts/pathfinding/path_search_scheduler.gd`.
- Code pointer: `scripts/pathfinding/path_world_snapshot.gd`.
- Contract: `tools/validate_worker_path_safety.gd` checks a threaded 60-block snapshot round trip.
- Runtime trace: `assignment_bid`, `assignment_bid_failed`, `assignment_bid_stale`, `assist_path_queued`, `assist_started`, and `assist_path_failed` include snapshot/search timing.
