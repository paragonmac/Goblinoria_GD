extends RefCounted
class_name MainSelectionController
signal selection_feedback(message: String)
signal cell_inspected(block_id: int, pos: Vector3i)
## Mouse drag selection, hover preview, and click-to-task logic.

#region Constants
const DRAG_CLICK_THRESHOLD := 5.0
const ROUND_HALF := 0.5
const CAMERA_RAYCAST_DISTANCE := 500.0
const PLACE_HEIGHT_OFFSET := 1.0
const PLACE_MATERIAL_ID := World.PLACE_MATERIAL_ID
const Flight = preload("res://scripts/stair_flight.gd")
#endregion

#region Refs
var world: World
var camera: Camera3D
var viewport: Viewport
var input_state = preload("res://scripts/game_input_state.gd").new()
var camera_controller: MainCameraController
#endregion

#region State
var released_drag_event_id := 0

var is_dragging := false
var drag_start: Vector2
var drag_plane_y: float = 0.0
var drag_projection_y: float = 0.0
const BLOCK_TOP_FACE_OFFSET := 0.5
var stair_rotation := 0

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
	released_drag_event_id = 0
	if world != null:
		world.clear_drag_preview()


func observe_input(event: InputEvent) -> void:
	# End ownership before GUI dispatch. Only this same release reaching
	# unhandled input may commit; a consumed release leaves no active drag.
	released_drag_event_id = 0
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT \
			and not event.pressed and is_dragging:
		released_drag_event_id = event.get_instance_id()
		is_dragging = false
		world.clear_drag_preview()


func handle_unhandled_input(event: InputEvent) -> bool:
	if world == null or camera == null or viewport == null:
		return false
	if _is_stair_mode() and event is InputEventMouseButton and event.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]:
		if viewport.gui_get_hovered_control() != null:
			return false
		if event.pressed:
			stair_rotation = posmod(stair_rotation + (1 if event.button_index == MOUSE_BUTTON_WHEEL_UP else -1), 4)
			if is_dragging:
				_update_drag_preview()
			else:
				update_hover_preview()
		return true
	if not event is InputEventMouseButton or event.button_index != MOUSE_BUTTON_LEFT:
		return false
	# Controls need not consume a release whose press began outside the GUI.
	if viewport.gui_get_hovered_control() != null:
		cancel_drag_and_clear_preview()
		return false
	# Embedded popups can dismiss after the parent receives the outside press.
	for popup: Window in viewport.get_embedded_subwindows():
		if popup.visible and popup.popup_window:
			cancel_drag_and_clear_preview()
			return false
	if event.pressed:
		_start_drag(event.position)
	elif released_drag_event_id == event.get_instance_id():
		released_drag_event_id = 0
		_end_drag(event.position)
	else:
		return false
	return true


func handle_mouse() -> void:
	if is_dragging:
		_update_drag_preview()


func update_hover_preview() -> void:
	if world == null:
		return
	if is_dragging:
		return
	if not _uses_hover_preview():
		world.clear_drag_preview()
		return

	var hit := _raycast_block_at_mouse()
	if not hit.get("hit", false):
		world.clear_drag_preview()
		return

	var hit_pos: Vector3i = hit["pos"]
	if world.player_mode == World.PlayerMode.INFORMATION:
		# Outline exactly the block a click would inspect.
		world.set_drag_preview_entries([{"pos": hit_pos, "valid": _is_explored(hit_pos)}], world.player_mode)
		return
	if world.player_mode == World.PlayerMode.DIG:
		world.set_drag_preview_entries([{
			"pos": hit_pos,
			"valid": _dig_preview_is_currently_workable(hit_pos),
		}], world.player_mode)
		return
	if _is_stair_mode():
		var anchor := _up_stair_target_from_hit(hit_pos) if world.player_mode == World.PlayerMode.UP_STAIRS else _down_stair_target_from_hit(hit_pos)
		world.set_drag_preview_entries(_flight_preview_entries(anchor), world.player_mode)
		return
	var pos := hit_pos
	var valid := true
	if world.player_mode == World.PlayerMode.TORCH:
		pos = _torch_target_from_hit(hit_pos)
		valid = _can_place_torch_at(pos)
	elif world.player_mode == World.PlayerMode.CHOP:
		pos = _chop_target_from_hit(hit_pos)
		valid = _is_explored(hit_pos) and _can_chop_at(pos)
	elif world.player_mode == World.PlayerMode.STOCKPILE:
		pos = _stockpile_target_from_hit(hit_pos)
		valid = _can_create_stockpile_at(pos)
	else:
		pos = _erase_target_from_hit(hit_pos)
		valid = _can_erase_at(pos)
	if not valid:
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
	info_block_id = world.get_block_no_generate(pos.x, pos.y, pos.z)
	info_block_pos = pos


