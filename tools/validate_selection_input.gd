extends SceneTree

# Keep Main's real input callbacks, selection controller, raycasts and worker UI.
# Only startup/simulation and rendering are replaced by a small deterministic map.
class SelectionWorld:
	extends World

	var preview_rect: Dictionary = {}
	var preview_entries: Array = []

	func _ready() -> void:
		_init_ramp_lookup()
		block_registry.load_from_csv(BLOCK_DATA_PATH)
		task_manager = TaskManager.new(self, task_queue)
		raycaster = WorldRaycasterScript.new(self)
		top_render_y = 8
		for x in range(-16, 17):
			for z in range(-12, 13):
				set_block_raw(x, 0, z, BLOCK_ID_GRANITE, true)

	func set_drag_preview(rect: Dictionary, _mode: int) -> void:
		preview_rect = rect.duplicate()

	func ensure_chunk_generated(coord: Vector3i) -> ChunkData:
		var chunk := ensure_chunk(coord)
		if chunk != null:
			chunk.generated = true
		return chunk

	func set_drag_preview_entries(entries: Array, _mode: int) -> void:
		preview_entries = entries.duplicate(true)

	func clear_drag_preview() -> void:
		preview_rect.clear()
		preview_entries.clear()


class InputMain:
	extends "res://scripts/Main.gd"

	func _ready() -> void:
		camera.position = Vector3(0, 20, 0)
		camera.look_at(Vector3.ZERO, Vector3.FORWARD)
		camera.size = 20.0
		camera_controller = MainCameraController.new()
		camera_controller.initialize(camera, get_viewport())
		selection_controller = MainSelectionController.new()
		selection_controller.initialize(world, camera, get_viewport(), camera_controller)
		worker_window_controller = MainWorkerWindowController.new()
		worker_window_controller.setup(hud_layer, world)
		_setup_context_menu()
		world_started = true
		menu_layer.hide()

	func _process(_dt: float) -> void:
		if not menu_open and not loading_active:
			handle_mouse()


var failures: Array[String] = []
var main: InputMain
var world: SelectionWorld


func _init() -> void:
	_run.call_deferred()


func _run() -> void:
	root.size = Vector2i(1000, 800)
	root.gui_embed_subwindows = true
	var scene := load("res://scenes/Main.tscn") as PackedScene
	var scene_root := scene.instantiate()
	scene_root.set_script(InputMain)
	main = scene_root
	main.get_node("World").set_script(SelectionWorld)
	root.add_child(main)
	world = main.world as SelectionWorld
	var worker := Worker.new()
	worker.worker_id = 1
	world.workers.append(worker)
	await process_frame
	await process_frame

	await _validate_terrain_selection()
	await _validate_worker_gui()
	await _validate_cancellation()
	await _validate_stockpile_erase()

	world.task_manager.shutdown()
	world.workers.clear()
	worker.free()
	main.free()
	if failures.is_empty():
		print("Selection input contract OK (Main events, worker GUI, cancellation, terrain selection and stockpile erase)")
		quit(0)
	else:
		for failure in failures:
			push_error(failure)
		quit(1)


func _validate_terrain_selection() -> void:
	world.set_player_mode(World.PlayerMode.DIG)
	var clicked := Vector3i(-9, 0, 6)
	await _click(_screen(clicked))
	_check(world.has_pending_task_request_at(clicked), "Normal terrain click did not queue DIG via Main")
	_check(not main.selection_controller.is_dragging, "Terrain release left selection dragging")
	var start := Vector3i(-8, 0, 5)
	var end := Vector3i(-6, 0, 6)
	await _drag(_screen(start), _screen(end))
	for x in range(start.x, end.x + 1):
		for z in range(start.z, end.z + 1):
			_check(world.has_pending_task_request_at(Vector3i(x, 0, z)), "Normal world-plane drag missed %s" % Vector3i(x, 0, z))
	_check(world.task_queue.active_count() == 7, "Terrain click/drag queued unexpected cells")
	world.task_queue.clear()


