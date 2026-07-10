# ADR-012: Worker Role Templates

Status: Accepted
Date: 2026-07-10

## Context

Workers previously shared one task pool, so every idle worker bid on every dig, build, stair, and haul task. Physical hauling now needs dedicated labor, while combat needs a readable reserve role before hostile entities and guard tasks are implemented.

## Decision

Workers retain one shared state machine, pathing implementation, safety behavior, and carry slot. `WorkerRoles` supplies role templates that define task eligibility:

- Miner: DIG, PLACE, and STAIRS.
- Hauler: HAUL.
- Fighter: no current task type; it remains at its reserve position until combat work exists.

Task assignment auctions include only workers whose role accepts the task. A structurally valid task with no eligible role becomes `NO_ELIGIBLE_WORKER`, distinct from a failed path search. Reassigning an idle worker role immediately requeues affected accessibility checks and auctions.

New worlds begin with two Miners, one Hauler, and one Fighter. Roles are persisted in `workers.dat` as worker-ID/role-ID records. V5 saves without that file receive the default roster; V4 terrain-slope migration remains supported.

## Consequences

- Mining and hauling throughput become player-visible labor-allocation decisions.
- Fighters are present and inspectable without manufacturing nonfunctional combat tasks.
- Roles are templates, not subclasses or permanent character classes. Skills, equipment, squads, and combat duties can extend this boundary later.
- Role changes are restricted to idle workers so active jobs are never silently invalidated.

## Guardrails

- Code pointer: `scripts/worker_roles.gd`.
- Code pointer: `scripts/worker.gd`, `can_accept_task()`.
- Code pointer: `scripts/task_manager.gd`, role-filtered auctions and `NO_ELIGIBLE_WORKER`.
- Code pointer: `scripts/main_worker_window_controller.gd`, idle-worker role selectors.
- Contract: `tools/validate_worker_roles.gd`.