func _start_drag(mouse_pos: Vector2) -> void:
	if viewport == null:
		return
	drag_start = mouse_pos
	is_dragging = true
	drag_plane_y = _get_drag_plane_y(drag_start)
	drag_projection_y = _get_drag_projection_y(drag_start)


func _end_drag(drag_end: Vector2) -> void:
	if viewport == null or world == null:
		return
	var drag_rect := _get_drag_rect(drag_start, drag_end, drag_plane_y)
	_commit_selection(drag_start, drag_end, drag_rect)
	is_dragging = false
	world.clear_drag_preview()


func _update_drag_preview() -> void:
	if viewport == null or world == null:
		return
	var drag_now := input_state.mouse_position(viewport)
	if world.player_mode == World.PlayerMode.INFORMATION:
		# Information is click-only; keep the hover outline instead of a rectangle.
		return
	if _is_stair_mode():
		var hit := _raycast_block_from_screen_pos(drag_now)
		if hit.get("hit", false):
			var anchor := _up_stair_target_from_hit(hit.pos) if world.player_mode == World.PlayerMode.UP_STAIRS else _down_stair_target_from_hit(hit.pos)
			world.set_drag_preview_entries(_flight_preview_entries(anchor), world.player_mode)
		else:
			world.clear_drag_preview()
		return
	var drag_rect := _get_drag_rect(drag_start, drag_now, drag_plane_y)
	if drag_rect.is_empty():
		world.clear_drag_preview()
		return
	if world.player_mode == World.PlayerMode.DIG:
		world.set_drag_preview_entries(_build_drag_preview_entries(drag_rect), world.player_mode)
		return
	if world.player_mode == World.PlayerMode.TORCH:
		world.set_drag_preview_entries(_build_torch_preview_entries(drag_rect), world.player_mode)
		return
	if world.player_mode == World.PlayerMode.CHOP:
		world.set_drag_preview_entries(_build_chop_preview_entries(drag_rect), world.player_mode)
		return
	if world.player_mode == World.PlayerMode.STOCKPILE:
		world.set_drag_preview_entries(_build_stockpile_preview_entries(drag_rect), world.player_mode)
		return
	if world.player_mode == World.PlayerMode.ERASE:
		world.set_drag_preview_entries(_build_erase_preview_entries(drag_rect), world.player_mode)
		return
	world.set_drag_preview(drag_rect, world.player_mode)


func _raycast_block_at_mouse() -> Dictionary:
	if viewport == null:
		return {"hit": false}
	var mouse_pos := input_state.mouse_position(viewport)
	return _raycast_block_from_screen_pos(mouse_pos)


func _raycast_block_from_screen_pos(screen_pos: Vector2) -> Dictionary:
	if world == null or camera == null:
		return {"hit": false}
	var ray_origin := camera.project_ray_origin(screen_pos)
	var ray_dir := camera.project_ray_normal(screen_pos)
	return world.raycast_block(ray_origin, ray_dir, CAMERA_RAYCAST_DISTANCE,
		world.player_mode != World.PlayerMode.INFORMATION and not _is_stair_mode())


