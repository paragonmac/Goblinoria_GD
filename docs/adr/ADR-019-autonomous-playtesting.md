# ADR-019: Autonomous Game Playtesting

Status: Accepted
Date: 2026-09-12

## Context

Headless contracts and user-supplied screenshots leave a gap between input,
rendered previews, queued jobs, and completed terrain. Development needs an
agent-operated graphical game with observable state and repeatable setup.

## Decision

A separate debug bootstrap runs the production Main scene in a dedicated process.
The launcher sets child-only application-data directories beneath `.playtest/`;
the bootstrap verifies `user://` before constructing the world. Reset starts a
fresh process. Existing sessions and saves are never used as fixture storage.

ADR-014's diagnostics service remains read-only. A separately authenticated local
control listener reuses its bounded transport implementation. Only the bootstrap
creates the control service. Ordinary game startup exposes no control endpoint.

The launcher writes an optional startup override inside isolated `user://` to
configure the Windows no-focus flag before window creation. Background acceptance
reads Windows foreground process ownership; a cached Godot focus flag alone is
insufficient. No desktop input injection is used.

Main and its controllers share a polling input adapter. Native sessions delegate
to Godot Input and viewport queries. The test driver owns synthetic key/button
state and pointer coordinates, then sends events through ordinary viewport input
dispatch. It never calls the designation functions as a substitute for clicks.
Development-only input guards also cover embedded popup windows, which may consume
events before Main. Physical input cancels automation; synthetic input retains
normal GUI ownership and propagation.

The canonical world update sequence accepts an explicit simulation gate. Paused
sessions continue generation-result application, renderer maintenance and overlay
refresh while assignments, workers, tasks and accessibility scheduling remain
stopped. Explicit test steps use 1/60 second per process frame. Async jobs remain
enabled; this is controlled advancement, not a deterministic replay guarantee.

Actions carry session/world/view identities and ordered sequence numbers. Receipts
allow safe retries after lost responses. Cancellation releases held inputs after
canceling gesture ownership so synthetic releases cannot designate terrain.

Observations pair pre-draw state with post-draw pixels and wait for relevant mesh
revisions and view application. Missing images, timeouts and incoherent boundaries
are explicit. Reports distinguish harness operation from gameplay findings.

## Consequences

- A reproducible fixture uses the real renderer, workers, task system and UI.
- Fixture terrain preparation is direct; subsequent gameplay uses normal input.
- Simulation steps, rendered frames and elapsed wall time have separate meanings.
- The workflow does not depend on desktop cursor control or an editor plugin.
- Captures and logs remain local, bounded and ignored by Git.
- Existing stair defects are evidence for subsequent fixes, not harness changes.
- V8 saves and normal gameplay behavior retain their existing contracts.

See [Autonomous playtesting](../autonomous_playtesting.md) for invocation,
acceptance, failure interpretation and scenario authoring.
