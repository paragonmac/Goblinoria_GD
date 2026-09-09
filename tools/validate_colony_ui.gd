extends SceneTree
const Fixture = preload("res://tools/validate_context_menu.gd")
const Policy = preload("res://scripts/ui/colony_window_policy.gd")
const Catalog = preload("res://scripts/ui/colony_capability_catalog.gd")

class UIMain extends Fixture.MenuMain:
	func _ready() -> void:
		super._ready()
		hud_controller.setup(hud_layer)
		_setup_debug_overlay()
		_setup_performance_capture()
		_setup_menu()
		_setup_live_diagnostics()
		_setup_colony_ui(false)
		set_process(false)

var main
var world: Fixture.MenuWorld
var ui
var checks := 0
var failures: Array[String] = []

func _init() -> void:
	_run.call_deferred()

func check(value: bool, message: String) -> void:
	checks += 1
	if not value: failures.append(message)

func settle() -> void:
	for i in range(8):
		ui.tick(0.05)
		await process_frame

func key(code: int, pressed: bool) -> void:
	var event := InputEventKey.new()
	event.keycode = code
	event.physical_keycode = code
	event.pressed = pressed
	Input.parse_input_event(event)
	Input.flush_buffered_events()

func mouse(pos: Vector2, button: int, pressed: bool) -> void:
	var motion := InputEventMouseMotion.new()
	motion.position = pos
	Input.parse_input_event(motion)
	Input.flush_buffered_events()
	var event := InputEventMouseButton.new()
	event.position = pos
	event.global_position = pos
	event.button_index = button
	event.pressed = pressed
	Input.parse_input_event(event)
	Input.flush_buffered_events()

