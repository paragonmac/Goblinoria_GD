extends SceneTree
const Fixture = preload("res://tools/validate_colony_ui.gd")
const MenuFixture = preload("res://tools/validate_context_menu.gd")

var main
var ui
var world: MenuFixture.MenuWorld
var checks := 0
var failures: Array[String] = []

func _init() -> void:
	_run.call_deferred()

func check(value: bool, message: String) -> void:
	checks += 1
	if not value: failures.append(message)

func settle() -> void:
	for index in range(10):
		ui.tick(0.05)
		await process_frame

func click(control: Control) -> void:
	var point := root.get_final_transform() * control.get_global_rect().get_center()
	var motion := InputEventMouseMotion.new()
	motion.position = point
	Input.parse_input_event(motion)
	Input.flush_buffered_events()
	for pressed in [true, false]:
		var event := InputEventMouseButton.new()
		event.position = point
		event.global_position = point
		event.button_index = MOUSE_BUTTON_LEFT
		event.pressed = pressed
		Input.parse_input_event(event)
		Input.flush_buffered_events()
	await settle()

func motion(point: Vector2) -> void:
	var event := InputEventMouseMotion.new()
	event.position = root.get_final_transform() * point
	Input.parse_input_event(event)
	Input.flush_buffered_events()

func button(point: Vector2, pressed: bool) -> void:
	var event := InputEventMouseButton.new()
	event.position = root.get_final_transform() * point
	event.global_position = event.position
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = pressed
	Input.parse_input_event(event)
	Input.flush_buffered_events()

