extends RefCounted

const H = preload("res://scripts/ui/colony_panel_helpers.gd")

const PANEL_SIZE := Vector2(700.0, 720.0)
const EDGE_MARGIN := 16.0
const HUD_TOP := 56.0
const HUD_BOTTOM := 76.0

signal close_requested

var panel: PanelContainer
var body: VBoxContainer

var _root: Control
var _header: Control
var _dragging := false
var _drag_offset := Vector2.ZERO


func setup(parent: Control, theme: Theme) -> void:
	if not is_instance_valid(parent):
		return
	shutdown()

	_root = parent

	panel = PanelContainer.new()
	panel.name = "JobsWorkerPopup"
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
	H.label(_header, "Jobs")

	var owner_ref: WeakRef = weakref(self)
	H.button(_header, "Close", func() -> void:
		var owner = owner_ref.get_ref()
		if owner != null:
			owner.close_requested.emit()
	)
	_header.gui_input.connect(func(event: InputEvent) -> void:
		var owner = owner_ref.get_ref()
		if owner != null:
			owner._on_header_gui_input(event)
	)

	body = H.scroll(content)
	body.name = "Body"

	parent.resized.connect(func() -> void:
		var owner = owner_ref.get_ref()
		if owner != null:
			owner._on_parent_resized()
	)
	_clamp_panel()


func open() -> void:
	if not is_instance_valid(panel):
		return
	if panel.visible:
		return
	_stop_drag()
	_clamp_panel()
	_center_panel()
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


func _on_header_gui_input(event: InputEvent) -> void:
	if not is_visible():
		return
	if event is InputEventMouse:
		_root.get_viewport().set_input_as_handled()
	# GUI events carry header-local coordinates; avoid polled mouse state,
	# which can differ from the event during buffered/replayed input.
	var pointer := Vector2.ZERO
	if event is InputEventMouse:
		pointer = _root.get_global_transform().affine_inverse() * (_header.get_global_transform() * event.position)
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			_dragging = true
			_drag_offset = pointer - panel.position
		else:
			_stop_drag()
		return
	if event is InputEventMouseMotion and _dragging:
		panel.position = pointer - _drag_offset
		_clamp_panel_position()


func _on_parent_resized() -> void:
	_stop_drag()
	_clamp_panel()


func _stop_drag() -> void:
	_dragging = false
	_drag_offset = Vector2.ZERO


func _safe_rect() -> Rect2:
	if not is_instance_valid(_root):
		return Rect2()
	var viewport_size := _root.size
	var left := EDGE_MARGIN if viewport_size.x >= EDGE_MARGIN * 2.0 else 0.0
	var right := viewport_size.x - EDGE_MARGIN if viewport_size.x >= EDGE_MARGIN * 2.0 else viewport_size.x
	var has_hud_height := viewport_size.y >= HUD_TOP + HUD_BOTTOM + EDGE_MARGIN * 2.0
	var top := HUD_TOP + EDGE_MARGIN if has_hud_height else 0.0
	var bottom := viewport_size.y - HUD_BOTTOM - EDGE_MARGIN if has_hud_height else viewport_size.y
	return Rect2(left, top, maxf(right - left, 0.0), maxf(bottom - top, 0.0))


func _clamp_panel() -> void:
	if not is_instance_valid(panel):
		return
	var safe := _safe_rect()
	var current_position := panel.position
	panel.size = Vector2(minf(PANEL_SIZE.x, safe.size.x), minf(PANEL_SIZE.y, safe.size.y))
	panel.position = current_position
	_clamp_panel_position()


func _clamp_panel_position() -> void:
	if not is_instance_valid(panel):
		return
	var safe := _safe_rect()
	var max_position := safe.position + safe.size - panel.size
	panel.position = Vector2(
		clampf(panel.position.x, safe.position.x, max_position.x),
		clampf(panel.position.y, safe.position.y, max_position.y)
	)


func _center_panel() -> void:
	if not is_instance_valid(panel):
		return
	var safe := _safe_rect()
	panel.position = safe.position + (safe.size - panel.size) * 0.5
	_clamp_panel_position()