func _validate_worker_gui() -> void:
	main.worker_window_controller.toggle()
	await process_frame
	await process_frame
	var panel: PanelContainer = main.worker_window_controller.panel
	var details: Button = main.worker_window_controller.details_button
	var old_details: bool = main.worker_window_controller.details_visible
	await _click(details.get_global_rect().get_center())
	_check(main.worker_window_controller.details_visible != old_details, "Worker details button did not receive click")
	_check(world.task_queue.active_count() == 0 and not main.selection_controller.is_dragging,
		"Worker button click passed through Main into terrain")
	await _click(panel.get_global_rect().position + Vector2(4, 4))
	_check(world.task_queue.active_count() == 0, "Worker panel background click selected terrain")

	var selector: OptionButton = main.worker_window_controller.role_selectors[1]
	await _click(selector.get_global_rect().get_center())
	var popup := selector.get_popup()
	_check(popup.visible, "Role dropdown did not open from mouse events")
	_check(world.task_queue.active_count() == 0 and not main.selection_controller.is_dragging,
		"Opening role dropdown selected terrain")
	# Three equal-height role entries: the middle of the popup selects Hauler.
	await _click(Vector2(popup.position) + Vector2(popup.size) * 0.5)
	_check(world.workers[0].role_id == WorkerRoles.Role.HAULER and not popup.visible,
		"Role dropdown item did not receive mouse selection")
	_check(world.task_queue.active_count() == 0 and not main.selection_controller.is_dragging,
		"Selecting a role dropdown item selected terrain")
	await _click(selector.get_global_rect().get_center())
	# Dismissing an embedded popup with a terrain click must not start a drag.
	await _click(_screen(Vector3i(-10, 0, 7)))
	_check(not popup.visible, "Outside click did not dismiss role dropdown")
	_check(world.task_queue.active_count() == 0 and not main.selection_controller.is_dragging,
		"Dropdown dismissal click selected terrain")
	world.task_queue.clear()

	# A drag beginning on terrain and released over GUI cancels, even when the
	# release never reaches Main._unhandled_input().
	_mouse_button(_screen(Vector3i(-10, 0, 6)), true)
	_check(main.selection_controller.is_dragging, "Terrain press did not start drag")
	await process_frame
	_mouse_motion(details.get_global_rect().get_center(), true)
	_mouse_button(details.get_global_rect().get_center(), false)
	await process_frame
	_check(not main.selection_controller.is_dragging and world.task_queue.active_count() == 0,
		"GUI-consumed release left a stuck drag or committed terrain tasks")

	# Starting on a control and releasing outside must not acquire terrain input.
	_mouse_button(details.get_global_rect().get_center(), true)
	await process_frame
	_mouse_motion(_screen(Vector3i(-9, 0, 7)), true)
	_mouse_button(_screen(Vector3i(-9, 0, 7)), false)
	await process_frame
	_check(not main.selection_controller.is_dragging and world.task_queue.active_count() == 0,
		"GUI-origin drag committed terrain on outside release")
	main.worker_window_controller.close()


func _validate_cancellation() -> void:
	var start := _screen(Vector3i(-9, 0, 6))
	_mouse_button(start, true)
	main.open_menu()
	_check(not main.selection_controller.is_dragging, "Main menu opening did not cancel drag")
	_mouse_button(start, false)
	await _click(start)
	_check(world.task_queue.active_count() == 0, "Menu-open input reached terrain")
	main.close_menu()
	_mouse_button(start, false)
	await process_frame
	_check(world.task_queue.active_count() == 0, "Release after menu cancellation committed selection")
	main.loading_active = true
	await _click(start)
	main.loading_active = false
	_check(world.task_queue.active_count() == 0, "Loading input reached terrain")
	_mouse_button(start, true)
	main.notification(Node.NOTIFICATION_APPLICATION_FOCUS_OUT)
	_mouse_button(start, false)
	await process_frame
	_check(not main.selection_controller.is_dragging and world.task_queue.active_count() == 0,
		"Focus loss did not cancel terrain selection")

	# An earlier release cannot cancel a new gesture in the same frame.
	_mouse_button(start, true)
	_mouse_button(start, false)
	var next := _screen(Vector3i(-8, 0, 6))
	_mouse_button(next, true)
	await process_frame
	_check(main.selection_controller.is_dragging, "Previous release cancelled a new same-frame drag")
	_mouse_button(next, false)
	await process_frame
	_check(world.task_queue.active_count() == 2, "Normal selection failed after menu/focus cancellation")
	world.task_queue.clear()


