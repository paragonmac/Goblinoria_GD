extends RefCounted
const H = preload("res://scripts/ui/colony_panel_helpers.gd")
const Catalog = preload("res://scripts/ui/colony_capability_catalog.gd")
const UITheme = preload("res://scripts/ui/colony_ui_theme.gd")
const PriorityEditor = preload("res://scripts/ui/worker_priority_editor.gd")
var ui
var colony_text: Label
var suggestion_button: Button
var detail_text: Label
var priority_selectors: Dictionary = {}
var priority_editor
var assignment_hint: Label
var stockpile_name: LineEdit
var _observed_stockpile_name := ""
var cancel_job_button: Button
var _cell_title: Label
var colony_tiles: Dictionary = {}
var speed_buttons: Dictionary = {}
var _detail_title: Label
var rows_signature := ""
var sim_speed_label: Label
var worker_count_label: Label

func kind_for(category: String) -> String:
	return {"workers": "worker", "assignments": "worker", "jobs": "job", "stockpiles": "stockpile", "resources": "resource"}.get(category, "")

func build(category: String, parent: VBoxContainer) -> void:
	rows_signature = ""
	colony_text = null
	suggestion_button = null
	if not kind_for(category).is_empty():
		_build_list(category, parent)
		if category == "assignments": return
	elif category == "colony":
		var grid := GridContainer.new()
		grid.columns = 3
		grid.add_theme_constant_override("h_separation", 6)
		grid.add_theme_constant_override("v_separation", 6)
		parent.add_child(grid)
		colony_tiles = {}
		for entry: Array in [["workers", "workers", "Workers"], ["working", "busy", "Busy"], ["travelling", "moving", "Moving"],
				["waiting", "idle", "Idle"], ["reserve", "reserve", "Reserve"], ["pending", "pending", "Pending"],
				["blocked", "blocked", "Blocked"], ["stored", "stored", "Stored"]]:
			colony_tiles[entry[0]] = H.stat_tile(grid, entry[1], entry[2], UITheme.BAD if entry[0] == "blocked" else UITheme.BRASS_LIGHT)
		colony_text = H.styled_label(parent, "Updating colony...", "Body")
		suggestion_button = H.button(parent, "Review available workers", _open_suggestion)
		update_colony(ui.model.snapshot())
	elif category == "world":
		H.icon_row(parent, "world", "Seed %s" % ui.main.world.world_seed)
		H.icon_row(parent, "block", "%d x %d x %d blocks" % [ui.main.world.world_size_x, ui.main.world.world_size_y, ui.main.world.world_size_z])
		H.icon_row(parent, "inspect", "Inspect [1] shows any block and what is on it")
	elif category == "game":
		H.styled_label(parent, "Saves keep terrain, items, stockpiles, roles, priorities, worker positions, pending jobs and the camera. Jobs in progress restart.", "Caption")
		if OS.is_debug_build():
			_build_debug_controls(parent)
	elif category == "defense":
		H.styled_label(parent, "Combat is not implemented yet. Open Jobs and select a worker to enable hauling, mining or building.", "Caption")
	elif category == "build":
		H.styled_label(parent, "Build costs one stored iron ore per block, without delivery. Stairs cost nothing. Erase cancels pending designations; it does not demolish terrain.", "Caption")
	# All future entries remain discoverable inside their category, never on
	# the gameplay command bar. Available features are actions; planned and
	# tentative ones collapse into one "Coming later" section to cut clutter.
	var later: Array[Dictionary] = []
	for feature: Dictionary in Catalog.entries(category):
		var unavailable: bool = feature.status in ["planned", "tentative"] or str(feature.action).is_empty()
		if unavailable and feature.status != "partial":
			later.append(feature)
			continue
		_feature_card(parent, feature, unavailable)
	if not later.is_empty():
		var section := VBoxContainer.new()
		var toggle := H.button(parent, "Coming later (%d)" % later.size(), func(): section.visible = not section.visible)
		toggle.alignment = HORIZONTAL_ALIGNMENT_LEFT
		toggle.tooltip_text = "Planned features that are not implemented yet"
		parent.add_child(section)
		for feature: Dictionary in later:
			_feature_card(section, feature, true)
		section.hide()