func _get_drag_plane_y(screen_pos: Vector2) -> float:
	# SEE-ADR-006: Drag selection resolves to one fixed world Y plane at drag start.
	var hit := _raycast_block_from_screen_pos(screen_pos)
	if hit.get("hit", false):
		var hit_pos: Vector3i = hit["pos"]
		var base_y := float(hit_pos.y)
		if world != null and world.player_mode == World.PlayerMode.PLACE:
			base_y += PLACE_HEIGHT_OFFSET
		elif world != null and world.player_mode == World.PlayerMode.TORCH:
			base_y += PLACE_HEIGHT_OFFSET
		elif world != null and world.player_mode == World.PlayerMode.UP_STAIRS:
			base_y = float(_up_stair_target_from_hit(hit_pos).y)
		elif world != null and world.player_mode == World.PlayerMode.DOWN_STAIRS:
			base_y = float(_down_stair_target_from_hit(hit_pos).y)
		elif world != null and world.player_mode == World.PlayerMode.ERASE:
			base_y = float(_erase_target_from_hit(hit_pos).y)
		elif world != null and world.player_mode == World.PlayerMode.STOCKPILE:
			base_y = float(_stockpile_target_from_hit(hit_pos).y)
		return base_y
	return float(world.top_render_y) if world != null else 0.0


## The height of the surface the player actually sees under the drag start: the
## clicked block's top face. Projecting onto a block's center instead shifted
## drag rectangles about 0.7 tiles away from the camera.
func _get_drag_projection_y(screen_pos: Vector2) -> float:
	var hit := _raycast_block_from_screen_pos(screen_pos)
	if hit.get("hit", false):
		return float(hit.pos.y) + BLOCK_TOP_FACE_OFFSET
	return float(world.top_render_y) if world != null else 0.0


