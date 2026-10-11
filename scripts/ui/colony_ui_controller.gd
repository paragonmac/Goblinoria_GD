extends RefCounted
## Main owns lifetime and authoritative actions; controls never own simulation.
const Catalog = preload("res://scripts/ui/colony_capability_catalog.gd")
const ThemeFactory = preload("res://scripts/ui/colony_ui_theme.gd")
const Navigation = preload("res://scripts/ui/colony_navigation.gd")
const Model = preload("res://scripts/ui/colony_presentation_model.gd")
const Panels = preload("res://scripts/ui/colony_management_panels.gd")
const JobsPopup = preload("res://scripts/ui/jobs_worker_popup.gd")
const WindowPolicy = preload("res://scripts/ui/colony_window_policy.gd")
const H = preload("res://scripts/ui/colony_panel_helpers.gd")
const Tools = preload("res://scripts/main_tool_catalog.gd")
const PAGE_SIZE := 50
const DETAILS_WIDTH := 400.0
const DETAILS_WIDE_WIDTH := 700.0
# Right edge of docked details: clear of the 84 px depth gauge and its margin.
const DETAILS_RIGHT := -112.0
const CommandBar = preload("res://scripts/ui/colony_command_bar.gd")

class PopupInput extends Node:
	var popup: Window
	var ui_ref: WeakRef
	func _input(event: InputEvent) -> void:
		var ui = ui_ref.get_ref()
		if ui == null or not popup.visible: return
		if event is InputEventKey:
			ui.main.key_state[event.keycode] = event.pressed
			if event.pressed and event.keycode == KEY_ESCAPE:
				popup.hide()
				popup.set_input_as_handled()
				if popup is AcceptDialog: popup.queue_free()
		elif event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_RIGHT:
			if not Rect2(Vector2.ZERO, Vector2(popup.size)).has_point(event.position):
				ui._held_buttons[MOUSE_BUTTON_RIGHT] = true
				popup.hide()
				popup.set_input_as_handled()
				if popup is AcceptDialog: popup.queue_free()

var main
var root: Control
var navigation = Navigation.new()
var model = Model.new()
var panels = Panels.new()
var jobs_popup = JobsPopup.new()
# Floating/docked windows: management (left dock), details (right dock), Jobs and
# debug panels (floating). Layout persists in user://ui_layout.cfg.
var layout: WindowLayout
var _management_header: Control
var _details_header: Control
const LAYOUT_PATH := "user://ui_layout.cfg"
const FLOAT_TOP := 72.0
var window_policy = WindowPolicy.new()
var command_bar = CommandBar.new()
var management: PanelContainer
var details: PanelContainer
var body: VBoxContainer
var detail_body: VBoxContainer
var rows_box: VBoxContainer
var category := ""
var title: Label
var summary: Label
var feedback: Label
var level_label: Label
var search: LineEdit
var filter: OptionButton
var pager: Label
var page := 0
var search_text := ""
var filter_text := "All"
var filtered: Array = []
var _filter_rows: Array = []
var _filter_index := 0
var _filtering := false
var _filter_revision := -1
var _filtered_work: Array = []
var selection: Dictionary = {}
var _selection_object
var _selection_serial := 0
var _panel_order: Array[String] = []
var _held_buttons: Dictionary = {}
var _release_event := 0
var _refresh_timer := 0.0
var _feedback_until := 0
var _was_loading := false
var _world_id := 0
var _world_epoch := -1
var _tool_buttons: Dictionary = {}
var _detail_signature := ""

