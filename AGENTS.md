# AGENTS.md

Local instructions for coding agents working in this repo.

## General
- Be direct; skip fluff.
- Prefer `rg` for searching.
- Keep changes minimal and scoped to the request.
- Avoid editing binary/asset files unless asked.

## Subagent Delegation And Cost-First Routing

- Use subagents by default for non-trivial work when independent workstreams help. Skip delegation for trivial/tightly coupled work or when coordination costs more than doing the work locally; briefly explain the exception.
- Keep write scopes disjoint. Give each agent a bounded task, relevant interfaces and constraints, and a concrete validation expectation. The main agent owns integration and final verification.
- The user authorizes choosing different available subagent models and reasoning efforts without asking for each allocation. Set both explicitly when supported; do not assume the inherited model is cheap.
- Optimize expected total cost to a verified result, including coordination, checking, retries, integration, delay and consequences of mistakes. Delegate when producing, checking and integrating the result is expected to reduce total effort, or when independent challenge justifies the added cost. Expensive routing analysis can outweigh savings from avoiding a few inexpensive attempts.
- Prefer Luna as the first candidate for bounded, recoverable work, including substantial implementation. Give inexpensive attempts substantial room when failure is cheap to detect and recover from. Do not limit Luna to documentation or infer a capability ceiling from model-tier branding.
- The user authorizes stronger starting models and higher reasoning effort for open-ended judgment. Requests to question fundamentals, design from scratch, spend time or use a healthy budget favor deeper exploration. Choose the model for the role first, then its effort; a stronger coordinator does not automatically make a cheaper specialist sufficient.

### Route By Acceptance Method

Choose how the result will be accepted before delegating. Keep this decision brief:

| Acceptance situation | Starting approach |
|---|---|
| Cheap, decisive validation | Give Luna substantial room to implement or investigate; verify behavior and contain failed attempts. |
| Evidence can be checked selectively | Use Luna for source inspection, factual research and constrained candidates; the coordinator checks consequential claims. |
| Quality depends heavily on open-ended judgment | Have the coordinator handle it directly or choose a stronger specialist from the start; no preliminary Luna attempt is required. |
| Consequential decision with credible competing approaches | Assign independent challenge and verify the claims that distinguish the alternatives. |

- For architectural research, give supporting agents concrete evidence tasks, such as finding dependencies an alternative would break, counterexamples or evidence against a proposal. A useful evidence report need not have the best overall recommendation.
- Ask independent challengers to develop the strongest competing approach and identify evidence that would change the recommendation. Avoid steering every reviewer toward the same conclusion.
- Multiple agreeing opinions can share blind spots. Stronger models also require evidence and proportionate review. When checking an opinion requires repeating the analysis, reconsider whether that delegation saves work.
- Do not routinely score every task or launch agents to decide routing. Reserve a detailed 1-10 rubric for expensive or disputed allocations; treat scores as judgments until calibrated against outcomes.

### Concurrency Allowance

- Allow up to six concurrently open subagents when all are `gpt-5.6-luna`, excluding the main agent. If any open subagent uses another model, limit the entire group to three subagents. These are ceilings, not launch targets; use fewer when independent work does not justify coordination overhead.
- Choose each Luna agent's reasoning effort for its task; the expanded allowance does not require Max effort. Preserve the cost-first routing and reporting rules below.
- Before introducing a non-Luna agent into a larger Luna group, wait for completion and close enough agents to leave at most two open before spawning it. Do not interrupt useful work just to make room, and do not evade limits through nested delegation.
- `.codex/config.toml` sets the overall six-subagent ceiling and Luna default. The model-dependent three-agent ceiling is an instruction policy, not a per-model runtime quota. Respect any lower runtime limit and disclose it rather than promising unavailable concurrency.

### Starting Model And Effort Choices

- `gpt-5.6-luna`, `low`/`medium`: straightforward implementation, mechanical edits, targeted searches, and running/summarizing existing validators.
- `gpt-5.6-luna`, `high`/`xhigh`/`max`: substantial, well-specified implementation or focused debugging with clear interfaces and independently checkable results. Examples include UI editors, filtering/pagination, profiler aggregation, pure culling logic, and regression tests. Use the effort warranted by the reasoning, not automatically Max for everything.
- `gpt-5.6-terra`, `medium`/`high`: bounded subsystem work needing more discovery or judgment, when Luna's likely retries or integration burden outweigh its savings.
- `gpt-5.6-sol`, `high`/`xhigh`: open-ended subsystem judgment, cross-system ambiguity, hard-to-detect correctness failures, or expensive consequences that justify starting above Luna/Terra. Examples include assignment/pathfinding/hauling interactions and save compatibility design.
- `gpt-6-astra`, `high`/`xhigh`/`max`: broad architectural synthesis, challenges to foundational assumptions, or especially difficult concurrency and integration problems. Give a concrete reason for the model and effort; do not use it automatically for every review.
- `gpt-5.5`: an explicitly requested or evidence-backed alternative, not a mandatory escalation tier. Choose a supported effort explicitly.
- These are starting heuristics, not benchmark-proven capability boundaries or a required escalation ladder. Availability and supported efforts come from the current tool; disclose unavailable choices and fallbacks rather than silently substituting.

