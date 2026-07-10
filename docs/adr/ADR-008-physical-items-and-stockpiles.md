# ADR-008: Physical Items And Stockpile Inventory

Status: Accepted
Date: 2026-07-05

## Context

Mining previously deposited block drops straight into a global inventory. That hid logistics: resources had no position, workers did not haul them, and stockpile layout could not matter.

## Decision

Mined blocks spawn physical item stacks in the world. Loose item stacks are not usable inventory until a worker hauls them to a stockpile cell that accepts their material.

Stockpiles are zone records with cells, category booleans, and exact material overrides. Exact material overrides win over category settings. Multiple stockpiles can exist at once.

Each stockpile cell holds one material type with a base capacity of 16 items. Deposits fill matching partial stacks before claiming empty cells. Containers may increase cell capacity in a later feature.

The global `world.inventory` dictionary is now a derived compatibility view over stockpiled item stacks. Placement/build checks consume from stored item stacks through the inventory bridge; construction hauling is a later feature.

Haul assignment and delivery paths run through the threaded path scheduler. If carrying is interrupted, the item becomes loose at the worker position, the old haul task is removed, and dirty-driven hauling creates a new task at that position. Queued task coordinates are immutable so task indexes remain coherent.

## Consequences

- Mining creates visible loose items instead of invisible global counts.
- Workers create and execute `HAUL` tasks for accepted loose item stacks.
- Stockpile filters control which materials become usable inventory.
- Stored item sprites remain visible on their occupied stockpile cells.
- Loose items can be stranded if no reachable accepting stockpile exists.
- Save/load must persist item stacks and stockpile zones.

## Guardrails

- Code pointer: `scripts/world/item_stack_store.gd`.
- Code pointer: `scripts/world/stockpile_store.gd`.
- Code pointer: `scripts/task_manager.gd`, `rebuild_haul_tasks()`.
- Code pointer: `scripts/worker.gd`, `_advance_haul_task()`.
- Contract: `tools/validate_stockpile_hauling.gd`.
- Contract: `tools/validate_worker_path_safety.gd` covers threaded haul delivery paths.