func setup(owner, configure_window: bool = true) -> void:
	main = owner
	panels.ui = self
	root = Control.new()
	root.name = "ColonyUI"
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	main.hud_layer.add_child(root)
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.theme = ThemeFactory.build()
	if configure_window:
		window_policy.setup(main.get_window())
	navigation.category_selected.connect(toggle_category)
	_build_shell()
	jobs_popup.setup(root, root.theme)
	jobs_popup.close_requested.connect(close_management)
	_setup_layout()
	model.bind_world(main.world)
	_world_id = main.world.get_instance_id()
	_world_epoch = main.world.runtime_epoch
	main.selection_controller.selection_feedback.connect(show_feedback)
	main.selection_controller.cell_inspected.connect(inspect_cell)
	main.context_menu_controller.external_inspector = true
	main.context_menu_controller.cell_inspected.connect(inspect_cell)
	main.context_menu_controller.action_feedback.connect(show_feedback)
	main.context_menu_controller.popup.theme = root.theme
	main.worker_window_controller.close()
	main.worker_window_controller.colony_ui = self
	main.hud_controller.retired = true
	for old in [main.hud_label, main.hud_controller.y_level_label, main.hud_controller.gen_status_label,
		main.hud_controller.inventory_label, main.hud_controller.stockpile_panel]:
		if is_instance_valid(old):
			old.hide()
	var menu: Control = main.menu_vbox.get_parent()
	menu.theme = root.theme
	menu.offset_left = -350
	menu.offset_right = 350
	menu.offset_top = -310
	menu.offset_bottom = 310
	H.label(main.menu_vbox, "Saves keep terrain, items, stockpiles, worker positions and roles, pending jobs and the camera. Jobs in progress restart.")
	# Recording/diagnostic status sits quietly at the top centre, clear of panels.
	for entry in [[main.performance_controller.indicator, 10], [main.diagnostics_controller.indicator, 34]]:
		var indicator: Label = entry[0]
		if indicator == null:
			continue
		indicator.anchor_left = 0.5
		indicator.anchor_right = 0.5
		indicator.anchor_top = 0
		indicator.anchor_bottom = 0
		indicator.offset_top = entry[1]
		indicator.offset_bottom = entry[1] + 24
		indicator.offset_left = -300
		indicator.offset_right = 300
		indicator.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		indicator.add_theme_font_size_override("font_size", 16)

func _build_shell() -> void:
	# Approved hybrid layout: one bottom command bar (status, tools, panels),
	# right-edge depth gauge, docked panels above the bar, world kept clear.
	var bar_top := -CommandBar.BAR_HEIGHT - 12.0
	management = PanelContainer.new()
	management.name = "Management"
	management.theme_type_variation = "Card"
	root.add_child(management)
	management.set_anchors_and_offsets_preset(Control.PRESET_LEFT_WIDE)
	management.offset_left = 16
	management.offset_right = 496
	management.offset_top = 16
	management.offset_bottom = bar_top
	var content := H.content(management)
	var header := HBoxContainer.new()
	content.add_child(header)
	_management_header = header
	title = H.styled_label(header, "Colony", "Heading")
	var close := H.icon_button(header, "close", "Close", close_management, "IconButton", 18, Vector2(44, 40))
	close.get_meta("caption").hide()
	body = H.scroll(content)
	management.hide()
	details = PanelContainer.new()
	details.name = "Details"
	details.theme_type_variation = "Card"
	root.add_child(details)
	details.set_anchors_and_offsets_preset(Control.PRESET_RIGHT_WIDE)
	details.offset_right = DETAILS_RIGHT
	details.offset_left = DETAILS_RIGHT - DETAILS_WIDTH
	details.offset_top = 16
	details.offset_bottom = bar_top - 58.0
	var detail_content := H.content(details)
	var detail_header := HBoxContainer.new()
	detail_content.add_child(detail_header)
	_details_header = detail_header
	H.styled_label(detail_header, "Details", "Subheading")
	var close_detail := H.icon_button(detail_header, "close", "Close details", close_details, "IconButton", 18, Vector2(44, 40))
	close_detail.get_meta("caption").hide()
	detail_body = H.scroll(detail_content)
	details.hide()
	command_bar.build(root, self)
	summary = command_bar.summary
	_tool_buttons = command_bar.tool_buttons
	level_label = command_bar.level_label
	feedback = Label.new()
	feedback.name = "Feedback"
	feedback.theme_type_variation = "Body"
	root.add_child(feedback)
	feedback.mouse_filter = Control.MOUSE_FILTER_IGNORE
	feedback.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	feedback.offset_left = 520
	feedback.offset_right = -520
	feedback.offset_top = bar_top - 96
	feedback.offset_bottom = bar_top - 64
	feedback.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	feedback.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.8))
	feedback.add_theme_constant_override("shadow_offset_x", 1)
	feedback.add_theme_constant_override("shadow_offset_y", 1)
	feedback.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	feedback.tooltip_text = ""