func _feature_card(parent: VBoxContainer, feature: Dictionary, unavailable: bool) -> void:
		var card := VBoxContainer.new()
		card.add_theme_constant_override("separation", 2)
		parent.add_child(card)
		var button = H.icon_row(card, _feature_icon(feature), str(feature.label), ui.dispatch_feature.bind(str(feature.id)))
		button.tooltip_text = str(feature.description)
		H.set_disabled(button, unavailable)
		if unavailable:
			var status_text := "Not implemented yet" + (" - tentative design" if feature.status == "tentative" else "")
			if feature.status == "partial":
				status_text = "Prototype subset available. Further management not implemented yet.\n" + str(feature.description)
			var explanation := H.label(card, status_text)
			explanation.focus_mode = Control.FOCUS_ALL
			explanation.mouse_filter = Control.MOUSE_FILTER_STOP
			explanation.tooltip_text = str(feature.description)
			explanation.focus_entered.connect(ui.show_feedback.bind(str(feature.description)))
		elif feature.status == "partial":
			H.styled_label(card, "Prototype: " + str(feature.description), "Caption")

static func _feature_icon(feature: Dictionary) -> String:
	var action := str(feature.get("action", ""))
	if action.begins_with("tool:"):
		match int(action.trim_prefix("tool:")):
			World.PlayerMode.INFORMATION: return "inspect"
			World.PlayerMode.DIG: return "dig"
			World.PlayerMode.PLACE: return "build"
			World.PlayerMode.UP_STAIRS: return "stairs_up"
			World.PlayerMode.DOWN_STAIRS: return "stairs_down"
			World.PlayerMode.ERASE: return "erase"
			World.PlayerMode.STOCKPILE: return "stockpile"
			World.PlayerMode.TORCH: return "build"
			World.PlayerMode.CHOP: return "dig"
	if action.begins_with("open:"):
		return {"colony": "colony", "workers": "workers", "assignments": "jobs", "jobs": "tasks", "stockpiles": "stockpiles", "resources": "resources"}.get(action.trim_prefix("open:"), "more")
	if action.begins_with("game:") or action.begins_with("debug:") or action.begins_with("diagnostics:"):
		return "game"
	if action.begins_with("level:"):
		return "up" if action.ends_with("up") else "down"
	if action.begins_with("camera:"):
		return "rotate"
	return "more"

## Debug builds only: simulation speed and worker roster controls.
func _build_debug_controls(parent: VBoxContainer) -> void:
	H.styled_label(parent, "Debug", "Subheading")
	var speed_row := HBoxContainer.new()
	speed_row.add_theme_constant_override("separation", 6)
	parent.add_child(speed_row)
	speed_row.add_child(H.Icon.make("speed", 24))
	sim_speed_label = H.styled_label(speed_row, "", "Body")
	for speed in [1, World.MAX_SIM_SPEED]:
		var button := H.icon_button(speed_row, "speed" if speed > 1 else "right", "%dx" % speed, _set_sim_speed.bind(speed), "ToolButton", 18, Vector2(64, 52))
		button.toggle_mode = true
		speed_buttons[speed] = button
	var workers_row := HBoxContainer.new()
	workers_row.add_theme_constant_override("separation", 6)
	parent.add_child(workers_row)
	workers_row.add_child(H.Icon.make("workers", 24))
	worker_count_label = H.styled_label(workers_row, "", "Body")
	for delta in [-10, -1, 1, 10]:
		H.icon_button(workers_row, "minus" if delta < 0 else "plus", "%+d" % delta, _change_worker_count.bind(delta), "IconButton", 16, Vector2(52, 52))
	refresh_debug_controls()


func refresh_debug_controls() -> void:
	if is_instance_valid(sim_speed_label):
		sim_speed_label.text = "Speed %dx  (` toggles)" % ui.main.world.sim_speed
	for speed: int in speed_buttons:
		if is_instance_valid(speed_buttons[speed]):
			speed_buttons[speed].set_pressed_no_signal(speed == ui.main.world.sim_speed)
	if is_instance_valid(worker_count_label):
		worker_count_label.text = "Workers: %d" % ui.main.world.workers.size()


func _set_sim_speed(speed: int) -> void:
	ui.main.world.set_sim_speed(speed)
	refresh_debug_controls()


