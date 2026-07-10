# ADR-011: Terrain Slope And Player Stair Identity

Status: Accepted
Date: 2026-07-10

## Context

Generated terrain slopes and player-built stairs originally shared block IDs 100 through 111. The renderer intentionally displays player stairs one level below their physical cell so a downward connection remains visible from its destination level. Applying that rule to terrain slopes made terrain above the selected render level appear to remain in the slice.

## Decision

Player stairs retain IDs 100 through 111. Generated terrain slopes use IDs 112 through 123 with the same ramp geometry and pathing shape. Both ranges are ramps for collision, worker movement, digging duration, and mesh construction.

The mesher encodes player stairs one level below their physical Y for render-level visibility. Terrain slopes encode their physical Y and are therefore removed when their level is above the selected slice.

Save format V5 records the expanded block table. Loading a V4 save migrates only a legacy ramp that matches the deterministic terrain ramp ID and height at the same position. Old mesh caches are rejected through the mesher cache version.

## Consequences

- Level cuts hide complete terrain hills above the selected level.
- Player-built up and down stairs remain visible from their connected lower level.
- New generation and full-map cooking emit terrain-slope IDs.
- The V4 migration has no source bit to consult, so a player stair that exactly matches the old deterministic terrain slope at that cell is treated as terrain. This is an unavoidable narrow ambiguity in legacy saves.

## Guardrails

- Code pointer: `scripts/world.gd`, terrain-slope IDs and `ramp_shape_id()`.
- Code pointer: `scripts/world/world_terrain_ramp_builder.gd` and `scripts/world_generation_pipeline.gd`.
- Code pointer: `scripts/rendering/chunk_mesher.gd`, ramp visibility encoding.
- Contract: `tools/validate_rendering_contract.gd` verifies separate visibility Y values.
