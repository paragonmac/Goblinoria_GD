extends SceneTree
## Regression coverage for two-cell stair task overlays versus stair ghosts.

const Flight = preload("res://scripts/stair_flight.gd")
const OverlayScript = preload("res://scripts/rendering/overlay_renderer.gd")

var failures := 0
var world: World
var overlay: OverlayRenderer
var queue: TaskQueue


func _init() -> void:
	_run.call_deferred()


func _run() -> void:
	print("Stair overlay alignment validation started")
	_setup()
	_test_flight_alignment_and_states()
	_test_legacy_overlay_shape_and_scale()
	_cleanup()
	if failures > 0:
		push_error("Stair overlay alignment validation failed: %d" % failures)
		quit(1)
		return
	print("Stair overlay alignment OK (8 flights, 4 states, world geometry, slice/depth, cache reuse, cleanup)")
	quit(0)


func _setup() -> void:
	world = World.new()
	world._init_ramp_lookup()
	world.block_registry.load_from_csv(World.BLOCK_DATA_PATH)
	world.top_render_y = 225
	queue = TaskQueue.new()
	overlay = OverlayScript.new()
	root.add_child(overlay)
	overlay.initialize(world)


func _check(condition: bool, message: String) -> void:
	if not condition:
		failures += 1
		push_error(message)


func _test_flight_alignment_and_states() -> void:
	var accessibility_states := [
		TaskQueue.TaskAccessibility.UNKNOWN,
		TaskQueue.TaskAccessibility.REACHABLE,
		TaskQueue.TaskAccessibility.UNREACHABLE,
	]
	for up in [true, false]:
		for rotation in range(Flight.ROTATION_COUNT):
			var anchor := Vector3i(
				-55 + rotation * 4 + (0 if up else 32),
				226,
				-2
			)
			_test_flight_case(anchor, rotation, up, accessibility_states)


func _test_flight_case(
	anchor: Vector3i,
	rotation: int,
	up: bool,
	accessibility_states: Array
) -> void:
	var mode := World.PlayerMode.UP_STAIRS if up else World.PlayerMode.DOWN_STAIRS
	world.top_render_y = anchor.y - 1 if up else anchor.y
	overlay.set_top_render_y(world.top_render_y)
	var cells := Flight.cells(anchor, rotation)
	var lower_material := Flight.lower_id(rotation)
	var upper_material := Flight.upper_id(rotation)
	var entries := [
		{"pos": cells[0], "valid": true, "stair_material": lower_material},
		{"pos": cells[1], "valid": true, "stair_material": upper_material},
	]
	overlay.set_drag_preview_entries(entries, mode)

	var task_id := queue.add_stair_flight_task(
		anchor,
		rotation,
		up,
		lower_material,
		upper_material
	)
	var task = queue.get_task(task_id)
	_check(task != null, "rotation %d %s did not create a stair flight task" % [rotation, "up" if up else "down"])
	if task == null:
		return
	_check(bool(task.data.get("flight", false)), "rotation %d %s task lost flight marker" % [rotation, "up" if up else "down"])
	_check(bool(task.data.get("up", true)) == up, "rotation %d %s task lost up/down mode" % [rotation, "up" if up else "down"])
	_check(task.data.get("footprint", []) == cells, "rotation %d %s task footprint is not the flight cells" % [rotation, "up" if up else "down"])
	_check(task.data.get("materials", []) == [lower_material, upper_material], "rotation %d %s task materials do not identify both halves" % [rotation, "up" if up else "down"])

	overlay.update_task_overlays([task])
	var task_nodes := _task_nodes(task.id)
	_check(task_nodes.size() == 2, "rotation %d %s task did not create two overlay nodes" % [rotation, "up" if up else "down"])
	if task_nodes.size() != 2:
		_cleanup_case(task)
		return

	var worker := Worker.new()
	worker.worker_id = 9000 + rotation + (10 if up else 20)
	var cached_meshes: Dictionary = overlay.stair_preview_mesh_cache.duplicate()
	for state in accessibility_states:
		task.status = TaskQueue.TaskStatus.PENDING
		task.assigned_worker = null
		task.set_accessibility(state, 100 + state)
		overlay.update_task_overlays([task])
		_assert_flight_render(
			task,
			task_nodes,
			entries,
			mode,
			rotation,
			"rotation %d %s %s" % [rotation, "up" if up else "down", _accessibility_name(state)]
		)

	task.set_accessibility(TaskQueue.TaskAccessibility.REACHABLE, 200)
	task.status = TaskQueue.TaskStatus.IN_PROGRESS
	task.assigned_worker = worker
	overlay.update_task_overlays([task])
	_assert_flight_render(
		task,
		task_nodes,
		entries,
		mode,
		rotation,
		"rotation %d %s assigned" % [rotation, "up" if up else "down"]
	)
	for node in task_nodes:
		_check(node.scale == Vector3.ONE, "rotation %d %s assigned flight was scaled" % [rotation, "up" if up else "down"])
		var material: ShaderMaterial = node.material_override
		_check(is_equal_approx(float(material.get_shader_parameter("pulse_strength")), OverlayScript.ASSIGNED_PULSE_STRENGTH), "Assigned flight retains its job-state pulse")
	for cache_key in cached_meshes:
		_check(is_same(cached_meshes[cache_key], overlay.stair_preview_mesh_cache.get(cache_key)), "Job-state transitions reuse cached half meshes")
	_check(overlay.stair_preview_mesh_cache.size() == cached_meshes.size(), "Job-state transitions allocate no new half meshes")
	# Node visibility deliberately includes World's upper-level margin; shader
	# clipping is tighter. Move beyond that margin to test node hiding as well.
	world.top_render_y -= int(ceil(World.VISIBILITY_Y_OFFSET)) + 1
	overlay.set_top_render_y(world.top_render_y)
	overlay.update_task_overlays([task])
	for entry in entries:
		var pos: Vector3i = entry.pos
		var ghost: MeshInstance3D = overlay.drag_previews[overlay.drag_preview_key(pos.x, pos.y, pos.z)]
		_check(not ghost.visible, "Ghost hides above its allowed slice")
	for node in task_nodes:
		_check(not node.visible, "Designation hides at the same slice as ghost")

	worker.free()
	_cleanup_case(task)


