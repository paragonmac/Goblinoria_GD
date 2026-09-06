# ADR-006: Selection Coordinate Model

Status: Accepted
Date: 2026-07-05

## Context

Selection and task overlays became confusing when visual selection drifted toward screen-space behavior. The player needs selected blocks, drag previews, and queued tasks to map to stable world block coordinates even as the camera angle changes.

## Decision

Click selection uses voxel raycast results. Drag selection stores the starting screen point, resolves a fixed world Y plane from the initial hit, projects both drag endpoints onto that plane, then rounds the resulting world X/Z bounds into block coordinates.

Selection previews and task overlays must be world-space block overlays, not screen-space rectangles. Place mode intentionally offsets the selected Y level by one block so the task targets the empty block above the clicked surface.

Raycast selection respects `top_render_y`; hidden blocks above the current render level should not be selectable.

World selection only starts from mouse presses that the GUI has not consumed. A release consumed by the GUI cancels an active world drag rather than committing a selection behind a panel. Erase targeting and previews include stockpile cells, including the cell above a clicked floor.

Right-click opens a context menu on release; a right gesture that moves at least six viewport pixels becomes a camera pan for the rest of that gesture. Right-press during left selection cancels it without opening a menu. GUI-origin and popup-dismissal gestures cannot acquire world input. While the context popup owns input, camera and selection controls are suspended but simulation and streaming continue.

Context tool entries select the existing active mode; they do not designate the opening cell. Immediate actions capture a visible hit with a non-generating raycast. Inspect uses the hit; pending-task cancellation and stockpile removal independently prefer the hit, then the cell above. These actions revalidate captured identities before changing state, never silently retarget, and leave the active mode unchanged. Inspection displays a closable cell snapshot rather than replacing hover state.

## Consequences

- Changing camera angle should not detach the selection preview from the world grid.
- A drag selection stays on the Y plane chosen when the drag started.
- Place, dig, up-stairs, down-stairs, and erase can share the same coordinate path while applying mode-specific validation.
- Selection traces are the source of truth for requested, queued, and rejected block coordinates.

## Guardrails

- Code pointer: `scripts/main_selection_controller.gd`, `_get_drag_plane_y()`, `_get_drag_rect()`, `_enqueue_rect_tasks()`, and `_handle_click()`.
- Code pointer: `scripts/main_camera_controller.gd`, `screen_to_plane()`.
- Code pointer: `scripts/world_raycaster.gd`, `raycast_block()`.
- Runtime trace: `selection_committed` logs mode, bounds, requested count, queued count, rejected count, queued positions, and rejection reasons.
