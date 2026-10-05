extends RefCounted
class_name PlaytestScenarios
## Deterministic, bounded fixtures used by the isolated graphical stair playtest.
##
## The fixtures deliberately use the real World, Worker, task, path and renderer
## objects.  Only the small terrain patch is stamped directly; generation and
## meshing continue through the normal systems after setup.

const Flight = preload("res://scripts/stair_flight.gd")
const WorkerRoles = preload("res://scripts/worker_roles.gd")

const STAIR_PREVIEW := "stair_preview"
const STAIR_CONTINUATION := "stair_continuation"
const VALID_SCENARIOS := [STAIR_PREVIEW, STAIR_CONTINUATION]
const SCENARIO_VERSION := 1

const DEFAULT_SEEDS := {
	STAIR_PREVIEW: 184207,
	STAIR_CONTINUATION: 184211,
}
const DEFAULT_DROP_SEEDS := {
	STAIR_PREVIEW: 920401,
	STAIR_CONTINUATION: 920407,
}

var scenario_name: String
var world_seed: int
var drop_seed: int


static func make(name: String, seed_override: int = -1):
	if not VALID_SCENARIOS.has(name):
		return null
	var result := new()
	result.scenario_name = name
	result.world_seed = seed_override if seed_override >= 0 else int(DEFAULT_SEEDS[name])
	result.drop_seed = int(DEFAULT_DROP_SEEDS[name]) ^ result.world_seed
	return result


func prepare(main) -> Dictionary:
	if main == null or main.world == null:
		push_error("Playtest scenario requires a ready Main with a World")
		return {}
	var world: World = main.world
	# Main's World._ready has already installed the ordinary systems. Reinitialize
	# through the production lifecycle so no fixture owns a parallel simulation.
	world.world_seed = world_seed
	world.drop_rng.seed = drop_seed
	# This fixture has no save directory by design. Keep normal streaming's
	# generation fallback active without repeating the expected load warning.
	if world.save_load != null:
		world.save_load.warned_missing_world_dir = true
	world.init_world(false)
	world.world_seed = world_seed
	world.drop_rng.seed = drop_seed

	var spec := _specification()
	var patch: Dictionary = spec["patch"]
	var required_cells: Array[Vector3i] = []
	for value in patch.keys():
		if value is Vector3i:
			required_cells.append(value)
	_ensure_local_chunks(world, required_cells)
	_apply_patch(world, patch)
	_apply_workers(world, spec["worker_start"], main.get("playtest_controller") != null if main is Object else false)

	var top_render_y := int(spec["top_render_y"])
	world.set_top_render_y(top_render_y)
	world.set_player_mode(World.PlayerMode.DOWN_STAIRS)
	_configure_rendering(main, world, spec["camera_target"], top_render_y)

	var affected_chunks := _affected_chunks(world, required_cells)
	_queue_local_meshes(world, affected_chunks)
	_restore_main_presentation(main, world)

	var terrain_rows := _terrain_fingerprint(world, patch.keys())
	var worker_rows := _worker_fingerprint(world)
	var camera_result := _camera_result(main, spec["camera_target"], top_render_y)
	var named_positions: Dictionary = _named_position_arrays(spec["named_positions"])
	var result := {
		"scenario": scenario_name,
		"scenario_version": SCENARIO_VERSION,
		"seed": world_seed,
		"drop_seed": drop_seed,
		"named_positions": named_positions,
		"named_position_arrays": named_positions.duplicate(true),
		"affected_chunks": _position_arrays(affected_chunks),
		"affected_chunk_arrays": _position_arrays(affected_chunks),
		"camera": camera_result,
		"initial_fingerprint": {
			"world_seed": world_seed,
			"drop_seed": drop_seed,
			"top_render_y": top_render_y,
			"terrain": terrain_rows,
			"workers": worker_rows,
			"camera": camera_result.duplicate(true),
		},
		"expectations": _plain_fixture_value(spec["expectations"]),
	}
	return result


func _specification() -> Dictionary:
	match scenario_name:
		STAIR_PREVIEW:
			return _preview_specification()
		STAIR_CONTINUATION:
			return _continuation_specification()
	return {}