func _change_worker_count(delta: int) -> void:
	var world: World = ui.main.world
	var changed: int = world.add_workers(delta, _camera_focus_cell()) if delta > 0 else world.remove_workers(-delta)
	ui.show_feedback("%s %d worker%s." % ["Added" if delta > 0 else "Removed", changed, "" if changed == 1 else "s"])
	refresh_debug_controls()


## The cell under the screen center on the current render level, if any.
func _camera_focus_cell() -> Variant:
	var main = ui.main
	if main.camera_controller == null or main.get_viewport() == null:
		return null
	var center: Vector2 = main.get_viewport().get_visible_rect().size * 0.5
	var plane_y := float(main.world.top_render_y)
	var hit: Vector3 = main.camera_controller.raycast_to_plane(center, plane_y)
	return Vector3i(int(round(hit.x)), main.world.top_render_y, int(round(hit.z)))


func _build_list(category: String, parent: VBoxContainer) -> void:
	ui.search = H.search_field(parent, "Search workers" if category == "assignments" else "Search " + ui.title.text.to_lower())
	ui.watch_popup(ui.search.get_menu())
	ui.search.text_changed.connect(func(value: String):
		ui.search_text = value
		ui.page = 0
		ui._start_filter())
	ui.filter = OptionButton.new()
	ui.filter.custom_minimum_size.y = 40
	ui.filter.tooltip_text = "Filter"
	var options: Array = ["All"]
	if category in ["workers", "assignments"]: options.append_array(["Working", "Travelling", "Waiting", "Reserve", "Hauling", "Mining", "Building"])
	if category == "jobs": options.append_array(["Pending", "Assigned", "Blocked", "Dig", "Place", "Stairs", "Haul", "Torch", "Chop"])
	for value in options:
		ui.filter.add_item(value)
	parent.add_child(ui.filter)
	ui.watch_popup(ui.filter.get_popup())
	ui.filter.item_selected.connect(func(index: int):
		ui.filter_text = ui.filter.get_item_text(index)
		ui.page = 0
		ui._start_filter())
	ui.pager = H.pager(parent, ui.change_page.bind(-1), ui.change_page.bind(1))
	ui.pager.text = "Updating..."
	ui.rows_box = VBoxContainer.new()
	ui.rows_box.add_theme_constant_override("separation", 4)
	parent.add_child(ui.rows_box)
	if category == "resources":
		H.styled_label(parent, "Stored is spendable. Loose and carried are not. Reserved overlaps these amounts; do not add it again.", "Caption")

func row_matches(row: Dictionary, query: String, filter_value: String) -> bool:
	var searchable := str(row.get("title", "")) + " " + str(row.get("description", "")) + " " + str(row.get("id", ""))
	if not query.is_empty() and not searchable.to_lower().contains(query.to_lower()):
		return false
	var filter := filter_value.to_lower()
	if filter == "all": return true
	if row.get("activity", "") == filter: return true
	if row.get("kind", "") == "worker" and filter in ["hauling", "mining", "building"]:
		return int(row.get("work_priorities", {}).get(filter, 0)) > 0
	if filter == "pending": return bool(row.get("pending", false))
	if filter == "assigned": return int(row.get("status", -1)) == TaskQueue.TaskStatus.IN_PROGRESS
	if filter == "blocked": return int(row.get("accessibility", -1)) == TaskQueue.TaskAccessibility.UNREACHABLE
	var task_type := int(row.get("task_type", -1))
	if task_type >= 0 and task_type < 6:
		return ["dig", "place", "stairs", "haul", "torch", "chop"][task_type] == filter
	return false