func _get_drag_rect(start: Vector2, end: Vector2, plane_y: float) -> Dictionary:
	# SEE-ADR-006: Screen drag endpoints are projected into world X/Z coordinates
	# on the visible surface; plane_y is the target level stored in the rect.
	if camera_controller == null:
		return {}
	var a: Variant = camera_controller.screen_to_plane(start, drag_projection_y)
	var b: Variant = camera_controller.screen_to_plane(end, drag_projection_y)
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
	# A stair tool stamps one complete flight, never overlapping rectangle cells.
	if _is_stair_mode():
		_handle_click(end)
		return
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
	if world != null and world.player_mode == World.PlayerMode.STOCKPILE:
		var cells: Array[Vector3i] = []
		var unexplored_cells := 0
		for pos: Vector3i in _rect_positions(rect):
			if not _is_explored(pos):
				unexplored_cells += 1
			elif _can_create_stockpile_at(pos):
				cells.append(pos)
		var result := _stockpile_result(cells)
		if unexplored_cells > 0:
			result["unexplored_count"] = unexplored_cells
			if cells.is_empty():
				result["reason"] = "unexplored"
		_trace_selection("drag", min_x, max_x, min_z, max_z, y, [result])
		return
	if world != null and world.player_mode == World.PlayerMode.TORCH:
		for pos: Vector3i in _rect_positions(rect):
			if not _is_explored(pos):
				results.append({"pos": pos, "queued": false, "reason": "unexplored"})
			elif _can_place_torch_at(pos):
				var queued: bool = world.queue_task_request(TaskQueue.TaskType.TORCH, pos, 0)
				results.append({"pos": pos, "queued": queued, "reason": "queued" if queued else "duplicate"})
			else:
				results.append({"pos": pos, "queued": false, "reason": _torch_reject_reason(pos)})
		_trace_selection("drag", min_x, max_x, min_z, max_z, y, results)
		return
	if world != null and world.player_mode == World.PlayerMode.CHOP:
		for hit_pos: Vector3i in _rect_positions(rect):
			var tree_pos := _chop_target_from_hit(hit_pos)
			if not _is_explored(hit_pos) or not _is_explored(tree_pos):
				results.append({"pos": tree_pos, "queued": false, "reason": "unexplored"})
			elif _can_chop_at(tree_pos):
				var queued: bool = world.queue_task_request(TaskQueue.TaskType.CHOP, tree_pos, 0)
				results.append({"pos": tree_pos, "queued": queued, "reason": "queued" if queued else "duplicate"})
			else:
				results.append({"pos": tree_pos, "queued": false, "reason": "no_tree"})
		_trace_selection("drag", min_x, max_x, min_z, max_z, y, results)
		return
	if world != null and world.player_mode == World.PlayerMode.ERASE:
		for hit_pos: Vector3i in _rect_positions(rect):
			var erase_pos := _erase_target_from_hit(hit_pos)
			results.append(_enqueue_task_at(erase_pos.x, erase_pos.y, erase_pos.z))
		_trace_selection("drag", min_x, max_x, min_z, max_z, y, results)
		return

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
	elif world != null and world.player_mode == World.PlayerMode.TORCH:
		pos = _torch_target_from_hit(pos)
	elif world != null and world.player_mode == World.PlayerMode.UP_STAIRS:
		pos = _up_stair_target_from_hit(pos)
	elif world != null and world.player_mode == World.PlayerMode.DOWN_STAIRS:
		pos = _down_stair_target_from_hit(pos)
	elif world != null and world.player_mode == World.PlayerMode.ERASE:
		pos = _erase_target_from_hit(pos)
	elif world != null and world.player_mode == World.PlayerMode.STOCKPILE:
		pos = _stockpile_target_from_hit(pos)
	if world.player_mode == World.PlayerMode.INFORMATION:
		if not _is_explored(pos):
			selection_feedback.emit("Unexplored")
			return
		cell_inspected.emit(world.get_block_no_generate(pos.x, pos.y, pos.z), pos)
		return
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
	var block_id := world.get_block_no_generate(x, y, z) if _is_stair_mode() else world.get_block(x, y, z)
	result["block_id"] = block_id
	# Fog of war: unexplored cells cannot be designated, except excavation (dig,
	# stairs), which tunnels blind into the dark.
	if not _is_excavation_mode() and not _is_explored(pos):
		result["reason"] = "unexplored"
		return result

	match world.player_mode:
		World.PlayerMode.TORCH:
			if _can_place_torch_at(pos):
				result["queued"] = world.queue_task_request(TaskQueue.TaskType.TORCH, pos, 0)
				result["reason"] = "queued" if result["queued"] else "duplicate"
			else:
				result["reason"] = _torch_reject_reason(pos)
		World.PlayerMode.CHOP:
			var tree_pos := _chop_target_from_hit(pos)
			result["pos"] = tree_pos
			if not _is_explored(pos) or not _is_explored(tree_pos):
				result["reason"] = "unexplored"
			elif _can_chop_at(tree_pos):
				result["queued"] = world.queue_task_request(TaskQueue.TaskType.CHOP, tree_pos, 0)
				result["reason"] = "queued" if result["queued"] else "duplicate"
			else:
				result["reason"] = "no_tree"
		World.PlayerMode.DIG:
			var reject_reason := _dig_selection_reject_reason(pos)
			if reject_reason == "not_diggable" and not _is_explored(pos):
				# Hidden air reads as accepted (no task: nothing to dig) so the
				# designation does not give away a cave before it is found.
				result["queued"] = true
				result["reason"] = "hidden"
			elif reject_reason.is_empty():
				result["queued"] = world.queue_task_request(TaskQueue.TaskType.DIG, pos, 0)
				result["reason"] = "queued" if result["queued"] else "duplicate"
			else:
				result["reason"] = reject_reason
				if reject_reason == "stairs_require_removal" or reject_reason == "stair_support_protected":
					result["feedback"] = "Right-click the stairs and choose Remove stairs first"
		World.PlayerMode.PLACE:
			if world.is_empty(x, y, z) and world.task_queue.has_active_task_at(pos, TaskQueue.TaskType.TORCH):
				result["reason"] = "duplicate"
			elif world.is_empty(x, y, z) and _has_place_stock():
				result["queued"] = world.queue_task_request(TaskQueue.TaskType.PLACE, pos, PLACE_MATERIAL_ID)
				result["reason"] = "queued" if result["queued"] else "duplicate"
			elif not world.is_empty(x, y, z):
				result["reason"] = "not_empty"
			else:
				result["reason"] = "no_stock"
		World.PlayerMode.UP_STAIRS:
			if _can_place_up_stairs_at(pos):
				result["queued"] = world.queue_stair_flight(pos, stair_rotation, true)
				result["reason"] = "queued" if result["queued"] else "duplicate"
			else:
				result["reason"] = "up_stairs_not_placeable"
		World.PlayerMode.DOWN_STAIRS:
			if _can_place_down_stairs_at(pos):
				result["queued"] = world.queue_stair_flight(pos, stair_rotation, false)
				result["reason"] = "queued" if result["queued"] else "duplicate"
			else:
				result["reason"] = "down_stairs_not_placeable"
		World.PlayerMode.ERASE:
			var removed: Array = world.cancel_pending_task_requests_at(pos)
			var removed_stockpiles: Array[int] = world.remove_stockpile_cells([pos])
			var removed_torch: bool = world.torch_store.remove_torch(pos)
			result["queued"] = not removed.is_empty() or not removed_stockpiles.is_empty() or removed_torch
			result["reason"] = "cancelled:%d stockpile_cells:%d" % [removed.size(), removed_stockpiles.size()] if result["queued"] else "nothing_to_erase"
		World.PlayerMode.STOCKPILE:
			var cells: Array[Vector3i] = []
			if _can_create_stockpile_at(pos):
				cells.append(pos)
			result = _stockpile_result(cells)
			if cells.is_empty() and (world.is_stockpile_cell(pos) or world.is_stockpile_cell(pos + Vector3i.UP)):
				result["feedback"] = "Already designated as stockpile"
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
	var message := "%d accepted, %d rejected" % [queued.size(), rejected.size()]
	var unexplored := 0
	for result: Dictionary in results:
		unexplored += _unexplored_count(result)
	if unexplored > 0 and queued.is_empty() and kind == "drag":
		message = "%d cells unexplored" % unexplored
	elif results.size() == 1 and queued.is_empty():
		var reasons := {"no_stock": "Requires one stored iron ore", "not_empty": "Target is occupied", "no_valid_stockpile_cells": "No valid stockpile cells", "unsupported": "Requires a solid floor", "torch_exists": "Already has a torch", "torch_unavailable": "No valid torch cells", "duplicate": "Already designated", "nothing_to_erase": "Nothing to erase", "unexplored": "Unexplored", "no_tree": "No tree here"}
		message = str(results[0].get("feedback", reasons.get(results[0].get("reason", ""), "Action unavailable: " + str(results[0].get("reason", "unknown")))))
	elif unexplored > 0:
		message += ", %d cells unexplored" % unexplored
	selection_feedback.emit(message)
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