func _preview_specification() -> Dictionary:
	var hover := Vector3i(-11, 225, 15)
	var anchor := Vector3i(-11, 225, 16)
	var upper := anchor + Flight.direction(0)
	var worker_start := Vector3i(-11, 226, 14)
	var patch := _flat_patch(Rect2i(-14, 12, 7, 7), 224, 228)
	return {
		"named_positions": {
			"hover_cell": hover,
			"lower": anchor,
			"upper": upper,
			"worker_start": worker_start,
		},
		"worker_start": worker_start,
		"camera_target": Vector3(-11.0, 225.0, 15.0),
		"top_render_y": 225,
		"patch": patch,
		"expectations": {
			"preview_mode": "down_stairs",
			"preview_rotation": 0,
			"preview_anchor": anchor,
			"preview_cells": [anchor, upper],
			"preview_should_be_valid": true,
		},
	}


func _continuation_specification() -> Dictionary:
	var old_lower := Vector3i(-12, 226, -5)
	var old_upper := Vector3i(-12, 226, -6)
	var hover := Vector3i(-12, 225, -5)
	var attempt_anchor := Vector3i(-12, 225, -4)
	var worker_start := Vector3i(-12, 227, -7)
	var patch := _flat_patch(Rect2i(-15, -9, 7, 8), 224, 228)
	# A real, named headroom obstruction documents why the continuation ghost is
	# rejected. The old flight remains a complete two-cell flight underneath it.
	patch[old_lower] = Flight.lower_id(0)
	patch[old_upper] = Flight.upper_id(0)
	patch[Vector3i(-12, 226, -4)] = World.BLOCK_ID_GRASS
	patch[Vector3i(-12, 226, -7)] = World.BLOCK_ID_GRASS
	return {
		"named_positions": {
			"hover_cell": hover,
			"lower": old_lower,
			"upper": old_upper,
			"worker_start": worker_start,
			"attempt_anchor": attempt_anchor,
			"attempt_upper": attempt_anchor + Flight.direction(0),
			"headroom_obstruction": Vector3i(-12, 226, -4),
		},
		"worker_start": worker_start,
		"camera_target": Vector3(-12.0, 225.0, -5.0),
		"top_render_y": 225,
		"patch": patch,
		"expectations": {
			"preview_mode": "down_stairs",
			"preview_rotation": 0,
			"old_flight": [old_lower, old_upper],
			"attempt_anchor": attempt_anchor,
			"attempt_cells": [attempt_anchor, attempt_anchor + Flight.direction(0)],
			"preview_should_be_valid": false,
			"rejection": "headroom",
		},
	}


func _flat_patch(rect: Rect2i, support_y: int, top_y: int) -> Dictionary:
	var patch := {}
	for x in range(rect.position.x, rect.end.x):
		for z in range(rect.position.y, rect.end.y):
			patch[Vector3i(x, support_y, z)] = World.BLOCK_ID_GRANITE
			patch[Vector3i(x, support_y + 1, z)] = World.BLOCK_ID_GRASS
			for y in range(support_y + 2, top_y + 1):
				patch[Vector3i(x, y, z)] = World.BLOCK_ID_AIR
	return patch


func _ensure_local_chunks(world: World, cells: Array[Vector3i]) -> void:
	var chunks := {}
	for cell: Vector3i in cells:
		var base := world.world_to_chunk_coords(cell.x, cell.y, cell.z)
		# One-cell neighborhood covers path/renderer reads around each fixture.
		for dx in range(-1, 2):
			for dy in range(-1, 2):
				for dz in range(-1, 2):
					var coord := Vector3i(base.x + dx, base.y + dy, base.z + dz)
					if world.is_chunk_coord_valid(coord):
						chunks[coord] = true
	for coord: Vector3i in chunks.keys():
		world.ensure_chunk_generated(coord)


func _apply_patch(world: World, patch: Dictionary) -> void:
	for cell: Vector3i in patch.keys():
		world.set_block_raw(cell.x, cell.y, cell.z, int(patch[cell]), true)


func _apply_workers(world: World, worker_start: Vector3i, trace_workers: bool) -> void:
	world.clear_workers()
	var worker := Worker.new()
	worker.worker_id = 1
	worker.role_id = WorkerRoles.Role.MINER
	worker.work_priorities = {
		"hauling": 0,
		"mining": 2,
		"building": 2,
	}
	worker.position = Vector3(worker_start)
	worker.wander_wait = 999999.0
	world.add_child(worker)
	world.workers.append(worker)
	world.diagnostics_workers_by_id[worker.worker_id] = worker
	world.diagnostics_workers_revision += 1
	if trace_workers:
		world._start_worker_trace_for_spawned_workers()
	world.notify_worker_roles_changed()


