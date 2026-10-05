extends SceneTree

const SelectionFixture = preload("res://tools/validate_selection_input.gd")
const Catalog = preload("res://scripts/main_tool_catalog.gd")
const Context = preload("res://scripts/main_context_menu_controller.gd")
const StairFlight = preload("res://scripts/stair_flight.gd")


class MenuWorld:
	extends SelectionFixture.SelectionWorld
	var simulation_steps := 0
	var streaming_steps := 0
	var generation_requests := 0

	func update_world(_dt: float) -> void:
		simulation_steps += 1

	func update_streaming(_rect: Rect2, _plane: float, _dt: float, _camera: Camera3D = null, _render_band_rects: Dictionary = {}) -> void:
		streaming_steps += 1

	func ensure_chunk_generated(coord: Vector3i) -> ChunkData:
		generation_requests += 1
		return super.ensure_chunk_generated(coord)


class MenuCamera:
	extends MainCameraController
	# Deterministic overhead projection; pan/keyboard/zoom still use production code.
	func _apply_camera_rotation() -> void:
		pass


class MenuMain:
	extends "res://scripts/Main.gd"

	func _ready() -> void:
		camera.position = Vector3(0, 20, 0)
		camera.look_at(Vector3.ZERO, Vector3.FORWARD)
		camera.size = 20.0
		camera_controller = MenuCamera.new()
		camera_controller.initialize(camera, get_viewport())
		camera_controller.world_ref = world
		selection_controller = MainSelectionController.new()
		selection_controller.initialize(world, camera, get_viewport(), camera_controller)
		hud_controller = MainHudController.new()
		worker_window_controller = MainWorkerWindowController.new()
		worker_window_controller.setup(hud_layer, world)
		_setup_context_menu()
		world_started = true
		menu_layer.hide()


var main: MenuMain
var world: MenuWorld
var failures: Array[String] = []
var checks := 0
var held_buttons := 0


func _init() -> void:
	_run.call_deferred()


func _run() -> void:
	root.size = Vector2i(1000, 800)
	root.gui_embed_subwindows = true
	var scene := load("res://scenes/Main.tscn") as PackedScene
	var node := scene.instantiate()
	node.set_script(MenuMain)
	main = node
	main.get_node("World").set_script(MenuWorld)
	root.add_child(main)
	world = main.world
	var worker := Worker.new()
	worker.worker_id = 1
	world.workers.append(worker)
	await _settle()
	await _test_tools_and_modal_input()
	await _test_gestures_and_gui()
	await _test_context_actions()
	await _test_lifecycle_and_bounds()
	await _test_debug_frame_path()
	world.task_manager.shutdown()
	world.workers.clear()
	worker.free()
	main.free()
	await process_frame
	if failures.is_empty():
		print("Context menu contract OK (%d checks)" % checks)
		quit(0)
	else:
		for failure in failures:
			push_error(failure)
		quit(1)


