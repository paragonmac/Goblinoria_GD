extends RefCounted
class_name ColonyNavigation
## Owns navigation only; Main owns pages, shell visibility, and action dispatch.

signal category_selected(id: String)

const Catalog = preload("res://scripts/ui/colony_capability_catalog.gd")
const UITheme = preload("res://scripts/ui/colony_ui_theme.gd")
const WIDTH := 176.0

var panel: PanelContainer
var scroll: ScrollContainer
var buttons: Dictionary = {}
var selected_id := "colony"


func setup(parent: Control) -> void:
	if not is_instance_valid(parent):
		return
	if is_instance_valid(panel):
		panel.get_parent().remove_child(panel)
		panel.queue_free()
	buttons.clear()
	panel = PanelContainer.new()
	panel.name = "ColonyNavigation"
	panel.theme = UITheme.build()
	parent.add_child(panel)
	panel.set_anchors_and_offsets_preset(Control.PRESET_LEFT_WIDE)
	panel.offset_top = 56.0
	panel.offset_bottom = -76.0
	panel.offset_right = WIDTH
	panel.mouse_filter = Control.MOUSE_FILTER_STOP
	scroll = ScrollContainer.new()
	scroll.name = "CategoryScroll"
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.mouse_filter = Control.MOUSE_FILTER_STOP
	scroll.follow_focus = true
	panel.add_child(scroll)
	var list := VBoxContainer.new()
	list.name = "Categories"
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(list)
	var group := ButtonGroup.new()
	for category: Dictionary in Catalog.categories():
		var id: String = category.id
		var button := Button.new()
		button.name = id.to_pascal_case()
		button.text = category.label
		button.tooltip_text = category.label
		button.custom_minimum_size.y = UITheme.CONTROL_HEIGHT
		button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		button.alignment = HORIZONTAL_ALIGNMENT_LEFT
		button.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		button.clip_text = true
		button.toggle_mode = true
		button.mouse_filter = Control.MOUSE_FILTER_STOP
		button.button_group = group
		button.pressed.connect(_on_category_pressed.bind(id))
		list.add_child(button)
		buttons[id] = button
	set_selected(selected_id)


func set_selected(id: String) -> void:
	# Main clears selection when the management panel closes.
	if not id.is_empty() and Catalog.categories().all(func(category: Dictionary) -> bool: return category.id != id):
		return
	selected_id = id
	for key: String in buttons:
		if is_instance_valid(buttons[key]):
			var button: Button = buttons[key]
			button.set_pressed_no_signal(key == id)
	if is_instance_valid(scroll) and buttons.has(id):
		# Layout must settle before scrolling a newly built list.
		scroll.ensure_control_visible.call_deferred(buttons[id])


func _on_category_pressed(id: String) -> void:
	set_selected(id)
	category_selected.emit(id)
