extends SceneTree
const Fixture = preload("res://tools/validate_colony_ui.gd")
const MenuFixture = preload("res://tools/validate_context_menu.gd")
const Flight = preload("res://scripts/stair_flight.gd")

var main
var world
var ui
var checks := 0
var failures: Array[String] = []

func _init() -> void:
	_run.call_deferred()

func check(value: bool, message: String) -> void:
	checks += 1
	if not value: failures.append(message)

func settle() -> void:
	for i in range(4):
		ui.tick(0.05)
		await process_frame

func motion(point: Vector2) -> void:
	var event := InputEventMouseMotion.new()
	event.position = point
	event.global_position = point
	Input.parse_input_event(event)
	Input.flush_buffered_events()

func mouse(point: Vector2, code: int, pressed: bool) -> void:
	var event := InputEventMouseButton.new()
	event.position = point
	event.global_position = point
	event.button_index = code
	event.pressed = pressed
	Input.parse_input_event(event)
	Input.flush_buffered_events()

func key(code: int, pressed: bool) -> void:
	var event := InputEventKey.new()
	event.keycode = code
	event.pressed = pressed
	Input.parse_input_event(event)
	Input.flush_buffered_events()

func _run() -> void:
	root.size = Vector2i(1920, 1080)
	root.gui_embed_subwindows = true
	main = load("res://scenes/Main.tscn").instantiate()
	main.set_script(Fixture.UIMain)
	main.get_node("World").set_script(MenuFixture.MenuWorld)
	root.add_child(main)
	world = main.world
	ui = main.colony_ui
	await settle()
	var selection = main.selection_controller
	var point: Vector2 = main.camera.unproject_position(Vector3(0, 0.5, 0))
	world.set_player_mode(World.PlayerMode.UP_STAIRS)
	motion(point)
	selection.update_hover_preview()
	var generated: int = world.generation_requests
	var zoom: float = main.camera.size
	var queued: int = world.task_queue.active_count()
	for rotation in range(4):
		check(selection.stair_rotation == rotation, "Wheel cycles cardinal rotation %d" % rotation)
		selection.update_hover_preview()
		var entries: Array = world.preview_entries
		check(entries.size() == 2, "Ghost has two cells")
		if entries.size() == 2:
			check(entries[1].pos - entries[0].pos == Flight.direction(rotation), "Ghost footprint follows rotation")
			check(entries[0].stair_material == Flight.lower_id(rotation) and entries[1].stair_material == Flight.upper_id(rotation), "Ghost geometry follows rotation")
			check(entries[0].valid and entries[1].valid, "Supported empty flight is placeable")
		mouse(point, MOUSE_BUTTON_WHEEL_UP, true)
		mouse(point, MOUSE_BUTTON_WHEEL_UP, false)
	check(selection.stair_rotation == 0 and main.camera.size == zoom, "Four wheel steps wrap without zoom")
	mouse(point, MOUSE_BUTTON_WHEEL_DOWN, true)
	mouse(point, MOUSE_BUTTON_WHEEL_DOWN, false)
	check(selection.stair_rotation == 3, "Wheel down rotates the opposite way once")
	check(world.task_queue.active_count() == queued and world.generation_requests == generated, "Preview/rotation neither queues tasks nor generates terrain")
	var expected: Vector3i = world.preview_entries[0].pos
	mouse(point, MOUSE_BUTTON_LEFT, true)
	mouse(point, MOUSE_BUTTON_LEFT, false)
	check(world.task_queue.active_count() == queued + 1, "Click queues one complete flight")
	check(world.has_pending_task_request_at(expected) and world.has_pending_task_request_at(expected + Flight.direction(3)), "Both ghost cells belong to the queued designation")
	check(main.context_menu_controller._pending_tasks_at(expected) == main.context_menu_controller._pending_tasks_at(expected + Flight.direction(3)), "Context cancellation captures the same task from either half")
	world.cancel_pending_task_requests_at(expected)
	check(world.task_queue.active_count() == queued, "Cancelling flight removes the whole designation")
	ui.open_category("workers")
	await settle()
	var panel_point: Vector2 = ui.management.get_global_rect().get_center()
	motion(panel_point)
	mouse(panel_point, MOUSE_BUTTON_WHEEL_UP, true)
	mouse(panel_point, MOUSE_BUTTON_WHEEL_UP, false)
	check(selection.stair_rotation == 3 and main.camera.size == zoom, "Panel scrolling does not rotate or zoom")
	ui.close_management()
	motion(point)
	mouse(point, MOUSE_BUTTON_RIGHT, true)
	mouse(point, MOUSE_BUTTON_RIGHT, false)
	await settle()
	check(main.context_menu_controller.is_visible(), "Context menu opens with stair tool")
	mouse(point, MOUSE_BUTTON_WHEEL_UP, true)
	mouse(point, MOUSE_BUTTON_WHEEL_UP, false)
	check(selection.stair_rotation == 3 and main.camera.size == zoom, "Context popup owns wheel")
	main._cancel_context_input()
	main.open_menu()
	mouse(point, MOUSE_BUTTON_WHEEL_UP, true)
	mouse(point, MOUSE_BUTTON_WHEEL_UP, false)
	check(selection.stair_rotation == 3 and world.preview_entries.is_empty(), "Menu clears preview and prevents rotation")
	main.menu_open = false
	main.menu_layer.hide()
	await settle()
	world.set_player_mode(World.PlayerMode.DOWN_STAIRS)
	for x in range(-2, 3):
		for z in range(-2, 3):
			world.set_block_raw(x, 1, z, World.BLOCK_ID_GRANITE, true)
	point = main.camera.unproject_position(Vector3(0, 1.5, 0))
	motion(point)
	selection.update_hover_preview()
	check(world.preview_entries.size() == 2 and world.preview_entries[1].pos == Vector3i(0, 1, 0), "Down ghost anchors its upper half at the cursor hit")
	check(world.preview_entries[0].valid, "Down flight converts two supported solid cells")
	var blocked: Vector3i = world.preview_entries[0].pos
	world.set_block_raw(blocked.x, blocked.y + 1, blocked.z, World.BLOCK_ID_GRANITE, true)
	var invalid: Array = selection._flight_preview_entries(blocked)
	check(not invalid[0].valid and not invalid[1].valid, "Blocked headroom marks the whole ghost invalid")
	world.set_player_mode(World.PlayerMode.DIG)
	selection.update_hover_preview()
	check(world.preview_entries.size() == 1 and not world.preview_entries[0].has("stair_material"), "Dig replaces stair ghost with a block hover highlight")
	motion(point)
	mouse(point, MOUSE_BUTTON_WHEEL_UP, true)
	check(main.camera.size != zoom, "Non-stair tools retain wheel zoom")
	world.task_manager.shutdown()
	main.free()
	await process_frame
	if failures.is_empty():
		print("STAIR_INPUT_OK (%d checks)" % checks)
		quit(0)
	else:
		for message in failures: push_error(message)
		quit(1)
