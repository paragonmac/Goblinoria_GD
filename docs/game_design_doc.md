# Goblinoria Game Design Document v0.2

Current prototype: Godot 4.6.x / GDScript.

This document describes the major design pillars and systems for Goblinoria. It is inspired by Dwarf Fortress-style colony simulation, but the goal is not to clone a specific game. The goal is to capture the core fantasy: a living settlement carved into a reactive voxel world, where simple systems combine into surprising outcomes.

Implementation details, formulas, balancing, UI flows, and edge-case rules should become focused GitHub issues or deeper design notes when a system enters active development.

## Vision

Goblinoria is a 3D voxel colony simulation about founding, expanding, and protecting an underground settlement.

The player does not directly control individuals. Instead, the player gives high-level instructions: dig here, build there, store this, defend that, prioritize this job. Workers interpret those instructions through job, pathing, resource, and survival systems.

The game should feel like managing a messy living machine:

- The world has physical shape and material consequences.
- Workers are limited by access, time, skills, needs, and danger.
- Resources move through the colony as items, stockpiles, and production chains.
- Threats and hazards emerge from the map and from player choices.
- The best stories come from interacting systems, not scripted events.

## Design Pillars

### Indirect Control

The player manages through designations, zones, priorities, policies, and alerts. Workers remain autonomous enough that planning matters, but predictable enough that failures feel diagnosable.

### Physical World

The voxel world is not just scenery. Terrain blocks access, supports structures, contains resources, carries hazards, and records player history through digging and building.

### Small Rules, Large Outcomes

Systems should be individually simple: tasks, items, needs, rooms, fluids, threats. Complexity should come from their overlap.

### Readable Simulation

The player should be able to understand why something happened. Debug overlays can exist during development, but the finished game needs visible state, alerts, and inspectable objects.

### Risk-First Development

Milestones should prove risky interactions early: world editing, pathing, task execution, save/load, rendering correctness, and worker state recovery.

## Player Fantasy

The player fantasy is to build a functional underground settlement in a hostile, material-rich world.

Core verbs:

- Dig tunnels, rooms, shafts, and defensive works.
- Build walls, floors, stairs, doors, bridges, workshops, storage, and traps.
- Assign zones and priorities.
- Manage workers, resources, rooms, and production.
- React to floods, collapses, enemies, shortages, and pathing mistakes.
- Watch the settlement develop its own logistical and social problems.

## Core Game Loop

The core loop is:

1. Survey the world.
2. Designate work.
3. Workers claim tasks.
4. Workers path, gather resources, and perform work.
5. The world changes.
6. New resources, hazards, and constraints appear.
7. The player adapts the colony plan.

The first playable slice should prove:

- Designate digging.
- Workers reach jobs.
- Blocks are removed.
- Terrain redraws correctly.
- Workers recover from world changes.
- Save/load preserves the changed world.

## World Model

The world is a finite voxel map for the current prototype. It is chunked, persistent, and editable.

Major world responsibilities:

- Terrain shape: surface, underground layers, caves, ramps, and entrances.
- Materials: soil, stone, ores, wood, water, and future special materials.
- Bounds: hard finite world limits for generation, pathing, rendering, and selection.
- Persistence: saves store final block data and relevant colony state.
- Render state: block changes invalidate and rebuild affected chunk meshes.
- Simulation hooks: blocks affect access, mining time, drops, support, fluids, and hazards.

World generation should support identity and replayability:

- Biomes and surface context.
- Underground geology.
- Ore and resource distribution.
- Caves and natural openings.
- Water or fluid features once visually and mechanically readable.

The current priority is stable, readable generation over maximum variety.

## Colony Model

The colony is the player-created organization layered on top of the world.

Major colony parts:

- Workers: individual agents that execute jobs.
- Tasks: concrete work items workers can claim.
- Zones: player-defined areas such as stockpiles, rooms, farms, and defenses.
- Items: physical resources that sit in the world, move through hauling, and feed production.
- Rooms: functional spaces created from zones, furniture, access, and materials.
- Policies: priority rules, allowed work, alerts, and future scheduling.

