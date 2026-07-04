# Project Management

GitHub Issues and GitHub Projects are the source of truth for active Goblinoria work. TODO files in the repo should only point here and should not carry active task lists.

## GitHub Project

The GitHub Project is [`Goblinoria Roadmap`](https://github.com/users/paragonmac/projects/7) under `paragonmac`.

Fields:
- `Status`: Inbox, Ready, In Progress, Review, Done, Parked
- `Priority`: Blocker, High, Normal, Low
- `Severity`: Critical, Major, Minor
- `Type`: Bug, Feature, Tech Debt, Design, Research, Docs, Tooling
- `Area`: Worker, World Generation, World Destruction, Streaming, Rendering, Save Load, Tooling, Project Management
- `Goal`: Prototype Stability, World Generation, World Destruction, Core Colony Loop, Tooling & Process
- `Phase`: Phase 0 - Hygiene & Tracking, Phase 1 - Stability, Phase 2 - World Generation, Phase 3 - Destruction, Phase 4 - Gameplay Loop
- `Validation`: Static Only, Godot Headless, Manual Editor, Playtest
- `Start Date`: planned start date for Project timeline views
- `Target Date`: planned target date for Project timeline views

Views:
- `Triage`: board grouped by Status
- `Roadmap`: table grouped by Phase, sorted by Priority
- `Priority Review`: filtered to Blocker/High
- `Bugs`: filtered to `type:bug`
- `World Gen`: filtered to `area:world-generation`
- Timeline/Roadmap view: use `Start Date` and `Target Date` as the date fields.

Project fields and item values can be managed through `gh` and the GitHub GraphQL API. Project views are currently configured in the GitHub UI.

Roadmap view setup:

1. Open the roadmap/timeline view in [`Goblinoria Roadmap`](https://github.com/users/paragonmac/projects/7).
2. In the top-right of the roadmap, click `Date fields`.
3. Set `Start date` to `Start Date`.
4. Set `Target date` to `Target Date`.
5. Set zoom to `Year` if the view looks empty because it is focused on the wrong month or quarter.
6. Optionally enable milestone markers from the `Markers` menu.

Enable Project auto-add for `paragonmac/Goblinoria_GD` issues with the filter `is:issue`.

## GitHub Milestones

GitHub Milestones represent playable outcomes. Issues are concrete work units inside those outcomes. The Project is the view/database layer across all issues.

Current milestones:

| Milestone | Tracker | Player-Facing Goal |
|---|---|---|
| [M0: Technical Foundation](https://github.com/paragonmac/Goblinoria_GD/milestone/1) | [#15](https://github.com/paragonmac/Goblinoria_GD/issues/15) | World loads, saves, renders, and can be edited safely. |
| [M1: Core Digging Loop](https://github.com/paragonmac/Goblinoria_GD/milestone/2) | [#16](https://github.com/paragonmac/Goblinoria_GD/issues/16) | Player marks terrain, workers dig it, pathing updates, and world changes persist. |
| [M2: Hauling And Stockpiles](https://github.com/paragonmac/Goblinoria_GD/milestone/3) | [#17](https://github.com/paragonmac/Goblinoria_GD/issues/17) | Mined resources become items and workers move them to stockpiles. |
| [M3: Building And Rooms](https://github.com/paragonmac/Goblinoria_GD/milestone/4) | [#18](https://github.com/paragonmac/Goblinoria_GD/issues/18) | Player constructs walls, floors, doors, and useful spaces. |
| [M4: Basic Colony Needs](https://github.com/paragonmac/Goblinoria_GD/milestone/5) | [#19](https://github.com/paragonmac/Goblinoria_GD/issues/19) | Workers need food, rest, and safety enough to create pressure. |
| [M5: Production Chains](https://github.com/paragonmac/Goblinoria_GD/milestone/6) | [#20](https://github.com/paragonmac/Goblinoria_GD/issues/20) | Raw materials become crafted goods through workshops. |
| [M6: Hazards And Fluids](https://github.com/paragonmac/Goblinoria_GD/milestone/7) | [#21](https://github.com/paragonmac/Goblinoria_GD/issues/21) | Water, lava, collapses, and hazards create emergent risk. |
| [M7: Threats And Combat](https://github.com/paragonmac/Goblinoria_GD/milestone/8) | [#22](https://github.com/paragonmac/Goblinoria_GD/issues/22) | Enemies exist, workers can fight, flee, heal, shoot, and defend. |
| [M8: Settlement Management](https://github.com/paragonmac/Goblinoria_GD/milestone/9) | [#23](https://github.com/paragonmac/Goblinoria_GD/issues/23) | UI, priorities, job controls, alerts, and diagnostics make the colony manageable. |
| [M9: World Depth](https://github.com/paragonmac/Goblinoria_GD/milestone/10) | [#24](https://github.com/paragonmac/Goblinoria_GD/issues/24) | Biomes, caves, ores, and underground features create map identity. |
| [M10: Emergent Systems](https://github.com/paragonmac/Goblinoria_GD/milestone/11) | [#25](https://github.com/paragonmac/Goblinoria_GD/issues/25) | Traps, flooding, production, combat roles, learned abilities, morale, and failures interact. |

Guidelines:

- Assign implementation issues to a GitHub Milestone when they directly move that playable outcome forward.
- Leave broad research or optional optimization issues without a product milestone unless they block a current outcome.
- Use the milestone tracker issue to discuss scope and completion criteria for the outcome.
- Do not split every design-doc bullet into an implementation issue until that milestone becomes active.
- Treat dates as planning windows, not hard promises. Move them when scope or reality changes.

## Timeline

Current planning timeline:

| Milestone | Start Date | Target Date |
|---|---:|---:|
| M0: Technical Foundation | 2026-06-15 | 2026-07-31 |
| M1: Core Digging Loop | 2026-07-15 | 2026-08-31 |
| M2: Hauling And Stockpiles | 2026-09-01 | 2026-09-30 |
| M3: Building And Rooms | 2026-10-01 | 2026-10-31 |
| M4: Basic Colony Needs | 2026-11-01 | 2026-11-30 |
| M5: Production Chains | 2026-12-01 | 2026-12-31 |
| M6: Hazards And Fluids | 2027-01-01 | 2027-01-31 |
| M7: Threats And Combat | 2027-02-01 | 2027-03-15 |
| M8: Settlement Management | 2027-03-16 | 2027-04-15 |
| M9: World Depth | 2027-04-16 | 2027-05-31 |
| M10: Emergent Systems | 2027-06-01 | 2027-07-31 |

## Labels

Create these repository labels:

- `priority:blocker`, `priority:high`, `priority:normal`, `priority:low`
- `severity:critical`, `severity:major`, `severity:minor`
- `type:bug`, `type:feature`, `type:tech-debt`, `type:design`, `type:research`, `type:docs`, `type:tooling`
- `area:worker`, `area:world-generation`, `area:world-destruction`, `area:streaming`, `area:rendering`, `area:save-load`, `area:tooling`, `area:project-management`

Priority means when work should be scheduled:
- `priority:blocker`: blocks commit, PR, validation, release, or the next required work item.
- `priority:high`: important follow-up before handoff, release, or major dependent work.
- `priority:normal`: useful planned work with no immediate blocker.
- `priority:low`: cleanup or optional polish to handle when working nearby.

Severity means user-visible bug impact:
- `severity:critical`: crash, data loss, or unusable core workflow.
- `severity:major`: broken or misleading behavior with no good workaround.
- `severity:minor`: small defect, visual issue, or behavior with an acceptable workaround.

## Ticket Shape

Every implementation ticket should include:

- Goal or problem
- Context
- Area
- Priority
- Severity for bugs
- Acceptance criteria
- Validation plan
- Notes or links when useful

Issue forms in `.github/ISSUE_TEMPLATE` enforce this structure for bugs, work items, and research tasks.

## Agent Workflow

When asked what to work on next:

1. Read open GitHub issues and the `Goblinoria Roadmap` project.
2. Prefer `priority:blocker`, then `priority:high`, then `priority:normal`, then nearby `priority:low` cleanup.
3. For bugs, use Severity to break ties inside the same Priority.
4. Confirm the ticket has acceptance criteria and validation before implementation.
5. Keep changes scoped to the ticket.
6. Update or close the GitHub issue when the work is complete.

If GitHub access is unavailable, use `docs/project_management.md` for schema and process, but do not reintroduce active TODO lists in the repo.

## References

- GitHub Projects: https://docs.github.com/en/issues/planning-and-tracking-with-projects
- GitHub issue forms: https://docs.github.com/en/communities/using-templates-to-encourage-useful-issues-and-pull-requests/syntax-for-issue-forms
- Project auto-add: https://docs.github.com/en/issues/planning-and-tracking-with-projects/automating-your-project/adding-items-automatically

## Seed Issues

Initial tracking issues:

### [Migrate project tracking from TODO docs to GitHub Issues/Projects](https://github.com/paragonmac/Goblinoria_GD/issues/1)

Metadata:
- Priority: Low
- Type: Tooling
- Area: Project Management
- Goal: Tooling & Process
- Phase: Phase 0 - Hygiene & Tracking
- Validation: Static Only

Acceptance criteria:
- GitHub labels from this document exist.
- `Goblinoria Roadmap` exists with the documented fields and views.
- Project auto-add is enabled for `paragonmac/Goblinoria_GD` issues with filter `is:issue`.
- Seed issues are added to the Project and fields are populated.
- `TODO.md` and `docs/todo.md` are pointers only.

### [Fix block-face redraw while digging](https://github.com/paragonmac/Goblinoria_GD/issues/2)

Metadata:
- Priority: High
- Severity: Major
- Type: Bug
- Area: Rendering
- Goal: Prototype Stability
- Phase: Phase 1 - Stability
- Validation: Manual Editor

Acceptance criteria:
- Digging a block updates exposed adjacent faces correctly.
- Digging a block removes faces that should become hidden or stale.
- Chunk-boundary digging redraws affected neighboring chunk faces correctly.
- No unrelated rendering behavior changes.

### [Rework underground water presentation before re-enabling static water](https://github.com/paragonmac/Goblinoria_GD/issues/3)

Metadata:
- Priority: High
- Type: Design
- Area: World Generation
- Goal: World Generation
- Phase: Phase 2 - World Generation
- Validation: Manual Editor

Acceptance criteria:
- Pick a visual approach for underground water.
- Keep static underground water disabled until the presentation is readable.
- Document the chosen approach if implementation is deferred.
- Avoid save-format changes unless explicitly planned.

### [Add explicit chunk destruction API for explosive world damage](https://github.com/paragonmac/Goblinoria_GD/issues/4)

Metadata:
- Priority: High
- Type: Feature
- Area: World Destruction
- Goal: World Destruction
- Phase: Phase 3 - Destruction
- Validation: Static Only

Acceptance criteria:
- Add or design an explicit destruction API for large destructive events.
- Use naming that clearly communicates gameplay destruction, not streaming unload.
- Identify rendering, save/load, and chunk data invalidation requirements.
- Avoid changing save format without a separate versioning plan.

### [Validate cave walker generation bounds, determinism, and stats](https://github.com/paragonmac/Goblinoria_GD/issues/5)

Metadata:
- Priority: Blocker
- Type: Tech Debt
- Area: World Generation
- Goal: Prototype Stability
- Phase: Phase 1 - Stability
- Validation: Static Only

Acceptance criteria:
- Cave walker coordinates and brush carving are bounds-safe.
- Generation remains deterministic for a given seed and world size.
- Stats counters accurately describe generated content.
- Progress reporting still matches startup phases.
- Performance risk is understood for full-map generation.
