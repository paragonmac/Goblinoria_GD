extends RefCounted
class_name MainSelectionController
## Mouse drag selection, hover preview, and click-to-task logic.

#region Constants
const DRAG_CLICK_THRESHOLD := 5.0
const ROUND_HALF := 0.5
const CAMERA_RAYCAST_DISTANCE := 500.0
const PLACE_HEIGHT_OFFSET := 1.0
const PLACE_MATERIAL_ID := World.PLACE_MATERIAL_ID
#endregion

#region Refs
var world: World
var camera: Camera3D
var viewport: Viewport
var camera_controller: MainCameraController
#endregion

#region State
var prev_mouse_down := false

var is_dragging := false
var drag_start: Vector2
var drag_plane_y: float = 0.0

var info_block_id: int = -1
var info_block_pos := Vector3i(-1, -1, -1)
#endregion


func initialize(world_ref: World, camera_ref: Camera3D, viewport_ref: Viewport, camera_controller_ref: MainCameraController) -> void:
	world = world_ref
	camera = camera_ref
	viewport = viewport_ref
	camera_controller = camera_controller_ref


func cancel_drag_and_clear_preview() -> void:
	is_dragging = false
	prev_mouse_down = false
	if world != null:
		world.clear_drag_preview()


func handle_mouse() -> void:
	if world == null or camera == null or viewport == null:
		return
	var mouse_down := Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT)
	var just_pressed := mouse_down and not prev_mouse_down
	var just_released := not mouse_down and prev_mouse_down
	prev_mouse_down = mouse_down

	if just_pressed and not is_dragging:
		_start_drag()

	if just_released and is_dragging:
		_end_drag()
		return

	if is_dragging:
		_update_drag_preview()


func update_hover_preview() -> void:
	if world == null:
		return
	if is_dragging:
		return
	if world.player_mode != World.PlayerMode.STAIRS:
		world.clear_drag_preview()
		return

	var hit := _raycast_block_at_mouse()
	if not hit.get("hit", false):
		world.clear_drag_preview()
		return

	var pos: Vector3i = hit["pos"]
	if not world.can_place_stairs_at(pos.x, pos.y, pos.z):
		world.clear_drag_preview()
		return

	var rect := {"min_x": pos.x, "max_x": pos.x, "min_z": pos.z, "max_z": pos.z, "y": pos.y}
	world.set_drag_preview(rect, world.player_mode)


func update_info_hover() -> void:
	if world == null:
		return
	if world.player_mode != World.PlayerMode.INFORMATION:
		info_block_id = -1
		return

	var hit := _raycast_block_at_mouse()
	if not hit.get("hit", false):
		info_block_id = -1
		return

	var pos: Vector3i = hit["pos"]
	info_block_id = world.get_block(pos.x, pos.y, pos.z)
	info_block_pos = pos


func _start_drag() -> void:
	if viewport == null:
		return
	drag_start = viewport.get_mouse_position()
	is_dragging = true
	drag_plane_y = _get_drag_plane_y(drag_start)


func _end_drag() -> void:
	if viewport == null or world == null:
		return
	var drag_end := viewport.get_mouse_position()
	var drag_rect := _get_drag_rect(drag_start, drag_end, drag_plane_y)
	_commit_selection(drag_start, drag_end, drag_rect)
	is_dragging = false
	world.clear_drag_preview()


func _update_drag_preview() -> void:
	if viewport == null or world == null:
		return
	var drag_now := viewport.get_mouse_position()
	var drag_rect := _get_drag_rect(drag_start, drag_now, drag_plane_y)
	world.set_drag_preview(drag_rect, world.player_mode)


func _raycast_block_at_mouse() -> Dictionary:
	if viewport == null:
		return {"hit": false}
	var mouse_pos := viewport.get_mouse_position()
	return _raycast_block_from_screen_pos(mouse_pos)


func _raycast_block_from_screen_pos(screen_pos: Vector2) -> Dictionary:
	if world == null or camera == null:
		return {"hit": false}
	var ray_origin := camera.project_ray_origin(screen_pos)
	var ray_dir := camera.project_ray_normal(screen_pos)
	return world.raycast_block(ray_origin, ray_dir, CAMERA_RAYCAST_DISTANCE)


func _get_drag_plane_y(screen_pos: Vector2) -> float:
	# SEE-ADR-006: Drag selection resolves to one fixed world Y plane at drag start.
	var hit := _raycast_block_from_screen_pos(screen_pos)
	if hit.get("hit", false):
		var hit_pos: Vector3i = hit["pos"]
		var base_y := float(hit_pos.y)
		if world != null and world.player_mode == World.PlayerMode.PLACE:
			base_y += PLACE_HEIGHT_OFFSET
		return base_y
	return float(world.top_render_y) if world != null else 0.0


func _get_drag_rect(start: Vector2, end: Vector2, plane_y: float) -> Dictionary:
	# SEE-ADR-006: Screen drag endpoints are projected into world X/Z coordinates.
	if camera_controller == null:
		return {}
	var a: Variant = camera_controller.screen_to_plane(start, plane_y)
	var b: Variant = camera_controller.screen_to_plane(end, plane_y)
	if a == null or b == null:
		return {}
	var a_pos: Vector3 = a
	var b_pos: Vector3 = b
	return {
		"min_x": minf(a_pos.x, b_pos.x),
		"max_x": maxf(a_pos.x, b_pos.x),
		"min_z": minf(a_pos.z, b_pos.z),
		"max_z": maxf(a_pos.z, b_pos.z),
		"y": plane_y,
	}