func _run() -> void:
	root.size = Vector2i(1920, 1080)
	root.gui_embed_subwindows = true
	main = load("res://scenes/Main.tscn").instantiate()
	main.set_script(UIMain)
	main.get_node("World").set_script(Fixture.MenuWorld)
	root.add_child(main)
	world = main.world
	ui = main.colony_ui
	for id in range(1, 5):
		var worker := Worker.new()
		worker.worker_id = id
		worker.role_id = [0, 0, 1, 2][id - 1]
		world.workers.append(worker)
	world.workers[0].state = Worker.WorkerState.WORKING
	world.workers[1].state = Worker.WorkerState.WORKING
	world.workers[2].state = Worker.WorkerState.MOVING
	world.workers[2].carried_count = 1
	world.workers[2].carried_material_id = World.BLOCK_ID_IRON_ORE
	await settle()
	var counts: Dictionary = ui.model.snapshot().counts
	check(counts.working == 2 and counts.travelling == 1 and counts.reserve == 1,
		"Two working Miners, delivering Hauler and reserved Fighter have distinct counts")
	check(ui.model.get_row("worker", 3).description.contains("Carrying 1"), "Delivering worker exposes carried material without live diagnostics")
	check(not main.hud_controller.stockpile_panel.visible, "Prototype stockpile panel retired")
	check(not main.diagnostics_controller.service.enabled, "Player UI does not enable diagnostics")
	for category: Dictionary in Catalog.categories():
		ui.open_category(category.id)
		await settle()
		check(ui.jobs_popup.is_visible() if category.id == "assignments" else ui.management.visible, "Category opens: " + str(category.id))
		for feature: Dictionary in Catalog.entries(category.id):
			if feature.status in ["planned", "tentative"]:
				var tasks: int = world.task_queue.active_count()
				check(not ui.dispatch_feature(feature.id) and tasks == world.task_queue.active_count(), "Unavailable feature cannot dispatch: " + str(feature.id))
	ui.show_workers("reserve")
	await settle()
	check(ui.filtered.size() == 1 and int(ui.filtered[0].id) == 4, "Reserve filter explains idle fighter")
	ui.select_row("worker", 4)
	await settle()
	check(ui.panels.detail_text.text.to_lower().contains("not implemented"), "Fighter explains missing combat")
	check(ui.panels.priority_selectors.is_empty(), "Workers are information-only; priorities belong to Assignments")
	ui.open_assignments(4)
	check(ui.set_selected_work_priority("hauling", 2), "Assignments accepts explicit priority")
	await settle()
	check(world.workers[3].get_work_priority("hauling") == 2 and ui.model.get_row("worker", 4).activity != "reserve", "Explicit priority enables reserve worker hauling")
	var a := Vector3i(-2, 1, 0)
	var b := Vector3i(2, 1, 0)
	var stockpile_a: int = world.create_stockpile([a])
	var stockpile_b: int = world.create_stockpile([b])
	await settle()
	ui.select_row("stockpile", stockpile_b)
	ui.set_stockpile_category("stone", false)
	ui.set_material_override(1, 2)
	check(bool(world.stockpile_store.stockpiles[stockpile_a].allowed_categories.stone), "Filters preserve other stockpile")
	check(not bool(world.stockpile_store.stockpiles[stockpile_b].allowed_categories.stone), "Selected stockpile category edited")
	ui.set_material_override(1, 0)
	check(not world.stockpile_store.stockpiles[stockpile_b].material_overrides.has(1), "Use category clears exact override")
	var item: int = world.item_store.add_stack(1, 3, Vector3i(0, 1, 0))
	var id: int = world.task_queue.add_task(Vector3i(0, 1, 0), TaskQueue.TaskType.HAUL, 1)
	var task = world.task_queue.get_task(id)
	task.data.item_id = item
	world.item_store.reserve_item(item, id)
	var other: int = world.task_queue.add_task(Vector3i(0, 1, 0), TaskQueue.TaskType.DIG, 0)
	await settle()
	ui.select_row("job", id)
	ui.cancel_selected_job()
	check(world.task_queue.get_task(id) == null and world.task_queue.get_task(other) != null, "Cancel only selected pending job at shared cell")
	check(int(world.item_store.get_item(item).reserved_by_task_id) == -1, "Pending haul cancellation releases item")
	await settle()
	check(ui.panels.detail_text == null or ui._detail_signature == "missing", "Completed/removed target disclosed")
	ui.select_row("job", other)
	world.task_queue.get_task(other).status = TaskQueue.TaskStatus.IN_PROGRESS
	ui.cancel_selected_job()
	check(world.task_queue.get_task(other) != null, "Active task cannot be cancelled by pending action")
	ui.open_category("workers")
	await settle()
	ui.search.grab_focus()
	var mode: int = world.player_mode
	key(KEY_2, true)
	main._handle_gameplay_input()
	key(KEY_2, false)
	check(world.player_mode == mode, "Typing in search does not switch tools")
	ui.search.release_focus()
	await settle()
	main._handle_gameplay_input()
	check(world.player_mode == mode, "Typed shortcut never replays")
	var camera_size: float = main.camera.size
	var point: Vector2 = ui.search.get_global_rect().get_center()
	mouse(point, MOUSE_BUTTON_WHEEL_UP, true)
	check(main.camera.size == camera_size, "Panel scroll does not zoom world")
	point = ui.title.get_global_rect().get_center()
	mouse(point, MOUSE_BUTTON_RIGHT, true)
	mouse(Vector2(1000, 500), MOUSE_BUTTON_RIGHT, false)
	check(not main.context_menu_controller.is_visible(), "GUI-origin right gesture cannot open context menu")
	check(not main.camera_controller.right_mouse_down, "GUI-origin right gesture cannot pan")
	ui.inspect_cell(1, Vector3i.ZERO)
	await settle()
	# A text-edit context popup owns Escape before either dock does.
	for popup in root.get_embedded_subwindows():
		if popup.visible:
			key(KEY_ESCAPE, true)
			key(KEY_ESCAPE, false)
			check(not popup.visible and ui.details.visible, "Escape closes text popup before details")
	await settle()
	key(KEY_ESCAPE, true)
	key(KEY_ESCAPE, false)
	check(not ui.details.visible and ui.management.visible and not main.menu_open, "Escape closes newest panel before menu")
	key(KEY_ESCAPE, true)
	key(KEY_ESCAPE, false)
	check(not ui.management.visible and not main.menu_open, "Escape then closes management")
	ui.panels.confirm_new_world()
	await settle()
	key(KEY_3, true)
	key(KEY_ESCAPE, true)
	key(KEY_ESCAPE, false)
	main._handle_gameplay_input()
	check(world.player_mode == mode and not main.menu_open, "Confirmation popup consumes held shortcut without replay after Escape")
	key(KEY_3, false)
	await settle()
	var steps: int = world.simulation_steps
	ui.open_category("workers")
	main._process(0.016)
	check(world.simulation_steps > steps, "Management does not pause simulation")
	ui.select_row("worker", 1)
	main.loading_active = true
	check(ui.selection.is_empty(), "Loading clears captured targets")
	main.loading_active = false
	await settle()
	ui.inspect_cell(1, Vector3i.ZERO)
	world.runtime_epoch += 1
	check(not ui.valid_selection(), "Same-node world replacement rejects captured selection before next refresh")
	await settle()
	check(ui.selection.is_empty(), "Same-node replacement clears snapshots without diagnostics")
	# Window fitting is testable without moving a real desktop window.
	check(Policy.fit_size(Vector2i(2560, 1440), Vector2i(16, 48)) == Vector2i(1920, 1080), "1080 baseline on large screen")
	check(Policy.fit_size(Vector2i(1920, 1040), Vector2i(16, 48)) == Vector2i(1904, 992), "1080 desktop fits chrome/workarea")
	for size in [Vector2i(1280, 720), Vector2i(1920, 1080), Vector2i(2560, 1440), Vector2i(3840, 2160), Vector2i(3440, 1440)]:
		root.size = size
		root.content_scale_size = Vector2i(1920, 1080)
		root.content_scale_mode = Window.CONTENT_SCALE_MODE_CANVAS_ITEMS
		root.content_scale_aspect = Window.CONTENT_SCALE_ASPECT_EXPAND
		await settle()
		check(ui.root.size.x >= 1920 and ui.root.size.y >= 1080, "Scaled logical canvas fits " + str(size))
		check(ui.summary.get_parent().get_parent().size.y <= 56, "Summary respects 56-pixel top bar " + str(size))
		var button: Button = ui._tool_buttons[World.PlayerMode.DIG]
		var native_point: Vector2 = root.get_final_transform() * button.get_global_rect().get_center()
		world.set_player_mode(World.PlayerMode.INFORMATION)
		var task_count := world.task_queue.active_count()
		mouse(native_point, MOUSE_BUTTON_LEFT, true)
		mouse(native_point, MOUSE_BUTTON_LEFT, false)
		await settle()
		check(world.player_mode == World.PlayerMode.DIG and world.task_queue.active_count() == task_count, "Scaled tool picking dispatches once without terrain work " + str(size))
		ui.close_management()
		ui.close_details()
		world.set_player_mode(World.PlayerMode.INFORMATION)
		var cell := Vector3i(2, 0, 0)
		var logical_point: Vector2 = main.camera.unproject_position(Vector3(cell))
		var hit: Dictionary = main.selection_controller._raycast_block_from_screen_pos(logical_point)
		check(hit.get("hit", false) and hit.pos == cell, "Scaled camera ray selects projected cell " + str(size))
		var generation_before: int = world.generation_requests
		native_point = root.get_final_transform() * logical_point
		mouse(native_point, MOUSE_BUTTON_LEFT, true)
		check(main.selection_controller.is_dragging, "World press acquired selection at %s; hovered=%s blocked=%s" % [native_point, root.gui_get_hovered_control(), main._context_blocks_world_input()])
		mouse(native_point, MOUSE_BUTTON_LEFT, false)
		await settle()
		check(ui.selection.get("kind") == "cell" and world.generation_requests == generation_before,
			"Information click inspects loaded terrain without generation %s: selection=%s generation=%d/%d" % [size, ui.selection, generation_before, world.generation_requests])
	# Enabling observation cannot mutate a frozen completed renderer snapshot.
	world.renderer = WorldRenderer.new()
	world.renderer.initialize(world)
	world.add_child(world.renderer)
	world.renderer.diagnostics_render_bounds = {"min_x": 1}
	world.renderer.diagnostics_render_bounds.make_read_only()
	main.diagnostics_controller.set_enabled(true)
	check(world.renderer.diagnostics_render_bounds.get("min_x") == 1, "Diagnostics leaves frozen renderer evidence unchanged")
	main.diagnostics_controller.set_enabled(false)
	world.renderer.free()
	world.renderer = null
	world.task_manager.shutdown()
	for worker in world.workers: worker.free()
	world.workers.clear()
	main.free()
	await process_frame
	if failures.is_empty():
		print("COLONY_UI_OK (%d checks)" % checks)
		quit(0)
	else:
		for message in failures: push_error(message)
		quit(1)
