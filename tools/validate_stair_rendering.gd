extends SceneTree
## Focused headless coverage for two-cell stair geometry and overlays.

const Flight = preload("res://scripts/stair_flight.gd")
const MesherScript = preload("res://scripts/rendering/chunk_mesher.gd")
const OverlayScript = preload("res://scripts/rendering/overlay_renderer.gd")

var failures := 0


func _init():
	_run.call_deferred()


func _run() -> void:
	print("Stair rendering validation started")
	_test_mesher_halves()
	_test_chunk_boundaries()
	_test_overlay_entries()
	if failures > 0:
		push_error("Stair rendering validation failed: %d" % failures)
		quit(1)
		return
	print("Stair rendering OK (4 rotations, 8 half meshes, lower-level cut, task footprint, cleanup)")
	quit(0)


func _check(condition: bool, message: String) -> void:
	if not condition:
		failures += 1
		push_error(message)


func _test_mesher_halves() -> void:
	var mesher := MesherScript.new()
	for rotation in range(4):
		var lower_pos := Vector3i(2, 2, 3)
		var cells := Flight.cells(lower_pos, rotation)
		var blocks := PackedByteArray()
		blocks.resize(World.CHUNK_VOLUME)
		blocks[mesher.chunk_index(World.CHUNK_SIZE, lower_pos.x, lower_pos.y, lower_pos.z)] = Flight.lower_id(rotation)
		var upper := cells[1]
		blocks[mesher.chunk_index(World.CHUNK_SIZE, upper.x, upper.y, upper.z)] = Flight.upper_id(rotation)
		var ramp_table := PackedByteArray()
		ramp_table.resize(BlockRegistry.TABLE_SIZE)
		ramp_table[Flight.lower_id(rotation)] = 1
		ramp_table[Flight.upper_id(rotation)] = 1
		var solid_table := PackedByteArray()
		solid_table.resize(BlockRegistry.TABLE_SIZE)
		var color_table := PackedColorArray()
		color_table.resize(BlockRegistry.TABLE_SIZE)
		color_table[Flight.lower_id(rotation)] = Color.WHITE
		color_table[Flight.upper_id(rotation)] = Color.WHITE
		var result: Dictionary = mesher.build_chunk_arrays_from_data({
			"chunk_size": World.CHUNK_SIZE,
			"cx": 0,
			"cy": 0,
			"cz": 0,
			"air_id": World.BLOCK_ID_AIR,
			"blocks": blocks,
			"solid_table": solid_table,
			"ramp_table": ramp_table,
			"color_table": color_table,
		})
		var vertices: PackedVector3Array = result.get("vertices", PackedVector3Array())
		var uv2s: PackedVector2Array = result.get("uv2", PackedVector2Array())
		var bounds := _bounds(vertices)
		_check(bounds.size.x > 0.99 and bounds.size.x < 1.01 if rotation % 2 == 0 else bounds.size.x > 1.99 and bounds.size.x < 2.01, "rotation %d X footprint" % rotation)
		_check(bounds.size.z > 1.99 and bounds.size.z < 2.01 if rotation % 2 == 0 else bounds.size.z > 0.99 and bounds.size.z < 1.01, "rotation %d Z footprint" % rotation)
		_check(bounds.size.y > 0.99 and bounds.size.y < 1.01, "rotation %d one-rise height" % rotation)
		var expected_vertices: int = mesher.build_stair_flight_half_mesh(Flight.lower_id(rotation)).surface_get_arrays(0)[Mesh.ARRAY_VERTEX].size() + mesher.build_stair_flight_half_mesh(Flight.upper_id(rotation)).surface_get_arrays(0)[Mesh.ARRAY_VERTEX].size()
		_check(not vertices.is_empty() and vertices.size() == expected_vertices, "rotation %d emits exactly one mesh per half, including exposed join faces" % rotation)
		for uv2 in uv2s:
			_check(is_equal_approx(uv2.x, 1.0), "rotation %d flight halves lost lower-level UV2" % rotation)


func _test_chunk_boundaries() -> void:
	var mesher := MesherScript.new()
	for rotation in 4:
		var direction := Flight.direction(rotation)
		var anchor := Vector3i(World.CHUNK_SIZE - 1 if direction.x > 0 else 0, 2, World.CHUNK_SIZE - 1 if direction.z > 0 else 0)
		var cells := Flight.cells(anchor, rotation)
		for index in 2:
			var cell: Vector3i = cells[index]
			var cx := floori(float(cell.x) / World.CHUNK_SIZE)
			var cz := floori(float(cell.z) / World.CHUNK_SIZE)
			var local := cell - Vector3i(cx, 0, cz) * World.CHUNK_SIZE
			var blocks := PackedByteArray()
			blocks.resize(World.CHUNK_VOLUME)
			blocks[mesher.chunk_index(World.CHUNK_SIZE, local.x, local.y, local.z)] = Flight.lower_id(rotation) if index == 0 else Flight.upper_id(rotation)
			var result: Dictionary = mesher.build_chunk_arrays_from_data({"chunk_size": World.CHUNK_SIZE, "cx": cx, "cy": 0, "cz": cz, "air_id": 0, "blocks": blocks, "solid_table": PackedByteArray(), "ramp_table": PackedByteArray(), "color_table": PackedColorArray()})
			var bounds := _bounds(result.vertices)
			_check(is_equal_approx(bounds.size.x, 1.0) and is_equal_approx(bounds.size.z, 1.0), "Boundary chunk emits only its own half")
			_check(bounds.position.x >= local.x - 0.501 and bounds.end.x <= local.x + 0.501 and bounds.position.z >= local.z - 0.501 and bounds.end.z <= local.z + 0.501, "No geometry escapes its owning cell")
			for uv2 in result.uv2:
				_check(is_equal_approx(uv2.x, 1.0), "Boundary half retains lower-level visibility even without loaded neighbor")


