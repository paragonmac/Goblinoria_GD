# ADR-006: Selection Coordinate Model

Status: Accepted
Date: 2026-07-05

## Context

Selection and task overlays became confusing when visual selection drifted toward screen-space behavior. The player needs selected blocks, drag previews, and queued tasks to map to stable world block coordinates even as the camera angle changes.

## Decision

Click selection uses voxel raycast results. Drag selection stores the starting screen point, resolves a fixed world Y plane from the initial hit, projects both drag endpoints onto that plane, then rounds the resulting world X/Z bounds into block coordinates.

Selection previews and task overlays must be world-space block overlays, not screen-space rectangles. Place mode intentionally offsets the selected Y level by one block so the task targets the empty block above the clicked surface.

Raycast selection respects `top_render_y`; hidden blocks above the current render level should not be selectable.

## Consequences

- Changing camera angle should not detach the selection preview from the world grid.
- A drag selection stays on the Y plane chosen when the drag started.
- Place, dig, and stairs can share the same coordinate path while applying mode-specific validation.
- Selection traces are the source of truth for requested, queued, and rejected block coordinates.

## Guardrails

- Code pointer: `scripts/main_selection_controller.gd`, `_get_drag_plane_y()`, `_get_drag_rect()`, `_enqueue_rect_tasks()`, and `_handle_click()`.
- Code pointer: `scripts/main_camera_controller.gd`, `screen_to_plane()`.
- Code pointer: `scripts/world_raycaster.gd`, `raycast_block()`.
- Runtime trace: `selection_committed` logs mode, bounds, requested count, queued count, rejected count, queued positions, and rejection reasons.