func _test_tools_and_modal_input() -> void:
	var pos := _screen(Vector3i(-9, 0, 6))
	for tool: Dictionary in Catalog.TOOLS:
		await _right_click(pos)
		_check(_menu().is_visible(), "Right click opens menu")
		var item := _popup().get_item_index(int(world.player_mode))
		_check(item >= 0 and _popup().is_item_checked(item), "Current tool is checked")
		var before := world.task_queue.active_count()
		_key(int(tool["key"]), true)
		await _settle()
		_check(not _menu().is_visible() and world.player_mode == int(tool["mode"]), "Menu shortcut selects %s" % tool["label"])
		_check(world.task_queue.active_count() == before, "Switching tool queues no designation")
		_key(int(tool["key"]), false)
		await _settle()
		world.set_player_mode((int(tool["mode"]) + 1) % 7)
		_key(int(tool["key"]), true)
		await _settle()
		_key(int(tool["key"]), false)
		await _settle()
		_check(world.player_mode == int(tool["mode"]), "Normal hotkey matches menu")
		_check(main.hud_controller._get_mode_display_name(world) == str(tool["label"]), "HUD uses shared catalog")
	world.set_player_mode(World.PlayerMode.DIG)
	await _right_click(pos)
	var camera_pos := main.camera.position
	var camera_size := main.camera.size
	var yaw := main.camera_controller.cam_yaw
	var level := world.top_render_y
	var steps := world.simulation_steps
	var stream_steps := world.streaming_steps
	_key(KEY_UP, true)
	_key(KEY_COMMA, true)
	_key(KEY_BRACKETRIGHT, true)
	_button(pos, MOUSE_BUTTON_WHEEL_UP, true)
	_button(pos, MOUSE_BUTTON_WHEEL_UP, false)
	_key(KEY_SHIFT, true)
	_button(pos, MOUSE_BUTTON_MIDDLE, true)
	_motion(pos + Vector2(20, 10))
	await _settle()
	_check(world.simulation_steps > steps, "Simulation continues with menu open")
	_check(world.streaming_steps > stream_steps, "Streaming continues with menu open")
	_check(main.camera.position == camera_pos and main.camera.size == camera_size \
		and main.camera_controller.cam_yaw == yaw and world.top_render_y == level, "Popup blocks movement/orbit/zoom/rotation/level keys")
	_button(pos, MOUSE_BUTTON_MIDDLE, false)
	_key(KEY_SHIFT, false)
	_key(KEY_UP, false)
	_key(KEY_ESCAPE, true)
	await _settle()
	_check(not _menu().is_visible() and not main.menu_open, "Escape closes popup, not main menu")
	_check(main.camera_controller.cam_yaw == yaw and world.top_render_y == level, "Held shortcuts do not replay after dismissal")
	_key(KEY_ESCAPE, false)
	_key(KEY_COMMA, false)
	_key(KEY_BRACKETRIGHT, false)
	await _settle()
	await _right_click(pos)
	_key(KEY_W, true)
	await _settle()
	_check(main.worker_window_controller.visible, "Popup W opens Workers")
	await _settle()
	_check(main.worker_window_controller.visible, "Held W does not replay to close Workers")
	_key(KEY_W, false)
	await _settle()
	await _right_click(pos)
	await _choose(Context.ACTION_WORKERS)
	_check(main.worker_window_controller.visible, "Open Workers is idempotent")
	main.worker_window_controller.close()
	await _right_click(pos)
	var workers_row := Vector2(_popup().position) + Vector2(_popup().size.x * 0.5, _popup().size.y - 16)
	await _left_click(workers_row)
	_check(main.worker_window_controller.visible and not _menu().is_visible(), "Mouse activates popup item without click-through")
	_check(world.task_queue.active_count() == 0 and not main.selection_controller.is_dragging, "Popup mouse activation queues no terrain task")
	main.worker_window_controller.close()


func _test_gestures_and_gui() -> void:
	var pos := _screen(Vector3i(-9, 0, 6))
	var camera_pos := main.camera.position
	_motion(pos)
	_button(pos, MOUSE_BUTTON_RIGHT, true)
	_motion(pos + Vector2(5, 0))
	await process_frame
	_check(main.camera.position == camera_pos, "Subthreshold motion does not pan")
	_button(pos + Vector2(5, 0), MOUSE_BUTTON_RIGHT, false)
	await _settle()
	_check(_menu().is_visible(), "Subthreshold release opens popup")
	await _escape()
	_button(pos, MOUSE_BUTTON_RIGHT, true)
	_motion(pos + Vector2(6, 0))
	_motion(pos + Vector2(30, 0))
	await process_frame
	_check(main.camera.position != camera_pos, "Threshold claims camera pan")
	_motion(pos)
	_button(pos, MOUSE_BUTTON_RIGHT, false)
	await _settle()
	_check(not _menu().is_visible() and not main.camera_controller.right_mouse_down, "Pan returning to origin never opens menu")
	main.camera.position = camera_pos
	pos = _screen(Vector3i(-9, 0, 6))
	world.set_player_mode(World.PlayerMode.DIG)
	_button(pos, MOUSE_BUTTON_LEFT, true)
	_check(main.selection_controller.is_dragging, "World left press starts selection")
	_button(pos, MOUSE_BUTTON_RIGHT, true)
	_button(pos, MOUSE_BUTTON_RIGHT, false)
	_button(pos, MOUSE_BUTTON_LEFT, false)
	await _settle()
	_check(not _menu().is_visible() and not main.selection_controller.is_dragging \
		and world.task_queue.active_count() == 0, "Right during left drag cancels whole gesture")
	await _right_click(pos)
	await _left_click(Vector2(5, 790))
	_check(not _menu().is_visible() and world.task_queue.active_count() == 0, "Outside left dismissal does not select terrain")
	await _right_click(pos)
	await _right_click(Vector2(5, 790))
	_check(not _menu().is_visible(), "Outside right dismissal does not reopen popup")
	await _left_click(pos)
	_check(world.has_pending_task_request_at(Vector3i(-9, 0, 6)), "Left selection works after pan and popup dismissal")
	world.task_queue.clear()
	main.worker_window_controller.open()
	await _settle()
	var panel_pos: Vector2 = main.worker_window_controller.panel.get_global_rect().position + Vector2(4, 4)
	await _right_click(panel_pos)
	_check(not _menu().is_visible(), "Right click on Workers belongs to GUI")
	_button(panel_pos, MOUSE_BUTTON_RIGHT, true)
	_motion(pos)
	_button(pos, MOUSE_BUTTON_RIGHT, false)
	await _settle()
	_check(not _menu().is_visible() and main.camera.position == camera_pos, "GUI-origin right drag cannot become pan")
	_button(pos, MOUSE_BUTTON_RIGHT, true)
	# No motion: release over GUI must still cancel pending ownership.
	_button(panel_pos, MOUSE_BUTTON_RIGHT, false)
	await _settle()
	_check(not _menu().is_visible() and not main.camera_controller.right_mouse_down, "GUI-owned release cancels right gesture")
	var selector: OptionButton = main.worker_window_controller.role_selectors[1]
	await _left_click(selector.get_global_rect().get_center())
	_check(selector.get_popup().visible, "Role popup opens")
	await _right_click(pos)
	_check(not selector.get_popup().visible and not _menu().is_visible(), "Role-popup dismissal cannot open context menu")
	main.worker_window_controller.close()


