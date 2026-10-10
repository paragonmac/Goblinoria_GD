extends RefCounted

const Icon = preload("res://scripts/ui/ui_icon.gd")


## Icon-over-caption button (command bar tools, chips and panels). The button
## keeps its own text empty; children ignore the mouse so clicks reach it.
static func icon_button(parent: Node, icon_name: String, caption: String, action: Callable,
		variation: String = "PanelButton", icon_px: int = 26, min_size: Vector2 = Vector2(72, 72)) -> Button:
	var control := Button.new()
	control.theme_type_variation = variation
	control.custom_minimum_size = min_size
	control.tooltip_text = caption
	control.focus_mode = Control.FOCUS_NONE
	if action.is_valid():
		control.pressed.connect(action)
	parent.add_child(control)
	var stack := VBoxContainer.new()
	stack.mouse_filter = Control.MOUSE_FILTER_IGNORE
	stack.alignment = BoxContainer.ALIGNMENT_CENTER
	stack.add_theme_constant_override("separation", 2)
	control.add_child(stack)
	stack.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var icon: Control = Icon.make(icon_name, icon_px)
	icon.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	stack.add_child(icon)
	var text := Label.new()
	text.theme_type_variation = "Caption"
	text.text = caption
	text.mouse_filter = Control.MOUSE_FILTER_IGNORE
	text.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	text.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	stack.add_child(text)
	control.set_meta("icon", icon)
	control.set_meta("caption", text)
	return control


## Icon + text row inside a rounded "Row" panel; optional action makes it a button.
static func icon_row(parent: Node, icon_name: String, value: String, action: Callable = Callable(), icon_color: Color = Color("e7c48a")) -> Control:
	var holder: Control
	if action.is_valid():
		var row_button := Button.new()
		row_button.theme_type_variation = "IconButton"
		row_button.custom_minimum_size = Vector2(0, 40)
		row_button.focus_mode = Control.FOCUS_NONE
		row_button.tooltip_text = value
		row_button.pressed.connect(action)
		holder = row_button
	else:
		var panel := PanelContainer.new()
		panel.theme_type_variation = "Row"
		panel.custom_minimum_size = Vector2(0, 40)
		holder = panel
	holder.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	parent.add_child(holder)
	var line := HBoxContainer.new()
	line.mouse_filter = Control.MOUSE_FILTER_IGNORE
	line.add_theme_constant_override("separation", 10)
	holder.add_child(line)
	if holder is Button:
		line.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		line.offset_left = 10
		line.offset_right = -10
	var icon: Control = Icon.make(icon_name, 22, icon_color)
	icon.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	line.add_child(icon)
	var text := Label.new()
	text.theme_type_variation = "Body"
	text.text = value
	text.mouse_filter = Control.MOUSE_FILTER_IGNORE
	text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	text.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	text.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	line.add_child(text)
	return holder


## Disables a button and dims its content (icon_button and icon_row children).
static func set_disabled(button: Button, disabled: bool) -> void:
	button.disabled = disabled
	if button.get_child_count() == 0:
		return
	var content := button.get_child(0) as Control
	if content != null:
		content.modulate = Color(1, 1, 1, 0.45) if disabled else Color(1, 1, 1, 1)


## Small rounded tag ("Solid", "Diggable").
static func tag(parent: Node, value: String, color: Color = Color("eee3ce")) -> PanelContainer:
	var panel := PanelContainer.new()
	panel.theme_type_variation = "Tag"
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(panel)
	var text := Label.new()
	text.theme_type_variation = "Caption"
	text.text = value
	text.add_theme_color_override("font_color", color)
	panel.add_child(text)
	return panel