func _assert_flight_render(
	task,
	task_nodes: Array,
	entries: Array,
	mode: int,
	_rotation: int,
	label: String
) -> void:
	var ghost_nodes: Array = []
	for entry in entries:
		var pos: Vector3i = entry["pos"]
		var key := overlay.drag_preview_key(pos.x, pos.y, pos.z)
		ghost_nodes.append(overlay.drag_previews.get(key, null))
	_check(ghost_nodes[0] != null and ghost_nodes[1] != null, label + ": corresponding ghost nodes missing")
	_check(task_nodes.size() == ghost_nodes.size(), label + ": task/ghost node counts differ")
	if ghost_nodes.size() != 2 or task_nodes.size() != 2:
		return

	for index in range(2):
		var task_node: MeshInstance3D = task_nodes[index]
		var ghost_node: MeshInstance3D = ghost_nodes[index]
		var material_id := int(entries[index]["stair_material"])
		_check(task_node.mesh is ArrayMesh, label + ": task half %d is not an ArrayMesh" % index)
		_check(ghost_node.mesh is ArrayMesh, label + ": ghost half %d is not an ArrayMesh" % index)
		_check(is_same(task_node.mesh, ghost_node.mesh), label + ": task half %d does not share the ghost mesh" % index)
		_check(is_same(task_node.mesh, overlay.stair_preview_mesh_cache.get(material_id)), label + ": task half %d bypassed the stair mesh cache" % index)
		_check(_world_vertices_match(task_node, ghost_node), label + ": task half %d world geometry differs from ghost" % index)
		_check(_transforms_match(task_node, ghost_node), label + ": task half %d world transform differs from ghost" % index)
		_check(task_node.scale == Vector3.ONE, label + ": task half %d is not unit scale" % index)
		_check(task_node.position == ghost_node.position, label + ": task half %d position differs from ghost" % index)
		_check(task_node.visible == ghost_node.visible, label + ": task half %d visibility differs from ghost" % index)
		_check(ghost_node.visible, label + ": ghost half %d is not visible at its matching render slice" % index)
		_assert_render_settings(task_node, mode, label + " task half %d" % index)
		_assert_render_settings(ghost_node, mode, label + " ghost half %d" % index)
		var material: ShaderMaterial = task_node.material_override
		_check(material.get_shader_parameter("albedo_color") == overlay.task_state_color(overlay.task_overlay_state(task)), label + ": job-state color is preserved")