func render_rows() -> void:
	if ui.rows_box == null or not is_instance_valid(ui.rows_box): return
	var total: int = ui.filtered.size()
	var signature := "%s:%d:%d" % [ui.category, ui.page, total]
	for index in range(ui.page * 50, mini((ui.page + 1) * 50, total)):
		var row: Dictionary = ui.filtered[index]
		signature += "|%s:%s:%s" % [row.id, row.get("title", ""), row.get("description", "")]
	ui.pager.text = "%d-%d / %d" % [mini(ui.page * 50 + 1, total), mini((ui.page + 1) * 50, total), total]
	if signature == rows_signature: return
	rows_signature = signature
	H.clear(ui.rows_box)
	if total == 0:
		H.styled_label(ui.rows_box, "Updating..." if ui.model.updating else "No matching entries", "Caption")
	var kind: String = "assignment" if ui.category == "assignments" else kind_for(ui.category)
	for index in range(ui.page * 50, mini((ui.page + 1) * 50, total)):
		var row: Dictionary = ui.filtered[index]
		var look := _row_look(row)
		H.list_row(ui.rows_box, look.icon, str(row.get("title", "%s %s" % [kind, row.id])), str(row.get("description", "")),
			ui.toggle_row.bind(kind, int(row.id)), look.color, look.badge, look.badge_color)


## Icon, tint and status tag for a list row, by row kind.
func _row_look(row: Dictionary) -> Dictionary:
	var look := {"icon": "more", "color": UITheme.BRASS_LIGHT, "badge": "", "badge_color": UITheme.WARM_TEXT}
	match str(row.get("kind", "")):
		"worker":
			var activity := str(row.get("activity", ""))
			look.icon = {"working": "busy", "travelling": "moving", "waiting": "idle", "reserve": "reserve"}.get(activity, "worker")
			look.color = UITheme.MUTED_TEXT if activity in ["waiting", "reserve"] else UITheme.BRASS_LIGHT
			look.badge = {"working": "Busy", "travelling": "Moving", "waiting": "Idle", "reserve": "Reserve"}.get(activity, "")
			look.badge_color = UITheme.GOOD if activity == "working" else (UITheme.MUTED_TEXT if activity in ["waiting", "reserve"] else UITheme.BRASS_LIGHT)
		"job":
			var task_type := int(row.get("task_type", -1))
			look.icon = ["dig", "build", "stairs", "stored"][task_type] if task_type >= 0 and task_type < 4 else "tasks"
			if int(row.get("accessibility", -1)) == TaskQueue.TaskAccessibility.UNREACHABLE:
				look.badge = "Blocked"
				look.badge_color = UITheme.BAD
				look.color = UITheme.BAD
			elif int(row.get("status", -1)) == TaskQueue.TaskStatus.IN_PROGRESS:
				look.badge = "Assigned"
				look.badge_color = UITheme.GOOD
			else:
				look.badge = "Pending"
				look.badge_color = UITheme.BRASS_LIGHT
		"stockpile":
			look.icon = "stockpile"
		"resource":
			look.icon = "block"
			var material := int(row.get("material_id", 0))
			if material > 0 and ui.main != null:
				look.color = ui.main.world.get_block_color(material).lightened(0.1)
	return look

func update_colony(data: Dictionary) -> void:
	if not is_instance_valid(colony_text): return
	var c: Dictionary = data.get("counts", {})
	for key: String in colony_tiles:
		if is_instance_valid(colony_tiles[key]):
			colony_tiles[key].text = str(int(c.get(key, 0)))
	colony_text.text = "Updating..." if ui.model.updating else ""
	var suggestion := str(data.get("suggestion", ""))
	suggestion_button.visible = not suggestion.is_empty()
	var target_category: String = data.get("suggestion_category", "workers")
	suggestion_button.text = "Review " + ({"workers": "jobs", "jobs": "tasks"}.get(target_category, target_category))
	suggestion_button.tooltip_text = suggestion
	if not suggestion.is_empty():
		colony_text.text = suggestion if colony_text.text.is_empty() else colony_text.text + "\n" + suggestion

func _open_suggestion() -> void:
	var data: Dictionary = ui.model.snapshot()
	var category: String = data.get("suggestion_category", "workers")
	if category == "workers": ui.open_assignments()
	else: ui.open_category(category)