func _uses_hover_preview() -> bool:
	return world != null and (
		_is_stair_mode()
		or world.player_mode == World.PlayerMode.INFORMATION
		or world.player_mode == World.PlayerMode.DIG
		or world.player_mode == World.PlayerMode.ERASE
		or world.player_mode == World.PlayerMode.STOCKPILE
		or world.player_mode == World.PlayerMode.TORCH
		or world.player_mode == World.PlayerMode.CHOP
	)


func _is_stair_mode() -> bool:
	return world != null and (
		world.player_mode == World.PlayerMode.UP_STAIRS
		or world.player_mode == World.PlayerMode.DOWN_STAIRS
	)


func _build_drag_preview_entries(rect: Dictionary) -> Array[Dictionary]:
	var entries: Array[Dictionary] = []
	for pos: Vector3i in _rect_positions(rect):
		entries.append({
			"pos": pos,
			"valid": _dig_preview_is_currently_workable(pos),
		})
	return entries


func _build_stair_preview_entries(rect: Dictionary) -> Array[Dictionary]:
	return _flight_preview_entries(Vector3i(int(round(rect.max_x)), int(rect.y), int(round(rect.max_z))))


func _flight_preview_entries(anchor: Vector3i) -> Array[Dictionary]:
	var valid := _stair_preview_is_valid(anchor)
	var cells := Flight.cells(anchor, stair_rotation)
	return [
		{"pos": cells[0], "valid": valid, "stair_material": Flight.lower_id(stair_rotation)},
		{"pos": cells[1], "valid": valid, "stair_material": Flight.upper_id(stair_rotation)},
	]


