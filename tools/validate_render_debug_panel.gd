extends SceneTree

const Fixture = preload("res://tools/validate_context_menu.gd")

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

# Counts dump_ramp_counts calls without touching the real overlay's output.
class CountingOverlay extends DebugOverlay:
	var dumps := 0

	func dump_ramp_counts() -> void:
		dumps += 1


var main
var world
var ui
var panel
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

func find_text_button(node: Node, text: String) -> Button:
	if node is Button and node.text == text:
		return node
	for child in node.get_children():
		var found := find_text_button(child, text)
		if found != null:
			return found
	return null

func select_index(option: OptionButton, index: int) -> void:
	option.select(index)
	option.item_selected.emit(index)

func _run() -> void:
	root.size = Vector2i(1920, 1080)
	root.gui_embed_subwindows = true
	main = load("res://scenes/Main.tscn").instantiate()
	main.set_script(UIMain)
	main.get_node("World").set_script(Fixture.MenuWorld)
	root.add_child(main)
	world = main.world
	ui = main.colony_ui
	# SelectionWorld._ready does not build a renderer, so create one the way validate_colony_ui does.
	if world.renderer == null:
		world.renderer = WorldRenderer.new()
		world.add_child(world.renderer)
		world.renderer.initialize(world)
	await settle()
	check(world.renderer != null, "World provides a renderer")
	check(main.debug_overlay != null, "Debug overlay exists in the fixture")
	_check_toggle()
	_check_controls()
	await _check_reflects()
	_check_dump()
	_check_readout()
	await _check_layout()
	world.renderer.free()
	world.renderer = null
	world.task_manager.shutdown()
	for worker in world.workers:
		worker.free()
	world.workers.clear()
	main.free()
	await process_frame
	if failures.is_empty():
		print("Render debug panel: %d checks, %d failures" % [checks, failures.size()])
		quit(0)
	else:
		for message in failures:
			push_error(message)
		print("Render debug panel: %d checks, %d failures" % [checks, failures.size()])
		quit(1)

func _check_toggle() -> void:
	# F7 in the game calls this same function (Main._handle_debug_keys); headless input state cannot be injected.
	main._toggle_render_debug_panel()
	panel = main.render_debug_panel
	check(panel != null and panel.visible, "F7 shows the rendering panel")
	check(world.renderer.void_meter_enabled, "F7 show enables the void meter")
	main._toggle_render_debug_panel()
	check(not panel.visible, "Second F7 hides the rendering panel")
	check(not world.renderer.void_meter_enabled, "Second F7 disables the void meter")
	main._toggle_render_debug_panel()
	check(panel.visible, "Third F7 reshows the rendering panel")

func _check_controls() -> void:
	var renderer = world.renderer
	var modes := ["async", "area", "sync"]
	for i in range(modes.size()):
		select_index(panel._visibility_option, i)
		check(renderer.get_render_debug()["visibility_mode"] == modes[i], "Show chunks option %d sets visibility_mode" % i)
	var depths := [0, 1, 2, 4, 8]
	for i in range(depths.size()):
		select_index(panel._depth_option, i)
		check(int(renderer.get_render_debug()["depth_layers"]) == depths[i], "Depth option %d sets depth_layers" % i)
	panel._look_ahead_check.button_pressed = false
	check(renderer.get_render_debug()["look_ahead"] == false, "Look-ahead checkbox off sets look_ahead false")
	panel._look_ahead_check.button_pressed = true
	check(renderer.get_render_debug()["look_ahead"] == true, "Look-ahead checkbox on sets look_ahead true")
	panel._look_ahead_slider.value = 0.25
	check(absf(float(renderer.get_render_debug()["look_ahead_sec"]) - 0.25) < 0.001, "Look-ahead slider sets look_ahead_sec")
	check(panel._look_ahead_value.text == "0.25 s", "Look-ahead value label shows seconds")
	select_index(panel._update_option, 1)
	check(renderer.get_render_debug()["refresh_every_frame"] == false, "Every 50 ms sets refresh_every_frame false")
	select_index(panel._update_option, 0)
	check(renderer.get_render_debug()["refresh_every_frame"] == true, "Every frame sets refresh_every_frame true")
	panel._freeze_check.button_pressed = true
	check(renderer.get_render_debug()["freeze"] == true, "Freeze checkbox on sets freeze true")
	panel._freeze_check.button_pressed = false
	check(renderer.get_render_debug()["freeze"] == false, "Freeze checkbox off sets freeze false")
	var draw_cases := [
		[1, Viewport.DEBUG_DRAW_UNSHADED],
		[2, Viewport.DEBUG_DRAW_OVERDRAW],
		[3, Viewport.DEBUG_DRAW_WIREFRAME],
		[0, Viewport.DEBUG_DRAW_DISABLED],
	]
	for case in draw_cases:
		select_index(panel._draw_option, case[0])
		check(main.get_viewport().debug_draw == case[1], "Draw mode option %d sets viewport debug_draw" % case[0])
		if case[1] == Viewport.DEBUG_DRAW_WIREFRAME:
			check(panel._wireframe_caption.visible, "Wireframe caption shown for Wireframe")
		else:
			check(not panel._wireframe_caption.visible, "Wireframe caption hidden for other draw modes")

