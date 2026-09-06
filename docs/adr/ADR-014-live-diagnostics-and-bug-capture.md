# ADR-014: Live Diagnostics And Bug Capture

Status: Accepted
Date: 2026-09-05

## Context

A screenshot of missing cave faces shows the symptom but cannot identify missing block data, stale meshes, render-zone rejection, or shader eligibility. Worker problems likewise need the real assignment and reservation decisions, not a second simulation reconstructed during inspection.

## Decision

Main owns a development-only, opt-in diagnostics controller. A UI-independent service stores bounded main-thread observations; a snapshot adapter reads existing records. A loopback TCP transport exposes a fixed NDJSON command allowlist to a PowerShell client. Each activation has fresh credentials. No diagnostic command changes gameplay, drives the camera, invokes arbitrary methods, or loads/saves worlds.

World epochs change at initialization and successful load commit, even when the same World node is reused. World queries require an epoch; screen queries require the exact view fingerprint. Paged collection cursors carry membership revisions. Loading state prevents inspecting partially reconstructed worlds. Failed precommit loads preserve identity. Main services requests independently of gameplay-only early returns.

Decisions are recorded at actual assignment, accessibility, path-result, movement, hauling, and reservation branches. Inspection never expires exclusions, reruns routes, searches destinations, generates chunks, applies caches, or creates meshes. Last-recorded reasons include age and invalidation; they are not a freshly calculated verdict. Background jobs do not access the journal. Engine warnings/errors enter a separate locked bounded queue and are attributed to the world at main-thread drain, explicitly distinguished from callback time.

F1 and a menu action request a bounded evidence bundle. One-off capture does not activate observation or the performance recorder. Snapshot state is read before drawing and image data after drawing; interrupted world/view/frame identities are disclosed. Only immutable owned copies reach the file writer thread. An incomplete manifest precedes output; completion is written last. Normal exit waits for the sole writer, but unexpected termination may leave partial files.

## Bounds And Measurement Limits

- Event history: 30 seconds, 4,096 rows, or 2 MiB encoded data. Latest decisions: 4,096 records or 2 MiB encoded data. Individual payloads: 16 KiB. Evictions and truncation are explicit. These are payload limits, not exact heap measurements.
- Transport: loopback only, two clients, 8 KiB requests, 256 KiB replies, eight queued requests, ten queries per second, one dispatched query per frame, and 64 KiB per-frame read/write budgets. Five-second deadlines include unfinished requests and replies. Bounded work is not a hard real-time latency guarantee.
- Capture: one in flight, five-second cooldown, 2 MiB structured snapshot, eight-megapixel image, 64 MiB bundle, 512 MiB retained-directory quota. Quota checking reserves a full bundle and never deletes old reports. Directory enumeration is bounded and refuses links.
- Capture copies seven chunks at most. Nearby entity search examines at most 512 entries per kind, retaining 32 nearby subjects plus referenced tasks. Omissions are reported. There are no per-frame entity or terrain scans.
- Image readback, diagnostic hooks, serialization, and I/O have overhead. Collection/service totals and capture readback/write durations are exposed. Async costs are not main-thread frame costs; eligibility is not proof of GPU pixels. A blocked main thread cannot serve queries.

## Consequences And Guardrails

The bridge works without an attached editor or plugin. Local authentication prevents accidental cross-session access, not access by other processes under the same user. Reports may contain game state, screenshot UI, machine metadata, and error paths; review them before sharing. Tokens, complete saves, arbitrary files, and whole performance recordings are not included automatically.

The profiler remains independent. Active recordings receive a bug-capture marker and bundles reference their path. GitHub remains the active-work tracker; reports are evidence, not a second backlog. No save/cache formats or scene resources change.

Headless guards: `validate_live_diagnostics.gd`, `validate_live_decisions.gd`, and `validate_live_diagnostics_transport.gd`, alongside existing validators. Graphical usability, screenshot fidelity, and ordinary-play overhead require separate approval. See [Live diagnostics](../live_diagnostics.md) for controls, protocol examples, and failure interpretation.
