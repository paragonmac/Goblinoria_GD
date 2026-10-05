extends SceneTree
## Headless contract checks for the synthetic playtest gesture driver.

const Gestures = preload("res://scripts/playtest/playtest_gestures.gd")
const ContextFixture = preload("res://tools/validate_context_menu.gd")
const UIFixture = preload("res://tools/validate_colony_ui.gd")

var checks := 0
var failures: Array[String] = []
var main_fixture
var driver
var received: Array = []
var real_main
var real_world
var real_ui
var real_driver


class FixtureMain extends Node:
	var input_state = preload("res://scripts/game_input_state.gd").new()
	var sink

	func _input(event: InputEvent) -> void:
		if sink != null:
			sink.received.append(event)


func _init() -> void:
	call_deferred("_run")


func check(value: bool, message: String) -> void:
	checks += 1
	if not value:
		failures.append(message)


func _run() -> void:
	root.size = Vector2i(640, 480)
	main_fixture = FixtureMain.new()
	main_fixture.input_state.synthetic = true
	main_fixture.sink = self
	root.add_child(main_fixture)
	driver = Gestures.new()
	driver.initialize(main_fixture)

	var click: Dictionary = driver.compile([{"kind": "click", "point": [100, 120]}])
	check(click.ok and click.stages.size() == 3, "click expands to move, down, and up")
	check(not driver.delivering, "delivery guard is idle between frames")
	check(_deliver_all(click.stages), "click stages deliver")
	check(main_fixture.input_state.pointer == Vector2(100, 120), "click updates pointer adapter")
	check(main_fixture.input_state.buttons.is_empty(), "click leaves no held button")
	check(driver.is_complete(), "driver reports final stage complete")
	driver.finish()
	check(not driver.delivering, "finish clears delivery state")

	var drag: Dictionary = driver.compile([{"kind": "drag", "from": [20, 20], "to": [120, 80], "steps": 4}])
	check(drag.ok and drag.stages.size() == 7, "drag expands to four moves plus endpoints")
	check(_deliver_all(drag.stages), "drag stages deliver")
	driver.finish()

	var hotkey: Dictionary = driver.compile([
		{"kind": "key", "key": "Shift", "state": "down"},
		{"kind": "key", "key": "5", "state": "down"},
		{"kind": "key", "key": "5", "state": "up"},
		{"kind": "key", "key": "Shift", "state": "up"},
	])
	check(hotkey.ok and hotkey.stages.size() == 4, "key sequence compiles")
	check(_deliver_all(hotkey.stages), "key sequence delivers")
	driver.finish()

	var modified_click: Dictionary = driver.compile([
		{"kind": "key", "key": "Shift", "state": "down"},
		{"kind": "click", "point": [150, 120]},
		{"kind": "key", "key": "Shift", "state": "up"},
	])
	check(modified_click.ok and _deliver_all(modified_click.stages), "modified mouse sequence delivers")
	var saw_shifted_mouse := false
	for index in range(received.size() - 1, -1, -1):
		var event = received[index]
		if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
			saw_shifted_mouse = event.shift_pressed
			break
	check(saw_shifted_mouse, "held Shift reaches synthetic mouse events")
	driver.finish()

	var text: Dictionary = driver.compile([{"kind": "text", "text": "Goblin"}])
	check(text.ok and text.stages.size() == 12, "text expands to key pairs")
	check(_deliver_all(text.stages), "text stages deliver")
	driver.finish()

	var wait: Dictionary = driver.compile([{"kind": "wait", "frames": 3}, {"kind": "wheel", "delta": 1, "point": [5, 5]}])
	check(wait.ok and wait.stages.size() == 4, "wait expands into frame stages")
	check(_deliver_all(wait.stages), "wait and wheel stages deliver")
	check(main_fixture.input_state.buttons.is_empty(), "wheel is transient in the adapter")
	driver.finish()

	var before := received.size()
	var invalid: Dictionary = driver.compile([{"kind": "pointer_move", "point": [640, 480]}])
	check(not invalid.ok and received.size() == before, "out of viewport point is rejected before dispatch")
	var malformed: Dictionary = driver.compile([{"kind": "button", "button": "left", "state": "up"}])
	check(not malformed.ok and received.size() == before, "unmatched release is rejected before dispatch")
	var too_long: Dictionary = driver.compile([{"kind": "text", "text": "12345678901234567890123456789012345678901234567890123456789012345"}])
	check(not too_long.ok, "text length is bounded")
	await _run_real_ui_contracts()

	if failures.is_empty():
		print("PLAYTEST_GESTURES_OK (%d checks)" % checks)
		quit(0)
	else:
		for message in failures:
			push_error(message)
		quit(1)