func _test_context_actions() -> void:
	var floor_pos := Vector3i(-9, 0, 6)
	var above := floor_pos + Vector3i.UP
	var pos := _screen(floor_pos)
	world.set_player_mode(World.PlayerMode.DIG)
	await _right_click(pos)
	_check(_disabled(Context.ACTION_CANCEL_TASKS) and _disabled(Context.ACTION_REMOVE_STOCKPILE), "Unavailable actions are disabled")
	await _choose(Context.ACTION_INSPECT)
	_check(_menu().snapshot_panel.visible and str(_menu().snapshot_label.text).contains(world.get_block_name(World.BLOCK_ID_GRANITE)), "Inspect shows readable block snapshot")
	_check(world.player_mode == World.PlayerMode.DIG, "Inspect preserves active tool")
	_menu().snapshot_panel.hide()
	world.task_queue.add_dig_task(floor_pos)
	world.task_queue.add_place_task(above, World.BLOCK_ID_DIRT)
	await _right_click(pos)
	await _choose(Context.ACTION_CANCEL_TASKS)
	_check(not world.has_pending_task_request_at(floor_pos) and world.has_pending_task_request_at(above), "Cancel prefers hit over above")
	await _right_click(pos)
	await _choose(Context.ACTION_CANCEL_TASKS)
	_check(not world.has_pending_task_request_at(above), "Cancel falls back to above")
	var task_id := world.task_queue.add_dig_task(floor_pos)
	await _right_click(pos)
	world.task_queue.get_task(task_id).status = TaskQueue.TaskStatus.IN_PROGRESS
	await _choose(Context.ACTION_CANCEL_TASKS)
	_check(world.task_queue.get_task(task_id) != null, "Task becoming active is not cancelled")
	_check(str(_menu().status_label.text).contains("Target changed"), "Stale action explains rejection")
	world.task_queue.clear()
	var old_id := world.task_queue.add_dig_task(floor_pos)
	await _right_click(pos)
	world.cancel_pending_task_requests_at(floor_pos)
	var replacement := world.task_queue.add_dig_task(floor_pos)
	await _choose(Context.ACTION_CANCEL_TASKS)
	_check(replacement != old_id and world.task_queue.get_task(replacement) != null, "Replacement task identity cannot be cancelled by stale menu")
	world.task_queue.clear()
	var stockpile_id := world.create_stockpile([above, above + Vector3i.RIGHT])
	var item_id := world.item_store.add_stack(World.BLOCK_ID_DIRT, 3, floor_pos)
	var haul_id := world.task_queue.add_haul_task(item_id, floor_pos, World.BLOCK_ID_DIRT, stockpile_id, above)
	world.item_store.reserve_item(item_id, haul_id)
	await _right_click(pos)
	await _choose(Context.ACTION_CANCEL_TASKS)
	_check(world.task_queue.get_task(haul_id) == null \
		and world.item_store.get_item(item_id)["reserved_by_task_id"] == -1, "Context cancellation releases pending haul reservation")
	var stored_id := world.item_store.add_stack(World.BLOCK_ID_GRANITE, 2, above, stockpile_id)
	world.refresh_inventory_from_stockpiles()
	await _right_click(pos)
	await _choose(Context.ACTION_REMOVE_STOCKPILE)
	_check(not world.is_stockpile_cell(above) and world.is_stockpile_cell(above + Vector3i.RIGHT), "Remove affects only chosen stockpile cell")
	_check(world.item_store.get_item(stored_id)["stored_stockpile_id"] == -1 \
		and world.get_inventory_count(World.BLOCK_ID_GRANITE) == 0, "Removed designation makes items loose and refreshes inventory")
	world.create_stockpile([above])
	await _right_click(pos)
	world.remove_stockpile_cells([above])
	world.create_stockpile([above])
	await _choose(Context.ACTION_REMOVE_STOCKPILE)
	_check(world.is_stockpile_cell(above), "Stale menu cannot remove replacement stockpile")
	await _right_click(pos)
	world.set_block_raw(floor_pos.x, floor_pos.y, floor_pos.z, World.BLOCK_ID_DIRT, true)
	await _choose(Context.ACTION_INSPECT)
	_check(not _menu().snapshot_panel.visible, "Changed inspected block rejects stale target")
	world.set_block_raw(floor_pos.x, floor_pos.y, floor_pos.z, World.BLOCK_ID_GRANITE, true)
	world.set_block_raw(floor_pos.x, 3, floor_pos.z, World.BLOCK_ID_DIRT, true)
	world.top_render_y = 1
	await _right_click(pos)
	await _choose(Context.ACTION_INSPECT)
	_check(str(_menu().snapshot_label.text).contains(world.get_block_name(World.BLOCK_ID_GRANITE)), "Context raycast respects visible render level")
	_menu().snapshot_panel.hide()
	world.top_render_y = 8
	world.set_block_raw(floor_pos.x, 3, floor_pos.z, World.BLOCK_ID_AIR, true)
	# Outside the loaded map: context rays must not trigger generation.
	main.camera.position = Vector3(90, 20, 90)
	world.set_player_mode(World.PlayerMode.DIG)
	var generated := world.generation_requests
	var chunk_count := world.chunks.size()
	await _right_click(Vector2(400, 400))
	_check(_menu().is_visible() and _disabled(Context.ACTION_INSPECT), "Empty ray offers generic menu only")
	_check(world.generation_requests == generated and world.chunks.size() == chunk_count, "Menu does not generate missing terrain")
	await _escape()
	main.camera.position = Vector3(0, 20, 0)

	# Stair removal captures the complete player-stair footprint and queues the
	# real World action, while preserving STAIRS task classification.
	var stair_anchor := Vector3i(-9, 1, 6)
	var stair_cells := StairFlight.cells(stair_anchor, 0)
	world.task_queue.clear()
	_set_stair_pair(stair_anchor, 0)
	await _right_click(_screen(stair_anchor))
	_check(not _disabled(Context.ACTION_REMOVE_STAIRS), "Player stair pair enables Remove stairs")
	await _choose(Context.ACTION_REMOVE_STAIRS)
	var removal_task = world.task_queue.find_nearest(TaskQueue.TaskType.STAIRS, Vector3(stair_anchor))
	_check(removal_task != null and bool(removal_task.data.get("remove_stairs", false)) \
		and removal_task.data.get("footprint", []) == stair_cells, "Context action queues real stair-removal task")
	_check(not world.queue_stair_removal(stair_anchor), "Duplicate stair removal is rejected")

	# Either half selects the same flight. Cancel through the upper half to
	# exercise the existing footprint-aware pending-task path.
	await _right_click(_screen(stair_cells[1]))
	_check(not _disabled(Context.ACTION_REMOVE_STAIRS), "Upper stair half enables Remove stairs")
	await _choose(Context.ACTION_CANCEL_TASKS)
	_check(world.task_queue.get_task(removal_task.id) == null, "Pending stair removal can be cancelled from upper half")
	_set_stair_pair(stair_anchor, 0)
	await _right_click(_screen(stair_cells[1]))
	await _choose(Context.ACTION_REMOVE_STAIRS)
	removal_task = world.task_queue.find_nearest(TaskQueue.TaskType.STAIRS, Vector3(stair_anchor))
	_check(removal_task != null and removal_task.pos == stair_anchor, "Upper-half selection queues the flight anchor")

	# A changed second half invalidates the menu snapshot instead of retargeting
	# the remaining half as a legacy/orphan stair.
	world.task_queue.clear()
	_set_stair_pair(stair_anchor, 0)
	await _right_click(_screen(stair_anchor))
	world.set_block_raw(stair_cells[1].x, stair_cells[1].y, stair_cells[1].z, World.BLOCK_ID_DIRT, true)
	await _choose(Context.ACTION_REMOVE_STAIRS)
	_check(world.task_queue.active_count() == 0 and str(_menu().status_label.text).contains("Target changed"), "Changed stair half rejects stale removal")

	# Generated terrain slopes are deliberately unavailable to player-stair removal.
	world.task_queue.clear()
	world.set_block_raw(stair_anchor.x, stair_anchor.y, stair_anchor.z, World.TERRAIN_SLOPE_NORTH_ID, true)
	await _right_click(_screen(stair_anchor))
	_check(_disabled(Context.ACTION_REMOVE_STAIRS), "Natural terrain slope has no Remove stairs action")
	await _escape()