func _commit_selection(start: Vector2, end: Vector2, rect: Dictionary) -> void:
	if _is_click(start, end):
		_handle_click(start)
		return
	if rect.is_empty():
		return
	_enqueue_rect_tasks(rect)


func _is_click(start: Vector2, end: Vector2) -> bool:
	return abs(end.x - start.x) < DRAG_CLICK_THRESHOLD and abs(end.y - start.y) < DRAG_CLICK_THRESHOLD


func _enqueue_rect_tasks(rect: Dictionary) -> void:
	# SEE-ADR-006: World-space drag bounds are rounded to stable block coordinates.
	var min_x := int(floor(float(rect["min_x"]) + ROUND_HALF))
	var max_x := int(floor(float(rect["max_x"]) + ROUND_HALF))
	var min_z := int(floor(float(rect["min_z"]) + ROUND_HALF))
	var max_z := int(floor(float(rect["max_z"]) + ROUND_HALF))
	var y := int(rect["y"])
	var results: Array = []

	for x in range(min_x, max_x + 1):
		for z in range(min_z, max_z + 1):
			results.append(_enqueue_task_at(x, y, z))
	_trace_selection("drag", min_x, max_x, min_z, max_z, y, results)


func _handle_click(screen_pos: Vector2) -> void:
	# SEE-ADR-006: Click selection uses voxel raycast; PLACE targets one block above.
	var hit := _raycast_block_from_screen_pos(screen_pos)
	if not hit.get("hit", false):
		return

	var pos: Vector3i = hit["pos"]
	if world != null and world.player_mode == World.PlayerMode.PLACE:
		pos.y += 1
	var result := _enqueue_task_at(pos.x, pos.y, pos.z)
	_trace_selection("click", pos.x, pos.x, pos.z, pos.z, pos.y, [result])


func _enqueue_task_at(x: int, y: int, z: int) -> Dictionary:
	var pos := Vector3i(x, y, z)
	var result := {
		"pos": pos,
		"queued": false,
		"reason": "invalid_position",
		"block_id": -1,
	}
	if world == null:
		result["reason"] = "missing_world"
		return result
	if not _is_valid_position(x, y, z):
		return result
	var block_id := world.get_block(x, y, z)
	result["block_id"] = block_id

	match world.player_mode:
		World.PlayerMode.DIG:
			if world.is_diggable_at(x, y, z):
				result["queued"] = world.queue_task_request(TaskQueue.TaskType.DIG, pos, 0)
				result["reason"] = "queued" if result["queued"] else "duplicate"
			else:
				result["reason"] = "not_diggable"
		World.PlayerMode.PLACE:
			if world.is_empty(x, y, z) and _has_place_stock():
				result["queued"] = world.queue_task_request(TaskQueue.TaskType.PLACE, pos, PLACE_MATERIAL_ID)
				result["reason"] = "queued" if result["queued"] else "duplicate"
			elif not world.is_empty(x, y, z):
				result["reason"] = "not_empty"
			else:
				result["reason"] = "no_stock"
		World.PlayerMode.STAIRS:
			if world.can_place_stairs_at(x, y, z):
				result["queued"] = world.queue_task_request(TaskQueue.TaskType.STAIRS, pos, World.STAIR_BLOCK_ID)
				result["reason"] = "queued" if result["queued"] else "duplicate"
			else:
				result["reason"] = "stairs_not_placeable"
	return result


func _trace_selection(
	kind: String,
	min_x: int,
	max_x: int,
	min_z: int,
	max_z: int,
	y: int,
	results: Array
) -> void:
	if world == null:
		return
	var queued: Array[String] = []
	var rejected: Array[String] = []
	for result: Dictionary in results:
		var pos: Vector3i = result["pos"]
		var block_id: int = int(result.get("block_id", -1))
		var block_name := world.block_registry.get_name(block_id) if block_id >= 0 else "invalid"
		var entry := "%d:%d:%d:block=%d:%s" % [pos.x, pos.y, pos.z, block_id, block_name]
		if bool(result.get("queued", false)):
			queued.append(entry)
		else:
			rejected.append("%s:reason=%s" % [entry, result.get("reason", "unknown")])
	var mode_name := str(World.PlayerMode.keys()[world.player_mode])
	world.trace_system_event("selection_committed", "kind=%s mode=%s bounds=%d..%d:%d:%d..%d requested=%d queued=%d rejected=%d queued_positions=%s rejected_positions=%s" % [
		kind,
		mode_name,
		min_x,
		max_x,
		y,
		min_z,
		max_z,
		results.size(),
		queued.size(),
		rejected.size(),
		"|".join(queued),
		"|".join(rejected),
	])


func _has_place_stock() -> bool:
	var stock: int = world.get_inventory_count(PLACE_MATERIAL_ID)
	var committed: int = world.task_queue.count_active_by_type_and_material(TaskQueue.TaskType.PLACE, PLACE_MATERIAL_ID)
	return stock - committed > 0


func _is_valid_position(x: int, y: int, z: int) -> bool:
	return world != null and world.is_block_coord_valid(x, y, z)
