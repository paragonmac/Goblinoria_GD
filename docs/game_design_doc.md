# Voxel Colony Sim - Design Document v0.1

## Vision

Dwarf Fortress-style colony management game. Isometric 3D voxel world. Workers dig, build, and fight based on player commands. Emergent gameplay from simple systems interacting.

Core loop: Player issues commands → Workers claim and execute tasks → World changes → New possibilities emerge

---

## Architecture Philosophy

- **Data-Oriented Design (DOD)** - Data separated by access pattern, not by "what it belongs to"
- **Urban Planner, not Architect** - High-level zoning and traffic, not rigid blueprints
- **Fluidity over perfection** - Don't lock down architecture until proven
- **Prove risk first** - Milestones target novel/risky systems, not content
- **Workers are chess pieces** - Systems move them, they don't "think"

---

## Data Model

### World

```
- 256³ total blocks
- 32³ chunks (8×8×8 = 512 chunks)
- 1 byte per block (type ID)
- BlockInfo[256] static lookup table
```

```zig
const BlockType = u8;

const BlockInfo = struct {
    name: []const u8,
    solid: bool,
    hardness: u8,        // 0 = indestructible, 1-255 = mine time
    drop_type: u8,       // item type spawned when mined
    replaceable: bool,   // can stairs be placed here?
};

const CHUNK_SIZE = 32;

const Chunk = struct {
    blocks: [CHUNK_SIZE * CHUNK_SIZE * CHUNK_SIZE]BlockType,
    dirty: bool,         // needs remesh?
};
```

**Block type blacklist for stairs:** AIR, LAVA, WATER, OBSIDIAN (explicit list, not derived from hardness)

### Workers

```
- 128 max (toy version)
- u16 IDs (room to scale to 65k)
- Move X/Y freely, Z via stairs only
```

```zig
const WorkerState = enum { idle, moving, working, fighting };
const JobType = enum { miner, builder, hauler };

const Worker = struct {
    id: u16,
    position: Vec3i,
    job_type: JobType,
    state: WorkerState,
    current_task: u16,        // task index or NONE
    work_progress: f32,       // 0.0 to 1.0
    path: [8]Vec3i,           // next 8 steps
    path_length: u8,
    path_index: u8,
};
```

### Tasks

```
- 4096 max (flat array, no hierarchy)
- No "Designation" wrapper - just tasks
- Player adds/removes tasks directly
```

```zig
const TaskType = enum { mine, build_stairs };
const TaskState = enum { unclaimed, claimed, complete };

const Task = struct {
    task_type: TaskType,
    planned: bool,            // true = inactive (red), false = active (green)
    state: TaskState,
    position: Vec3i,
    assigned_worker: u16,     // worker index or NONE
};
```

### Items

```
- Spawn from mining
- Sit on ground (no hauling in milestone 1)
```

```zig
const Item = struct {
    item_type: u8,
    position: Vec3i,
};
```

---

## Systems

Run each frame in order. Each system does update + render prep in one pass (not separate).

```zig
fn game_update(world: *World, workers: []Worker, tasks: []Task, dt: f32) void {
    assign_tasks(workers, tasks);
    calculate_paths(workers, world, tasks);
    move_workers(workers, dt);
    do_work(workers, tasks, dt);
    complete_tasks(workers, tasks, world);
}
```

### 1. assign_tasks()
- Idle workers scan for nearest unclaimed task they can do
- Claim task, set worker state to moving
- O(workers × tasks) - ~500k comparisons, microseconds

### 2. calculate_paths()
- Workers with task but no valid path get A* pathfinding
- 128 block search radius limit
- If goal farther: path toward goal, recalculate when path exhausted
- Stairs required for Z movement

### 3. move_workers()
- Follow path array
- Increment path_index
- If blocked (unexpected wall), recalculate

### 4. do_work()
- Workers at task destination increment work_progress
- Progress rate based on BlockInfo.hardness

### 5. complete_tasks()
- work_progress >= 1.0 triggers completion
- Mine: destroy block, spawn item
- Build stairs: replace block with stair
- Task marked complete, worker goes idle

---

## Pathfinding

```
- A* with sparse visited set (HashMap)
- Search radius: 128 blocks max
- Heuristic: Manhattan distance
- Cost: 1 per move (uniform, expand later)
- Z movement: stairs only
- Blocked path: ignore until worker hits wall, then recalculate
```

Path stored on worker (8 steps). When exhausted or blocked, recalculate.

Future expansion: Octree for long-range queries (not milestone 1).

---

## Timing

```
- Fixed timestep: 60hz (DT = 1/60 ≈ 0.0167)
- Fallback: 30hz (DT = 1/30 ≈ 0.0333)
- Deterministic simulation within each mode
```