func update_details(kind: String, row: Dictionary) -> void:
	var signature := "%s:%s" % [kind, row.get("id", -1)]
	if kind == "cell":
		signature += ":" + str(row.get("workers", [])) + str(row.get("items", [])) \
			+ str(row.get("stockpile", {})) + str(row.get("jobs", [])) + str(row.get("empty", false)) \
			+ str(row.get("diggable", false)) + str(row.get("protection_reason", ""))
	if kind == "worker": signature += ":task=" + str(row.get("task_id", -1))
	if kind == "resource": signature += str(row.get("stockpile_ids", [])) + str(row.get("worker_ids", [])) + str(row.get("item_ids", []))
	if signature != ui._detail_signature:
		ui._detail_signature = signature
		H.clear(ui.detail_body)
		if kind == "cell":
			_cell_header(ui.detail_body, row)
		else:
			_kind_header(ui.detail_body, kind, row)
		detail_text = H.styled_label(ui.detail_body, "", "Body")
		priority_selectors = {}
		priority_editor = null
		assignment_hint = null
		stockpile_name = null
		cancel_job_button = null
		if row.has("pos"):
			H.icon_row(ui.detail_body, "locate", "Locate", ui.selection_action(ui.locate_selection))
		if kind == "cell":
			H.styled_label(ui.detail_body, "On this block", "Subheading")
			if bool(row.get("empty", false)):
				H.styled_label(ui.detail_body, "Nothing on this block.", "Caption")
			else:
				_cell_group(ui.detail_body, row.get("workers", []), "worker", "worker")
				_cell_group(ui.detail_body, row.get("items", []), "resource", "item")
				var stockpile: Dictionary = row.get("stockpile", {})
				if not stockpile.is_empty():
					H.icon_row(ui.detail_body, "stockpile", str(stockpile.get("label", "Stockpile")),
						ui.select_row.bind("stockpile", int(stockpile.id)))
				_cell_group(ui.detail_body, row.get("jobs", []), "job", "")
		elif kind == "worker": _worker_controls(ui.detail_body, row)
		elif kind == "assignment": _assignment_controls(ui.detail_body, row)
		elif kind == "job": cancel_job_button = H.button(ui.detail_body, "Cancel pending task", ui.selection_action(ui.cancel_selected_job))
		elif kind == "stockpile": _stockpile_controls(ui.detail_body, row)
		elif kind == "resource": _resource_relationships(ui.detail_body, row)
	var description := str(row.get("description", ""))
	if kind == "cell":
		var pos: Vector3i = row.get("pos", Vector3i.ZERO)
		detail_text.text = "Level %d   (%d, %d, %d)" % [int(row.get("level", 0)), pos.x, pos.y, pos.z]
		detail_text.text += "\nLight S%d B%d%s" % [int(row.get("sky_light", 0)), int(row.get("block_light", 0)), " Explored" if bool(row.get("explored", false)) else ""]
		if bool(row.get("torch", false)):
			detail_text.text += "\nTorch"
		if not str(row.get("tree_text", "")).is_empty():
			detail_text.text += "\n" + str(row.tree_text)
		var protection_reason := str(row.get("protection_reason", ""))
		if not protection_reason.is_empty():
			detail_text.text += "\nProtected: " + protection_reason.replace("_", " ")
		if is_instance_valid(_cell_title):
			_cell_title.text = str(row.get("block_name", "Unknown block"))
	else:
		detail_text.text = description
		if is_instance_valid(_detail_title):
			_detail_title.text = str(row.get("title", kind.capitalize()))
		if row.has("pos"): detail_text.text += "\nPosition: " + str(row.pos)
		if kind == "job" and int(row.get("accessibility_updated_msec", 0)) > 0:
			detail_text.text += "\nLast accessibility evaluation: %.1f s ago" % (float(Time.get_ticks_msec() - int(row.accessibility_updated_msec)) / 1000.0)
		if kind == "job":
			detail_text.text += "\nAssigned worker: " + (str(row.assigned_worker_id) if int(row.get("assigned_worker_id", -1)) >= 0 else "None")
		if ui.model.updating:
			detail_text.text += "\nUpdating - showing last completed observation."
	if kind == "assignment":
		priority_editor.refresh()
		assignment_hint.text = "Current job finishes first. Changes apply to the next assignment." if ui._selection_object.current_task_id >= 0 else "1 before 2 before 3... Equal priorities use the cheapest reachable route. Off disables this work."
	if kind == "stockpile" and stockpile_name != null and not stockpile_name.has_focus():
		var observed: String = row.get("name", row.title)
		if stockpile_name.text == _observed_stockpile_name:
			stockpile_name.text = observed
		_observed_stockpile_name = observed
	if kind == "job" and cancel_job_button != null:
		cancel_job_button.disabled = ui._selection_object.status != TaskQueue.TaskStatus.PENDING
		cancel_job_button.tooltip_text = "Only pending tasks can be cancelled" if cancel_job_button.disabled else "Cancel only this task; release its hauling reservations."