func _test_lifecycle_and_bounds() -> void:
	for point in [Vector2(3, 3), Vector2(997, 3), Vector2(3, 797), Vector2(997, 797)]:
		await _right_click(point)
		_check(_menu().is_visible(), "Corner right click opens menu")
		var rect := Rect2i(_popup().position, _popup().size)
		_check(Rect2i(Vector2i.ZERO, root.size).encloses(rect), "Popup stays inside viewport at %s" % point)
		await _escape()
	root.size = Vector2i(320, 240)
	await _settle()
	await _right_click(Vector2(315, 235))
	_check(_menu().is_visible(), "Small viewport menu opens")
	_check(Rect2i(Vector2i.ZERO, root.size).encloses(Rect2i(_popup().position, _popup().size)), "Small viewport constrains popup")
	root.size = Vector2i(1000, 800)
	await _settle()
	_check(not _menu().is_visible(), "Resize closes popup")
	var pos := _screen(Vector3i(-9, 0, 6))
	await _right_click(pos)
	main.notification(Node.NOTIFICATION_APPLICATION_FOCUS_OUT)
	_check(not _menu().is_visible(), "Focus loss closes popup")
	await _settle()
	await _right_click(pos)
	main.open_menu()
	_check(not _menu().is_visible(), "Main menu closes popup")
	main.close_menu()
	await _settle()
	await _right_click(pos)
	await _choose(Context.ACTION_INSPECT)
	main.loading_active = true
	_check(not _menu().is_visible() and not _menu().snapshot_panel.visible, "Loading clears menu and inspection snapshot")
	await _right_click(pos)
	_check(not _menu().is_visible(), "Loading cannot open context menu")
	main.loading_active = false
	await _settle()
	for pan in [false, true]:
		_button(pos, MOUSE_BUTTON_RIGHT, true)
		if pan:
			_motion(pos + Vector2(20, 0))
		main.loading_active = true
		_button(pos, MOUSE_BUTTON_RIGHT, false)
		_key(KEY_7, true)
		_key(KEY_W, true)
		_key(KEY_ESCAPE, true)
		await _settle()
		var mode := world.player_mode
		main.loading_active = false
		await _settle()
		_check(not _menu().is_visible() and not main.camera_controller.right_mouse_down, "Loading cancels pending/claimed right gesture")
		_check(world.player_mode == mode and not main.worker_window_controller.visible and not main.menu_open, "Loading keys cannot replay on completion")
		_key(KEY_7, false)
		_key(KEY_W, false)
		_key(KEY_ESCAPE, false)
		await _settle()
	main.camera.position = Vector3(0, 20, 0)
	await _right_click(pos)
	_check(_menu().is_visible(), "Open popup before loading transition")
	main.loading_active = true
	_check(not _menu().is_visible(), "Loading closes an open popup")
	main.loading_active = false
	await _settle()
	_button(pos, MOUSE_BUTTON_RIGHT, true)
	main.notification(Node.NOTIFICATION_APPLICATION_FOCUS_OUT)
	_button(pos, MOUSE_BUTTON_RIGHT, false)
	await _settle()
	_check(not _menu().is_visible() and not main.camera_controller.right_mouse_down, "Focus loss clears pending right gesture")
	_button(pos, MOUSE_BUTTON_RIGHT, true)
	_motion(pos + Vector2(20, 0))
	main.camera_controller.free_orbit_dragging = true
	main.notification(Node.NOTIFICATION_APPLICATION_FOCUS_OUT)
	_button(pos, MOUSE_BUTTON_RIGHT, false)
	await _settle()
	_check(not main.camera_controller.right_mouse_down and not main.camera_controller.free_orbit_dragging, "Focus loss clears claimed pan and orbit")
	await _right_click(pos)
	_check(_menu().is_visible(), "Normal gesture works after focus cancellation")
	await _escape()