func _assert_render_settings(node: MeshInstance3D, mode: int, label: String) -> void:
	var material := node.material_override as ShaderMaterial
	_check(material != null and material.shader != null, label + ": missing shader material")
	if material == null or material.shader == null:
		return
	var depth_disabled := material.shader.get_code().contains("depth_test_disabled")
	var expected_depth_disabled := mode == World.PlayerMode.DOWN_STAIRS
	_check(depth_disabled == expected_depth_disabled, label + ": depth-test mode does not match ghost")
	var expected_margin := 1.0 if mode == World.PlayerMode.UP_STAIRS else 0.0
	_check(is_equal_approx(float(material.get_shader_parameter("top_render_margin")), expected_margin), label + ": render margin does not match ghost")
	_check(is_equal_approx(float(material.get_shader_parameter("top_render_y")), float(world.top_render_y)), label + ": shader slice is current")


func _world_vertices_match(first: MeshInstance3D, second: MeshInstance3D) -> bool:
	if first.mesh == null or second.mesh == null:
		return false
	if first.mesh.get_surface_count() != second.mesh.get_surface_count():
		return false
	for surface in range(first.mesh.get_surface_count()):
		var first_arrays: Array = first.mesh.surface_get_arrays(surface)
		var second_arrays: Array = second.mesh.surface_get_arrays(surface)
		var first_vertices: PackedVector3Array = first_arrays[Mesh.ARRAY_VERTEX]
		var second_vertices: PackedVector3Array = second_arrays[Mesh.ARRAY_VERTEX]
		if first_vertices.size() != second_vertices.size():
			return false
		for index in range(first_vertices.size()):
			var first_world := first.global_transform * first_vertices[index]
			var second_world := second.global_transform * second_vertices[index]
			if not first_world.is_equal_approx(second_world):
				return false
	return true


func _transforms_match(first: Node3D, second: Node3D) -> bool:
	var first_transform := first.global_transform
	var second_transform := second.global_transform
	return first_transform.origin.is_equal_approx(second_transform.origin) \
		and first_transform.basis.is_equal_approx(second_transform.basis)


func _task_nodes(task_id: int) -> Array:
	var nodes: Array = []
	if not overlay.task_overlays.has(task_id):
		return nodes
	nodes.append(overlay.task_overlays[task_id])
	nodes.append_array(overlay.stair_task_overlays.get(task_id, []))
	return nodes


func _cleanup_case(task) -> void:
	queue.remove_task(task)
	overlay.update_task_overlays(queue.tasks)
	_check(not overlay.task_overlays.has(task.id) and not overlay.stair_task_overlays.has(task.id), "Removing a task clears both designation registries")
	overlay.clear_drag_preview()
	overlay.clear_task_overlays()
	_check(overlay.drag_previews.is_empty(), "case cleanup retained drag previews")
	_check(overlay.task_overlays.is_empty() and overlay.stair_task_overlays.is_empty(), "case cleanup retained task overlays")


func _test_legacy_overlay_shape_and_scale() -> void:
	var tasks := [
		queue.get_task(queue.add_dig_task(Vector3i(-10, 4, -10))),
		queue.get_task(queue.add_place_task(Vector3i(-8, 4, -10), World.PLACE_MATERIAL_ID)),
		queue.get_task(queue.add_stairs_task(Vector3i(-6, 4, -10), World.RAMP_NORTH_ID)),
	]
	world.top_render_y = 4
	overlay.update_task_overlays(tasks)
	for task in tasks:
		var node: MeshInstance3D = overlay.task_overlays[task.id]
		_check(node.mesh is BoxMesh, "legacy task type %d was changed from cube overlay" % task.type)
		_check(node.scale == Vector3.ONE, "legacy task type %d was not unit scale while pending" % task.type)

	var worker := Worker.new()
	for task in tasks:
		task.status = TaskQueue.TaskStatus.IN_PROGRESS
		task.assigned_worker = worker
	overlay.update_task_overlays(tasks)
	for task in tasks:
		var node: MeshInstance3D = overlay.task_overlays[task.id]
		_check(node.mesh is BoxMesh, "assigned legacy task type %d lost cube overlay" % task.type)
		_check(node.scale == OverlayScript.ASSIGNED_OVERLAY_SCALE, "assigned legacy task type %d lost assigned scale" % task.type)
	worker.free()
	for task in tasks:
		queue.remove_task(task)
	overlay.update_task_overlays(queue.tasks)
	overlay.clear_task_overlays()
	_check(overlay.task_overlays.is_empty(), "legacy cleanup retained task overlays")


func _accessibility_name(state: int) -> String:
	return TaskQueue.TaskAccessibility.keys()[state]


func _cleanup() -> void:
	queue.clear()
	overlay.clear_drag_preview()
	overlay.clear_task_overlays()
	if overlay != null and is_instance_valid(overlay):
		overlay.free()
	if world != null and is_instance_valid(world):
		world.free()