func escape() -> void:
	for pressed in [true, false]:
		var event := InputEventKey.new()
		event.keycode = KEY_ESCAPE
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
	for id in range(1, 5):
		var worker := Worker.new()
		worker.worker_id = id
		worker.role_id = WorkerRoles.default_spawn_role(id - 1)
		world.workers.append(worker)
	await settle()
	for category: String in ui.navigation.buttons:
		if not ui.navigation.is_primary(category):
			await click(ui.navigation.more_button)
		await click(ui.navigation.buttons[category])
		check((ui.jobs_popup.is_visible() if category == "assignments" else ui.management.visible) and ui.category == category, "Navigation opens " + category)
		if category == "jobs": check(ui.title.text == "Tasks" and ui.search.placeholder_text == "Search tasks", "Task title and search use display name")
		if category == "assignments": check(ui.title.text == "Jobs" and ui.search.placeholder_text == "Search workers" and not ui.management.visible, "Jobs opens a separate worker-list window")
		if not ui.navigation.is_primary(category):
			await click(ui.navigation.more_button)
		await click(ui.navigation.buttons[category])
		check(not ui.management.visible and not ui.jobs_popup.is_visible(), "Repeated navigation click closes " + category)
	ui.open_assignments()
	await settle()
	check(not ui.details.visible and ui.jobs_popup.body.get_child_count() == 4, "Jobs initially contains only worker list controls, no feature cards or editor")
	check(ui.filtered.size() == 4, "Jobs lists all workers")
	var popup_position: Vector2 = ui.jobs_popup.panel.position
	var header_point: Vector2 = ui.jobs_popup._header.get_global_rect().position + Vector2(30, 20)
	var drag_camera: Vector3 = main.camera.position
	var drag_tasks: int = world.task_queue.active_count()
	motion(header_point)
	button(header_point, true)
	motion(header_point + Vector2(-100, 40))
	button(header_point + Vector2(-100, 40), false)
	await settle()
	check(ui.jobs_popup.panel.position.is_equal_approx(popup_position + Vector2(-100, 40)), "Real Main events drag the Jobs header")
	check(main.camera.position == drag_camera and world.task_queue.active_count() == drag_tasks and not main.selection_controller.is_dragging, "Window dragging never pans or selects terrain")
	popup_position = ui.jobs_popup.panel.position
	ui.open_assignments()
	check(ui.jobs_popup.panel.position == popup_position, "Programmatic open preserves an existing pop-out position")
	header_point = ui.jobs_popup._header.get_global_rect().position + Vector2(30, 20)
	motion(header_point)
	button(header_point, true)
	check(ui.layout.is_interacting(), "Header press starts a window interaction before focus loss")
	main._notification(MainLoop.NOTIFICATION_APPLICATION_FOCUS_OUT)
	check(not ui.layout.is_interacting() and ui.jobs_popup.is_visible(), "Focus loss cancels dragging without losing Jobs")
	button(header_point, false)
	motion(header_point)
	button(header_point, true)
	motion(Vector2(-1000, -1000))
	button(Vector2(-1000, -1000), false)
	check(ui.jobs_popup.panel.position.x >= 16 and ui.jobs_popup.panel.position.y >= 72, "Dragging clamps Jobs inside the viewport and HUD margins")
	ui.search.text = "4"
	ui.search.text_changed.emit("4")
	await settle()
	check(ui.filtered.size() == 1 and ui.filtered[0].id == 4, "Pop-out worker search uses existing bounded model")
	ui.search.release_focus()
	var steps: int = world.simulation_steps
	main._process(0.016)
	check(world.simulation_steps > steps and not main.menu_open, "Jobs pop-out does not pause simulation")
	escape()
	await settle()
	check(not ui.jobs_popup.is_visible() and not main.menu_open, "Escape closes Jobs before game menu")
	ui.open_assignments()
	await settle()
	await click(ui.jobs_popup._header.get_child(1))
	check(not ui.jobs_popup.is_visible() and ui.category.is_empty(), "Close button clears navigation and closes pop-out")
	ui.show_workers("reserve")
	await settle()
	await click(ui.rows_box.get_child(0))
	check(ui.details.visible and ui.selection.kind == "worker", "Worker row opens information")
	check(ui.panels.priority_selectors.is_empty(), "Worker information has no priority editors")
	await click(ui.rows_box.get_child(0))
	check(not ui.details.visible, "Repeated worker-row click closes information")
	ui.open_assignments(4)
	await settle()
	check(ui.selection.kind == "assignment", "Separate assignments selection")
	check(ui.panels.priority_selectors.keys() == ["hauling", "mining", "building"], "Only implemented work is editable; crafting remains unavailable")
	var options: OptionButton = ui.panels.priority_selectors.hauling
	check(options.get_item_text(0) == "Off" and options.get_item_text(2) == "2", "Priority numbers and Off are visible")
	options.select(2)
	options.item_selected.emit(2)
	check(world.workers[3].get_work_priority("hauling") == 2, "Priority editor changes its worker")
	check(world.workers[0].get_work_priority("hauling") == 0, "Priority editor leaves other workers unchanged")
	await settle()
	check(ui.panels.row_matches(ui.model.get_row("worker", 4), "", "Hauling"), "Hauling filter includes enabled former Fighter")
	check(not ui.panels.row_matches(ui.model.get_row("worker", 1), "", "Hauling"), "Work filter excludes disabled hauling")
	check(not ui.set_selected_work_priority("crafting", 1), "Future work cannot dispatch")
	var editor = ui.panels.priority_editor
	check(editor.checks.size() == 7, "Grouped work inventory includes future work")
	check(editor.checks.crafting.disabled and editor.checks.combat.disabled, "Future checkboxes disabled")
	check(editor.checks.mining.get_parent() == editor.checks.building.get_parent(), "Mining and building grouped together")
	check(editor.checks.hauling.get_parent() != editor.checks.mining.get_parent(), "Logistics has its own work group")
	check(editor.checks.mining.get_global_rect().end.x < editor.rows.mining.get_global_rect().position.x, "Grouped work sits left of priority controls")
	check(ui.details.size.x == ui.DETAILS_WIDE_WIDTH and ui.details.get_global_rect().position.x > ui.management.get_global_rect().end.x, "Expanded editor preserves central world space")
	check(ui.jobs_popup.panel.get_global_rect().end.x < ui.details.get_global_rect().position.x, "Worker list does not cover the priority editor")
	await click(editor.checks.mining)
	check(world.workers[3].get_work_priority("mining") == 2, "Checkbox enables selected worker work at priority 2")
	check(editor.order == ["hauling", "mining", "building"], "Equal priorities keep deterministic visual order; Off last")
	await click(editor.row_buttons.hauling)
	var camera_before: Vector3 = main.camera.position
	var tasks_before: int = world.task_queue.active_count()
	await click(editor.move_up)
	check(world.workers[3].get_work_priority("hauling") == 1, "Move Up increases selected work priority")
	check(world.workers[3].get_work_priority("mining") == 2, "Move Up leaves other work numbers unchanged")
	check(editor.move_up.disabled, "Cannot move above priority 1")
	await click(editor.move_down)
	check(world.workers[3].get_work_priority("hauling") == 2 and world.workers[3].get_work_priority("mining") == 2, "Move Down can form equal priority ties")
	await click(editor.move_down)
	check(editor.order == ["mining", "hauling", "building"], "Priority list sorts higher-priority work first")
	check(editor.row_buttons.hauling.button_pressed, "Reordering preserves selected work")
	check(main.camera.position == camera_before and world.task_queue.active_count() == tasks_before, "Editor mouse gestures never move camera or designate terrain")
	check(world.workers[0].get_work_priority("hauling") == 0, "Priority moves remain per-worker")
	await click(editor.checks.hauling)
	check(world.workers[3].get_work_priority("hauling") == 0 and options.selected == 0, "Unchecking disables work and updates numeric editor")
	check(editor.move_up.disabled and editor.move_down.disabled, "Move controls cannot silently re-enable Off work")
	options.item_selected.emit(9)
	check(editor.checks.hauling.button_pressed and editor.move_down.disabled, "Numeric editor enables work and clamps lower priority at 9")
	var remembered: Dictionary = world.workers[3].get_work_configuration().duplicate()
	ui.select_row("assignment", 1)
	options.item_selected.emit(3)
	editor.checks.mining.toggled.emit(false)
	editor.move_up.pressed.emit()
	check(world.workers[0].get_work_priority("hauling") == 0, "Old priority callback cannot retarget a new worker")
	check(world.workers[0].get_work_priority("mining") == 2 and world.workers[3].get_work_configuration() == remembered, "Stale checkbox and move callbacks cannot edit either worker")
	var task_id := world.task_queue.add_dig_task(Vector3i(2, 0, 0))
	var task = world.task_queue.get_task(task_id)
	task.status = TaskQueue.TaskStatus.IN_PROGRESS
	task.assigned_worker = world.workers[0]
	world.workers[0].current_task_id = task_id
	world.workers[0].state = Worker.WorkerState.WORKING
	ui.open_assignments(1)
	await settle()
	check(ui.set_selected_work_priority("mining", 0), "Active worker can configure next job")
	check(task.assigned_worker == world.workers[0] and world.workers[0].current_task_id == task_id, "Priority edit does not interrupt current work")
	check(not ui.panels.priority_selectors.mining.disabled, "Active-worker priority editor stays available")
	check(ui.panels.assignment_hint.text.contains("Current job finishes"), "Deferred effect explained")
	for size in [Vector2i(1280, 720), Vector2i(1920, 1080), Vector2i(3840, 2160), Vector2i(3440, 1440)]:
		root.size = size
		root.content_scale_size = Vector2i(1920, 1080)
		root.content_scale_mode = Window.CONTENT_SCALE_MODE_CANVAS_ITEMS
		root.content_scale_aspect = Window.CONTENT_SCALE_ASPECT_EXPAND
		await settle()
		editor = ui.panels.priority_editor
		check(ui.details.get_global_rect().end.x <= ui.root.size.x and ui.details.size.x == ui.DETAILS_WIDE_WIDTH, "Priority dock fits scaled viewport " + str(size))
		check(Rect2(Vector2.ZERO, ui.root.size).encloses(ui.jobs_popup.panel.get_rect()), "Jobs window fits scaled viewport " + str(size))
		check(editor.rows.mining.get_global_rect().end.x <= ui.details.get_global_rect().end.x, "Priority controls fit within dock " + str(size))
		var before: int = world.workers[0].get_work_priority("hauling")
		await click(editor.checks.hauling)
		check(world.workers[0].get_work_priority("hauling") == (2 if before == 0 else 0), "Scaled checkbox targets selected worker " + str(size))
		check(world.workers[0].current_task_id == task_id, "Scaled checkbox preserves current task " + str(size))
	ui.select_row("worker", 1)
	await settle()
	check(ui.details.size.x == ui.DETAILS_WIDTH, "Worker information restores compact details width")
	ui.inspect_cell(1, Vector3i.ZERO)
	await settle()
	check(ui.details.size.x == ui.DETAILS_WIDTH, "Cell snapshot retains compact details width")
	var first := world.create_stockpile([Vector3i(-2, 1, 0)])
	var second := world.create_stockpile([Vector3i(3, 1, 0)])
	await settle()
	ui.select_row("stockpile", second)
	await settle()
	ui.panels.stockpile_name.grab_focus()
	ui.panels.stockpile_name.text = "Iron depot"
	ui.panels.stockpile_name.release_focus()
	await settle()
	check(ui.panels.stockpile_name.text == "Iron depot", "Draft name survives refresh/focus change before Rename")
	ui.panels.stockpile_name.text_submitted.emit("Iron depot")
	await settle()
	check(world.stockpile_store.display_name(second) == "Iron depot", "Rename input commits the selected zone")
	check(world.stockpile_store.display_name(first) == "Stockpile %d" % first, "Rename leaves other zone unchanged")
	check(ui.model.get_row("stockpile", second).title.contains("Iron depot"), "Renamed title reaches list model")
	var previous_editor: LineEdit = ui.panels.stockpile_name
	ui.select_row("stockpile", first)
	previous_editor.text_submitted.emit("Wrong zone")
	check(world.stockpile_store.display_name(first) == "Stockpile %d" % first, "Old name callback cannot retarget another zone")
	ui.select_row("stockpile", second)
	ui.open_category("stockpiles")
	ui.search_text = "Iron depot"
	ui._start_filter()
	await settle()
	check(ui.filtered.size() == 1 and ui.filtered[0].id == second, "Stockpile search finds new name")
	world.runtime_epoch += 1
	check(not ui.rename_selected_stockpile("Wrong world"), "Renaming rejects stale world selection")
	await settle()
	check(not ui.jobs_popup.is_visible(), "World replacement closes Jobs")
	ui.open_assignments(4)
	editor = ui.panels.priority_editor
	remembered = world.workers[3].get_work_configuration().duplicate()
	world.runtime_epoch += 1
	check(not ui.set_selected_work_priority("hauling", 1), "Assignments reject stale world selection")
	editor.checks.hauling.toggled.emit(false)
	editor.move_up.pressed.emit()
	check(world.workers[3].get_work_configuration() == remembered, "Group and move controls reject replaced world before refresh")
	check(not main.diagnostics_controller.service.enabled, "Player controls need no diagnostics")
	world.task_manager.shutdown()
	for worker in world.workers: worker.free()
	world.workers.clear()
	main.free()
	await process_frame
	if failures.is_empty():
		print("ASSIGNMENT_UI_OK (%d checks)" % checks)
		quit(0)
	else:
		for message in failures: push_error(message)
		quit(1)
