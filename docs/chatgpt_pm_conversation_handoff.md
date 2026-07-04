# ChatGPT Handoff: Goblinoria Project Management And Milestones

Use this as context for a voice conversation about project management and milestone planning for Goblinoria.

Do not include private keys, tokens, app credentials, or local credential file contents in the conversation.

## Project Context

Goblinoria is a Godot 4.6.x voxel colony sim inspired by Dwarf Fortress. The current prototype focuses on a finite chunked voxel world, workers, mining/digging, pathing, rendering, save/load, chunk streaming, and world generation.

The repo is public:

https://github.com/paragonmac/Goblinoria_GD

The current design docs include:

- `docs/game_design_doc.md`: gameplay/system design and milestone outline.
- `docs/chunk_streaming_plan.md`: chunk storage, streaming, rendering, and persistence plan.
- `docs/project_management.md`: new GitHub Issues/Projects workflow.

## What Changed In This Conversation

We moved active work tracking away from local TODO docs and into GitHub Issues.

Repo-side changes:

- Added GitHub issue forms for bugs, work items, and research.
- Added `docs/project_management.md`.
- Replaced `TODO.md` and `docs/todo.md` with pointers to GitHub Issues/Projects.
- Updated `AGENTS.md` so agents treat GitHub Issues/Projects as the source of truth.
- Updated `docs/chunk_streaming_plan.md` so open checklist items now link to GitHub issues.

GitHub-side changes:

- Created priority labels:
  - `priority:blocker`
  - `priority:high`
  - `priority:normal`
  - `priority:low`
- Created severity labels:
  - `severity:critical`
  - `severity:major`
  - `severity:minor`
- Created type labels:
  - `type:bug`
  - `type:feature`
  - `type:tech-debt`
  - `type:design`
  - `type:research`
  - `type:docs`
  - `type:tooling`
- Created area labels:
  - `area:worker`
  - `area:world-generation`
  - `area:world-destruction`
  - `area:streaming`
  - `area:rendering`
  - `area:save-load`
  - `area:tooling`
  - `area:project-management`

We intentionally replaced the earlier private `RAC` terminology with public-facing `Priority` and `Severity`, because those are easier for contributors to understand.

## Current GitHub Issues

Initial project-management and active TODO migration:

- #1 Migrate project tracking from TODO docs to GitHub Issues/Projects
- #2 Fix block-face redraw while digging
- #3 Rework underground water presentation before re-enabling static water
- #4 Add explicit chunk destruction API for explosive world damage
- #5 Validate cave walker generation bounds, determinism, and stats

Migrated chunk-streaming TODOs:

- #6 Add chunk save migration stub
- #7 Decide runtime cache eviction policy for larger worlds
- #8 Prevent chunk load queue starvation with age-based priority
- #9 Tighten Y-level reveal gate to actual visible chunks
- #10 Define mesh cleanup and neighbor readiness policy for chunk reload/destruction
- #11 Benchmark bulk chunk compression CPU vs disk savings
- #12 Add background load/save threading for chunk IO
- #13 Plan optional region-file layout and compaction strategy
- #14 Evaluate higher-risk rendering optimizations from mesh metrics

The GitHub Project still needs to be created manually unless a token/app permission with user-level Project creation is provided.

Suggested Project name:

`Goblinoria Roadmap`

Suggested Project fields:

- `Status`: Inbox, Ready, In Progress, Review, Done, Parked
- `Priority`: Blocker, High, Normal, Low
- `Severity`: Critical, Major, Minor
- `Type`: Bug, Feature, Tech Debt, Design, Research, Docs, Tooling
- `Area`: Worker, World Generation, World Destruction, Streaming, Rendering, Save Load, Tooling, Project Management
- `Goal`: Prototype Stability, World Generation, World Destruction, Core Colony Loop, Tooling & Process
- `Phase`: Phase 0 - Hygiene & Tracking, Phase 1 - Stability, Phase 2 - World Generation, Phase 3 - Destruction, Phase 4 - Gameplay Loop
- `Validation`: Static Only, Godot Headless, Manual Editor, Playtest

## Important PM Decision

We decided:

- Issues are concrete work units.
- GitHub Milestones should represent playable outcomes.
- GitHub Projects should be the database/view layer across issues.
- Local docs should contain design/reference material, not active task tracking.

## Milestone Brainstorm

A Dwarf Fortress-like colony sim should organize milestones around playable vertical slices, not just system names.

Suggested milestone track:

| Milestone | Theme | Player-Facing Goal |
|---|---|---|
| M0 | Technical Foundation | World loads, saves, renders, and can be edited safely. |
| M1 | Core Digging Loop | Player marks terrain, workers dig it, pathing updates, world changes persist. |
| M2 | Hauling & Stockpiles | Mined resources become items and workers move them to stockpiles. |
| M3 | Building & Rooms | Player constructs walls/floors/doors and defines useful spaces. |
| M4 | Basic Colony Needs | Workers need food/rest/shelter enough to create pressure. |
| M5 | Production Chains | Raw materials become crafted goods through workshops. |
| M6 | Hazards & Fluids | Water/lava/cave-ins/environmental hazards create emergent risk. |
| M7 | Threats & Combat | Enemies exist, workers can fight/flee, defenses matter. |
| M8 | Settlement Management | UI, priorities, job controls, alerts, and diagnostics make the colony manageable. |
| M9 | World Depth | Better world generation, biomes, underground features, ores, and long-term map identity. |
| M10 | Emergent Systems | Multiple systems interact: traps, flooding, fire, production, combat, morale, etc. |

## Example Milestone Detail

### Milestone 1: Core Digging Loop

Goal:

Player can start a new world, designate digging, workers execute tasks, terrain changes correctly, and the result survives save/load.

Scope:

- World chunk storage is stable.
- Dig designations create tasks.
- Workers claim and execute mining tasks.
- Workers path across flat ground and stairs/ramps.
- Edited chunks redraw correctly.
- Save/load preserves modified terrain.
- Basic debug UI exposes worker/task/world state.

Success criteria:

- Start new world.
- Select an area to dig.
- Worker reaches the job.
- Block is removed.
- Neighbor faces redraw correctly.
- Worker does not get stuck or float.
- Save, quit, reload, terrain is still changed.

Likely issues inside this milestone:

- #2 Fix block-face redraw while digging
- #5 Validate cave walker generation bounds, determinism, and stats
- #6 Add chunk save migration stub
- #8 Prevent chunk load queue starvation with age-based priority
- #9 Tighten Y-level reveal gate to actual visible chunks
- #10 Define mesh cleanup and neighbor readiness policy for chunk reload/destruction
- #12 Add background load/save threading for chunk IO

## Question For ChatGPT Voice Conversation

I want to discuss whether these milestones are the right shape for a Dwarf Fortress-like game, and how to split them into GitHub Milestones, Project phases, and issues without creating too much process overhead.

Specific things to talk through:

1. Should M0 Technical Foundation exist separately from M1 Core Digging Loop?
2. Which current issues should be assigned to M1 versus left as infrastructure backlog?
3. Should World Depth come early because the game identity depends on world generation, or later because the core colony loop matters more?
4. How should open design-doc milestone checklists be represented: one tracking issue per milestone, or direct GitHub Milestones only?
5. What is the right first "playable slice" for a solo dev prototype?

## Suggested Prompt To Paste Into ChatGPT Web

I am building a Godot 4.6 voxel colony sim inspired by Dwarf Fortress. I just migrated active TODO tracking to GitHub Issues and want to design a clean milestone system. Please help me reason verbally about GitHub Milestones, Project fields, and issue breakdowns for a public repo.

Use this model as a starting point:

- Issues are concrete work units.
- GitHub Milestones are playable outcomes.
- GitHub Projects are the database/view layer.
- Local docs are design/reference material, not active task tracking.

Here is the proposed milestone track:

- M0 Technical Foundation
- M1 Core Digging Loop
- M2 Hauling & Stockpiles
- M3 Building & Rooms
- M4 Basic Colony Needs
- M5 Production Chains
- M6 Hazards & Fluids
- M7 Threats & Combat
- M8 Settlement Management
- M9 World Depth
- M10 Emergent Systems

Please help me critique the milestone order, decide what belongs in M1, and decide whether to create one tracking issue per milestone or rely on GitHub Milestones plus Project fields.