## Bands for docked windows and the area floating windows must stay inside, in
## root coordinates: clear of the bottom command bar, the right depth gauge and
## the blocked-jobs toast above the bar.
func _layout_area(side: String) -> Rect2:
	var size := root.size
	var bar_top := size.y - CommandBar.BAR_HEIGHT - 12.0
	match side:
		"left":
			return Rect2(16.0, 16.0, minf(900.0, size.x * 0.5 - 24.0), maxf(0.0, bar_top - 16.0))
		"right":
			var right := size.x + DETAILS_RIGHT
			var width := minf(900.0, size.x * 0.5 - 24.0)
			return Rect2(right - width, 16.0, width, maxf(0.0, bar_top - 58.0 - 16.0))
	return Rect2(16.0, FLOAT_TOP, maxf(0.0, size.x - 32.0), maxf(0.0, bar_top - FLOAT_TOP))


func _setup_layout() -> void:
	layout = WindowLayout.new()
	# Headless validators must never read or overwrite the player's layout.
	layout.config_path = "" if DisplayServer.get_name() == "headless" else LAYOUT_PATH
	layout.setup(root, _layout_area)
	var float_area := _layout_area("float")
	layout.register("management", management, _management_header,
		{"dock": "left", "dock_width": 480.0, "min_size": Vector2(360, 240),
		"float_rect": Rect2(float_area.position + Vector2(40, 0), Vector2(480, 640))})
	layout.register("details", details, _details_header,
		{"dock": "right", "dock_width": DETAILS_WIDTH, "min_size": Vector2(320, 200),
		"float_rect": Rect2(float_area.end.x - DETAILS_WIDTH - 40.0, float_area.position.y, DETAILS_WIDTH, 640)})
	var jobs_size := Vector2(minf(JobsPopup.PANEL_SIZE.x, float_area.size.x), minf(JobsPopup.PANEL_SIZE.y, float_area.size.y))
	layout.register("jobs", jobs_popup.panel, jobs_popup._header,
		{"dock": "float", "min_size": Vector2(480, 360), "dock_width": jobs_size.x,
		"float_rect": Rect2(float_area.position + (float_area.size - jobs_size) * 0.5, jobs_size)})
	layout.load()


## For panels created elsewhere (debug tools): reparent into the layout root and
## manage as a window. defaults as WindowLayout.register.
func register_window(id: String, panel: Control, handle: Control, defaults: Dictionary) -> void:
	if panel.get_parent() != root:
		if panel.get_parent() != null:
			panel.get_parent().remove_child(panel)
		root.add_child(panel)
	layout.register(id, panel, handle, defaults)


func reset_layout() -> void:
	if layout != null:
		layout.reset()


static func tool_hint(mode: int) -> String:
	match mode:
		World.PlayerMode.PLACE: return "Place one block using one stored iron ore. Construction delivery is not implemented yet."
		World.PlayerMode.ERASE: return "Cancel pending jobs or remove stockpiles and torches. Not demolition or undo."
		World.PlayerMode.TORCH: return "Designate explored floor cells for miners to illuminate with free torches."
		World.PlayerMode.CHOP: return "Designate explored trees for miners to fell into logs."
		World.PlayerMode.UP_STAIRS, World.PlayerMode.DOWN_STAIRS: return "Place one 2 x 1 stair flight. Mouse wheel rotates 90 degrees; red ghost means unavailable. No material cost."
	return Tools.mode_label(mode)

func tick(dt: float) -> void:
	window_policy.tick(dt)
	# Native/embedded text menus can consume releases in another viewport.
	for button in [MOUSE_BUTTON_LEFT, MOUSE_BUTTON_RIGHT, MOUSE_BUTTON_MIDDLE]:
		if _held_buttons.has(button) and not main.input_state.is_mouse_button_pressed(button):
			_held_buttons.erase(button)
	if main.loading_active and not _was_loading:
		reset_world()
	_was_loading = main.loading_active
	root.visible = main.world_started and not main.menu_open and not main.loading_active
	if main.loading_active:
		return
	if main.world.get_instance_id() != _world_id or main.world.runtime_epoch != _world_epoch:
		reset_world()
	model.pump()
	_filter_pump()
	_refresh_timer += dt
	if _refresh_timer >= 0.2:
		_refresh_timer = 0
		_refresh_summary()
		if not category.is_empty() and not _filtering and _filter_revision != model.revision:
			_start_filter()
		_refresh_details()
		model.refresh_workers()
		panels.refresh_debug_controls()
	command_bar.update_tools(main.world.player_mode)
	command_bar.update_level(main.world.top_render_y - main.hud_controller.render_level_base_y, main.world.top_render_y)
	if Time.get_ticks_msec() > _feedback_until:
		feedback.text = ""