func _test_debug_frame_path() -> void:
	# Exercise the production timed path too, without enabling trace/file output.
	main.debug_overlay = DebugOverlay.new()
	main.debug_overlay.world = world
	main.add_child(main.debug_overlay)
	main.render_level_controller = MainRenderLevelController.new()
	await _right_click(_screen(Vector3i(-9, 0, 6)))
	var steps := world.simulation_steps
	var streamed := world.streaming_steps
	var camera_pos := main.camera.position
	_key(KEY_RIGHT, true)
	await _settle()
	_key(KEY_RIGHT, false)
	_check(_menu().is_visible() and world.simulation_steps > steps and world.streaming_steps > streamed, "Debug-overlay frame path keeps simulation/streaming running")
	_check(main.camera.position == camera_pos, "Debug-overlay frame path still gates camera input")
	await _escape()


func _menu():
	return main.context_menu_controller


func _popup() -> PopupMenu:
	return _menu().popup


func _disabled(id: int) -> bool:
	return _popup().is_item_disabled(_popup().get_item_index(id))


func _choose(id: int) -> void:
	# Keyboard focus + Enter travels through the popup's real input handling.
	_popup().set_focused_item(_popup().get_item_index(id))
	_key(KEY_ENTER, true)
	await process_frame
	_key(KEY_ENTER, false)
	await _settle()