func _configure_rendering(main, world: World, target: Vector3, render_y: int) -> void:
	if main.camera_controller != null:
		main.camera_controller.setup_camera(world)
		var viewport_center: Vector2 = main.get_viewport().get_visible_rect().get_center()
		var current: Variant = main.camera_controller.screen_to_plane(viewport_center, float(render_y))
		if current is Vector3:
			main.camera.position += target - current
		main.camera.position.y = target.y + 60.0
		main.camera_controller._clamp_camera_to_world()
		main.camera.size = 24.0
	if main.render_level_controller != null:
		main.render_level_controller.update_world(world)
	# Queue the actual local render requests. The renderer's normal asynchronous
	# worker applies them on later frames; setup never force-finishes simulation.
	world.update_streaming(
		main.get_stream_view_rect_for_y(render_y),
		float(render_y),
		0.0,
		main.camera,
		main.render_level_controller.get_render_band_view_rects(render_y) if main.render_level_controller != null else {}
	)


func _queue_local_meshes(world: World, chunks: Array[Vector3i]) -> void:
	if world.renderer == null:
		return
	for coord: Vector3i in chunks:
		world.renderer.queue_chunk_mesh_build(coord, world.top_render_y, false, true, false)


func _restore_main_presentation(main, world: World) -> void:
	# These are the production lifecycle/UI adapters used by normal startup.
	main.world_started = true
	main.loading_active = false
	main._set_render_level_base()
	main._set_world_draw_enabled(true)
	main.close_menu()


func _affected_chunks(world: World, cells: Array[Vector3i]) -> Array[Vector3i]:
	var seen := {}
	for cell: Vector3i in cells:
		seen[world.world_to_chunk_coords(cell.x, cell.y, cell.z)] = true
	var result: Array[Vector3i] = []
	for coord: Vector3i in seen.keys():
		result.append(coord)
	result.sort_custom(Callable(self, "_coord_less"))
	return result


func _terrain_fingerprint(world: World, cells: Array) -> Array:
	var positions: Array[Vector3i] = []
	for cell in cells:
		if cell is Vector3i:
			positions.append(cell)
	positions.sort_custom(Callable(self, "_coord_less"))
	var rows: Array = []
	for cell: Vector3i in positions:
		rows.append({"pos": _position_array(cell), "block_id": world.get_block_no_generate(cell.x, cell.y, cell.z)})
	return rows


func _worker_fingerprint(world: World) -> Array:
	var rows: Array = []
	for worker: Worker in world.workers:
		rows.append({
			"id": worker.worker_id,
			"role_id": worker.role_id,
			"position": _position_array(worker.get_block_coord()),
			"priorities": worker.work_priorities.duplicate(true),
		})
	rows.sort_custom(Callable(self, "_worker_less"))
	return rows


func _camera_result(main, target: Vector3, render_y: int) -> Dictionary:
	return {
		"target": [target.x, target.y, target.z],
		"position": [main.camera.position.x, main.camera.position.y, main.camera.position.z],
		"rotation_degrees": [main.camera.rotation_degrees.x, main.camera.rotation_degrees.y, main.camera.rotation_degrees.z],
		"size": main.camera.size,
		"render_y": render_y,
	}


func _named_position_arrays(named_positions: Dictionary) -> Dictionary:
	var result := {}
	for key in named_positions.keys():
		var value = named_positions[key]
		if value is Vector3i:
			result[key] = _position_array(value)
	return result


func _plain_fixture_value(value: Variant) -> Variant:
	if value is Vector3i:
		return _position_array(value)
	if value is Vector3:
		return [value.x, value.y, value.z]
	if value is Dictionary:
		var result := {}
		for key in value.keys():
			result[key] = _plain_fixture_value(value[key])
		return result
	if value is Array:
		var result: Array = []
		for item in value:
			result.append(_plain_fixture_value(item))
		return result
	return value


func _position_arrays(values: Array) -> Array:
	var result: Array = []
	for value in values:
		if value is Vector3i:
			result.append(_position_array(value))
	return result


func _position_array(value: Vector3i) -> Array[int]:
	return [value.x, value.y, value.z]


func _coord_less(a: Vector3i, b: Vector3i) -> bool:
	if a.x != b.x:
		return a.x < b.x
	if a.y != b.y:
		return a.y < b.y
	return a.z < b.z


func _worker_less(a: Dictionary, b: Dictionary) -> bool:
	return int(a.get("id", 0)) < int(b.get("id", 0))