func reset_world() -> void:
	cancel_popups()
	navigation.close_more()
	close_details()
	close_management()
	model.bind_world(main.world)
	_world_id = main.world.get_instance_id()
	_world_epoch = main.world.runtime_epoch
	filtered = []
	_filtering = false
	_filter_revision = -1
	_held_buttons.clear()

func _refresh_summary() -> void:
	var data: Dictionary = model.snapshot()
	var counts: Dictionary = data.get("counts", {})
	command_bar.update_counts(counts, model.updating)
	if category == "colony":
		panels.update_colony(data)

func open_category(id: String) -> void:
	if main.loading_active or not main.world_started:
		return
	if id == "assignments" and category == id and jobs_popup.is_visible():
		return
	jobs_popup.hide()
	navigation.close_more()
	category = id
	page = 0
	search_text = ""
	filter_text = "All"
	search = null
	filter = null
	rows_box = null
	pager = null
	H.clear(body)
	H.clear(jobs_popup.body)
	for entry: Dictionary in Catalog.categories():
		if entry.id == id:
			title.text = entry.label
	navigation.set_selected(id)
	var page_body: VBoxContainer = body
	if id == "assignments":
		management.hide()
		close_details()
		jobs_popup.open()
		page_body = jobs_popup.body
	else:
		management.show()
	_touch_panel("management")
	panels.build(id, page_body)
	_start_filter()

func toggle_category(id: String) -> void:
	if (management.visible or jobs_popup.is_visible()) and category == id:
		close_management()
	else:
		open_category(id)

func toggle_workers(activity: String) -> void:
	if management.visible and category == "workers" and filter_text.to_lower() == activity.to_lower() and search_text.is_empty():
		close_management()
	else:
		show_workers(activity)

func show_workers(activity: String) -> void:
	open_category("workers")
	filter_text = activity
	if filter != null:
		for index in range(filter.item_count):
			if filter.get_item_text(index).to_lower() == activity:
				filter.select(index)
	_start_filter()

func show_tasks(filter_value: String) -> void:
	open_category("jobs")
	filter_text = filter_value
	if filter != null:
		for index in range(filter.item_count):
			if filter.get_item_text(index) == filter_value:
				filter.select(index)
	_start_filter()

func close_management() -> void:
	jobs_popup.hide()
	management.hide()
	category = ""
	_filtering = false
	_panel_order.erase("management")
	navigation.set_selected("")

func close_details() -> void:
	_selection_serial += 1
	details.hide()
	selection = {}
	_selection_object = null
	_detail_signature = ""
	_panel_order.erase("details")

func _touch_panel(id: String) -> void:
	_panel_order.erase(id)
	_panel_order.append(id)

func _more_open() -> bool:
	return is_instance_valid(navigation.more_panel) and navigation.more_panel.visible


func close_latest() -> bool:
	if _more_open():
		navigation.close_more()
		return true
	if _panel_order.is_empty():
		return false
	if _panel_order.back() == "details":
		close_details()
	else:
		close_management()
	return true

func choose_tool(mode: int) -> void:
	if main.loading_active or not main.world_started:
		return
	navigation.close_more()
	main._cancel_context_input()
	main.world.set_player_mode(mode)
	show_feedback(tool_hint(mode))

func change_level(delta: int) -> void:
	if not main.loading_active:
		main._handle_render_layer_change(delta)

func show_feedback(message: String) -> void:
	feedback.text = message
	_feedback_until = Time.get_ticks_msec() + 4000