func _cell_group(parent: VBoxContainer, entries: Array, kind: String, icon_name: String) -> void:
	for entry: Dictionary in entries:
		var label := str(entry.get("label", ""))
		H.icon_row(parent, icon_name if not icon_name.is_empty() else _job_icon(label), label,
			ui.select_row.bind(kind, int(entry.get("id", -1))))


static func _job_icon(label: String) -> String:
	for prefix: String in ["Dig", "Place", "Stairs", "Haul"]:
		if label.begins_with(prefix):
			return {"Dig": "dig", "Place": "build", "Stairs": "stairs", "Haul": "stored"}[prefix]
	return "tasks"


## Icon + title header for workers, jobs, stockpiles and materials.
func _kind_header(parent: VBoxContainer, kind: String, row: Dictionary) -> void:
	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 12)
	parent.add_child(header)
	var title := str(row.get("title", kind.capitalize()))
	var icon_name: String = {"worker": "worker", "assignment": "jobs", "stockpile": "stockpile", "resource": "resources"}.get(kind, "")
	if kind == "job":
		icon_name = _job_icon(title)
	header.add_child(H.Icon.make(icon_name if not icon_name.is_empty() else "more", 36))
	_detail_title = H.styled_label(header, title, "Heading")
	_detail_title.size_flags_vertical = Control.SIZE_SHRINK_CENTER


## Block icon tinted with the block colour, name, and property tags.
func _cell_header(parent: VBoxContainer, row: Dictionary) -> void:
	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 12)
	parent.add_child(header)
	var block_id := int(row.get("block_id", 0))
	var tint: Color = ui.main.world.get_block_color(block_id) if block_id > 0 else Color("6d6458")
	var icon = H.Icon.make("block", 48, tint.lightened(0.1))
	icon.accent_color = tint.darkened(0.35)
	header.add_child(icon)
	var stack := VBoxContainer.new()
	stack.add_theme_constant_override("separation", 4)
	stack.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(stack)
	_cell_title = H.styled_label(stack, str(row.get("block_name", "Unknown block")), "Heading")
	var tags := HFlowContainer.new()
	tags.add_theme_constant_override("h_separation", 6)
	tags.add_theme_constant_override("v_separation", 4)
	stack.add_child(tags)
	H.tag(tags, "Solid" if bool(row.get("solid", false)) else "Air")
	if bool(row.get("diggable", false)):
		H.tag(tags, "Diggable", UITheme.GOOD)
	elif bool(row.get("solid", false)):
		H.tag(tags, "Not diggable", UITheme.MUTED_TEXT)
	var shape := str(row.get("shape", "None"))
	if shape != "None":
		H.tag(tags, shape, UITheme.BRASS_LIGHT)

func _worker_controls(parent: VBoxContainer, row: Dictionary) -> void:
	H.icon_row(parent, "jobs", "Open Jobs", ui.open_assignments.bind(int(row.id)))
	var task_id := int(row.get("task_id", -1))
	if task_id >= 0: H.icon_row(parent, "tasks", "Inspect assigned task", ui.toggle_row.bind("job", task_id))

func _assignment_controls(parent: VBoxContainer, row: Dictionary) -> void:
	H.styled_label(parent, "Work priorities - Worker %d" % int(row.id), "Subheading")
	assignment_hint = H.styled_label(parent, "", "Caption")
	priority_editor = PriorityEditor.new()
	priority_editor.build(ui, parent)
	priority_selectors = priority_editor.selectors

