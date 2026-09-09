extends RefCounted
const H = preload("res://scripts/ui/colony_panel_helpers.gd")
const Catalog = preload("res://scripts/ui/colony_capability_catalog.gd")
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
var rows_signature := ""

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
		colony_text = H.label(parent, "Updating colony...")
		suggestion_button = H.button(parent, "Review available workers", _open_suggestion)
		update_colony(ui.model.snapshot())
	elif category == "world":
		H.label(parent, "Seed: %s\nWorld: %d x %d x %d blocks\nInformation [1] selects a cell snapshot." % [ui.main.world.world_seed, ui.main.world.world_size_x, ui.main.world.world_size_y, ui.main.world.world_size_z])
	elif category == "game":
		H.label(parent, "Saves restore terrain, items, stockpile names, roles and work priorities. Workers respawn and unfinished jobs reset. Save before starting or loading another world.")
	elif category == "defense":
		H.label(parent, "Combat is not implemented yet. Open Jobs and select a worker to enable hauling, mining or building.")
	elif category == "build":
		H.label(parent, "Place costs one stored iron ore per block, without delivery. Stairs currently consume no material. Erase cancels pending designations; it does not demolish terrain.")
	# All future entries remain discoverable inside their category, never on
	# the gameplay command bar. Focusable explanation labels accompany buttons.
	for feature: Dictionary in Catalog.entries(category):
		var unavailable: bool = feature.status in ["planned", "tentative"] or str(feature.action).is_empty()
		var card := VBoxContainer.new()
		parent.add_child(card)
		var button := H.button(card, str(feature.label), ui.dispatch_feature.bind(str(feature.id)))
		button.tooltip_text = str(feature.description)
		button.disabled = unavailable
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
			H.label(card, "Prototype: " + str(feature.description))

func _build_list(category: String, parent: VBoxContainer) -> void:
	ui.search = LineEdit.new()
	ui.search.placeholder_text = "Search workers" if category == "assignments" else "Search " + ui.title.text.to_lower()
	ui.search.custom_minimum_size.y = 36
	parent.add_child(ui.search)
	ui.watch_popup(ui.search.get_menu())
	ui.search.text_changed.connect(func(value: String):
		ui.search_text = value
		ui.page = 0
		ui._start_filter())
	ui.filter = OptionButton.new()
	ui.filter.custom_minimum_size.y = 36
	var options: Array = ["All"]
	if category in ["workers", "assignments"]: options.append_array(["Working", "Travelling", "Waiting", "Reserve", "Hauling", "Mining", "Building"])
	if category == "jobs": options.append_array(["Pending", "Assigned", "Blocked", "Dig", "Place", "Stairs", "Haul"])
	for value in options:
		ui.filter.add_item(value)
	parent.add_child(ui.filter)
	ui.watch_popup(ui.filter.get_popup())
	ui.filter.item_selected.connect(func(index: int):
		ui.filter_text = ui.filter.get_item_text(index)
		ui.page = 0
		ui._start_filter())
	var paging := HBoxContainer.new()
	parent.add_child(paging)
	H.button(paging, "Previous", ui.change_page.bind(-1))
	ui.pager = H.label(paging, "Updating...")
	H.button(paging, "Next", ui.change_page.bind(1))
	ui.rows_box = VBoxContainer.new()
	ui.rows_box.add_theme_constant_override("separation", 8)
	parent.add_child(ui.rows_box)
	if category == "resources":
		H.label(parent, "Stored is spendable. Loose and carried are not. Reserved overlaps these amounts; do not add it again.")

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
	if task_type >= 0 and task_type < 4:
		return ["dig", "place", "stairs", "haul"][task_type] == filter
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
		H.label(ui.rows_box, "Updating..." if ui.model.updating else "No matching entries")
	var kind: String = "assignment" if ui.category == "assignments" else kind_for(ui.category)
	for index in range(ui.page * 50, mini((ui.page + 1) * 50, total)):
		var row: Dictionary = ui.filtered[index]
		H.button(ui.rows_box, str(row.get("title", "%s %s" % [kind, row.id])), ui.toggle_row.bind(kind, int(row.id)))
		H.label(ui.rows_box, str(row.get("description", "")))

func update_colony(data: Dictionary) -> void:
	if not is_instance_valid(colony_text): return
	var c: Dictionary = data.get("counts", {})
	colony_text.text = "Updating..." if ui.model.updating else "%d workers\n%d working | %d travelling\n%d waiting | %d reserve\n\n%d pending jobs | %d blocked\n%d stored materials" % [int(c.get("workers", 0)), int(c.get("working", 0)), int(c.get("travelling", 0)), int(c.get("waiting", 0)), int(c.get("reserve", 0)), int(c.get("pending", 0)), int(c.get("blocked", 0)), int(c.get("stored", 0))]
	var suggestion := str(data.get("suggestion", ""))
	suggestion_button.visible = not suggestion.is_empty()
	var target_category: String = data.get("suggestion_category", "workers")
	suggestion_button.text = "Review " + ({"workers": "jobs", "jobs": "tasks"}.get(target_category, target_category))
	suggestion_button.tooltip_text = suggestion
	if not suggestion.is_empty():
		colony_text.text += "\n\n" + suggestion

