# ADR-015: Asynchronous Visibility

Status: Accepted
Date: 2026-09-05

## Decision

Favor frame responsiveness over immediate visibility. Compute existing padded frustum eligibility on one dedicated worker using exclusively owned value snapshots. Keep one running job, one replaceable pending request, one result slot and one main-thread application batch. No scene objects, terrain access, recorder state or gameplay mutations cross the worker boundary.

Soft camera changes do not cancel running work. Adopt monotonically newer completions within the current renderer epoch, even when the camera has moved again, and finish their application before taking another soft result. World/renderer/streaming resets, level changes, camera identity changes and viewport identity/size changes invalidate all older work and partial batches without rolling back actual state. Cancellation is cooperative at 256-candidate boundaries. Only teardown joins the worker.

The main-thread pump runs once per Main frame, including menus/loading, with a shared cooperative 1 ms/2048-step allowance for application and thread-start-failure fallback. Stable coordinate slots bound reconciliation without copying whole dictionaries. Effective eligibility includes missing/empty mesh coordinates and is distinct from actual shown nodes. All mesh-install/hide/removal paths maintain shown state. Additions precede removals; partial views and latency remain explicit diagnostics.

## Amendment (2026-10-05): delta application

F1 captures measured 170-210 ms visibility lag during fast camera pans: chunks were loaded and meshed but remained hidden while each accepted view scanned roughly 1.7k-7k accepted and eligible coordinates under the 1 ms pump (about 750 steps per frame), taking 5-14 frames. Typical frame-to-frame changes are only a few hundred coordinates. Each request now carries the most recently adopted `base_sequence`. The worker retains the accepted dictionaries from the last four published results in the current epoch and computes entering/exiting coordinates off the scheduler mutex. The main thread applies additions before removals, one coordinate per pump step. It uses a delta only when the result's base matches the last fully applied sequence in the same epoch and eligibility is clean, with no pending reconcile or initial-node scan; otherwise the existing full scan applies. Thread-start failure deliberately keeps the incremental kernel and full-scan application, so it never performs an unbudgeted diff on the main thread. The worker does not mutate published accepted sets after handoff, and the history is discarded on epoch invalidation.

## Consequences

Visibility can lag during motion and cached level changes. Existing terrain/mesh loading remains, but visibility introduces no new loading-screen gate. Broad cave coverage, padding, save formats and normal streaming budgets are unchanged. Startup failure falls back to the same incremental kernel, never a full synchronous scan. Budgeting cannot bound every engine call, allocation or operating-system delay; this is not a zero-stutter guarantee.

Worker completion/cancellation accounting is distinct from main-thread pump cost and request-to-applied age. Capture epochs exclude earlier recordings without changing scheduling. Headless kernel-oracle, mailbox, partial-application, lifecycle and legacy validators establish correctness, not GPU/visual acceptance or controlled performance improvement.

## Guardrails

- `render_zone_cull_scheduler.gd` and `render_zone_cull_kernel.gd`: value-only ownership and bounded scheduling.
- `world_renderer_visibility.gd` and `stable_coord_slots.gd`: effective/shown state and budgeted reconciliation.
- `validate_render_zone_cull_scheduler.gd` and `validate_async_visibility.gd`: thread barriers, stale results, lifecycle and frame-pump contracts.
- [Measurement interpretation](../gameplay_profiling.md).

Follow-up (2026-10-05): requests are submitted every frame while the camera moves (a newer request replaces the pending one). With publications every ~23 ms, the four-entry history evicted the main thread's base before its next job finished, so 105 of 169 applications fell back to full scans. A first fix pinned the submit-time base, but with a request every frame some job is always in flight with a base older than the next adopted result (481 of 606 applications were still full). The main thread now reports each adoption (`note_adopted`); the worker pins that result and diffs every completing job against it, and the main thread accepts a delta when `delta_base_sequence` equals the last applied sequence. The kernel tests normalized planes (identical results to FrustumCuller, ~40% faster). Symmetric speed-scaled padding was tried and rejected (6 chunks grew the accepted set to ~9.9k); instead a job may carry `lead_planes`, the frustum translated by the smoothed pan velocity times 0.15 s (capped at 48 units), and a chunk is accepted when it is inside either frustum. Base padding is unchanged.
Review hardening (2026-10-09): a one-frame camera move above 64 units (Locate, load, level change) is a teleport and resets the smoothed lead instead of seeding it; pan speed is clamped to the speed the 48-unit lead can represent; stream reset clears the lead. The render-zone key includes whether a lead is active, so the view is re-requested once the lead decays to zero and the look-ahead chunks are trimmed at rest. `lead_planes` are validated at submit like `planes`.

Debug comparison modes (2026-10-09, debug builds via the F7 Rendering panel; runtime only): `area` submits the render box with no frustum planes so every meshed chunk in the box is shown and Godot's own culling skips off-screen ones; `sync` culls and applies the whole view on the main thread in the request call, unbudgeted. Both exist to measure this ADR's async design against its alternatives and are not shipping modes. A depth limit (top N chunk layers), freeze, look-ahead on/off and lead seconds, and refresh cadence are also switchable. A void meter (on-screen chunks in the top two render layers that have geometry but are hidden) samples at 20 Hz while the panel is open and is included in F1 visibility snapshots.
