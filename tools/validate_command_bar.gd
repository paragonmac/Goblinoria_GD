extends SceneTree

class InstantLevels extends MainRenderLevelController:
	func update_world(world_ref: World) -> void:
		world = world_ref
	func handle_render_layer_change(delta: int) -> void:
		world.set_top_render_y(clampi(world.top_render_y + delta, 0, world.world_size_y - 1))

const Fixture = preload("res://tools/validate_context_menu.gd")
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
var world
var ui
var checks := 0
var failures: Array[String] = []

func _init() -> void:
	_run.call_deferred()

func check(value: bool, message: String) -> void:
	checks += 1
	if not value:
		failures.append(message)

func settle() -> void:
	for i in range(8):
		ui.tick(0.05)
		await process_frame

func find_named(node: Node, target: String) -> Node:
	if node.name == target:
		return node
	for child in node.get_children():
		var found := find_named(child, target)
		if found != null:
			return found
	return null

func button_named(node: Node, target: String) -> Button:
	return find_named(node, target) as Button

func press(button: Button) -> void:
	if button != null:
		button.pressed.emit()

func _run() -> void:
	root.size = Vector2i(1920, 1080)
	root.gui_embed_subwindows = true
	main = load("res://scenes/Main.tscn").instantiate()
	main.set_script(UIMain)
	main.get_node("World").set_script(Fixture.MenuWorld)
	root.add_child(main)
	world = main.world
	ui = main.colony_ui
	await settle()
	_check_tools()
	await _check_options()
	await _check_status_chips()
	await _check_alert()
	await _check_gauge()
	await _check_more()
	await _check_coming_later()
	await _check_layout()
	world.task_manager.shutdown()
	for worker in world.workers:
		worker.free()
	world.workers.clear()
	main.free()
	await process_frame
	if failures.is_empty():
		print("Command bar: %d checks, %d failures" % [checks, failures.size()])
		quit(0)
	else:
		for message in failures:
			push_error(message)
		print("Command bar: %d checks, %d failures" % [checks, failures.size()])
		quit(1)

func _check_tools() -> void:
	var expected := {
		"Inspect": World.PlayerMode.INFORMATION,
		"Dig": World.PlayerMode.DIG,
		"Build": World.PlayerMode.PLACE,
		"Erase": World.PlayerMode.ERASE,
		"Stockpile": World.PlayerMode.STOCKPILE,
	}
	for caption: String in expected:
		var button: Button = ui.command_bar.tool_buttons[expected[caption]]
		press(button)
		ui.tick(0.05)
		check(world.player_mode == expected[caption], caption + " button selects its world mode")
		var selected := 0
		for mode: int in ui.command_bar.tool_buttons:
			if ui.command_bar.tool_buttons[mode].button_pressed:
				selected += 1
		check(button.button_pressed and selected == 1, caption + " alone is highlighted")
	var stairs: Button = ui.command_bar.stairs_button
	press(stairs)
	ui.tick(0.05)
	check(world.player_mode == World.PlayerMode.UP_STAIRS and stairs.button_pressed, "Stairs initially selects UP_STAIRS")
	press(ui.command_bar.stairs_down)
	ui.tick(0.05)
	check(world.player_mode == World.PlayerMode.DOWN_STAIRS and ui.command_bar.stairs_down.button_pressed, "Down toggle selects DOWN_STAIRS")
	press(stairs)
	ui.tick(0.05)
	check(world.player_mode == World.PlayerMode.DOWN_STAIRS, "Stairs remembers DOWN_STAIRS")
	check(stairs.button_pressed and ui.command_bar.tool_buttons[World.PlayerMode.UP_STAIRS].button_pressed, "Both stairs modes highlight the single stairs button")
	world.set_player_mode(World.PlayerMode.UP_STAIRS)
	ui.tick(0.05)
	check(ui.command_bar.stairs_up.button_pressed and not ui.command_bar.stairs_down.button_pressed, "Keyboard-selected up stairs is reflected in toggles")
	world.set_player_mode(World.PlayerMode.DOWN_STAIRS)
	ui.tick(0.05)
	check(ui.command_bar.stairs_down.button_pressed and not ui.command_bar.stairs_up.button_pressed, "Keyboard-selected down stairs is reflected in toggles")