func select_row(kind: String, id: int) -> void:
	var row: Dictionary = model.get_row(_model_kind(kind), id)
	if row.is_empty():
		show_feedback("No longer available")
		return
	_selection_serial += 1
	selection = {"kind": kind, "id": id, "epoch": model.epoch}
	_selection_object = _actual_target(kind, id)
	_detail_signature = ""
	# The priority editor needs the wide layout; the user's own width wins if larger.
	layout.set_width_floor("details", DETAILS_WIDE_WIDTH if kind == "assignment" else 0.0)
	details.show()
	_touch_panel("details")
	_refresh_details()

func toggle_row(kind: String, id: int) -> void:
	if details.visible and selection.get("kind") == kind and selection.get("id") == id and valid_selection():
		close_details()
	else:
		select_row(kind, id)

static func _model_kind(kind: String) -> String:
	return "worker" if kind == "assignment" else kind

func open_assignments(worker_id: int = -1) -> void:
	open_category("assignments")
	if worker_id >= 0:
		select_row("assignment", worker_id)

func inspect_cell(block_id: int, pos: Vector3i) -> void:
	_selection_serial += 1
	selection = {"kind": "cell", "id": block_id, "pos": pos, "epoch": model.epoch}
	_selection_object = null
	layout.set_width_floor("details", 0.0)
	details.show()
	_touch_panel("details")
	_detail_signature = ""
	_refresh_details()

func _actual_target(kind: String, id: int):
	match kind:
		"worker", "assignment":
			for worker in main.world.workers:
				if is_instance_valid(worker) and worker.worker_id == id:
					return worker
		"job": return main.world.task_queue.get_task(id)
		"stockpile": return main.world.stockpile_store.stockpiles.get(id)
		"resource": return id if not model.get_row(kind, id).is_empty() else null
	return null

func valid_selection() -> bool:
	if selection.is_empty() or int(selection.epoch) != model.epoch or main.loading_active:
		return false
	if main.world.get_instance_id() != _world_id or main.world.runtime_epoch != _world_epoch:
		return false
	if selection.kind == "cell":
		return true
	var actual = _actual_target(selection.kind, int(selection.id))
	if actual == null:
		return false
	if actual is Object:
		return is_instance_valid(_selection_object) and actual == _selection_object
	return is_same(actual, _selection_object)

func matches_selection_serial(serial: int) -> bool:
	return serial == _selection_serial and valid_selection()

func selection_action(action: Callable) -> Callable:
	var serial := _selection_serial
	return func():
		if matches_selection_serial(serial): action.call()

func _refresh_details() -> void:
	if selection.is_empty():
		return
	if not valid_selection():
		if _detail_signature != "missing":
			H.clear(detail_body)
			H.label(detail_body, "No longer available")
			_detail_signature = "missing"
		return
	var row: Dictionary = Model.cell_details(main.world, selection.pos,
		main.hud_controller.render_level_base_y) if selection.kind == "cell" \
		else model.get_row(_model_kind(selection.kind), int(selection.id))
	if row.is_empty():
		return
	# Do not rebuild editors or focused controls every activity refresh.
	panels.update_details(selection.kind, row)

func locate_selection() -> void:
	if not valid_selection():
		show_feedback("No longer available")
		return
	var row: Dictionary = selection if selection.kind == "cell" else model.get_row(_model_kind(selection.kind), int(selection.id))
	if not row.has("pos"):
		return
	var pos: Vector3 = Vector3(row.pos)
	if selection.kind in ["worker", "assignment"]:
		pos = _selection_object.position
	var target_y := clampi(int(round(pos.y)), 0, main.world.world_size_y - 1)
	var current: Vector3 = main.camera_controller.get_stream_target(float(target_y))
	main.camera.position += Vector3(pos.x - current.x, 0, pos.z - current.z)
	main.camera_controller._clamp_camera_to_world()
	main._handle_render_layer_change(target_y - main.world.top_render_y)

func cancel_selected_job() -> void:
	if not valid_selection() or selection.kind != "job":
		show_feedback("No longer available")
		return
	var removed: bool = main.world.task_manager.cancel_pending_task(int(selection.id), _selection_object)
	show_feedback("Pending task cancelled" if removed else "Task changed or is already active")