func _validate_stockpile_erase() -> void:
	var floor_pos := Vector3i(-9, 0, 6)
	var cell := floor_pos + Vector3i.UP
	world.create_stockpile([cell])
	world.set_player_mode(World.PlayerMode.ERASE)
	_mouse_motion(_screen(floor_pos), false)
	main.update_hover_preview()
	_check(not world.preview_rect.is_empty() and int(world.preview_rect.get("y", -1)) == cell.y,
		"Stockpile erase hover did not preview cell above floor")
	await _click(_screen(floor_pos))
	_check(not world.is_stockpile_cell(cell), "Ordinary floor click did not erase stockpile above it")

	var cells: Array[Vector3i] = [Vector3i(-8, 1, 5), Vector3i(-7, 1, 5), Vector3i(-6, 1, 5)]
	world.create_stockpile(cells)
	world.set_player_mode(World.PlayerMode.ERASE)
	_mouse_button(_screen(cells[0] - Vector3i.UP), true)
	_check(main.selection_controller.drag_plane_y == 1.0, "Stockpile erase drag used floor Y")
	_mouse_motion(_screen(cells[-1] - Vector3i.UP), true)
	main.handle_mouse()
	_check(world.preview_entries.size() == cells.size(), "Stockpile drag preview missed cells")
	for entry: Dictionary in world.preview_entries:
		_check(entry["valid"] and cells.has(entry["pos"]), "Stockpile erase drag preview marked cell invalid")
	_mouse_button(_screen(cells[-1] - Vector3i.UP), false)
	await process_frame
	for stockpile_cell in cells:
		_check(not world.is_stockpile_cell(stockpile_cell), "Ordinary floor drag missed stockpile cell %s" % stockpile_cell)
	main.update_hover_preview()
	_check(world.preview_rect.is_empty(), "Empty erase target retained hover preview")

	world.task_queue.add_dig_task(floor_pos)
	world.create_stockpile([cell])
	await _click(_screen(floor_pos))
	_check(not world.has_pending_task_request_at(floor_pos) and world.is_stockpile_cell(cell),
		"Erase lost priority for a pending task directly on the hit block")
	await _click(_screen(floor_pos))
	_check(not world.is_stockpile_cell(cell), "Stockpile erase failed after removing floor task")
	world.task_queue.add_place_task(cell, World.BLOCK_ID_DIRT)
	await _click(_screen(floor_pos))
	_check(not world.has_pending_task_request_at(cell), "Erase no longer targets pending task above floor")


func _screen(pos: Vector3i) -> Vector2:
	return main.camera.unproject_position(Vector3(pos))


func _mouse_motion(pos: Vector2, held: bool) -> void:
	var event := InputEventMouseMotion.new()
	event.position = pos
	event.global_position = pos
	event.button_mask = MOUSE_BUTTON_MASK_LEFT if held else 0
	Input.parse_input_event(event)
	Input.flush_buffered_events()


func _mouse_button(pos: Vector2, pressed: bool) -> void:
	var event := InputEventMouseButton.new()
	event.position = pos
	event.global_position = pos
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = pressed
	event.button_mask = MOUSE_BUTTON_MASK_LEFT if pressed else 0
	Input.parse_input_event(event)
	Input.flush_buffered_events()


func _click(pos: Vector2) -> void:
	_mouse_motion(pos, false)
	_mouse_button(pos, true)
	await process_frame
	_mouse_button(pos, false)
	await process_frame


func _drag(start: Vector2, end: Vector2) -> void:
	_mouse_motion(start, false)
	_mouse_button(start, true)
	await process_frame
	_mouse_motion(end, true)
	await process_frame
	_mouse_button(end, false)
	await process_frame


func _check(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