func _check_reflects() -> void:
	var renderer = world.renderer
	renderer.set_render_debug("visibility_mode", "sync")
	renderer.set_render_debug("depth_layers", 4)
	renderer.set_render_debug("look_ahead", false)
	renderer.set_render_debug("look_ahead_sec", 0.3)
	renderer.set_render_debug("refresh_every_frame", false)
	renderer.set_render_debug("freeze", true)
	main.get_viewport().debug_draw = Viewport.DEBUG_DRAW_OVERDRAW
	main._toggle_render_debug_panel()
	check(not panel.visible, "Panel hides before reflect check")
	main._toggle_render_debug_panel()
	check(panel._visibility_option.selected == 2, "Shown panel reflects visibility_mode sync")
	check(panel._depth_option.selected == 3, "Shown panel reflects depth_layers 4")
	check(panel._look_ahead_check.button_pressed == false and not panel._look_ahead_slider.editable, "Shown panel reflects look-ahead off and disables slider")
	check(absf(panel._look_ahead_slider.value - 0.3) < 0.001, "Shown panel reflects look_ahead_sec")
	check(panel._update_option.selected == 1, "Shown panel reflects 50 ms cadence")
	check(panel._freeze_check.button_pressed == true, "Shown panel reflects freeze")
	check(panel._draw_option.selected == 2, "Shown panel reflects overdraw draw mode")
	check(not panel._wireframe_caption.visible, "Wireframe caption hidden for overdraw")
	# Restore defaults so later checks start clean.
	renderer.set_render_debug("visibility_mode", "async")
	renderer.set_render_debug("depth_layers", 0)
	renderer.set_render_debug("look_ahead", true)
	renderer.set_render_debug("look_ahead_sec", 0.15)
	renderer.set_render_debug("refresh_every_frame", true)
	renderer.set_render_debug("freeze", false)
	main.get_viewport().debug_draw = Viewport.DEBUG_DRAW_DISABLED
	await process_frame

func _check_dump() -> void:
	var dump := find_text_button(panel, "Dump ramp counts")
	check(dump != null, "Dump ramp counts button exists")
	var overlay = main.debug_overlay
	var counter := CountingOverlay.new()
	main.debug_overlay = counter
	if dump != null:
		dump.pressed.emit()
	check(counter.dumps == 1, "Dump ramp counts calls dump_ramp_counts once")
	main.debug_overlay = null
	if dump != null:
		dump.pressed.emit()
	check(counter.dumps == 1, "Dump ramp counts is a no-op with a null debug overlay")
	main.debug_overlay = overlay
	check(main.debug_overlay == overlay, "Debug overlay restored after null-guard check")
	counter.free()


func _check_readout() -> void:
	var renderer = world.renderer
	panel._refresh_readout()
	check(panel._fps_label.text.begins_with("FPS "), "FPS readout updates")
	check(panel._void_label.text.begins_with("Void now "), "Void readout updates")
	check(panel._shown_label.text.begins_with("Shown "), "Shown readout updates")
	check(panel._updates_label.text.begins_with("Updates/s "), "Updates readout updates")

	# Injected stats go straight into the panel; creating a second WorldRenderer here would leak at exit.
	var stats: Dictionary = renderer.get_render_debug_stats()
	stats["vis_lag_ms"] = null
	stats["void"] = {"hidden": 3, "checked": 10, "max_recent": 4, "void_ms": 80.0, "void_pct_recent": 15.0}
	panel._apply_stats(stats)
	check(panel._shown_label.text.contains("vis lag n/a"), "Null vis lag shows n/a")
	check(panel._void_label.text.contains("Void now 3"), "Hidden void count is shown")
	check(panel._void_label.has_theme_color_override("font_color") and panel._void_label.get_theme_color("font_color") == ColonyUITheme.BAD, "Hidden void uses BAD colour")

	stats["vis_lag_ms"] = 42.0
	stats["void"] = {"hidden": 0, "checked": 10, "max_recent": 0, "void_ms": 0.0, "void_pct_recent": 0.0}
	panel._apply_stats(stats)
	check(panel._shown_label.text.contains("vis lag 42 ms"), "Numeric vis lag is shown")
	check(not panel._void_label.has_theme_color_override("font_color"), "No void highlight when nothing hidden")
	# Return the readout to the live renderer values.
	panel._refresh_readout()

func _check_layout() -> void:
	for i in range(3):
		await process_frame
	var rect: Rect2 = panel.get_global_rect()
	check(Rect2(Vector2.ZERO, Vector2(1920, 1080)).encloses(rect), "Panel rect is inside 1920x1080")
	check(not rect.intersects(ui.command_bar.bar.get_global_rect()), "Panel does not overlap the command bar")
	check(not rect.intersects(ui.command_bar.gauge.get_global_rect()), "Panel does not overlap the depth gauge")
	check(not rect.intersects(ui.details.get_global_rect()) and not rect.intersects(ui.management.get_global_rect()),
		"Panel does not overlap the details or management panels")
	var motion := InputEventMouseMotion.new()
	motion.position = rect.get_center()
	motion.global_position = rect.get_center()
	root.push_input(motion)
	await process_frame
	check(ui.pointer_owned(), "Hovering the panel makes colony_ui.pointer_owned() true")