func set_selected_work_priority(work_id: String, priority: int) -> bool:
	if not valid_selection() or selection.kind != "assignment":
		show_feedback("No longer available")
		return false
	var ok: bool = main.world.set_worker_work_priority(int(selection.id), work_id, priority)
	show_feedback("Priority updated for the next job; current work is unchanged" if ok else "Priority unavailable")
	model.refresh_workers()
	return ok

func rename_selected_stockpile(value: String) -> bool:
	if not valid_selection() or selection.kind != "stockpile":
		show_feedback("No longer available")
		return false
	var ok: bool = main.world.stockpile_store.rename_stockpile(int(selection.id), value)
	show_feedback("Stockpile renamed" if ok else "Use a name of 1-64 characters without line breaks or control characters")
	return ok

func set_stockpile_category(category_id: String, allowed: bool) -> void:
	if valid_selection() and selection.kind == "stockpile":
		main.world.stockpile_store.set_category_allowed(int(selection.id), category_id, allowed)

func set_material_override(material_id: int, value: int) -> void:
	if not valid_selection() or selection.kind != "stockpile":
		return
	if value == 0:
		main.world.stockpile_store.clear_material_override(int(selection.id), material_id)
	else:
		main.world.stockpile_store.set_material_override(int(selection.id), material_id, value == 1)

func remove_selected_stockpile() -> void:
	if not valid_selection() or selection.kind != "stockpile":
		return
	var cells: Array[Vector3i] = []
	for cell: Vector3i in _selection_object.get("cells", []):
		cells.append(cell)
	main.world.remove_stockpile_cells(cells)
	show_feedback("Stockpile designation removed; items remain in the world")

func _start_filter() -> void:
	_filter_revision = model.revision
	if rows_box == null or not is_instance_valid(rows_box):
		return
	_filter_rows = model.list_rows(panels.kind_for(category))
	_filter_index = 0
	_filtered_work = []
	_filtering = true
	if pager != null:
		pager.text = "Updating..."

func _filter_pump() -> void:
	if not _filtering:
		return
	var started := Time.get_ticks_usec()
	var steps := 0
	while _filter_index < _filter_rows.size() and steps < 128 and Time.get_ticks_usec() - started < 1000:
		var row: Dictionary = _filter_rows[_filter_index]
		_filter_index += 1
		steps += 1
		if panels.row_matches(row, search_text, filter_text):
			_filtered_work.append(row)
	if _filter_index == _filter_rows.size():
		filtered = _filtered_work
		_filtering = false
		page = clampi(page, 0, maxi(0, (filtered.size() - 1) / PAGE_SIZE))
		panels.render_rows()

func change_page(delta: int) -> void:
	page = clampi(page + delta, 0, maxi(0, (filtered.size() - 1) / PAGE_SIZE))
	panels.render_rows()

func dispatch_feature(id: String) -> bool:
	var feature: Dictionary = Catalog.find_feature(id)
	if feature.is_empty() or str(feature.get("action", "")).is_empty() or feature.status in ["planned", "tentative"]:
		return false
	return dispatch_action(str(feature.action))

func dispatch_action(action: String) -> bool:
	if main.loading_active:
		return false
	if action.begins_with("open:"):
		toggle_category(action.trim_prefix("open:"))
	elif action.begins_with("tool:"):
		choose_tool(int(action.trim_prefix("tool:")))
	elif action == "level:up": change_level(1)
	elif action == "level:down": change_level(-1)
	elif action == "camera:left": main.camera_controller.rotate_view(-1, float(main.world.top_render_y))
	elif action == "camera:right": main.camera_controller.rotate_view(1, float(main.world.top_render_y))
	elif action == "game:menu": main.open_menu()
	elif action == "game:save":
		main.open_menu()
		main._on_save_pressed()
	elif action == "game:load":
		main.open_menu()
		main._on_load_pressed()
	elif action == "game:new": panels.confirm_new_world()
	elif action == "diagnostics:live": main.diagnostics_controller.set_enabled(not main.diagnostics_controller.service.enabled)
	elif action == "diagnostics:capture": main.diagnostics_controller.request_capture({})
	elif action == "diagnostics:performance":
		var event := InputEventKey.new()
		event.keycode = KEY_F12
		event.pressed = true
		main.performance_controller.handle_unhandled_input(event)
	elif action.begins_with("debug:"):
		var calls := {"profiler": "toggle_profiler", "burden": "toggle_draw_burden", "timings": "toggle_debug_timings", "streaming": "toggle_streaming_stats", "streaming_capture": "toggle_streaming_capture", "ramps": "dump_ramp_counts", "map": "export_map_snapshot", "timings_log": "toggle_debug_timings_log", "workers": "toggle_worker_trace"}
		var name := action.trim_prefix("debug:")
		if name == "normals": main.world.renderer.toggle_debug_normals()
		elif name == "render_panel": main._toggle_render_debug_panel()
		elif calls.has(name): main.debug_overlay.call(calls[name])
		else: return false
	else:
		return false
	return true

