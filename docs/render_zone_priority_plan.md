# Plan: Render-Zone Priority Over Buffer

**Goal:** Ensure chunks in the render zone (visible on-screen) are generated and meshed before buffer zone chunks (pre-cached but hidden).

---

## Current Behavior

In [world_streaming.gd](scripts/world_streaming.gd):
- `chunk_build_queue` is a single FIFO array
- `enqueue_stream_chunks()` adds chunks in center-spiral order across the entire stream bounds (render + buffer combined)
- No distinction between render zone and buffer zone when queuing
- Buffer zone chunks can block render zone chunks from processing

The render zone bounds are computed in `update_streaming()` (lines 162-176) but only used for visibility toggling in the renderer, not for queue prioritization.

---

## Proposed Changes

### 1. Add render zone bounds to streaming state

Track the current render zone bounds alongside stream bounds:

```gdscript
var render_min_cx: int = DUMMY_INT
var render_max_cx: int = -DUMMY_INT
var render_min_cz: int = DUMMY_INT
var render_max_cz: int = -DUMMY_INT
```

### 2. Split queue into two tiers

Replace single queue with priority-aware structure:

```gdscript
var chunk_build_queue_render: Array = []   # High priority (render zone)
var chunk_build_queue_buffer: Array = []   # Low priority (buffer zone)
var chunk_build_set: Dictionary = {}       # Keep unified for dedup
```

### 3. Modify `enqueue_stream_chunks()` to classify chunks

When iterating the spiral, check if each chunk coord falls within render zone bounds:

```gdscript
func _is_in_render_zone(coord: Vector3i) -> bool:
    return coord.x >= render_min_cx and coord.x <= render_max_cx \
       and coord.z >= render_min_cz and coord.z <= render_max_cz \
       and coord.y >= stream_min_y and coord.y <= stream_max_y
```

Enqueue to appropriate tier:
```gdscript
if _is_in_render_zone(key):
    chunk_build_queue_render.append(key)
else:
    chunk_build_queue_buffer.append(key)
```

### 4. Modify `process_chunk_queue()` to drain render first

```gdscript
func process_chunk_queue() -> void:
    # ... existing checks ...
    var build_count: int = min(chunks_per_frame,
        chunk_build_queue_render.size() + chunk_build_queue_buffer.size())
    for _i in range(build_count):
        var key: Vector3i
        if chunk_build_queue_render.size() > 0:
            key = chunk_build_queue_render.pop_front()
        elif chunk_build_queue_buffer.size() > 0:
            key = chunk_build_queue_buffer.pop_front()
        else:
            break
        chunk_build_set.erase(key)
        # ... rest of processing ...
```

### 5. Update queue clearing/reset

In `reset_state()` and when anchor changes:
```gdscript
chunk_build_queue_render.clear()
chunk_build_queue_buffer.clear()
chunk_build_set.clear()
```

### 6. Update `_unload_distant_chunks()`

Erase from both queues when unloading (or just rely on set check):
```gdscript
if chunk_build_set.erase(coord):
    chunk_build_queue_render.erase(coord)
    chunk_build_queue_buffer.erase(coord)
```

---

## Files to Modify

| File | Changes |
|------|---------|
| [world_streaming.gd](scripts/world_streaming.gd) | Add render zone tracking, split queues, modify enqueue/process logic |

---

## Testing

1. **Visual check:** Pan camera quickly - render zone should fill before buffer
2. **Debug logging:** Add optional print to show which tier each chunk comes from
3. **HUD stats:** Could expose `queue_render` vs `queue_buffer` counts if helpful

---

## Edge Cases

- **Anchor change:** Both queues cleared and rebuilt - no special handling needed
- **Render zone expansion:** New render-zone chunks already in buffer queue should ideally be promoted. For simplicity, queue reset on bound change handles this.
- **Spiral order preserved:** Each tier maintains center-spiral order independently

---

## Not In Scope

- Starvation prevention (age bump) - separate milestone item
- Neighbor-aware meshing - separate milestone item