### Verification And Escalation

- Route by clarity of requirements, component boundaries, available validation, and the cost of undetected mistakes, not merely task length or file count.
- Prefer an inexpensive attempt when failure is cheap to detect and recover from. Allow a targeted correction when the cause is understood; reassess after it rather than repeatedly retrying the same unsuccessful approach.
- Escalate effort or model when evidence shows reasoning gaps, overlooked dependencies, repeated invariant violations, or unexpected scope. Do not escalate just because a tool, permission or environment failed.
- Use proportionate tests and integration checks. Do not automatically assign a premium reviewer to every Luna result; use stronger independent review where risk warrants it. Passing self-authored tests alone is not proof of correctness.
- Keep failed attempts contained, preserve unrelated work, and retain authorization boundaries. Cheap tokens do not justify unsafe changes, corrupted data or unbounded cleanup.
- Do not claim exact cost savings or cross-model equivalence without measurements. API token rates are not necessarily the user's product charges, and reasoning/retries can change total usage.

### Subagent Labels And Reporting

- Use `Model(Effort)-Number - Task` in launch announcements, progress updates and final allocation summaries. Examples: `Luna(Max)-1 - Priority editor`, `Luna(Max)-2 - Regression tests`, `Terra(High)-3 - Integration review`.
- Assign numbers in spawn order, unique across all models within the current user task. Keep the number when continuing the same agent; a newly spawned replacement gets a new number and an explicit handoff from the previous label.
- Before spawning, report the task, exact requested model ID, effort, and brief allocation reason. Put the reporting label in the subagent's task prompt and ask it to use that label in its summary.
- After spawning, map the label to the returned app nickname (and retain the tool's agent ID for routing). These labels do not rename app-generated nicknames when the tool has no rename field.
- If the model or effort is inherited and its resolved value is unavailable, say so. Use labels such as `Inherited(High)-3` or `Luna(Inherited)-3`; never guess the underlying setting. Announce any configuration change or fallback and update the label accurately.
- In the final response, briefly report which labeled agents were used and their scopes. Distinguish requested configuration from independently confirmed runtime metadata when only the former is available.
- Use the existing launch and final summaries as a compact allocation record: task/role, model/effort, acceptance method, outcome (accepted/corrected/reassigned), and integration burden. Include a short routing lesson when the outcome changes an allocation assumption; acceptance records the checks performed, not proof of correctness.
- Do not create a separate routing log or benchmark project unless requested. Revisit routing rules using observed corrections, reassignments and integration effort; report measured usage when available and keep cost estimates distinct from actual charges.

## Project Tracking
- GitHub Issues and the `Goblinoria Roadmap` GitHub Project are the source of truth for active work.
- Use `docs/project_management.md` for ticket schema, priority/severity labels, project fields, and workflow.
- Do not add active task lists to `TODO.md` or `docs/todo.md`; keep those files as pointers only.

## Godot / GDScript
- Engine: Godot 4.7.x (`project.godot` is authoritative).
- Avoid hand-editing `.tscn`/`.tres` unless explicitly requested.
- Use tabs for indentation, snake_case names, and ASCII only.

## World / Chunk System
- Chunked world lives in `scripts/world.gd`, `scripts/chunk_data.gd`.
- `World.CHUNK_SIZE` is authoritative; if changing it, update docs and bump save version.
- Streaming logic is in `scripts/world_streaming.gd` and renders via `scripts/rendering/world_renderer.gd`.

## Save/Load
- Current V8 saves use bulk chunk data (including two-cell stair identities) plus metadata, named stockpiles/items, worker role templates/work priorities, and optional mesh caches, orchestrated by `scripts/world_save_load.gd`. V4-V7 remain readable with legacy defaults.
- If the format changes, bump `SAVE_VERSION` and add mismatch checks.

## Tests / Runs
- Headless regression scripts live in `tools/validate_*.gd`; see `docs/prototype_checkpoint.md` for coverage and limitations.
- Run them with `godot --headless --path <repo> --script res://tools/<script>.gd`; inspect exit status and output. Save-related tests write isolated test data.
- Ask before running the editor or a graphical playtest.

## References
- `docs/design_philosophy.md` is the canonical design intent.
- `docs/chunk_streaming_plan.md` tracks the chunk streaming roadmap.
- `docs/game_design_doc.md` captures gameplay/system specs.
- `docs/prototype_checkpoint.md` is a dated implementation/validation snapshot, not an active task list; GitHub remains the work tracker.
- When you see a `SEE-ADR-###` code comment, read the referenced file in `docs/adr/` before changing that code path.
- Archived docs in `docs/archive/` are historical only; do not treat as current.
