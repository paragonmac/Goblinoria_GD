# Prototype Checkpoint - 2026-09-05

## Conclusion

Goblinoria has a connected excavation/logistics/building prototype, substantial procedural terrain and rendering infrastructure, and useful inspection tools. It is not yet a sustained colony simulation: recurring needs, production, rooms, combat, and interacting environmental hazards remain future systems. The next recommended outcome is to prove the existing playable loop before expanding it.

This is a dated evidence snapshot, not a second backlog. [GitHub Issues and the Roadmap](project_management.md) own active work; the [GDD](game_design_doc.md) owns gameplay intent, [design philosophy](design_philosophy.md) owns principles, [architecture](current_architecture.md) describes runtime ownership, and [ADRs](adr/) preserve focused technical decisions. Keep those documents rather than introduce another competing design document.

## Evidence And Status Rules

- Baseline: local worktree based on commit `70ddc1e`, including uncommitted bug fixes and context-menu implementation. This assessment is not a claim about the published branch.
- Runtime: `project.godot` specifies Godot 4.7; validation used Godot 4.7.2 on Windows.
- Two independent read-only audits covered gameplay/persistence and worldgen/rendering/UI/documentation. The main audit reconciled their findings with live issues and ran the validators.
- **Implemented** means the bounded capability exists in code; it does not mean a whole milestone passed acceptance.
- **Partial** means a meaningful subset exists with explicit gaps. **Planned** means specified in the GDD but not found as a working system. **Deferred** below identifies an explicit hold or an exclusion from the proposed checkpoint, not cancellation of the long-term design.
- No editor, graphical playtest, full-map performance benchmark, or complete interactive-session acceptance was performed for this checkpoint.

## System Inventory