func _build_erase_preview_entries(rect: Dictionary) -> Array[Dictionary]:
	var entries: Array[Dictionary] = []
	for hit_pos: Vector3i in _rect_positions(rect):
		var pos := _erase_target_from_hit(hit_pos)
		entries.append({
			"pos": pos,
			"valid": _can_erase_at(pos),
		})
	return entries


func _build_stockpile_preview_entries(rect: Dictionary) -> Array[Dictionary]:
	var entries: Array[Dictionary] = []
	for pos: Vector3i in _rect_positions(rect):
		entries.append({
			"pos": pos,
			"valid": _can_create_stockpile_at(pos),
		})
	return entries


func _rect_positions(rect: Dictionary) -> Array[Vector3i]:
	var min_x := int(floor(float(rect["min_x"]) + ROUND_HALF))
	var max_x := int(floor(float(rect["max_x"]) + ROUND_HALF))
	var min_z := int(floor(float(rect["min_z"]) + ROUND_HALF))
	var max_z := int(floor(float(rect["max_z"]) + ROUND_HALF))
	var y := int(rect["y"])
	var positions: Array[Vector3i] = []
	for x in range(min_x, max_x + 1):
		for z in range(min_z, max_z + 1):
			positions.append(Vector3i(x, y, z))
	return positions


func _dig_selection_reject_reason(pos: Vector3i) -> String:
	if world == null:
		return "missing_world"
	if not _is_valid_position(pos.x, pos.y, pos.z):
		return "invalid_position"
	var stair_reason := world.stair_dig_reject_reason(pos)
	if not stair_reason.is_empty():
		return stair_reason
	if not world.is_diggable_at(pos.x, pos.y, pos.z):
		return "not_diggable"
	if world.task_queue != null and world.task_queue.has_active_task_at(pos, TaskQueue.TaskType.DIG):
		return "duplicate"
	return ""


func _dig_preview_is_currently_workable(pos: Vector3i) -> bool:
	return _is_explored(pos) \
		and _dig_selection_reject_reason(pos).is_empty() \
		and _has_horizontal_dig_work_position(pos)


func _has_horizontal_dig_work_position(pos: Vector3i) -> bool:
	if world == null or world.pathfinder == null:
		return false
	return not preload("res://scripts/task_work_position_rules.gd").task_work_positions(
		world, world.pathfinder, pos, TaskQueue.TaskType.DIG).is_empty()


func _stair_preview_is_valid(pos: Vector3i) -> bool:
	if world == null:
		return false
	if world.player_mode == World.PlayerMode.UP_STAIRS:
		return _can_place_up_stairs_at(pos)
	if world.player_mode == World.PlayerMode.DOWN_STAIRS:
		return _can_place_down_stairs_at(pos)
	return false


func _up_stair_target_from_hit(hit_pos: Vector3i) -> Vector3i:
	return hit_pos + Vector3i.UP


func _down_stair_target_from_hit(hit_pos: Vector3i) -> Vector3i:
	# Anchor the upper end at the clicked surface; the other half descends away.
	return hit_pos - Flight.direction(stair_rotation)


func _can_place_up_stairs_at(pos: Vector3i) -> bool:
	return world != null and world.can_place_stair_flight(pos, stair_rotation, true)


func _can_place_down_stairs_at(pos: Vector3i) -> bool:
	return world != null and world.can_place_stair_flight(pos, stair_rotation, false)


func _erase_target_from_hit(hit_pos: Vector3i) -> Vector3i:
	if world == null:
		return hit_pos
	if _can_erase_at(hit_pos):
		return hit_pos
	var above := Vector3i(hit_pos.x, hit_pos.y + 1, hit_pos.z)
	if _can_erase_at(above):
		return above
	return hit_pos