```zig
const TARGET_FPS = 60;
const DT: f32 = 1.0 / @as(f32, TARGET_FPS);
```

---

## Asset Loading

Non-blocking. Never hitch.

```zig
const AssetState = enum { not_loaded, loading, loaded };

const Asset = struct {
    state: AssetState,
    data: ?*AssetData,
};

fn get_texture(asset_id: u16) *Texture {
    const asset = &assets[asset_id];
    
    if (asset.state == .loaded) return asset.data.texture;
    
    if (asset.state == .not_loaded) {
        queue_load(asset_id);  // non-blocking
        asset.state = .loading;
    }
    
    return &default_white_texture;  // fallback
}
```

**Default assets (always in memory):**
- White texture (fallback block)
- Magenta texture (debug "missing")
- Silent audio buffer

---

## Threading Strategy (Future)

Not for milestone 1. When needed:

**Thread by element, not by step:**

```
GOOD:
  Thread 1: update+render workers 0-63
  Thread 2: update+render workers 64-127

BAD:
  Thread 1: update all workers
  Thread 2: render all workers (waits on thread 1)
```

Keeps data in cache, avoids dependencies between threads.

---

## Toolchain

```
- Language: Zig
- Graphics: Raylib (via raylib-zig)
- Profiler: Tracy
- IDE: CLion + ZigBrains plugin
- OS: CachyOS (Linux)
- Debugger: CLion (wraps gdb/lldb)
```

---

# Milestones

## Milestone 1: Core Loop (Current)

**Goal:** Prove the risky/novel systems work.

**Scope:**
- [ ] World: chunks, blocks, get/set
- [ ] Workers: spawn, move X/Y, move Z via stairs
- [ ] Tasks: mine, build stairs
- [ ] Pathfinding: A* with stairs constraint
- [ ] Items: drop from mining (sit on ground)
- [ ] Debug render: blocks as cubes, workers as colored cubes

**NOT in scope:**
- Hauling
- Stockpiles
- Combat
- Enemies
- Fluids
- Lighting
- UI

**Success criteria:** Click area → workers dig it out → stairs let them go up/down.

---

## Milestone 2: Hauling & Stockpiles

**Goal:** Items have purpose.

**Scope:**
- [ ] Stockpile zones with material flags
- [ ] Haul task type
- [ ] Worker carrying state
- [ ] Items moved to stockpiles

**Success criteria:** Mined rocks get hauled to designated dump zones.

---

## Milestone 3: Building & Production

**Goal:** Players can construct things.

**Scope:**
- [ ] Build task (place blocks)
- [ ] Multi-block structures (prefabs)
- [ ] Resource requirements (need rocks to build wall)
- [ ] Basic production chains

**Success criteria:** Workers haul rocks to build site, construct walls.

---

## Milestone 4: Combat

**Goal:** Threats exist.

**Scope:**
- [ ] Enemy spawning
- [ ] Combat state for workers
- [ ] Damage, health, death
- [ ] Basic AI for enemies

**Success criteria:** Enemies attack, workers fight back or flee.

---

## Milestone 5: Fluids

**Goal:** Environmental hazards.

**Scope:**
- [ ] Fluid simulation (block-based)
- [ ] Lava, water
- [ ] Damage from fluids
- [ ] Flooding mechanics

**Success criteria:** Dig into water pocket, it floods tunnels.

---

## Milestone 6: Polish & Systems Interaction

**Goal:** Emergent gameplay.

**Scope:**
- [ ] Traps
- [ ] Doors
- [ ] Pressure plates / triggers
- [ ] Systems interacting (flood trap kills enemies)

**Success criteria:** Player builds trap system that kills invaders with lava.

---

## Future Milestones (TBD)

- Lighting
- Proper UI
- Save/Load
- Larger worlds
- Z-level visualization
- Worker attributes/skills
- Jobs specialization
- Audio
- Music

---

# Open Questions

1. **Intra-system dependencies:** If worker A blocks worker B, how do we handle within move_workers()?

2. **Chunk boundaries:** Worker pathing across chunk boundaries - any special handling?

3. **Memory budget:** How many items can exist? Cap? Pool?

4. **Render strategy:** Isometric 2D sprites or actual 3D voxels?

---

# References

- Casey Muratori - Handmade Hero (architecture, DOD)
- Casey Muratori - "The Big OOPs" (OOP critique)
- Mike Acton - CppCon 2014 "Data-Oriented Design"
- Andrew Kelley - Zig talks
- Dwarf Fortress, Gnomoria (gameplay reference)

---

*Document version: 0.1*
*Last updated: Session 1*