func _test_overlay_entries() -> void:
	var world := World.new()
	world._init_ramp_lookup()
	world.block_registry.load_from_csv(World.BLOCK_DATA_PATH)
	world.top_render_y = 1
	var overlay := OverlayScript.new()
	root.add_child(overlay)
	overlay.initialize(world)
	var anchor := Vector3i(10, 2, 10)
	for rotation in range(4):
		var cells := Flight.cells(anchor, rotation)
		var entries := [
			{"pos": cells[0], "valid": true, "stair_material": Flight.lower_id(rotation)},
			{"pos": cells[1], "valid": true, "stair_material": Flight.upper_id(rotation)},
		]
		overlay.set_drag_preview_entries(entries, World.PlayerMode.UP_STAIRS)
		_check(overlay.drag_previews.size() == 2, "rotation %d did not retain both ghost cells" % rotation)
		_check(overlay.stair_preview_mesh_cache.size() == (rotation + 1) * 2, "rotation %d did not cache both half meshes" % rotation)
		for entry in entries:
			var key := overlay.drag_preview_key(entry.pos.x, entry.pos.y, entry.pos.z)
			var node: MeshInstance3D = overlay.drag_previews[key]
			_check(node.mesh is ArrayMesh and node.mesh.get_surface_count() == 1, "rotation %d ghost is not actual stair geometry" % rotation)
			_check(node.position == Vector3(entry.pos), "rotation %d ghost retains exact block coordinates" % rotation)
			var ghost_bounds: AABB = node.mesh.get_aabb()
			ghost_bounds.position += node.position
			_check(is_equal_approx(ghost_bounds.position.y, entry.pos.y - 0.5) and is_equal_approx(ghost_bounds.end.y, entry.pos.y + (0.0 if Flight.is_lower(entry.stair_material) else 0.5)), "Ghost world-space height matches the built half")
		_check(overlay.drag_previews[overlay.drag_preview_key(anchor.x, anchor.y, anchor.z)].visible, "up ghost was not visible from lower level")

	var valid_material: Material = overlay.drag_previews.values()[0].material_override
	overlay.set_drag_preview_entries([
		{"pos": anchor, "valid": false, "stair_material": Flight.lower_id(0)},
		{"pos": Flight.cells(anchor, 0)[1], "valid": false, "stair_material": Flight.upper_id(0)},
	], World.PlayerMode.DOWN_STAIRS)
	var invalid_material: ShaderMaterial = overlay.drag_previews.values()[0].material_override
	_check(valid_material != invalid_material, "invalid ghost did not change material")
	_check(invalid_material.shader.get_code().contains("depth_test_disabled"), "down ghost depth test remains enabled")
	overlay.set_drag_preview_entries([
		{"pos": anchor, "valid": true, "stair_material": Flight.lower_id(0)},
		{"pos": Flight.cells(anchor, 0)[1], "valid": true, "stair_material": Flight.upper_id(0)},
	], World.PlayerMode.UP_STAIRS)
	var up_material: ShaderMaterial = overlay.drag_previews.values()[0].material_override
	_check(is_equal_approx(float(up_material.get_shader_parameter("top_render_margin")), 1.0), "up ghost lost render cut margin")

	var task := TaskQueue.Task.new(7, anchor, TaskQueue.TaskType.STAIRS, Flight.lower_id(0))
	task.data = {"footprint": Flight.cells(anchor, 0)}
	overlay.update_task_overlays([task])
	var task_stats := overlay.get_overlay_debug_stats()
	_check(task_stats["task_positions"].size() == 2, "stair task overlay did not show both footprint cells")
	_check(is_equal_approx(float(overlay.task_overlays[task.id].material_override.get_shader_parameter("top_render_margin")), 1.0), "Queued flight stays visible from the lower slice")
	overlay.clear_drag_preview()
	overlay.clear_task_overlays()
	_check(overlay.drag_previews.is_empty() and overlay.task_overlays.is_empty(), "stair overlay cleanup retained nodes")
	world.free()
	overlay.free()


func _bounds(vertices: PackedVector3Array) -> AABB:
	if vertices.is_empty():
		return AABB()
	var bounds := AABB(vertices[0], Vector3.ZERO)
	for vertex in vertices:
		bounds = bounds.expand(vertex)
	return bounds