func keyboard_owned() -> bool:
	var focus: Control = main.get_viewport().gui_get_focus_owner()
	if focus is LineEdit or focus is TextEdit:
		return true
	for popup: Window in main.get_viewport().get_embedded_subwindows():
		if popup.visible and popup.popup_window:
			return true
	return false

func handle_escape(event: InputEvent) -> bool:
	if not event is InputEventKey or not event.pressed or event.echo or event.keycode != KEY_ESCAPE:
		return false
	for popup: Window in main.get_viewport().get_embedded_subwindows():
		if popup.visible and popup.popup_window:
			# Embedded windows normally dispatch their own input. This also
			# covers events delivered to the parent viewport by input tooling.
			popup.hide()
			if popup is AcceptDialog: popup.queue_free()
			return true
	return close_latest()

func watch_popup(popup: Window) -> void:
	var observer := PopupInput.new()
	observer.popup = popup
	observer.ui_ref = weakref(self)
	popup.add_child(observer)
	popup.visibility_changed.connect(main._sync_context_key_state)

func cancel_popups() -> void:
	jobs_popup.cancel_drag()
	if layout != null:
		layout.cancel_interaction()
	if main == null: return
	for popup: Window in main.get_viewport().get_embedded_subwindows():
		if popup.visible and popup.popup_window:
			popup.hide()
			if popup is AcceptDialog: popup.queue_free()

func pointer_owned() -> bool:
	return not _held_buttons.is_empty() or main.get_viewport().gui_get_hovered_control() != null \
		or (layout != null and layout.is_interacting())

func observe_input(event: InputEvent) -> bool:
	_release_event = 0
	if event is InputEventKey:
		if keyboard_owned() or (event.keycode == KEY_ESCAPE and not _panel_order.is_empty()):
			main.key_state[event.keycode] = event.pressed
			main.key_state[event.physical_keycode] = event.pressed
		return false
	if event is InputEventMouseButton:
		if event.pressed and _more_open():
			# Outside click closes More without consuming the event.
			var hovered: Control = main.get_viewport().gui_get_hovered_control()
			var in_more: bool = hovered != null and (hovered == navigation.more_button or hovered == navigation.more_panel or navigation.more_panel.is_ancestor_of(hovered))
			if not in_more:
				navigation.close_more()
		if event.pressed and main.get_viewport().gui_get_hovered_control() != null:
			if event.button_index in [MOUSE_BUTTON_LEFT, MOUSE_BUTTON_RIGHT, MOUSE_BUTTON_MIDDLE]:
				_held_buttons[event.button_index] = true
			return true
		if not event.pressed and _held_buttons.has(event.button_index):
			_held_buttons.erase(event.button_index)
			_release_event = event.get_instance_id()
			return true
	if event is InputEventMouseMotion and not _held_buttons.is_empty():
		return true
	return false

func handle_unhandled_input(event: InputEvent) -> bool:
	if event.get_instance_id() == _release_event or not _held_buttons.is_empty():
		return true
	if event is InputEventKey:
		if event.pressed and not event.echo and event.keycode == KEY_ESCAPE and close_latest():
			main._sync_context_key_state()
			return true
		if keyboard_owned():
			return true
	return false

func shutdown() -> void:
	jobs_popup.shutdown()
	model.clear()
	panels.ui = null
	command_bar.ui = null
	if navigation.category_selected.is_connected(toggle_category):
		navigation.category_selected.disconnect(toggle_category)
	main = null