| System / GDD area | Status | Current evidence and limits |
|---|---|---|
| Finite editable voxel world | Implemented | [World](../scripts/world.gd), [ChunkData](../scripts/chunk_data.gd): chunk size 8, 32x32x32 chunks, 256 blocks per axis. X/Z are -128..127; Y is 0..255. Not an infinite world. |
| Procedural world identity | Partial | [Layered pipeline](../scripts/world_generation_pipeline.gd): climate, biomes, geology, caves, ores, slopes, flowers. Full-map generation uses one background generation task followed by parallel mesh cooking. [Streamed fallback](../scripts/world/world_terrain_chunk_builder.gd) produces simpler terrain; same-seed content parity is not promised. Strategic replayability remains untested. |
| Streaming and terrain rendering | Implemented foundation | [Streaming](../scripts/world_streaming.gd), [renderer](../scripts/rendering/world_renderer.gd): greedy cubes, separate slope/stair geometry, asynchronous meshes, raw caches, pooling, slice clipping, bounded reveal and prewarm. Visual acceptance and measured performance remain separate from contract tests. |
| Digging, stairs, task/path execution | Implemented | [Worker](../scripts/worker.gd), [TaskManager](../scripts/task_manager.gd), [Pathfinder](../scripts/pathfinder.gd): reachable work, excavation drops, stairs, terrain invalidation and movement recovery. Ordinary dig work is horizontal. Open worker-loss report #27 remains a sign-off risk. |
| Physical items and hauling | Implemented, basic | [ItemStackStore](../scripts/world/item_stack_store.gd), [Worker](../scripts/worker.gd): loose/reserved/carried/stored stacks, pickup, delivery, cancellation and failed-route recovery. Loose items are not spendable inventory. |
| Stockpile management | Partial | [StockpileStore](../scripts/world/stockpile_store.gd): multiple zones, filters, material overrides and 16-item cell capacity. [HUD](../scripts/main_hud_controller.gd) filters only the first stockpile; backend capability is broader than exposed management. |
| Building and rooms | Partial | [Worker completion](../scripts/worker.gd) consumes one globally stored material for PLACE; [World](../scripts/world.gd) currently selects iron ore. Stairs replace terrain directly without material consumption. No construction-site delivery, doors, room recognition or room usefulness. |
| Worker roles and colony model | Partial | [WorkerRoles](../scripts/worker_roles.gd): two Miners, one Hauler, one Fighter by default; role-aware assignment and idle role reassignment. Fighter is a reserve with no combat tasks. Skills, learned abilities and rich individual simulation remain planned. |
| Needs, morale, health and production | Planned | GDD M4/M5; [task types](../scripts/task_queue.gd) are DIG, PLACE, STAIRS and HAUL. No implemented food/rest demand, workshops, recipes or production chains were found. |
| Hazards, fluids and combat | Planned; movement-safety subset exists | Worker falling/recovery is not injury, collapse or flood simulation. Fighter role is not combat. [Static underground water](../scripts/world/world_terrain_material_generator.gd) is explicitly disabled pending presentation work (#3). |
| Tools, inspection and management UI | Partial | [Tool catalog](../scripts/main_tool_catalog.gd), [context menu](../scripts/main_context_menu_controller.gd), [Workers panel](../scripts/main_worker_window_controller.gd): seven tools, snapshot inspection, pending cancellation, one-cell stockpile removal, roles/details, overlays and diagnostics. Broad job lists, policies, priorities and alerts remain future management work. |
| Persistence and session continuation | Partial | [WorldSaveLoad](../scripts/world_save_load.gd) and helpers implement V6 metadata/items/zones/roles plus bulk V2 terrain, migration checks and transactional slot replacement. Full worker/task continuation is not saved; see the contract below. |
| Deterministic simulation and tooling | Partial | Seeded generation has fixtures. Eleven standalone validators and CSV diagnostics exist. Simulation currently receives frame delta from [Main](../scripts/Main.gd), not a fixed 60 Hz tick. No checked-in CI workflow was found. |

Static water is deferred by the existing issue, not newly removed here. Needs, production, combat, larger-world cache eviction and higher-risk rendering changes are excluded from the proposed validation gate, not globally rescheduled. The broader phrase "fantasy world simulator" needs a separate scope decision if it means regional history, civilizations or ecosystems beyond the current settlement/terrain GDD.

## The Playable Loop And Its Missing Connections

The implemented chain is:

`dig -> loose mining drop -> hauler -> stockpile -> stored inventory -> basic placement`

The significant limits are:

1. **Construction logistics stop at storage.** Placement removes material from stored inventory without a worker fetching it to the site or validating access to the supplying stockpile. That is a prototype abstraction, not the GDD's M3 material-delivery criterion.
2. **The build demonstration needs iron ore.** Excavating arbitrary stone does not establish that placement can proceed. A reproducible acceptance scenario must record accessible iron ore and account for what is consumed. Stair conversion follows a different resource rule; changing either rule requires a design decision.
3. **Reload is a world-state restart, not session continuation.** Worker positions, unfinished designations, assignments and progress do not round-trip. This must be visible in expectations before claiming the colony resumes after load.
4. **Management is narrower than the data model.** Multiple stockpiles exist, but independent per-zone filter editing is not exposed. Worker diagnostics help explain stalls but are not a complete player-facing job/alert system.
5. **There is no recurring colony pressure yet.** Building and extraction work, but needs, production demand and threats do not yet make expansion necessary or create a sustained survival loop.

These are design/implementation boundaries, not an instruction to fix every gap in this documentation pass.

## Current Save/Load Contract

Authoritative save data includes terrain, world metadata, physical item stacks, stockpile zones/filters, and worker-ID-to-role records. Mesh caches are optional acceleration data. Current saves require valid terrain; failed loads must preserve live state, and failed writes must preserve or recover the previous slot. V4 terrain-slope migration and V5 default-role migration remain supported.

On successful load, workers respawn and tasks/designations reset. Saved carried stacks become loose at the saved carrier cell; reservations clear and hauling can be reconstructed. This preserves material accounting without restoring a worker's path, timer or delivery stage. Passing failure/rollback tests does not prove successful task round-tripping.

Evidence: [save orchestration](../scripts/world_save_load.gd), [transaction helper](../scripts/world_save_transaction.gd), [item/stockpile snapshot](../scripts/world_item_stockpile_save_load.gd), [worker-role snapshot](../scripts/world_worker_save_load.gd).

## Verification Performed

All eleven validators passed on the local worktree on 2026-09-05, with exit code 0 and their success markers inspected:

| Validator | Result |
|---|---|
| [Context menu](../tools/validate_context_menu.gd) | Pass, 108 checks |
| [Selection input](../tools/validate_selection_input.gd) | Pass |
| [Worker path safety](../tools/validate_worker_path_safety.gd) | Pass |
| [Stockpile hauling](../tools/validate_stockpile_hauling.gd) | Pass |
| [Event-driven worker updates](../tools/validate_event_driven_worker_updates.gd) | Pass |
| [Rendering contract](../tools/validate_rendering_contract.gd) | Pass |
| [Rendering regressions](../tools/validate_rendering_regressions.gd) | Pass |
| [Generation contract](../tools/validate_generation_contract.gd) | Pass, 2 fixture cases |
| [Save/load transactions](../tools/validate_save_load_transaction.gd) | Pass, 128 checks |
| [Worker roles](../tools/validate_worker_roles.gd) | Pass |
| [Terrain-slope migration](../tools/validate_terrain_slope_migration.gd) | Pass |

`Main.gd` also passed headless `--check-only` parsing. Runs used explicit log files under the Windows temporary directory (`goblinoria-checkpoint-*.log`); these are local transient evidence, not committed artifacts. Save tests use isolated slots/fixtures. Transaction tests deliberately log injected failures; the sandbox also produced a certificate-store warning and an existing atlas warning in relevant runs. A passing exit code alone is not sufficient evidence without the expected success marker and output review.

Re-run a validator with `godot --headless --path <repo> --script res://tools/<validator>.gd`; parse Main with `godot --headless --path <repo> --check-only --script res://scripts/Main.gd`. Use a writable explicit `--log-file` when needed. Ask before starting the editor or any graphical run.

These tests cover contracts and synthetic regressions. Some exercise backend methods directly. They do not prove that an ordinary player can complete the full loop, that meshes look correct, that worker disappearance is resolved, or that full-map startup meets a performance budget.

## Recommended Next Outcome: Prototype Loop Sign-off

Use existing M0 Technical Foundation as the validation umbrella, feeding M1/M2 acceptance and demonstrating only the implemented placement subset of M3. Do not invent M11 or mark M3 complete from a block-placement demo. The recommendation is to validate today's behavior first; physical construction delivery is a candidate next M3 feature after sign-off, not approved implementation here.

The proposed acceptance protocol is:

1. Record the tested commit/dirty state, Godot version, hardware, seed, startup mode, stockpile layout and camera/level route. Retain fresh validator and Main-parse outputs.
2. After graphical approval, start a documented world with accessible iron ore. Use normal tools to excavate, collect drops, haul to eligible storage and place blocks. A useful scenario is ten mined iron-ore units and five placements, leaving five units across loose/carried/stored states. Record totals before/after; do not seed invisible inventory and call it end-to-end proof.
3. Exercise stockpile filtering/capacity, pending-haul cancellation and blocked-route recovery. Show that reservations and items are released or recovered without unexplained duplication, loss or permanent stalls. Record the first-stockpile-only filter limitation rather than silently adding new UI.
4. Exercise stairs and terrain edits across slice/chunk boundaries; inspect worker motion, exposed faces and orientation. Test context-menu/GUI input ownership and idle role reassignment using visible controls.
5. Save/reload both a settled session and a mid-haul session. Compare terrain, zones/filters, roles and material totals under the documented restart contract. Worker respawn, cleared tasks and loose saved carried items are expected; preservation of unfinished designations is a separate future requirement.
6. Smoke-test both limited-streaming and full-map startup, recording timing/settings and failures. They are different generation modes, not a parity test. Set performance targets from measured evidence rather than inventing a frame-time promise.
7. Explicitly disposition worker-loss issue #27 using reproduction and diagnostics. Review #2/#26 visually and complete #28's outstanding role-panel check. Keep defects open when acceptance is unproven.
8. Record whether the session is understandable without debug intervention: where work stops, how the player knows why, and whether recovery is possible. Update tracker evidence without claiming all GDD systems are done.

A sign-off report should distinguish passing checks, observed defects and consciously accepted prototype limits. This documentation checkpoint itself does not satisfy that graphical gate.

## Live Tracking Reconciliation

Live issue inspection on 2026-09-05 found:

| Tracker | Evidence-based disposition |
|---|---|
| [M0 #15](https://github.com/paragonmac/Goblinoria_GD/issues/15), [M1 #16](https://github.com/paragonmac/Goblinoria_GD/issues/16), [M2 #17](https://github.com/paragonmac/Goblinoria_GD/issues/17) | Open checklists lag the amount of local implementation, but headless results do not certify their interactive success criteria. Add dated evidence before considering closure. |
| [M3 #18](https://github.com/paragonmac/Goblinoria_GD/issues/18) | Partial: placement/stairs exist; construction delivery, doors and rooms are not satisfied. |
| [M8 #23](https://github.com/paragonmac/Goblinoria_GD/issues/23), [M9 #24](https://github.com/paragonmac/Goblinoria_GD/issues/24) | Early management and procedural-map work exists ahead of the original planning windows. This is not full milestone acceptance. |
| [Worker loss #27](https://github.com/paragonmac/Goblinoria_GD/issues/27) | Open, Blocker/Critical. Falling through terrain is a reported hypothesis, not a cause proven by this audit. Keep it a sign-off risk until dispositioned. |
| [Face redraw #2](https://github.com/paragonmac/Goblinoria_GD/issues/2), [ramp/stair visuals #26](https://github.com/paragonmac/Goblinoria_GD/issues/26) | Open graphical acceptance work; mesh/path regressions alone do not close them. |
| [Worker roles #28](https://github.com/paragonmac/Goblinoria_GD/issues/28) | Existing implementation comment already records automated checks and pending manual role reassignment. Remaining open is intentional. |
| [Underground water #3](https://github.com/paragonmac/Goblinoria_GD/issues/3) | Explicit presentation hold before static water is re-enabled; do not confuse a generation pass with fluid gameplay. |

Proposed tracking handoff: one M0 validation issue titled **Validate the existing prototype dig-haul-build-reload loop**, with the protocol above, High priority, Tech Debt type, Project Management area, Prototype Stability goal, Phase 1 - Stability, and Playtest validation supported by headless checks. Link the existing trackers and add dated implementation/validation evidence to M0-M3 without replacing their original criteria.

The attempted issue creation returned GitHub 403, `Resource not accessible by integration`. No issue was created and no existing issue, milestone or Project field was modified. Project board fields/dates could not be verified. Reconciliation therefore stops at a documented proposal until issue-write access is available; this section is not a live local task list. Original date tables are now explicitly historical planning windows, not revised delivery commitments.

## Decisions To Make Before Expansion

Keep the next feature decision narrow after observing the gate: construction-site material delivery under M3 is the recommended candidate. Decide its material rules, whether stairs share those rules, and whether unfinished designations must survive reload before implementing it. Independent stockpile management and player-facing stall explanations should be evaluated from the recorded session, not assumed to require a broad HUD redesign.

Needs, workshops, threats and larger-scale fantasy-world simulation remain separate design decisions. No gameplay behavior, save format, scene/resource file, roadmap dates or commit was changed by this documentation pass.