The colony should become more difficult to manage as it grows, but the difficulty should come from logistics and risk rather than opaque worker behavior.

## Workers

Workers are not free-form characters in the first version. They are reliable game pieces with enough individuality to create planning pressure later.

The current prototype uses role templates rather than separate worker classes: Miners handle excavation/build access, Haulers move physical items, and Fighters remain in reserve until combat work exists. These templates are reassigned through the worker panel and are deliberately a bridge to later skills, equipment, and squads rather than permanent character classes.

Major worker responsibilities:

- Find claimable tasks.
- Path to work.
- Perform work over time.
- Carry items when hauling exists.
- React to blocked paths, missing support, falling, threats, and inaccessible tasks.
- Report why work cannot proceed.

Future worker depth can include:

- Skills and professions.
- Needs such as hunger, rest, safety, and morale.
- Injuries and death.
- Preferences or personality.
- Schedules and squads.

Worker identity should eventually come from learned capability, not fixed character classes. A worker can become valuable because they survived, practiced, trained, fought, healed, crafted, or repeatedly solved a type of colony problem.

Major worker progression ideas:

- Skills improve over time through use, training, and survival.
- Roles emerge from skill, equipment, assignment, and experience.
- Workers can specialize without becoming locked forever.
- Experienced workers should feel worth protecting.
- Losing a skilled worker should matter to the colony.

Long-term combat and support roles:

- Fighters: melee workers who hold chokepoints, protect civilians, and use heavy weapons or shields.
- Rangers: ranged workers who attack from distance, scout, hunt, or defend from prepared positions.
- Clerics: support workers who heal injuries, cure poison, protect allies, and stabilize fights.
- Specialists: rare or advanced workers with powerful learned abilities.

Advanced abilities can become a major differentiator from a pure management sim. Examples include mass healing, cure poison, ranged volleys, shield walls, and an AOE storm blade attack that cleaves through groups. These should be earned through progression and should create tactical planning opportunities without turning the game into direct unit micro.

The early rule is simple: workers must be predictable before they become complex.

## Jobs And Designations

Player intent enters the simulation through designations and zones. Designations become tasks when they are valid and reachable.

Major job categories:

- Dig: remove blocks and expose new terrain.
- Build: place blocks, structures, furniture, and stairs.
- Haul: move items between sources, stockpiles, workshops, and construction sites.
- Operate: use workshops or production buildings.
- Maintain: repair, clean, restock, and recover.
- Defend: fight, flee, guard, or operate traps.

Important job rules:

- Tasks should be inspectable.
- Tasks should explain blocked state.
- Workers should not reserve impossible tasks forever.
- Player priority should matter without requiring constant micromanagement.

## Items, Materials, And Economy

The economy starts physical: mined blocks become items, items occupy positions, and workers move them.

Major resource concepts:

- Raw materials: stone, soil, ore, logs, food, water, and future special materials.
- Items: discrete physical objects on the map or in stockpiles.
- Stockpiles: zones that accept item categories and materials.
- Inventory: carried items or stored quantities where abstraction is needed.
- Production inputs and outputs: workshops consume items and create goods.

The economy should remain understandable:

- If a workshop cannot produce, the player should know which input is missing.
- If a building cannot be placed, the player should know which material is missing.
- If hauling is slow, the bottleneck should be visible through distance, priority, or worker availability.

## Building And Rooms

Building turns gathered resources into a designed settlement.

Major construction concepts:

- Constructed blocks: walls, floors, ramps, stairs, bridges, and supports.
- Furniture and fixtures: doors, beds, tables, workshops, storage, traps.
- Rooms: player-defined or detected spaces with function and quality.
- Access control: doors, restricted zones, safe paths, and future alerts.
- Structural rules: support, cave-ins, and fluid containment when those systems exist.

Rooms should matter because they organize the colony:

- Bedrooms and dormitories.
- Dining halls and meeting spaces.
- Workshops.
- Storage rooms.
- Barracks and defensive areas.
- Medical or recovery rooms in later versions.

## Production

