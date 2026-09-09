# ADR-017: Work Priorities And Stockpile Names

Status: Accepted
Date: 2026-09-05

## Context

Worker information and work configuration are different tasks. Fixed role
eligibility cannot express a worker who mines first and hauls when mining is
unavailable. Numeric preferences must affect the actual scheduler, not just labels.
Stockpile IDs also need readable player-supplied names without changing identity.

## Decision

Workers presents activity, carried items, current tasks and waiting reasons.
Jobs (formerly Work Priorities) opens a code-created movable, non-modal worker-list
pop-out. Its body contains only search, filters, pagination and worker rows; opening
it clears old details. Selecting a worker exposes their screenshot-inspired
layout: grouped work-enable checkboxes on the left and priority controls on the
right in the separate details dock. Simulation continues; repeated navigation clicks,
Close and Escape dismiss the pop-out. Tasks is the player-facing task-list name. The internal category IDs
`assignments` and `jobs`, feature IDs and routes `open:assignments` and `open:jobs`
remain unchanged. The shared work catalog defines Hauling, Mining, Crafting, Building and future
categories; only existing HAUL, DIG, PLACE and STAIRS task types are enabled.

Per-worker values are Off (0) or 1-9, with 1 highest. Move Up decreases the selected
work type's numeric priority by one; Move Down increases it by one, within 1-9.
Other work values are not renumbered and ties are allowed. Off or an unchecked
enable checkbox disables future claims; current work finishes.
Equal-priority reachable work
uses actual path cost; deterministic IDs resolve equal costs. Failed/unavailable
higher-priority work must not permanently prevent lower-priority reachable work.
Edits affect new assignments, not already-owned work or delivery paths. Priority
changes invalidate pending decisions so old bids cannot silently apply new settings.
Role templates still initialize/save the default roster, but explicit settings
override their eligibility. Default template work uses priority 2.

Player-editable work-priority templates are explicitly deferred future design;
the existing roster defaults do not imply a template editor. Active work is tracked
in GitHub Issues and the Goblinoria Roadmap, not a local TODO board in this ADR.

The priority scheduler remains asynchronous and bounded; no UI snapshot runs
assignment or pathfinding. Choosing the cheapest reachable work requires evaluating
alternatives and can add decision latency; it is not a promise of instant claims.

Stockpile names are display-only strings, trimmed and limited to 64 characters,
without control characters. Duplicate names are allowed; ID, cells, filters and
reservations remain authoritative. Renaming emits visual invalidation but does not
rebuild hauling. Missing legacy names use Stockpile <id>.

V7 persists names in stockpile records and priority overrides in worker records.
Older V4-V6 formats remain readable using defaults for missing fields. Invalid work
keys/values and unsupported versions reject loading before the live world is
replaced. Workers still respawn and unfinished tasks still reset; this does not add
full colony-session continuation. Transactional save handling is unchanged.

Clicking the same category or selected information-row button toggles its panel
closed. Internal open/refresh calls remain idempotent. Priority and name editors
retain normal GUI input ownership and selected-world/entity revalidation.

## Guardrails

- WorkerWorkPriorities, Worker.can_accept_task/get_work_priority,
  World.set_worker_work_priority and TaskManager's assignment handoffs.
- StockpileStore.rename_stockpile/display_name and WorldWorkerSaveLoad validation.
- validate_work_priorities, validate_stockpile_names, validate_assignment_ui and
  validate_assignment_persistence, plus existing path, hauling, save and UI contracts.
- Graphical usability still requires separate approval and acceptance.
