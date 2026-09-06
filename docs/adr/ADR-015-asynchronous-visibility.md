# ADR-015: Asynchronous Visibility

Status: Accepted
Date: 2026-09-05

## Decision

Favor frame responsiveness over immediate visibility. Compute existing padded frustum eligibility on one dedicated worker using exclusively owned value snapshots. Keep one running job, one replaceable pending request, one result slot and one main-thread application batch. No scene objects, terrain access, recorder state or gameplay mutations cross the worker boundary.

Soft camera changes do not cancel running work. Adopt monotonically newer completions within the current renderer epoch, even when the camera has moved again, and finish their application before taking another soft result. World/renderer/streaming resets, level changes, camera identity changes and viewport identity/size changes invalidate all older work and partial batches without rolling back actual state. Cancellation is cooperative at 256-candidate boundaries. Only teardown joins the worker.

The main-thread pump runs once per Main frame, including menus/loading, with a shared cooperative 1 ms/256-coordinate allowance for application and thread-start-failure fallback. Stable coordinate slots bound reconciliation without copying whole dictionaries. Effective eligibility includes missing/empty mesh coordinates and is distinct from actual shown nodes. All mesh-install/hide/removal paths maintain shown state. Additions precede removals; partial views and latency remain explicit diagnostics.

## Consequences

Visibility can lag during motion and cached level changes. Existing terrain/mesh loading remains, but visibility introduces no new loading-screen gate. Broad cave coverage, padding, save formats and normal streaming budgets are unchanged. Startup failure falls back to the same incremental kernel, never a full synchronous scan. Budgeting cannot bound every engine call, allocation or operating-system delay; this is not a zero-stutter guarantee.

Worker completion/cancellation accounting is distinct from main-thread pump cost and request-to-applied age. Capture epochs exclude earlier recordings without changing scheduling. Headless kernel-oracle, mailbox, partial-application, lifecycle and legacy validators establish correctness, not GPU/visual acceptance or controlled performance improvement.

## Guardrails

- `render_zone_cull_scheduler.gd` and `render_zone_cull_kernel.gd`: value-only ownership and bounded scheduling.
- `world_renderer_visibility.gd` and `stable_coord_slots.gd`: effective/shown state and budgeted reconciliation.
- `validate_render_zone_cull_scheduler.gd` and `validate_async_visibility.gd`: thread barriers, stale results, lifecycle and frame-pump contracts.
- [Measurement interpretation](../gameplay_profiling.md).