func _screen(pos: Vector3i) -> Vector2:
	return main.camera.unproject_position(Vector3(pos))


func _set_stair_pair(anchor: Vector3i, rotation: int) -> void:
	var cells := StairFlight.cells(anchor, rotation)
	world.set_block_raw(cells[0].x, cells[0].y, cells[0].z, StairFlight.lower_id(rotation), true)
	world.set_block_raw(cells[1].x, cells[1].y, cells[1].z, StairFlight.upper_id(rotation), true)


func _key(code: int, pressed: bool) -> void:
	var event := InputEventKey.new()
	event.keycode = code
	event.physical_keycode = code
	event.pressed = pressed
	Input.parse_input_event(event)
	Input.flush_buffered_events()


func _motion(pos: Vector2) -> void:
	var event := InputEventMouseMotion.new()
	event.position = pos
	event.global_position = pos
	event.button_mask = held_buttons
	Input.parse_input_event(event)
	Input.flush_buffered_events()


func _button(pos: Vector2, button: int, pressed: bool) -> void:
	var mask := 1 << (button - 1)
	if pressed:
		held_buttons |= mask
	else:
		held_buttons &= ~mask
	var event := InputEventMouseButton.new()
	event.position = pos
	event.global_position = pos
	event.button_index = button
	event.pressed = pressed
	event.button_mask = held_buttons
	Input.parse_input_event(event)
	Input.flush_buffered_events()


func _right_click(pos: Vector2) -> void:
	_motion(pos)
	_button(pos, MOUSE_BUTTON_RIGHT, true)
	await process_frame
	_button(pos, MOUSE_BUTTON_RIGHT, false)
	await _settle()


func _left_click(pos: Vector2) -> void:
	_motion(pos)
	_button(pos, MOUSE_BUTTON_LEFT, true)
	await process_frame
	_button(pos, MOUSE_BUTTON_LEFT, false)
	await _settle()


func _escape() -> void:
	_key(KEY_ESCAPE, true)
	await process_frame
	_key(KEY_ESCAPE, false)
	await _settle()


func _settle() -> void:
	await process_frame
	await process_frame


func _check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)
