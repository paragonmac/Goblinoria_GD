extends RefCounted
## Per-worker controls only. All writes retain the selected world's/entity's identity.
const H = preload("res://scripts/ui/colony_panel_helpers.gd")
const Work = preload("res://scripts/worker_work_priorities.gd")
const UITheme = preload("res://scripts/ui/colony_ui_theme.gd")

const WORK_ICONS := {
	"hauling": "stored",
	"mining": "dig",
	"building": "build",
	"crafting": "build",
	"gathering": "item",
	"farming": "resources",
	"combat": "reserve",
}

var ui_ref: WeakRef
var serial := -1
var selectors: Dictionary = {}
var checks: Dictionary = {}
var row_buttons: Dictionary = {}
var rows: Dictionary = {}
var order: Array[String] = []
var selected_work := ""
var priority_rows: VBoxContainer
var move_up: Button
var move_down: Button

func build(ui, parent: VBoxContainer) -> void:
	ui_ref = weakref(ui)
	serial = ui._selection_serial
	var columns := HBoxContainer.new()
	columns.add_theme_constant_override("separation", 20)
	parent.add_child(columns)
	var groups := VBoxContainer.new()
	groups.custom_minimum_size.x = 240
	groups.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	columns.add_child(groups)
	H.styled_label(groups, "Enabled work", "Subheading")
	var right := VBoxContainer.new()
	right.custom_minimum_size.x = 280
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	columns.add_child(right)
	H.styled_label(right, "Work type priority", "Subheading")
	priority_rows = VBoxContainer.new()
	right.add_child(priority_rows)
	var group_boxes: Dictionary = {}
	var button_group := ButtonGroup.new()
	for work: Dictionary in Work.entries():
		var group_name: String = work.group
		if not group_boxes.has(group_name):
			var group_box := VBoxContainer.new()
			groups.add_child(group_box)
			H.styled_label(group_box, group_name, "Subheading")
			group_boxes[group_name] = group_box
		var checkbox := CheckBox.new()
		checkbox.text = ""
		checkbox.custom_minimum_size.y = 36
		checkbox.disabled = not bool(work.implemented)
		checkbox.tooltip_text = str(work.description)
		group_boxes[group_name].add_child(checkbox)
		var check_content := HBoxContainer.new()
		check_content.mouse_filter = Control.MOUSE_FILTER_IGNORE
		check_content.add_theme_constant_override("separation", 6)
		check_content.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		check_content.offset_left = 30
		check_content.offset_right = -4
		checkbox.add_child(check_content)
		var work_icon: Control = H.Icon.make(str(WORK_ICONS.get(str(work.id), "worker")), 22)
		work_icon.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		check_content.add_child(work_icon)
		var work_label := Label.new()
		work_label.theme_type_variation = "Body"
		work_label.text = str(work.label)
		work_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		work_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		work_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		if checkbox.disabled:
			work_label.add_theme_color_override("font_color", UITheme.MUTED_TEXT)
		check_content.add_child(work_label)
		checks[work.id] = checkbox
		if not work.implemented:
			var unavailable := H.styled_label(group_boxes[group_name], "Not implemented yet", "Caption")
			unavailable.add_theme_color_override("font_color", UITheme.MUTED_TEXT)
			continue
		checkbox.toggled.connect(_toggle.bind(str(work.id)))
		var line := HBoxContainer.new()
		priority_rows.add_child(line)
		rows[work.id] = line
		var button := H.icon_row(line, str(WORK_ICONS.get(str(work.id), "worker")),
			str(work.label), _select.bind(str(work.id))) as Button
		button.toggle_mode = true
		button.button_group = button_group
		button.tooltip_text = str(work.description)
		row_buttons[work.id] = button
		var choice := OptionButton.new()
		choice.custom_minimum_size = Vector2(90, 36)
		choice.theme_type_variation = "Number"
		choice.add_item("Off", 0)
		for priority in range(1, 10): choice.add_item(str(priority), priority)
		choice.tooltip_text = str(work.description)
		line.add_child(choice)
		ui.watch_popup(choice.get_popup())
		selectors[work.id] = choice
		choice.item_selected.connect(_set_priority.bind(str(work.id)))
	var actions := HBoxContainer.new()
	right.add_child(actions)
	move_up = H.icon_button(actions, "up", "Move Up", _move.bind(-1), "IconButton", 22, Vector2(48, 36))
	move_down = H.icon_button(actions, "down", "Move Down", _move.bind(1), "IconButton", 22, Vector2(48, 36))
	move_up.get_meta("caption").hide()
	move_down.get_meta("caption").hide()
	move_up.tooltip_text = "Increase selected work's priority by one (toward 1). Other numbers stay unchanged."
	move_down.tooltip_text = "Decrease selected work's priority by one (toward 9). Other numbers stay unchanged."
	H.styled_label(right, "Select a work type, then move its priority up or down. Equal numbers share priority; their display order does not break ties. Enable work at priority 2.", "Caption")
	refresh()

func _owner():
	var ui = ui_ref.get_ref()
	return ui if ui != null and ui.matches_selection_serial(serial) else null

func _toggle(enabled: bool, work_id: String) -> void:
	_set_priority(2 if enabled else 0, work_id)

func _set_priority(value: int, work_id: String) -> void:
	var ui = _owner()
	if ui == null or not Work.is_available(work_id): return
	if ui.set_selected_work_priority(work_id, value):
		selected_work = work_id
		refresh()

func _select(work_id: String) -> void:
	if _owner() == null: return
	selected_work = work_id
	refresh()

func _move(direction: int) -> void:
	var ui = _owner()
	if ui == null or not Work.is_available(selected_work): return
	var priority: int = ui._selection_object.get_work_priority(selected_work)
	if priority == 0: return
	_set_priority(clampi(priority + direction, 1, 9), selected_work)

func refresh() -> void:
	var ui = _owner()
	if ui == null: return
	var values: Dictionary = ui._selection_object.get_work_configuration()
	var next_order: Array[String] = []
	var catalog_order: Dictionary = {}
	for work_id: String in selectors:
		var value := int(values.get(work_id, 0))
		selectors[work_id].select(value)
		checks[work_id].set_pressed_no_signal(value > 0)
		row_buttons[work_id].set_pressed_no_signal(work_id == selected_work)
		catalog_order[work_id] = next_order.size()
		next_order.append(work_id)
	# Stable catalog order for ties is visual only; gameplay still compares route cost.
	next_order.sort_custom(func(a: String, b: String):
		var av := int(values.get(a, 0))
		var bv := int(values.get(b, 0))
		if av == bv: return catalog_order[a] < catalog_order[b]
		return (10 if av == 0 else av) < (10 if bv == 0 else bv))
	if next_order != order:
		order = next_order
		for index in range(order.size()): priority_rows.move_child(rows[order[index]], index)
	var selected_value := int(values.get(selected_work, 0))
	H.set_disabled(move_up, selected_value <= 1)
	H.set_disabled(move_down, selected_value == 0 or selected_value >= 9)
