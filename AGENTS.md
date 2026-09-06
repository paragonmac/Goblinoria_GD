# AGENTS.md

Local instructions for coding agents working in this repo.

## General
- Be direct; skip fluff.
- Prefer `rg` for searching.
- Keep changes minimal and scoped to the request.
- Avoid editing binary/asset files unless asked.

## Project Tracking
- GitHub Issues and the `Goblinoria Roadmap` GitHub Project are the source of truth for active work.
- Use `docs/project_management.md` for ticket schema, priority/severity labels, project fields, and workflow.
- Do not add active task lists to `TODO.md` or `docs/todo.md`; keep those files as pointers only.

## Godot / GDScript
- Engine: Godot 4.7.x (`project.godot` is authoritative).
- Avoid hand-editing `.tscn`/`.tres` unless explicitly requested.
- Use tabs for indentation, snake_case names, and ASCII only.

## World / Chunk System
- Chunked world lives in `scripts/world.gd`, `scripts/chunk_data.gd`.
- `World.CHUNK_SIZE` is authoritative; if changing it, update docs and bump save version.
- Streaming logic is in `scripts/world_streaming.gd` and renders via `scripts/rendering/world_renderer.gd`.

## Save/Load
- Current V6 saves use bulk chunk data plus metadata, items/stockpiles, worker roles, and optional mesh caches, orchestrated by `scripts/world_save_load.gd`.
- If the format changes, bump `SAVE_VERSION` and add mismatch checks.

## Tests / Runs
- Headless regression scripts live in `tools/validate_*.gd`; see `docs/prototype_checkpoint.md` for coverage and limitations.
- Run them with `godot --headless --path <repo> --script res://tools/<script>.gd`; inspect exit status and output. Save-related tests write isolated test data.
- Ask before running the editor or a graphical playtest.

## References
- `docs/design_philosophy.md` is the canonical design intent.
- `docs/chunk_streaming_plan.md` tracks the chunk streaming roadmap.
- `docs/game_design_doc.md` captures gameplay/system specs.
- `docs/prototype_checkpoint.md` is a dated implementation/validation snapshot, not an active task list; GitHub remains the work tracker.
- When you see a `SEE-ADR-###` code comment, read the referenced file in `docs/adr/` before changing that code path.
- Archived docs in `docs/archive/` are historical only; do not treat as current.