func _stockpile_controls(parent: VBoxContainer, row: Dictionary) -> void:
	var serial: int = ui._selection_serial
	H.styled_label(parent, "Name", "Subheading")
	stockpile_name = LineEdit.new()
	stockpile_name.max_length = 64
	stockpile_name.custom_minimum_size.y = 36
	stockpile_name.text = str(row.get("name", row.title))
	_observed_stockpile_name = stockpile_name.text
	parent.add_child(stockpile_name)
	ui.watch_popup(stockpile_name.get_menu())
	stockpile_name.text_submitted.connect(func(value: String):
		if ui.matches_selection_serial(serial): ui.rename_selected_stockpile(value))
	H.icon_row(parent, "check", "Rename", ui.selection_action(func(): ui.rename_selected_stockpile(stockpile_name.text)))
	H.styled_label(parent, "Accepted categories", "Subheading")
	var stockpile: Dictionary = ui._selection_object
	for category: String in StockpileStore.CATEGORIES:
		var checkbox := CheckBox.new()
		checkbox.text = category.capitalize()
		checkbox.button_pressed = bool(stockpile.get("allowed_categories", {}).get(category, false))
		checkbox.toggled.connect(func(allowed: bool):
			if ui.matches_selection_serial(serial): ui.set_stockpile_category(category, allowed))
		parent.add_child(checkbox)
	H.styled_label(parent, "Material overrides", "Subheading")
	H.styled_label(parent, "Overrides take precedence over categories.", "Caption")
	var material := OptionButton.new()
	material.custom_minimum_size.y = 36
	material.clip_text = true
	for id in range(1, BlockRegistry.TABLE_SIZE):
		var material_name: String = ui.main.world.block_registry.names[id]
		if not material_name.is_empty(): material.add_item(material_name, id)
	parent.add_child(material)
	ui.watch_popup(material.get_popup())
	var override_choice := OptionButton.new()
	for option in ["Use category", "Allow", "Deny"]: override_choice.add_item(option)
	parent.add_child(override_choice)
	ui.watch_popup(override_choice.get_popup())
	var update_material := func(_index: int = 0):
		if not ui.matches_selection_serial(serial): return
		var id := material.get_selected_id()
		var overrides: Dictionary = ui._selection_object.get("material_overrides", {})
		override_choice.select(0 if not overrides.has(id) else (1 if bool(overrides[id]) else 2))
	material.item_selected.connect(update_material)
	update_material.call()
	override_choice.item_selected.connect(func(index: int):
		if ui.matches_selection_serial(serial): ui.set_material_override(material.get_selected_id(), index))
	H.icon_row(parent, "erase", "Remove designation...", ui.selection_action(confirm_stockpile_removal), UITheme.BAD)

func _resource_relationships(parent: VBoxContainer, row: Dictionary) -> void:
	H.styled_label(parent, "Reserved is a subset of physical items. Only stored items can be used for building.", "Caption")
	for entry in row.get("stockpile_ids", []):
		var stockpile: Dictionary = ui.model.get_row("stockpile", int(entry))
		H.icon_row(parent, "stockpile", str(stockpile.get("title", "Stockpile %d" % int(entry))), ui.toggle_row.bind("stockpile", int(entry)))
	for entry in row.get("worker_ids", []):
		H.icon_row(parent, "worker", "Carried by worker %d" % int(entry), ui.toggle_row.bind("worker", int(entry)))
	if row.has("item_ids"):
		H.styled_label(parent, "Item stacks: " + str(row.item_ids), "Caption")
	if row.get("item_ids_truncated", false) or row.get("stockpile_ids_truncated", false) or row.get("worker_ids_truncated", false):
		H.styled_label(parent, "Related records truncated to 32 per type.", "Caption")

func _confirm(message: String, action: Callable) -> void:
	var dialog := ConfirmationDialog.new()
	dialog.dialog_text = message
	dialog.title = "Confirm"
	dialog.theme = ui.root.theme
	dialog.confirmed.connect(action)
	dialog.confirmed.connect(dialog.queue_free)
	dialog.canceled.connect(dialog.queue_free)
	ui.root.add_child(dialog)
	ui.watch_popup(dialog)
	dialog.popup_centered(Vector2i(620, 200))

func confirm_stockpile_removal() -> void:
	_confirm("Remove this stockpile designation? Items remain but become loose and are no longer spendable storage.", ui.selection_action(ui.remove_selected_stockpile))

func confirm_new_world() -> void:
	_confirm("Start a new world? Unsaved progress will be replaced.", func():
		ui.main.open_menu()
		ui.main._start_new_world_with_loading())
