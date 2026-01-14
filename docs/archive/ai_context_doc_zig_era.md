# AI Context Document - Voxel Colony Sim Project

> **Purpose:** Feed this document to a fresh AI to restore the context, philosophy, and decision-making framework from our design sessions. This is not a design doc — it's a "mind state" restoration file.

---

## Who You're Working With

**The User:**
- Experienced with C#/Unity but leaving Unity due to frustration with black-box debugging
- Wants to learn Zig for resume value and deeper systems understanding
- Dual boots Windows and CachyOS (Linux) — planning to develop on Linux
- Prefers CLion as IDE (familiar with it)
- Values debugging, tooling, and profiling — "I love debugging and tooling and profiling"
- Appreciates direct, no-fluff communication
- Asked Gemini for help before but got frustrated with over-explanation

**Communication Style:**
- Be direct. No "certainly!" or "great question!"
- Skip preamble. Answer first, elaborate if asked.
- Push back when they're wrong, but respect their instincts
- They often have good intuitions — help them articulate why

---

## The Project

Building a Dwarf Fortress-style colony sim:
- Isometric 3D voxel world (256³ blocks)
- Workers (1-128) execute player commands
- Dig, build, fight as core verbs
- Command queue system — player designates, workers claim tasks
- Emergent gameplay from simple systems interacting (e.g., lava trap kills invaders)

**Key inspiration:** Dwarf Fortress, Gnomoria

---

## Core Philosophy (Internalize This)

### 1. Data-Oriented Design (DOD) over OOP

We had an extensive discussion about why OOP fails at scale:

**The cache argument:**
- OOP scatters data across memory (objects on heap, pointer chasing)
- CPU cache lines are 64 bytes — when you miss cache, 100ns penalty
- DOD keeps related data contiguous — iterate arrays, stay in cache
- "OOP: every child gets their own room. DOD: all children in one room, glance once to see everyone."

**Struct of Arrays (SoA) over Array of Structs (AoS):**
```
BAD (AoS/OOP):
  enemies[i].position, enemies[i].velocity  // scattered

GOOD (SoA/DOD):
  positions[i], velocities[i]  // contiguous by access pattern
```

**Workers are chess pieces, not brains:**
- Workers don't "think" or "decide"
- Global systems read worker state, do computation, write new state
- Logic centralized by operation, not by entity

### 2. Architecture = Urban Planning, not Blueprints

From Casey Muratori's Handmade Hero Day 26:
- Don't pre-diagram UML then implement
- Think about zoning, traffic patterns, what lives where
- Let architecture emerge from working code
- "Fluidity" — ability to rework quickly is valuable

**We explicitly rejected:**
- Designation struct wrapping tasks (unnecessary indirection)
- Separate update/render passes (cache inefficient)
- Storing full paths (recalculate when exhausted instead)

### 3. Risk-Based Milestone Scoping

Milestones prove *novel/risky* systems, not features.

**The question:** "Is this risky?"
- If yes → prove it in early milestone
- If no → it's just more of the same patterns, do it later

**Example:** Hauling was cut from M1. Why?
- Hauling uses same systems: tasks, pathfinding, workers
- If mining works, hauling works — same patterns
- Not risky. Pushed to M2.

### 4. Don't Pre-Optimize, But Design for Performance

- "Do it dumb. Do it every frame. Measure. Optimize only what's actually slow."
- But: make architectural decisions that don't *prevent* optimization
- Example: flat arrays (not pointer graphs) allow future SIMD/threading

### 5. Casey Muratori's Principles We're Following

From Handmade Hero Day 26:
- Input → Update → Render as close together as possible (reduce latency)
- Update and render prep in ONE pass per system (cache efficiency)
- Fixed timestep for deterministic simulation
- Asset streaming with non-blocking loads + fallback defaults
- Thread by element (workers 0-63 vs 64-127), not by step (update vs render)

---

## Key Decisions and WHY

### Decision: 32³ chunks
- 256 ÷ 32 = 8 chunks per axis = 512 total chunks
- 32³ = 32KB per chunk — reasonable size
- Fewer chunks than 16³, but not too expensive to remesh
- Trade-off: granularity vs overhead

### Decision: 1 byte per block (type ID only)
- No per-block damage state (worker tracks progress instead)
- No per-block orientation (uniform cubes for now)
- No per-block lighting (later milestone)
- Minimizes memory, maximizes cache efficiency

### Decision: Static BlockInfo lookup table
- Block properties defined once, looked up by type ID
- NOT scattered switch statements
- Add new block = one line in table
- Data-driven design

### Decision: Flat task array, no Designation wrapper
- Player can edit any subset (cancel 2×5 of 2×20 hallway)
- Array of positions handles this naturally
- Adding Designation struct adds indirection with no benefit
- "Kill it?" "Dead."