func _open_suggestion() -> void:
	var data: Dictionary = ui.model.snapshot()
	var category: String = data.get("suggestion_category", "workers")
	if category == "workers": ui.open_assignments()
	else: ui.open_category(category)

func update_details(kind: String, row: Dictionary) -> void:
	var signature := "%s:%s" % [kind, row.get("id", -1)]
	if kind == "cell": signature += str(row.get("description", ""))
	if kind == "worker": signature += ":task=" + str(row.get("task_id", -1))
	if kind == "resource": signature += str(row.get("stockpile_ids", [])) + str(row.get("worker_ids", [])) + str(row.get("item_ids", []))
	if signature != ui._detail_signature:
		ui._detail_signature = signature
		H.clear(ui.detail_body)
		detail_text = H.label(ui.detail_body, "")
		priority_selectors = {}
		priority_editor = null
		assignment_hint = null
		stockpile_name = null
		cancel_job_button = null
		if row.has("pos"):
			H.button(ui.detail_body, "Locate", ui.selection_action(ui.locate_selection))
		if kind == "worker": _worker_controls(ui.detail_body, row)
		elif kind == "assignment": _assignment_controls(ui.detail_body, row)
		elif kind == "job": cancel_job_button = H.button(ui.detail_body, "Cancel pending task", ui.selection_action(ui.cancel_selected_job))
		elif kind == "stockpile": _stockpile_controls(ui.detail_body, row)
		elif kind == "resource": _resource_relationships(ui.detail_body, row)
	var description := str(row.get("description", ""))
	if kind == "cell":
		detail_text.text = "Cell snapshot\n" + description + "\nCaptured on selection; not a live terrain reading."
	else:
		detail_text.text = str(row.get("title", kind.capitalize())) + "\n" + description
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

func _worker_controls(parent: VBoxContainer, row: Dictionary) -> void:
	H.button(parent, "Open Jobs", ui.open_assignments.bind(int(row.id)))
	var task_id := int(row.get("task_id", -1))
	if task_id >= 0: H.button(parent, "Inspect assigned task", ui.toggle_row.bind("job", task_id))

func _assignment_controls(parent: VBoxContainer, row: Dictionary) -> void:
	H.label(parent, "Work priorities - Worker %d" % int(row.id))
	assignment_hint = H.label(parent, "")
	priority_editor = PriorityEditor.new()
	priority_editor.build(ui, parent)
	priority_selectors = priority_editor.selectors

func _stockpile_controls(parent: VBoxContainer, row: Dictionary) -> void:
	var serial: int = ui._selection_serial
	H.label(parent, "Stockpile name")
	stockpile_name = LineEdit.new()
	stockpile_name.max_length = 64
	stockpile_name.custom_minimum_size.y = 36
	stockpile_name.text = str(row.get("name", row.title))
	_observed_stockpile_name = stockpile_name.text
	parent.add_child(stockpile_name)
	ui.watch_popup(stockpile_name.get_menu())
	stockpile_name.text_submitted.connect(func(value: String):
		if ui.matches_selection_serial(serial): ui.rename_selected_stockpile(value))
	H.button(parent, "Rename", ui.selection_action(func(): ui.rename_selected_stockpile(stockpile_name.text)))
	H.label(parent, "Accepted categories")
	var stockpile: Dictionary = ui._selection_object
	for category: String in StockpileStore.CATEGORIES:
		var checkbox := CheckBox.new()
		checkbox.text = category.capitalize()
		checkbox.button_pressed = bool(stockpile.get("allowed_categories", {}).get(category, false))
		checkbox.toggled.connect(func(allowed: bool):
			if ui.matches_selection_serial(serial): ui.set_stockpile_category(category, allowed))
		parent.add_child(checkbox)
	H.label(parent, "Material overrides take precedence over categories.")
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
	H.button(parent, "Remove designation...", ui.selection_action(confirm_stockpile_removal))

func _resource_relationships(parent: VBoxContainer, row: Dictionary) -> void:
	H.label(parent, "Reserved is a subset of physical items. Only stored items can currently be used for placement.")
	for entry in row.get("stockpile_ids", []):
		var stockpile: Dictionary = ui.model.get_row("stockpile", int(entry))
		H.button(parent, str(stockpile.get("title", "Stockpile %d" % int(entry))), ui.toggle_row.bind("stockpile", int(entry)))
	for entry in row.get("worker_ids", []):
		H.button(parent, "Carrier %d" % int(entry), ui.toggle_row.bind("worker", int(entry)))
	if row.has("item_ids"):
		H.label(parent, "Item stacks: " + str(row.item_ids))
	if row.get("item_ids_truncated", false) or row.get("stockpile_ids_truncated", false) or row.get("worker_ids_truncated", false):
		H.label(parent, "Related records truncated to 32 per type.")

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