Production gives resources purpose.

Major production stages:

- Extraction: mining, chopping, gathering, farming, or hunting.
- Refinement: ore to bars, logs to planks, raw food to meals.
- Crafting: tools, furniture, weapons, containers, trade goods.
- Construction: buildings and structures consume materials.
- Maintenance: replacement, repair, and restocking.

Production should be job-driven and spatial:

- Workshops need input items.
- Workers must haul resources.
- Output items must go somewhere.
- Poor layout should create visible inefficiency.

## Needs, Morale, And Colony Health

Needs make workers and colony layout matter.

Early needs can be minimal. Long-term needs can include:

- Food.
- Drink or water.
- Sleep.
- Safety.
- Shelter.
- Social spaces.
- Job satisfaction or morale.

The intent is not to simulate every emotion early. The intent is to create understandable pressure that rewards good planning.

Colony health can be expressed through:

- Worker availability.
- Injuries and deaths.
- Shortage alerts.
- Unsafe paths.
- Room quality.
- Production bottlenecks.
- Threat readiness.

## Threats And Combat

Threats create stakes for building and logistics.

Major threat sources:

- Hostile creatures or factions.
- Wildlife.
- Underground discoveries.
- Environmental hazards.
- Player-created failures such as floods or collapses.

Major defense tools:

- Worker combat behavior.
- Squads or guard assignments.
- Learned fighter, ranger, cleric, and specialist roles.
- Doors, walls, chokepoints, and bridges.
- Traps.
- Alerts and burrows/restricted zones.

Combat should be readable before it is deep:

- Who is fighting?
- Who is injured?
- Why did someone flee or die?
- Which path did the enemy use?
- Which defenses worked?
- Which skill, role, or ability changed the fight?

Combat depth should grow from worker progression:

- Melee skills improve holding, blocking, cleaving, and surviving.
- Ranged skills improve accuracy, range, target choice, and volleys.
- Cleric skills improve healing, poison removal, protection, and recovery.
- Advanced skills can unlock AOE attacks, mass healing, cures, and other high-impact abilities.
- Equipment and terrain should interact with skill instead of replacing it.

## Fluids And Environmental Hazards

Fluids and hazards are key to emergent colony stories, but they should arrive after world editing, pathing, and rendering are stable.

Major hazard categories:

- Water and flooding.
- Lava or damaging fluids.
- Cave-ins or support failure.
- Fire or smoke if added later.
- Poison gas or other special underground features.
- Temperature or pressure only if they add clear gameplay.

Fluid simulation should be simple enough to reason about and visual enough to plan around.

## User Interface And Player Tools

The UI should help the player plan and diagnose, not hide the simulation.

Major UI surfaces:

- Dig/build designation tools.
- Selection and inspection.
- Worker list and worker details.
- Task/job list.
- Stockpile and zone tools.
- Alerts and blocked-work messages.
- Overlay modes for access, jobs, resources, danger, and fluids.
- Debug overlays during development.

Important UI principles:

- The player should see what command mode they are in.
- Designations should preview validity.
- Blocked tasks should explain why they are blocked.
- Repeated actions should be efficient.
- Debug-only information should become player-facing only when it helps decision-making.

## Save, Load, And Persistence

Persistence is core because colony games create long-running stories.

Major persistence requirements:

- World seed and dimensions.
- Edited block data.
- Workers and their state.
- Tasks and zones.
- Items and stockpiles.
- Inventory and production state.
- Renderer caches only as optional acceleration.
- Version checks and migration stubs.

Save/load must fail loudly on incompatible formats. Silent corruption is worse than a clear error.

## Simulation And Technical Direction

Goblinoria should favor data-oriented, inspectable systems.

Technical principles:

- Keep world data chunked and bounded.
- Keep systems deterministic where practical.
- Keep worker behavior state-machine driven before adding personality.
- Prefer flat, inspectable task data over deep object hierarchies.
- Keep save format changes explicit and versioned.
- Use metrics before major optimization rewrites.
- Keep rendering correctness ahead of rendering cleverness.

## Milestone Direction

