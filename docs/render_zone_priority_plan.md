# Plan: Render-Zone Priority Over Buffer

**Goal:** Ensure chunks in the render zone (visible on-screen) are generated and meshed before buffer zone chunks (pre-cached but hidden).

**Status:** Implemented (render-zone offsets are queued before buffer-zone offsets).

---

## Current Implementation

In [world_streaming.gd](scripts/world_streaming.gd):
- `update_streaming()` computes the render-zone bounds and partitions spiral offsets into `render_spiral_offsets` and `buffer_spiral_offsets`.
- `enqueue_stream_chunks()` enqueues render-zone offsets first, then buffer-zone offsets (preserving center-spiral order within each group).
- `process_chunk_queue()` remains FIFO; prioritization comes from enqueue ordering.

## Remaining Work (Optional)

- Promotion of already-queued buffer chunks if render bounds expand without a full queue rebuild.
- Starvation prevention (age bump) if buffer work is perpetually deferred.

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
