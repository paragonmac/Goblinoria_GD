extends SceneTree

const WindowLayoutScript = preload("res://scripts/ui/window_layout.gd")

var checks := 0
var failures := 0
var ui_root: Control
var manager
var panels := {}
var close_buttons := {}
var headers := {}
var right_band := Rect2(1328, 16, 480, 894)
var left_band := Rect2(16, 16, 480, 952)
var float_area := Rect2(0, 0, 1920, 968)
var pressed_count := 0
var test_viewport: SubViewport

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var viewport := SubViewport.new()
	viewport.size = Vector2i(1920, 1080)
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	get_root().add_child(viewport)
	test_viewport = viewport
	ui_root = Control.new()
	ui_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	viewport.add_child(ui_root)
	manager = WindowLayoutScript.new()
	manager.config_path = "user://window_layout_validation_%d.cfg" % Time.get_ticks_usec()
	manager.setup(ui_root, Callable(self, "_area"))
	_make_window("a", "left", Rect2(16, 16, 480, 400), 480)
	_make_window("b", "right", Rect2(1328, 16, 400, 300), 400)
	_make_window("c", "right", Rect2(1328, 16, 400, 300), 400)
	_make_window("d", "float", Rect2(600, 200, 360, 400), 360)
	await process_frame
	await process_frame
	check(_rect("a").is_equal_approx(Rect2(16, 16, 480, 952)), "left default fills band")
	check(_rect("b").size.y == 443 and _rect("c").position.y == 467, "right defaults split with gap")
	panels["b"].hide()
	await process_frame
	check(is_equal_approx(_rect("c").size.y, 894.0), "hiding re-stacks visible dock windows")
	panels["b"].show()
	await process_frame
	check(is_equal_approx(_rect("b").size.y, 443.0), "showing restores split")

	var initial_d: Rect2 = _rect("d")
	var commit_count := [0]
	manager.layout_changed.connect(func(): commit_count[0] += 1)
	_send_button(Vector2(650, 215), true)
	_send_motion(Vector2(680, 245))
	await process_frame
	check(manager.is_interacting(), "drag becomes interacting")
	_send_motion(Vector2(700, 265))
	await process_frame
	check(commit_count[0] == 0, "motion does not commit")
	_send_button(Vector2(700, 265), false)
	await process_frame
	check(not manager.is_interacting(), "release ends drag")
	check(_rect("d").position.is_equal_approx(initial_d.position + Vector2(50, 50)), "floating drag follows pointer delta")
	check(commit_count[0] == 1, "drag commits once")

	_send_button(close_buttons["a"].get_global_rect().get_center(), true)
	_send_button(close_buttons["a"].get_global_rect().get_center(), false)
	await process_frame
	check(pressed_count == 1, "header button press still activates")
	check(not manager.is_interacting(), "button press does not start drag")

	var d_rect := _rect("d")
	_send_button(d_rect.position + Vector2(80, 15), true)
	_send_motion(Vector2(1750, 50))
	await process_frame
	check(manager._highlight.visible, "dock highlight appears near right band")
	_send_button(Vector2(1750, 50), false)
	await process_frame
	check(manager.get_state("d")["dock"] == "right", "drop docks to right")
	check(manager._orders["right"].size() == 3, "right stack contains three windows")

	manager.undock("a", Rect2(600, 300, 480, 400))
	var a_pos := _rect("a").position
	_send_button(a_pos + Vector2(50, 15), true)
	_send_motion(a_pos + Vector2(80, 40))
	await process_frame
	check(manager.get_state("a")["dock"] == "float", "dragging docked panel undocks immediately")
	_send_button(a_pos + Vector2(80, 40), false)
	await process_frame
	check(_rect("a").size.is_equal_approx(Vector2(480, 400)), "undock uses remembered float size")

	manager.dock("a", "left")
	manager.set_width_floor("a", 0)
	var left_before: float = manager.get_state("a")["dock_width"]
	_send_button(Vector2(_rect("a").end.x - 1, _rect("a").position.y + 100), true)
	_send_motion(Vector2(_rect("a").end.x - 80, _rect("a").position.y + 100))
	await process_frame
	_send_button(Vector2.ZERO, false)
	await process_frame
	check(manager.get_state("a")["dock_width"] < left_before, "inner dock edge resizes width")
	_send_button(Vector2(_rect("a").end.x - 1, 100), true)
	_send_motion(Vector2(3000, 100))
	await process_frame
	_send_button(Vector2.ZERO, false)
	check(manager.get_state("a")["dock_width"] <= left_band.size.x, "dock width is band clamped")

	manager.undock("d", Rect2(600, 200, 360, 400))
	var d_start := _rect("d")
	_send_button(d_start.end - Vector2(2, 100), true)
	_send_motion(d_start.position + Vector2(80, 300))
	await process_frame
	_send_button(Vector2.ZERO, false)
	check(_rect("d").size.x >= 240 and _rect("d").size.y >= 160, "floating resize respects minimum")
	var corner := _rect("d")
	_send_button(corner.end - Vector2(2, 2), true)
	_send_motion(Vector2(3000, 1200))
	await process_frame
	_send_button(Vector2.ZERO, false)
	check(_rect("d").end.x <= float_area.end.x and _rect("d").end.y <= float_area.end.y, "floating corner resize stays inside float area")

	manager.undock("d", Rect2(1850, 920, 600, 300))
	check(_rect("d").end.x <= 1920 and _rect("d").end.y <= 968, "relayout clamps large floating rect")
	manager.undock("d", Rect2(600, 200, 360, 400))
	manager.set_width_floor("d", 500)
	check(_rect("d").size.x >= 500, "width floor widens window")
	manager.set_width_floor("d", 0)
	check(is_equal_approx(_rect("d").size.x, 360), "clearing floor restores saved user width")

	manager.dock("d", "right", 1)
	manager.undock("a", Rect2(700, 250, 400, 350))
	manager.save()
	var saved_a: Dictionary = manager.get_state("a")
	var saved_order: Array = manager._orders["right"].duplicate()
	var manager2 = WindowLayoutScript.new()
	manager2.config_path = manager.config_path
	manager2.setup(ui_root, Callable(self, "_area"))
	for id in ["a", "b", "c", "d"]:
		manager2.register(id, panels[id], headers[id], {"dock":"float", "float_rect":Rect2(400,200,300,200), "dock_width":300, "min_size":Vector2(240,160)})
	check(manager2.load(), "valid saved layout loads")
	check(manager2.get_state("a")["float_rect"].is_equal_approx(saved_a["float_rect"]), "round trip restores float rect")
	check(manager2._orders["right"] == saved_order, "round trip restores dock order")
	check(is_equal_approx(manager2.get_state("d")["dock_width"], manager.get_state("d")["dock_width"]), "round trip restores dock width")
	check(manager2.get_state("d")["dock"] == "right", "round trip restores dock side")

	var bad_path: String = manager.config_path + ".bad"
	var bad := FileAccess.open(bad_path, FileAccess.WRITE)
	bad.store_string("this is not a valid config [[")
	bad.close()
	manager2.config_path = bad_path
	check(not manager2.load(), "corrupt config ignored")
	check(manager2.get_state("a")["dock"] == "float", "corrupt config keeps current defaults")
	var wrong_path: String = manager.config_path + ".version"
	var wrong := ConfigFile.new()
	wrong.set_value("layout", "version", 99)
	wrong.save(wrong_path)
	manager2.config_path = wrong_path
	check(not manager2.load(), "wrong version ignored")

	manager2.reset()
	check(manager2.get_state("a")["dock"] == "float", "reset restores registered defaults")
	# manager2 drives the same panels; free it so it stops fighting manager over
	# their rects (signal connections to a freed object are dropped).
	manager2._overlay.free()
	manager2.free()
	manager.relayout()

	manager.undock("a", Rect2(700, 250, 360, 300))
	manager.undock("d", Rect2(700, 250, 360, 300))
	var a_index: int = panels["a"].get_index()
	manager._input(_left_click_event(Vector2(710, 260)))
	check(panels["d"].get_index() > panels["a"].get_index() and panels["a"].get_index() == a_index, "click raises floating window")
	manager.root_keep_overlay_last()
	check(ui_root.get_child(ui_root.get_child_count() - 1) == manager._overlay, "overlay remains topmost")
	await _hardening_checks()
	await _review_checks()
	_cleanup()
	if failures == 0:
		print("Window layout: %d checks, %d failures" % [checks, failures])
		quit(0)
	else:
		print("Window layout: %d checks, %d failures" % [checks, failures])
		quit(1)