func _check_options() -> void:
	var hints := {
		World.PlayerMode.INFORMATION: "Click a block",
		World.PlayerMode.DIG: "Drag to mark",
		World.PlayerMode.PLACE: "stored iron ore",
		World.PlayerMode.ERASE: "Cancels pending",
		World.PlayerMode.STOCKPILE: "designate a stockpile",
	}
	for mode: int in hints:
		world.set_player_mode(mode)
		await settle()
		check(ui.command_bar.options_row.visible and ui.command_bar.options_hint.text.to_lower().contains(hints[mode].to_lower()), "Options row has contextual hint for mode " + str(mode))
		check(not ui.command_bar.stairs_options.visible, "Stairs toggles hidden outside stairs modes")
	for mode: int in [World.PlayerMode.UP_STAIRS, World.PlayerMode.DOWN_STAIRS]:
		world.set_player_mode(mode)
		await settle()
		check(ui.command_bar.options_row.visible and ui.command_bar.stairs_options.visible, "Stairs options visible for mode " + str(mode))
	check(ui.command_bar.options_row.mouse_filter == Control.MOUSE_FILTER_IGNORE, "Options row ignores mouse so clicks reach its controls")
	check(ui.command_bar.stairs_up.mouse_filter == Control.MOUSE_FILTER_STOP and ui.command_bar.stairs_down.mouse_filter == Control.MOUSE_FILTER_STOP, "Stairs toggles keep mouse input")

func _check_status_chips() -> void:
	# Seeded, distinct values so each chip is checked against its own number.
	var counts := {"working": 3, "travelling": 5, "waiting": 7, "reserve": 11, "pending": 13, "blocked": 17, "stored": 19}
	ui.command_bar.update_counts(counts, false)
	for id: String in ui.command_bar.status_chips:
		var chip: Button = ui.command_bar.status_chips[id]
		var number: Label = chip.get_meta("number")
		check(number.text == str(int(counts.get(id, 0))), "" + id + " chip matches model count")
	var worker_filters := {"Busy": "working", "Moving": "travelling", "Idle": "waiting", "Reserve": "reserve"}
	for caption: String in worker_filters:
		press(ui.command_bar.status_chips[worker_filters[caption]])
		await settle()
		check(ui.category == "workers" and ui.filter_text.to_lower() == worker_filters[caption], caption + " opens the matching Workers filter")
	for id: String in ["pending", "blocked"]:
		press(ui.command_bar.status_chips[id])
		await settle()
		check(ui.category == "jobs" and ui.filter_text == id.capitalize(), id.capitalize() + " opens filtered Tasks")
	press(ui.command_bar.status_chips["stored"])
	await settle()
	check(ui.category == "resources", "Stored opens Resources")

func _check_alert() -> void:
	ui.command_bar.update_counts({"blocked": 0}, false)
	check(not ui.command_bar.alert.visible, "Blocked alert hidden at zero")
	ui.command_bar.update_counts({"blocked": 1}, false)
	check(ui.command_bar.alert.visible and ui.command_bar.alert_text.text == "1 job can't be reached", "Alert uses singular job")
	ui.command_bar.update_counts({"blocked": 3}, false)
	check(ui.command_bar.alert.visible and ui.command_bar.alert_text.text == "3 jobs can't be reached", "Alert uses plural jobs")
	press(ui.command_bar.alert)
	await settle()
	check(ui.category == "jobs" and ui.filter_text == "Blocked", "Blocked alert opens Tasks filtered Blocked")

