extends RefCounted

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