## Two-line list row: icon, title, one-line subtitle and an optional status tag.
## A single Button, so the whole row is one click target.
static func list_row(parent: Node, icon_name: String, title: String, subtitle: String, action: Callable,
		icon_color: Color = Color("e7c48a"), badge: String = "", badge_color: Color = Color("eee3ce")) -> Button:
	var row := Button.new()
	row.theme_type_variation = "IconButton"
	row.custom_minimum_size = Vector2(0, 58)
	row.focus_mode = Control.FOCUS_NONE
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.tooltip_text = title if subtitle.is_empty() else "%s\n%s" % [title, subtitle]
	if action.is_valid():
		row.pressed.connect(action)
	parent.add_child(row)
	var line := HBoxContainer.new()
	line.mouse_filter = Control.MOUSE_FILTER_IGNORE
	line.add_theme_constant_override("separation", 10)
	row.add_child(line)
	line.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	line.offset_left = 10
	line.offset_right = -10
	var icon: Control = Icon.make(icon_name, 28, icon_color)
	icon.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	line.add_child(icon)
	var stack := VBoxContainer.new()
	stack.mouse_filter = Control.MOUSE_FILTER_IGNORE
	stack.alignment = BoxContainer.ALIGNMENT_CENTER
	stack.add_theme_constant_override("separation", 0)
	stack.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	line.add_child(stack)
	for entry: Array in [[title, "Body"], [subtitle, "Caption"]]:
		if str(entry[0]).is_empty():
			continue
		var text := Label.new()
		text.theme_type_variation = entry[1]
		text.text = entry[0]
		text.mouse_filter = Control.MOUSE_FILTER_IGNORE
		text.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		text.clip_text = true
		stack.add_child(text)
	if not badge.is_empty():
		var tag_panel := tag(line, badge, badge_color)
		tag_panel.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	return row


## Previous/next icon buttons around a page label; returns the label.
static func pager(parent: Node, previous: Callable, next: Callable) -> Label:
	var paging := HBoxContainer.new()
	paging.add_theme_constant_override("separation", 8)
	parent.add_child(paging)
	var back := icon_button(paging, "left", "Previous page", previous, "IconButton", 18, Vector2(48, 40))
	back.get_meta("caption").hide()
	var text := Label.new()
	text.theme_type_variation = "Caption"
	text.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	text.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	paging.add_child(text)
	var forward := icon_button(paging, "right", "Next page", next, "IconButton", 18, Vector2(48, 40))
	forward.get_meta("caption").hide()
	return text


## Search field with a magnifier icon; returns the LineEdit.
static func search_field(parent: Node, placeholder: String) -> LineEdit:
	var holder := HBoxContainer.new()
	holder.add_theme_constant_override("separation", 8)
	parent.add_child(holder)
	var icon: Control = Icon.make("search", 22)
	icon.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	holder.add_child(icon)
	var field := LineEdit.new()
	field.placeholder_text = placeholder
	field.custom_minimum_size.y = 40
	field.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	field.clear_button_enabled = true
	holder.add_child(field)
	return field


## Icon + number + caption tile for overview grids; returns the number label.
static func stat_tile(parent: Node, icon_name: String, caption: String, icon_color: Color = Color("e7c48a")) -> Label:
	var panel := PanelContainer.new()
	panel.theme_type_variation = "Row"
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel.custom_minimum_size = Vector2(0, 76)
	parent.add_child(panel)
	var stack := VBoxContainer.new()
	stack.alignment = BoxContainer.ALIGNMENT_CENTER
	stack.add_theme_constant_override("separation", 0)
	panel.add_child(stack)
	var icon: Control = Icon.make(icon_name, 22, icon_color)
	icon.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	stack.add_child(icon)
	var number := Label.new()
	number.theme_type_variation = "Number"
	number.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	number.text = "0"
	stack.add_child(number)
	var text := Label.new()
	text.theme_type_variation = "Caption"
	text.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	text.text = caption
	stack.add_child(text)
	return number


static func styled_label(parent: Node, value: String, variation: String) -> Label:
	var control := label(parent, value)
	control.theme_type_variation = variation
	return control

static func label(parent: Node, value: String) -> Label:
	var control := Label.new()
	control.text = value
	control.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	control.mouse_filter = Control.MOUSE_FILTER_IGNORE
	control.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	parent.add_child(control)
	return control

static func button(parent: Node, value: String, action: Callable) -> Button:
	var control := Button.new()
	control.text = value
	control.custom_minimum_size.y = 36
	control.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	control.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	control.clip_text = true
	control.tooltip_text = value
	if action.is_valid():
		control.pressed.connect(action)
	parent.add_child(control)
	return control

static func clear(parent: Node) -> void:
	for child in parent.get_children():
		parent.remove_child(child)
		child.queue_free()

static func content(panel: Control) -> VBoxContainer:
	var margin := MarginContainer.new()
	for edge in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + edge, 12)
	panel.add_child(margin)
	var stack := VBoxContainer.new()
	stack.add_theme_constant_override("separation", 8)
	margin.add_child(stack)
	return stack

static func scroll(parent: Control) -> VBoxContainer:
	var scroller := ScrollContainer.new()
	scroller.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroller.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroller.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	parent.add_child(scroller)
	var stack := VBoxContainer.new()
	stack.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	stack.add_theme_constant_override("separation", 8)
	scroller.add_child(stack)
	return stack