func _check_gauge() -> void:
	# The fixture has no render-level controller (Main skips level changes
	# without one); an instant stub verifies the gauge reaches the same entry
	# point as the [ / ] keys without needing meshed chunks.
	main.render_level_controller = InstantLevels.new()
	var base: int = main.hud_controller.render_level_base_y
	world.set_top_render_y(0)
	await settle()
	var start: int = world.top_render_y
	press(button_named(ui.command_bar.gauge, "LevelUp"))
	for i in range(120):
		ui.tick(0.05)
		await process_frame
		if world.top_render_y == start + 1:
			break
	check(world.top_render_y == start + 1, "LevelUp increments render level (start=%d current=%d world_height=%d loading=%s)" % [start, world.top_render_y, world.world_size_y, str(main.loading_active)])
	check(ui.command_bar.level_label.text == str(world.top_render_y - base), "Gauge label reports offset from HUD base")
	press(button_named(ui.command_bar.gauge, "LevelDown"))
	await settle()
	check(world.top_render_y == start, "LevelDown decrements render level")
	world.top_render_y = world.world_size_y - 1
	press(button_named(ui.command_bar.gauge, "LevelUp"))
	await settle()
	check(world.top_render_y == world.world_size_y - 1, "LevelUp respects upper bound")
	world.top_render_y = 0
	press(button_named(ui.command_bar.gauge, "LevelDown"))
	await settle()
	check(world.top_render_y == 0, "LevelDown respects lower bound")
	# Shift + mouse wheel steps the level (wheel up = up), even in a stairs mode
	# where the plain wheel rotates the flight; plain wheel still zooms.
	world.set_player_mode(World.PlayerMode.DOWN_STAIRS)
	var rotation_before: int = main.selection_controller.stair_rotation
	world.set_top_render_y(10)
	for pair in [[MOUSE_BUTTON_WHEEL_UP, 11], [MOUSE_BUTTON_WHEEL_DOWN, 10]]:
		for pressed in [true, false]:
			var wheel := InputEventMouseButton.new()
			wheel.button_index = pair[0]
			wheel.pressed = pressed
			wheel.shift_pressed = true
			wheel.position = Vector2(960, 300)
			wheel.global_position = wheel.position
			main._input(wheel)
		check(world.top_render_y == pair[1], "Shift + wheel steps the render level to %d (got %d)" % [pair[1], world.top_render_y])
	check(main.selection_controller.stair_rotation == rotation_before, "Shift + wheel does not rotate a stair flight")
	world.set_player_mode(World.PlayerMode.INFORMATION)
	# Either direction may sit at a zoom limit; one of them must change the zoom.
	var zoom_changed := false
	for button in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]:
		var zoom_before: float = main.camera.size
		var plain := InputEventMouseButton.new()
		plain.button_index = button
		plain.pressed = true
		plain.position = Vector2(960, 300)
		plain.global_position = plain.position
		main._input(plain)
		zoom_changed = zoom_changed or main.camera.size != zoom_before
	check(world.top_render_y == 10 and zoom_changed, "Plain wheel zooms and leaves the level alone (zoom changed %s)" % str(zoom_changed))

func _check_more() -> void:
	var secondary := ""
	for category: Dictionary in Catalog.categories():
		if not ui.navigation.PRIMARY.has(category.id):
			secondary = str(category.id)
			break
	check(not secondary.is_empty(), "Catalog contains a secondary category")
	press(ui.navigation.more_button)
	check(ui.navigation.more_panel.visible, "More opens its popover")
	var category_button: Button = ui.navigation.buttons.get(secondary)
	press(category_button)
	await settle()
	check(ui.category == secondary, "More category dispatches " + secondary)
	check(not ui.navigation.more_panel.visible, "More closes after category pick")

func _check_coming_later() -> void:
	ui.open_category("colony")
	await settle()
	var toggle := find_named(ui.body, "ComingLater") as Button
	if toggle == null:
		for button in ui.body.find_children("*", "Button", true, false):
			if (button as Button).text.begins_with("Coming later ("):
				toggle = button
				break
	check(toggle != null, "Colony includes Coming later toggle")
	if toggle == null:
		return
	var section: Control = toggle.get_parent().get_child(toggle.get_index() + 1) as Control
	check(not section.visible, "Coming later section starts hidden")
	press(toggle)
	check(section.visible, "Coming later section opens")
	var planned: Dictionary = {}
	for feature: Dictionary in Catalog.entries("colony"):
		if feature.status in ["planned", "tentative"]:
			planned = feature
			break
	check(not planned.is_empty(), "Colony has planned or tentative feature fixture")
	if not planned.is_empty():
		var matching := false
		for label in section.find_children("*", "Label", true, false):
			if (label as Label).text == str(planned.label):
				matching = true
				var card_button := label.get_parent().get_parent() as Button
				check(card_button.disabled, "Planned feature card is disabled")
				break
		check(matching, "Planned feature appears in Coming later")
		check(not ui.dispatch_feature(str(planned.id)), "Dispatch rejects planned feature")

func _check_layout() -> void:
	ui.inspect_cell(1, Vector3i.ZERO)
	await settle()
	var bar: Control = ui.command_bar.bar
	var gauge: Control = ui.command_bar.gauge
	check(is_equal_approx(bar.anchor_bottom, 1.0) and is_equal_approx(bar.anchor_top, 1.0), "Command bar is anchored to bottom")
	check(bar.get_global_rect().position.y >= gauge.get_global_rect().end.y or not bar.get_global_rect().intersects(gauge.get_global_rect()), "Command bar does not overlap depth gauge")
	check(ui.details.get_global_rect().end.x < gauge.get_global_rect().position.x, "Details right edge is left of depth gauge")
