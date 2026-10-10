extends RefCounted

const H = preload("res://scripts/ui/colony_panel_helpers.gd")

const PANEL_SIZE := Vector2(700.0, 720.0)

signal close_requested

var panel: PanelContainer
var body: VBoxContainer

var _root: Control
var _header: Control
# Dragging, resizing and clamping belong to the colony UI WindowLayout; this
# flag remains only for callers that cancel gestures generically.
var _dragging := false


func setup(parent: Control, theme: Theme) -> void:
	if not is_instance_valid(parent):
		return
	shutdown()

	_root = parent

	panel = PanelContainer.new()
	panel.name = "JobsWorkerPopup"
	panel.theme_type_variation = "Card"
	panel.mouse_filter = Control.MOUSE_FILTER_STOP
	panel.visible = false
	if theme != null:
		panel.theme = theme
	_root.add_child(panel)

	var content := H.content(panel)
	_header = HBoxContainer.new()
	_header.name = "Header"
	_header.custom_minimum_size.y = 44.0
	_header.mouse_filter = Control.MOUSE_FILTER_STOP
	content.add_child(_header)
	var title_row := HBoxContainer.new()
	title_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	title_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_row.add_theme_constant_override("separation", 10)
	_header.add_child(title_row)
	var jobs_icon: Control = H.Icon.make("jobs", 26)
	jobs_icon.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	title_row.add_child(jobs_icon)
	var title := H.styled_label(title_row, "Jobs", "Heading")
	title.vertical_alignment = VERTICAL_ALIGNMENT_CENTER

	var owner_ref: WeakRef = weakref(self)
	var close_button := Button.new()
	close_button.theme_type_variation = "IconButton"
	close_button.custom_minimum_size = Vector2(40.0, 40.0)
	close_button.tooltip_text = "Close Jobs"
	close_button.accessibility_name = "Close Jobs"
	close_button.focus_mode = Control.FOCUS_NONE
	_header.add_child(close_button)
	var close_icon: Control = H.Icon.make("close", 22)
	close_icon.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	close_button.add_child(close_icon)
	close_button.pressed.connect(func() -> void:
		var owner = owner_ref.get_ref()
		if owner != null:
			owner.close_requested.emit()
	)

	body = H.scroll(content)
	body.name = "Body"

	# Position, size, dragging and clamping belong to the colony UI's WindowLayout.
	panel.size = PANEL_SIZE


func open() -> void:
	if not is_instance_valid(panel):
		return
	if panel.visible:
		return
	panel.show()


func hide() -> void:
	_stop_drag()
	if is_instance_valid(panel):
		panel.hide()


func cancel_drag() -> void:
	_stop_drag()


func is_visible() -> bool:
	return is_instance_valid(panel) and panel.visible


func shutdown() -> void:
	_stop_drag()
	if is_instance_valid(panel):
		var parent := panel.get_parent()
		if parent != null:
			parent.remove_child(panel)
		panel.queue_free()
	_root = null
	_header = null
	body = null
	panel = null


func _stop_drag() -> void:
	_dragging = false