Milestones should represent playable outcomes, not just system names.

Suggested milestone track:

| Milestone | Tracker | Theme | Player-Facing Goal |
|---|---|---|---|
| [M0](https://github.com/paragonmac/Goblinoria_GD/milestone/1) | [#15](https://github.com/paragonmac/Goblinoria_GD/issues/15) | Technical Foundation | World loads, saves, renders, and can be edited safely. |
| [M1](https://github.com/paragonmac/Goblinoria_GD/milestone/2) | [#16](https://github.com/paragonmac/Goblinoria_GD/issues/16) | Core Digging Loop | Player marks terrain, workers dig it, pathing updates, world changes persist. |
| [M2](https://github.com/paragonmac/Goblinoria_GD/milestone/3) | [#17](https://github.com/paragonmac/Goblinoria_GD/issues/17) | Hauling And Stockpiles | Mined resources become items and workers move them to stockpiles. |
| [M3](https://github.com/paragonmac/Goblinoria_GD/milestone/4) | [#18](https://github.com/paragonmac/Goblinoria_GD/issues/18) | Building And Rooms | Player constructs walls, floors, doors, and useful spaces. |
| [M4](https://github.com/paragonmac/Goblinoria_GD/milestone/5) | [#19](https://github.com/paragonmac/Goblinoria_GD/issues/19) | Basic Colony Needs | Workers need food, rest, and safety enough to create pressure. |
| [M5](https://github.com/paragonmac/Goblinoria_GD/milestone/6) | [#20](https://github.com/paragonmac/Goblinoria_GD/issues/20) | Production Chains | Raw materials become crafted goods through workshops. |
| [M6](https://github.com/paragonmac/Goblinoria_GD/milestone/7) | [#21](https://github.com/paragonmac/Goblinoria_GD/issues/21) | Hazards And Fluids | Water, lava, collapses, and hazards create emergent risk. |
| [M7](https://github.com/paragonmac/Goblinoria_GD/milestone/8) | [#22](https://github.com/paragonmac/Goblinoria_GD/issues/22) | Threats And Combat | Enemies exist, workers can fight, flee, heal, shoot, and defend. |
| [M8](https://github.com/paragonmac/Goblinoria_GD/milestone/9) | [#23](https://github.com/paragonmac/Goblinoria_GD/issues/23) | Settlement Management | UI, priorities, job controls, alerts, and diagnostics make the colony manageable. |
| [M9](https://github.com/paragonmac/Goblinoria_GD/milestone/10) | [#24](https://github.com/paragonmac/Goblinoria_GD/issues/24) | World Depth | Biomes, caves, ores, and underground features create map identity. |
| [M10](https://github.com/paragonmac/Goblinoria_GD/milestone/11) | [#25](https://github.com/paragonmac/Goblinoria_GD/issues/25) | Emergent Systems | Traps, flooding, production, combat roles, learned abilities, morale, and failures interact. |

Current development should focus on M0 and M1 until the core loop is reliable.

The current planning timeline is documented in `docs/project_management.md` and mirrored in the `Goblinoria Roadmap` GitHub Project through `Start Date` and `Target Date` fields.

## First Playable Slice

The first strong slice is:

Player starts a world, designates a dig area, workers dig it, the terrain redraws correctly, workers recover from terrain changes, and the modified world persists through save/load.

This slice proves:

- Player intent.
- Task creation.
- Worker assignment.
- Pathing.
- World mutation.
- Renderer invalidation.
- Save/load.
- Basic diagnostics.

Everything else builds on this.

## Deferred Detail

The following areas need deeper design later:

- Exact worker skill model.
- Fighter, ranger, cleric, and specialist progression.
- Advanced ability design such as mass healing, cure poison, and AOE cleave attacks.
- Exact pathing costs and movement rules.
- Room detection and room quality.
- Workshop recipes.
- Item stack and container rules.
- Combat model.
- Fluid algorithm.
- Social and morale systems.
- UI wireframes.
- World-generation biome/resource tuning.

Those details should be designed when the corresponding milestone becomes active, not all at once.