## Regressions found during integration (2026-10-09).
func _hardening_checks() -> void:
	# Isolate from earlier checks: only d floats in the test area, b and c visible.
	panels["a"].hide()
	panels["b"].show()
	panels["c"].show()
	# Dropping inside a band but away from its screen-side edge must stay floating.
	manager.undock("d", Rect2(700, 300, 360, 300))
	panels["d"].move_to_front()
	manager.root_keep_overlay_last()
	await process_frame
	var header_point: Vector2 = _header_grab("d")
	var inside_left := Vector2(left_band.position.x + 300, 500)
	_send_button(header_point, true)
	_send_motion(header_point + Vector2(10, 10))
	_send_motion(inside_left)
	_send_button(inside_left, false)
	await process_frame
	check(manager.get_state("d")["dock"] == "float" and not _rect("d").position.is_equal_approx(Vector2(700, 300)),
		"drop inside a band away from its edge moves the window but stays floating")
	# cancel_interaction ends a drag where it is, without docking.
	header_point = _header_grab("d")
	_send_button(header_point, true)
	_send_motion(header_point + Vector2(30, 0))
	_send_motion(Vector2(left_band.position.x + 4, 400))
	check(manager.is_interacting(), "drag in progress before cancel")
	manager.cancel_interaction()
	check(not manager.is_interacting() and manager.get_state("d")["dock"] == "float" and not manager._highlight.visible,
		"cancel_interaction stops the drag, floats the window and hides the dock highlight")
	_send_button(Vector2(left_band.position.x + 4, 400), false)
	# A window registered after load() still gets its saved layout.
	manager.undock("c", Rect2(900, 500, 300, 200))
	manager.save()
	var late := WindowLayoutScript.new()
	late.config_path = manager.config_path
	late.setup(ui_root, Callable(self, "_area"))
	late.load()
	var late_panel := PanelContainer.new()
	ui_root.add_child(late_panel)
	var late_header := HBoxContainer.new()
	late_panel.add_child(late_header)
	late.register("c", late_panel, late_header, {"dock": "right", "float_rect": Rect2(0, 0, 300, 300), "dock_width": 400.0, "min_size": Vector2(240, 160)})
	check(late.get_state("c")["dock"] == "float" and late.get_state("c")["float_rect"].position.is_equal_approx(Vector2(900, 500)),
		"late registration applies the saved layout")
	late_panel.queue_free()
	late._overlay.queue_free()
	late.queue_free()
	# Empty config_path disables persistence entirely.
	var no_save := WindowLayoutScript.new()
	no_save.config_path = ""
	no_save.setup(ui_root, Callable(self, "_area"))
	no_save.save()
	check(not no_save.load(), "empty config path never loads")
	no_save._overlay.queue_free()
	no_save.queue_free()
	# A panel shrinks back when its content minimum shrinks.
	manager.dock("b", "right")
	var wide := Control.new()
	wide.custom_minimum_size = Vector2(700, 10)
	panels["b"].get_node("Body").add_child(wide)
	await process_frame
	await process_frame
	check(_rect("b").size.x >= 700.0, "wide content widens a docked panel")
	wide.queue_free()
	await process_frame
	await process_frame
	check(is_equal_approx(_rect("b").size.x, 400.0), "removing wide content shrinks the panel back to its dock width")