func _can_erase_at(pos: Vector3i) -> bool:
	return world != null and _is_explored(pos) and (world.has_pending_task_request_at(pos) or world.is_stockpile_cell(pos) or world.torch_store.has_torch(pos))


func _chop_target_from_hit(hit_pos: Vector3i) -> Vector3i:
	if world == null:
		return hit_pos
	if world.tree_store.has_tree(hit_pos):
		return hit_pos
	var above := hit_pos + Vector3i.UP
	return above if world.tree_store.has_tree(above) else hit_pos


func _can_chop_at(pos: Vector3i) -> bool:
	return world != null and world.tree_store.has_tree(pos) and _is_explored(pos) \
		and world.task_queue.get_active_tasks_at(pos).is_empty()


func _build_chop_preview_entries(rect: Dictionary) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for hit_pos: Vector3i in _rect_positions(rect):
		var tree_pos := _chop_target_from_hit(hit_pos)
		result.append({"pos": tree_pos, "valid": _is_explored(hit_pos) and _can_chop_at(tree_pos)})
	return result


func _torch_target_from_hit(hit_pos: Vector3i) -> Vector3i:
	if world == null:
		return hit_pos
	var above := hit_pos + Vector3i.UP
	return above if _can_place_torch_at(above) else hit_pos


func _torch_reject_reason(pos: Vector3i) -> String:
	if not _is_explored(pos):
		return "unexplored"
	var site_reason: String = world.torch_site_reject_reason(pos)
	if not site_reason.is_empty():
		return site_reason
	if not world.task_queue.get_active_tasks_at(pos).is_empty():
		return "duplicate"
	return ""


func _can_place_torch_at(pos: Vector3i) -> bool:
	return world != null and _torch_reject_reason(pos).is_empty()


func _build_torch_preview_entries(rect: Dictionary) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for pos: Vector3i in _rect_positions(rect):
		result.append({"pos": pos, "valid": _can_place_torch_at(pos)})
	return result


func _stockpile_target_from_hit(hit_pos: Vector3i) -> Vector3i:
	if world == null:
		return hit_pos
	var above := Vector3i(hit_pos.x, hit_pos.y + 1, hit_pos.z)
	if _can_create_stockpile_at(above):
		return above
	return hit_pos


func _can_create_stockpile_at(pos: Vector3i) -> bool:
	return world != null \
		and _is_explored(pos) \
		and world.pathfinder != null \
		and world.is_block_coord_valid(pos.x, pos.y, pos.z) \
		and world.pathfinder.is_walkable(world, pos.x, pos.y, pos.z) \
		and not world.is_stockpile_cell(pos)


func _stockpile_result(cells: Array[Vector3i]) -> Dictionary:
	var result := {
		"pos": cells[0] if not cells.is_empty() else Vector3i.ZERO,
		"queued": false,
		"reason": "no_valid_stockpile_cells",
		"block_id": -1,
	}
	if world == null:
		result["reason"] = "missing_world"
		return result
	if cells.is_empty():
		return result
	var stockpile_id := world.create_stockpile(cells)
	result["queued"] = stockpile_id > 0
	result["reason"] = "stockpile:%d cells:%d" % [stockpile_id, cells.size()] if result["queued"] else "stockpile_failed"
	return result


func _unexplored_count(result: Dictionary) -> int:
	if result.has("unexplored_count"):
		return int(result["unexplored_count"])
	return 1 if str(result.get("reason", "")) == "unexplored" else 0


func _is_excavation_mode() -> bool:
	return world != null and (world.player_mode == World.PlayerMode.DIG or _is_stair_mode())


func _is_explored(pos: Vector3i) -> bool:
	if world == null or world.light_field == null or not world.light_field_built:
		return true
	return world.light_field.is_explored(pos.x, pos.y, pos.z)


func _is_valid_position(x: int, y: int, z: int) -> bool:
	return world != null and world.is_block_coord_valid(x, y, z)