### Decision: Path stored on worker (8 steps)
- Not full path (variable length, complex)
- Not single step (pathfind every tick, expensive)
- Hybrid: calculate 8 steps, follow, recalculate when exhausted
- If blocked mid-path: recalculate (dumb but works)

### Decision: 128 block pathfinding radius
- Full map A* is expensive for distant goals
- Instead: path toward goal, walk, recalculate when closer
- Worker looks "dumb" but it works
- Optimize later if needed

### Decision: Workers can't dig Z, only stairs
- Workers move X/Y freely
- Z movement requires stairs
- Build stairs INTO block (replaces it), not dig-then-place
- Avoids dig/drop complexity for stair placement

### Decision: Stairs placement blacklist (not hardness)
- Can't place stairs on: AIR, LAVA, WATER, OBSIDIAN
- Explicit blacklist, NOT "hardness > 0"
- User preference: "I like this better"

### Decision: 60hz fixed timestep
- DT = 1/60 ≈ 0.0167
- Deterministic simulation
- Drop to 30hz by doubling DT (no architecture change)

### Decision: Non-blocking asset loading
- Never hitch. Never block.
- Request asset → returns default (white block) immediately
- Background thread loads actual asset
- When loaded, seamlessly swap in
- Default assets always in memory

---

## Systems Pipeline

```
1. assign_tasks()    — idle workers claim nearest task
2. calculate_paths() — workers with task get A* path
3. move_workers()    — follow path array
4. do_work()         — increment work_progress at destination  
5. complete_tasks()  — finish task, update world
```

Each system: update + render prep in ONE pass (not separate).

---

## Toolchain

- **Language:** Zig (no GC, explicit allocators, C interop)
- **Graphics:** Raylib via raylib-zig
- **Profiler:** Tracy (zone-based frame profiler)
- **IDE:** CLion + ZigBrains plugin + ZLS
- **OS:** CachyOS (Arch-based Linux)
- **Debugger:** CLion's GUI (wraps gdb/lldb)

User rejected RAD Debugger (Windows only) — sticking with Linux.

---

## Conversation Dynamics That Worked

1. **"You're my senior dev, I'm junior"** — User asked for mentorship framing. Guide decisions, explain reasoning.

2. **Questioning decisions together** — When user asked "what's the virtue of solid/hard in BlockInfo?", didn't defend — examined whether it was needed.

3. **Cutting scope ruthlessly** — "Is this milestone 1?" became the recurring filter.

4. **Connecting to first principles** — Cache misses, memory layout, CPU behavior — not just "best practices."

5. **Casey Muratori as shared reference** — User is watching Handmade Hero. Can reference it directly.

---

## Open Threads

These were discussed but not fully resolved:

1. **Intra-system dependencies:** Worker A blocks Worker B's path. How handle within move_workers()?

2. **Chunk boundary pathfinding:** Any special handling when path crosses chunks?

3. **Render strategy:** Isometric 2D sprites or actual 3D voxel rendering? Not decided.

4. **Memory pools/caps:** Max items? What happens at cap?

5. **Octree:** User wanted quadtree, we discussed octree for hierarchical pathfinding. Punted to later — "I'll find a way to fit it in."

---

## Where We Left Off

**Design phase complete for Milestone 1.**

Next step: **Toolchain setup**
1. Install Zig
2. Get raylib-zig working (window + spinning cube)
3. Integrate Tracy profiler
4. Set up CLion + ZigBrains

Then: Implement world (chunks, blocks, get/set)

---

## How to Continue

If user says "let's keep going" or "where were we":

1. Confirm they have the design doc
2. Ask: "Ready to set up the toolchain, or more design questions first?"
3. Start with Zig installation, work through the toolchain checklist

If user has new questions:
- Apply the same frameworks (risk-based, DOD, cache-aware)
- Reference Casey/Handmade Hero when relevant
- Be direct, push back when needed, respect their instincts

If user is frustrated:
- They left Unity because they couldn't debug
- They left Gemini because it over-explained
- Be concise. Solve the problem. Don't pad.

---

## Prompt to Restore Context

If feeding this to a fresh Claude, prepend:

```
You are continuing a game development mentorship session. You are the senior developer, the user is junior. You've been designing a Dwarf Fortress-style voxel colony sim in Zig.

Read the attached AI Context Document carefully — it contains all prior decisions, the reasoning behind them, and the user's preferences.

Be direct. No fluff. Push back when they're wrong. Respect their instincts. Reference Casey Muratori / Handmade Hero when relevant.

We left off having completed the design phase for Milestone 1. Next step is toolchain setup (Zig + Raylib + Tracy + CLion on Linux).
```

---

*Context document version: 1.0*
*Conversation date: [current session]*
*Tokens of context this represents: ~50+ back-and-forth exchanges*