## Regressions from the opus-reviewer-3 review (2026-10-09).
func _review_checks() -> void:
	for id in ["a", "b", "c", "d"]:
		panels[id].show()
	panels["a"].hide()
	# 1. Clicking raises the window actually on top at that point, not the most
	#    recently registered one.
	manager.undock("b", Rect2(600, 300, 400, 300))
	manager.undock("c", Rect2(700, 350, 400, 300))
	manager.undock("d", Rect2(1300, 700, 300, 200))
	panels["c"].move_to_front()
	panels["b"].move_to_front()
	manager.root_keep_overlay_last()
	await process_frame
	var overlap := Vector2(900, 400)
	_send_motion(overlap)
	_send_button(overlap, true)
	_send_button(overlap, false)
	await process_frame
	check(panels["b"].get_index() > panels["c"].get_index(), "click keeps the front window in front (raise by z-order)")
	# 2. The back window's resize handles are covered by the front window.
	var back_west := Vector2(manager.get_state("c").rect.position.x + 3, 500)
	_send_motion(back_west)
	_send_button(back_west, true)
	check(not (manager._interaction == "resize" and manager._active_id == "c"), "front window covers resize handles of the window behind")
	_send_button(back_west, false)
	manager.cancel_interaction()
	# 3. Docked stacks never leave their band, even when minimums do not fit.
	var saved_band := right_band
	right_band = Rect2(1328, 16, 480, 300)
	for id in ["b", "c", "d"]:
		manager.dock(id, "right")
	manager.relayout()
	var bottom := 0.0
	for id in ["b", "c", "d"]:
		bottom = maxf(bottom, _rect(id).end.y)
	check(bottom <= right_band.end.y + 0.5, "docked stack fits the band when minimums exceed it")
	right_band = saved_band
	manager.relayout()
	# 4. A temporary width floor is never stored by an edge resize.
	manager.undock("c", Rect2(700, 350, 400, 300))
	manager.undock("d", Rect2(1300, 700, 300, 200))
	var before_width: float = manager.get_state("b").dock_width
	manager.set_width_floor("b", 700.0)
	await process_frame
	var edge := Vector2(_rect("b").position.x + 1, _rect("b").position.y + 200)
	_send_motion(edge)
	_send_button(edge, true)
	_send_motion(edge + Vector2(-1, 0))
	_send_button(edge + Vector2(-1, 0), false)
	check(manager.get_state("b").dock_width < 650.0, "edge resize under a width floor stores the real width")
	manager.set_width_floor("b", 0.0)
	check(_rect("b").size.x < 650.0, "clearing the floor returns to the stored width")
	# 5. Saved entries for windows not created this session survive a save;
	#    reset() clears them.
	var ghost := ConfigFile.new()
	ghost.set_value("layout", "version", manager.LAYOUT_VERSION)
	ghost.set_value("windows", "ghost", {"dock": "float", "float_rect": Rect2(900, 500, 300, 200), "dock_width": 300.0, "order": -1})
	ghost.save(manager.config_path)
	manager.load()
	manager.save()
	var reread := ConfigFile.new()
	reread.load(manager.config_path)
	check(reread.has_section_key("windows", "ghost"), "save keeps layouts of windows not opened this session")
	manager.reset()
	check(not manager._saved.has("ghost"), "reset clears remembered layouts")
	# 6. Dropping against the screen's right edge (past the band inset) docks.
	for id in ["b", "c"]:
		manager.undock(id, Rect2(200 + 50 * ["b", "c"].find(id), 300, 300, 200))
	manager.undock("d", Rect2(700, 300, 300, 200))
	panels["d"].move_to_front()
	manager.root_keep_overlay_last()
	await process_frame
	var grab := _header_grab("d")
	_send_button(grab, true)
	_send_motion(grab + Vector2(10, 0))
	_send_motion(Vector2(1915, 400))
	_send_button(Vector2(1915, 400), false)
	check(manager.get_state("d").dock == "right", "drop at the screen's right edge docks right")
	# 8. Hiding the dragged window cancels the drag instead of docking it later.
	manager.undock("d", Rect2(700, 300, 300, 200))
	panels["d"].move_to_front()
	manager.root_keep_overlay_last()
	await process_frame
	grab = _header_grab("d")
	_send_button(grab, true)
	_send_motion(grab + Vector2(20, 0))
	_send_motion(Vector2(1915, 400))
	panels["d"].hide()
	check(not manager.is_interacting(), "hiding the dragged window cancels the drag")
	_send_button(Vector2(1915, 400), false)
	check(manager.get_state("d").dock == "float", "a cancelled drag does not dock on release")
	panels["d"].show()


