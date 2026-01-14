# Design Philosophy

Toolchain-agnostic design intent for the project. The original Zig-era context has been archived in `docs/archive/ai_context_doc_zig_era.md`.

## Project Snapshot
- Dwarf Fortress-style colony sim.
- Isometric-ish 3D voxel world with workers executing player tasks.
- Core verbs: dig, build, fight.

## Core Philosophy
- **Data-oriented design over OOP:** keep related data contiguous; minimize pointer chasing.
- **Workers are chess pieces:** systems move workers; workers do not "think."
- **Architecture as urban planning:** avoid rigid blueprints; let structure emerge from working code.
- **Risk-based milestones:** prove novel/risky systems early; defer routine features.
- **Optimize later, but keep doors open:** measure first; avoid architectural dead ends.
- **Single-pass systems:** update + render prep together for cache efficiency.
- **Deterministic sim:** fixed timestep; non-blocking asset loading is a long-term goal.

## Key Design Decisions (Carry Forward)
- **Chunked world storage** with a 1-byte block ID and a static block registry table.
- **Flat task array** (no designation wrapper).
- **Path caching on worker** (short segments, recompute when exhausted/blocked).
- **Pathfinding radius cap** (128 blocks) for long-distance targets.
- **Z movement requires stairs;** stairs replace blocks instead of dig-then-place.
- **Stairs placement blacklist:** AIR, LAVA, WATER, OBSIDIAN.
- **Fixed timestep:** 60 Hz baseline.

## Current Divergences / Open Questions
- **Chunk size:** current Godot prototype uses `World.CHUNK_SIZE = 8` (256^3 total via 32 chunks per axis). Treat as authoritative unless explicitly changed.
- **Path caching:** design calls for short path segments; current pathfinder returns full paths.