func _deliver_all(stages: Array) -> bool:
	for stage in stages:
		var result: Dictionary = driver.deliver(stage)
		if not result.get("ok", false):
			return false
	return true


func _run_real_ui_contracts() -> void:
	# Reuse the deterministic Main/UI fixture used by the existing input
	# contracts. It keeps real Controls, PopupMenu routing, raycasts, and the
	# production Main callbacks while avoiding a graphical playtest launch.
	root.size = Vector2i(1000, 800)
	root.gui_embed_subwindows = true
	real_main = load("res://scenes/Main.tscn").instantiate()
	real_main.set_script(UIFixture.UIMain)
	real_main.get_node("World").set_script(ContextFixture.MenuWorld)
	root.add_child(real_main)
	real_world = real_main.world
	real_ui = real_main.colony_ui
	real_main.input_state.synthetic = true
	real_main.camera_controller.input_state = real_main.input_state
	real_main.selection_controller.input_state = real_main.input_state
	var worker := Worker.new()
	worker.worker_id = 1
	real_world.workers.append(worker)
	real_driver = Gestures.new()
	real_driver.initialize(real_main)
	await _real_settle()

	# A synthetic click must follow the ordinary Control path and leave no
	# adapter/UI button ownership behind.
	real_world.set_player_mode(World.PlayerMode.INFORMATION)
	var tool_button: Button = real_ui._tool_buttons[World.PlayerMode.DIG]
	var tool_point := tool_button.get_global_rect().get_center()
	await _drive_real([{"kind": "click", "point": _point_array(tool_point)}], "tool button click")
	check(real_world.player_mode == World.PlayerMode.DIG, "synthetic click activates a real tool button")
	check(real_main.input_state.buttons.is_empty() and real_ui._held_buttons.is_empty(),
		"completed GUI click leaves no held adapter/UI button")

	# Unicode key stages must reach a focused LineEdit while gameplay shortcuts
	# remain gated by GUI ownership.
	real_ui.open_category("workers")
	await _real_settle()
	real_ui.search.text = ""
	real_ui.search.grab_focus()
	var mode_before_text: int = real_world.player_mode
	await _drive_real([{"kind": "text", "text": "Goblin"}], "focused text input")
	check(real_ui.search.text == "Goblin", "Unicode key stages reach focused LineEdit")
	check(real_world.player_mode == mode_before_text, "focused text does not switch gameplay tool")
	real_ui.search.release_focus()
	real_ui.close_management()
	await _real_settle()

	# Right click enters the real context PopupMenu, and Escape is routed to
	# that popup before global menu handling.
	var world_point: Vector2 = real_main.camera.unproject_position(Vector3(0, 0, 0))
	await _drive_real([{"kind": "click", "point": _point_array(world_point), "button": "right"}], "context popup click")
	check(real_main.context_menu_controller.is_visible(), "synthetic right click opens real context popup")
	await _drive_real([
		{"kind": "key", "key": "Escape", "state": "down"},
		{"kind": "key", "key": "Escape", "state": "up"},
	], "context popup escape")
	check(not real_main.context_menu_controller.is_visible() and not real_main.menu_open,
		"popup Escape closes context menu without opening main menu")

	# Leave a real world drag pending, then cancel through the driver. Main's
	# context cancellation must run before adapter cleanup so no terrain task is
	# committed and no synthetic button remains pressed.
	real_world.set_player_mode(World.PlayerMode.DIG)
	real_main._cancel_context_input()
	await _real_settle()
	var pending: Dictionary = real_driver.compile([
		{"kind": "pointer_move", "point": _point_array(world_point)},
		{"kind": "button", "button": "left", "state": "down"},
		{"kind": "wait", "frames": 1},
	])
	check(pending.get("ok", false), "pending world drag compiles")
	if pending.get("ok", false):
		for index in mini(2, pending.stages.size()):
			var delivered: Dictionary = real_driver.deliver(pending.stages[index])
			check(delivered.get("ok", false), "pending drag stage delivers")
			real_main._process(0.016)
		await process_frame
	check(real_main.selection_controller.is_dragging, "synthetic world press starts real selection drag")
	real_driver.cancel()
	await _real_settle()
	check(not real_main.selection_controller.is_dragging and real_world.task_queue.active_count() == 0,
		"driver cancel clears pending world drag without committing terrain")
	check(real_main.input_state.buttons.is_empty() and real_ui._held_buttons.is_empty(),
		"driver cancel clears synthetic and GUI button ownership")

	# Polled hover plus a wheel event must drive the real two-cell stair ghost
	# and rotate it without zooming the camera.
	real_world.set_player_mode(World.PlayerMode.UP_STAIRS)
	var stair_point: Vector2 = real_main.camera.unproject_position(Vector3(0, 0.5, 0))
	await _drive_real([{"kind": "pointer_move", "point": _point_array(stair_point)}], "stair hover")
	check(real_world.preview_entries.size() == 2, "synthetic hover creates two-cell stair preview")
	var rotation_before: int = real_main.selection_controller.stair_rotation
	var camera_size_before: float = real_main.camera.size
	await _drive_real([{"kind": "wheel", "delta": 1, "point": _point_array(stair_point)}], "stair wheel")
	check(real_main.selection_controller.stair_rotation == posmod(rotation_before + 1, 4),
		"synthetic wheel rotates stair preview")
	check(real_main.camera.size == camera_size_before, "stair wheel does not zoom camera")

	# finish() also has to cancel an incomplete world press. This exercises the
	# normal-completion cleanup path separately from the explicit cancel above.
	real_main._cancel_context_input()
	await _real_settle()
	real_world.set_player_mode(World.PlayerMode.DIG)
	var partial: Dictionary = real_driver.compile([
		{"kind": "pointer_move", "point": _point_array(world_point)},
		{"kind": "button", "button": "left", "state": "down"},
	])
	check(partial.get("ok", false), "partial world press compiles")
	if partial.get("ok", false):
		for stage in partial.stages:
			var delivered: Dictionary = real_driver.deliver(stage)
			check(delivered.get("ok", false), "partial world press delivers")
			real_main._process(0.016)
			await process_frame
	check(real_main.selection_controller.is_dragging, "partial world press starts drag before finish")
	real_driver.finish()
	await _real_settle()
	check(not real_main.selection_controller.is_dragging and real_world.task_queue.active_count() == 0,
		"finish cancels incomplete world press without committing terrain")
	check(real_main.input_state.buttons.is_empty() and real_ui._held_buttons.is_empty(),
		"finish clears incomplete world button ownership")

	# A partial press on an already-selected toggle must preserve that toggle
	# while clearing the control's internal mouse-press state.
	real_world.set_player_mode(World.PlayerMode.DIG)
	await _real_settle()
	check(tool_button.button_pressed, "selected tool toggle is pressed before partial GUI press")
	var partial_gui: Dictionary = real_driver.compile([
		{"kind": "pointer_move", "point": _point_array(tool_point)},
		{"kind": "button", "button": "left", "state": "down"},
	])
	check(partial_gui.get("ok", false), "partial GUI press compiles")
	if partial_gui.get("ok", false):
		for stage in partial_gui.stages:
			var delivered: Dictionary = real_driver.deliver(stage)
			check(delivered.get("ok", false), "partial GUI press delivers")
			real_main._process(0.016)
			await process_frame
	real_driver.finish()
	await _real_settle()
	check(tool_button.button_pressed and real_ui._held_buttons.is_empty(),
		"finish preserves selected BaseButton toggle and clears UI ownership")

	# Cancelling a jobs-popup drag must stop its drag state while preserving the
	# legitimate visible popup itself.
	real_ui.open_assignments(1)
	await _real_settle()
	var jobs_header_point: Vector2 = real_ui.jobs_popup._header.get_global_rect().get_center()
	var partial_jobs: Dictionary = real_driver.compile([
		{"kind": "pointer_move", "point": _point_array(jobs_header_point)},
		{"kind": "button", "button": "left", "state": "down"},
	])
	check(partial_jobs.get("ok", false), "partial jobs-popup press compiles")
	if partial_jobs.get("ok", false):
		for stage in partial_jobs.stages:
			var delivered: Dictionary = real_driver.deliver(stage)
			check(delivered.get("ok", false), "partial jobs-popup press delivers")
			real_main._process(0.016)
			await process_frame
	check(real_ui.jobs_popup._dragging, "jobs-popup header enters drag state")
	real_driver.cancel()
	await _real_settle()
	check(real_ui.jobs_popup.is_visible() and not real_ui.jobs_popup._dragging,
		"cancel stops jobs-popup drag without closing the popup")
	real_ui.close_management()

	real_driver.cancel()
	real_world.task_manager.shutdown()
	real_world.workers.clear()
	worker.free()
	real_main.free()
	await process_frame


func _drive_real(events: Array, label: String) -> void:
	var compiled: Dictionary = real_driver.compile(events)
	check(compiled.get("ok", false), label + " compiles")
	if not compiled.get("ok", false):
		return
	for stage in compiled.stages:
		var delivered: Dictionary = real_driver.deliver(stage)
		check(delivered.get("ok", false), label + " stage delivers")
		real_main._process(0.016)
		await process_frame
	real_driver.finish()
	await _real_settle()


func _real_settle() -> void:
	for _step in 3:
		real_main._process(0.016)
		await process_frame


func _point_array(point: Vector2) -> Array:
	return [point.x, point.y]