## A point on the empty part of a header (right end), clear of its title and close button.
func _header_grab(id: String) -> Vector2:
	var rect: Rect2 = headers[id].get_global_rect()
	return rect.position + Vector2(rect.size.x - 20.0, rect.size.y * 0.5)


func _area(side: String) -> Rect2:
	if side == "left": return left_band
	if side == "right": return right_band
	return float_area

func _make_window(id: String, dock: String, rect: Rect2, width: float) -> void:
	var panel := PanelContainer.new()
	panel.name = "Panel_" + id
	ui_root.add_child(panel)
	var body := VBoxContainer.new()
	body.name = "Body"
	panel.add_child(body)
	var header := HBoxContainer.new()
	header.name = "Header"
	body.add_child(header)
	var title := Label.new()
	title.text = id
	header.add_child(title)
	var close := Button.new()
	close.text = "x"
	close.pressed.connect(func(): pressed_count += 1)
	header.add_child(close)
	var content := Label.new()
	content.text = "body"
	body.add_child(content)
	panels[id] = panel
	headers[id] = header
	close_buttons[id] = close
	manager.register(id, panel, header, {"dock":dock, "float_rect":rect, "dock_width":width, "min_size":Vector2(240,160)})

func _rect(id: String) -> Rect2:
	return Rect2(panels[id].position, panels[id].size)

## Events go through the SubViewport's real input path: _input on the manager,
## then GUI routing with control-local positions, like a real window.
func _send_button(point: Vector2, down: bool) -> void:
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = down
	event.button_mask = MOUSE_BUTTON_MASK_LEFT if down else 0
	event.position = point
	event.global_position = point
	test_viewport.push_input(event)

func _left_click_event(point: Vector2) -> InputEventMouseButton:
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = true
	event.position = point
	event.global_position = point
	return event

func _send_motion(point: Vector2) -> void:
	var event := InputEventMouseMotion.new()
	event.button_mask = MOUSE_BUTTON_MASK_LEFT
	event.position = point
	event.global_position = point
	test_viewport.push_input(event)
func check(condition: bool, label: String) -> void:
	checks += 1
	if not condition:
		failures += 1
		push_error("FAIL: " + label)

func _cleanup() -> void:
	DirAccess.remove_absolute(ProjectSettings.globalize_path(manager.config_path))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(manager.config_path + ".bad"))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(manager.config_path + ".version"))