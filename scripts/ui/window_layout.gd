extends Node
class_name WindowLayout

signal layout_changed

var config_path := "user://ui_layout.cfg"
const LAYOUT_VERSION := 1
const GAP := 8.0
const DRAG_THRESHOLD := 6.0
const DOCK_EDGE_DISTANCE := 64.0

var _root: Control
var _area_provider: Callable
var _overlay: Control
var _windows: Dictionary = {}
var _orders := {"left": [], "right": []}
var _interaction := ""
var _active_id := ""
var _press_pos := Vector2.ZERO
var _pointer_offset := Vector2.ZERO
var _dragging := false
var _resize_edges := ""
var _start_rect := Rect2()
var _start_width := 0.0
var _highlight: Panel
var _handles: Dictionary = {}
# Validated saved entries by id, kept so windows registered after load() (created
# lazily, e.g. debug panels) still get their saved layout.
var _saved: Dictionary = {}
var _relayout_queued := false


func setup(root: Control, area_provider: Callable) -> void:
	_root = root
	_area_provider = area_provider
	if get_parent() != root:
		if get_parent() != null:
			get_parent().remove_child(self)
		_root.add_child(self)
	_overlay = Control.new()
	_overlay.name = "WindowLayoutOverlay"
	_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(_overlay)
	_highlight = Panel.new()
	_highlight.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_highlight.visible = false
	_highlight.modulate = Color(1, 1, 1, 0.35)
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.79, 0.63, 0.39, 0.35)
	style.border_color = Color(0.9, 0.72, 0.45, 0.95)
	style.set_border_width_all(2)
	_highlight.add_theme_stylebox_override("panel", style)
	_overlay.add_child(_highlight)
	_root.resized.connect(relayout)
	set_process_input(true)


func register(id: String, panel: Control, handle: Control, defaults: Dictionary) -> void:
	if not _windows.has(id):
		var dock: String = str(defaults.get("dock", "float"))
		var float_rect: Rect2 = defaults.get("float_rect", Rect2(panel.position, panel.size))
		var entry := {
			"panel": panel, "handle": handle, "dock": dock,
			"float_rect": float_rect, "dock_width": float(defaults.get("dock_width", float_rect.size.x)),
			"min_size": defaults.get("min_size", Vector2(160, 120)), "width_floor": 0.0,
			"default": {"dock": dock, "float_rect": float_rect,
				"dock_width": float(defaults.get("dock_width", float_rect.size.x))}
		}
		_windows[id] = entry
		if dock in ["left", "right"]:
			_orders[dock].append(id)
		if _saved.has(id):
			var saved: Dictionary = _saved[id]
			entry["dock"] = saved["dock"]
			entry["float_rect"] = saved["float_rect"]
			entry["dock_width"] = float(saved["dock_width"])
			_orders["left"].erase(id)
			_orders["right"].erase(id)
			if entry["dock"] in ["left", "right"]:
				_orders[entry["dock"]].append(id)
		panel.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
		panel.visibility_changed.connect(_on_visibility_changed)
		panel.minimum_size_changed.connect(_queue_relayout)
		handle.mouse_filter = Control.MOUSE_FILTER_STOP if handle.mouse_filter == Control.MOUSE_FILTER_IGNORE else handle.mouse_filter
		handle.gui_input.connect(_on_handle_input.bind(id))
		panel.gui_input.connect(_on_panel_input.bind(id))
		_add_handles(id)
		root_keep_overlay_last()
	relayout()


func set_width_floor(id: String, width: float) -> void:
	if not _windows.has(id): return
	# Draw-time only: stored dock_width/float_rect never include the floor.
	_windows[id]["width_floor"] = maxf(0.0, width)
	relayout()


func dock(id: String, side: String, index: int = -1) -> void:
	if not _windows.has(id) or not side in ["left", "right"]: return
	_remove_order(id)
	_windows[id]["dock"] = side
	var stack: Array = _orders[side]
	if index < 0 or index >= stack.size(): stack.append(id)
	else: stack.insert(index, id)
	_orders[side] = stack
	relayout()
	_commit()


func undock(id: String, rect: Rect2) -> void:
	if not _windows.has(id): return
	_remove_order(id)
	_windows[id]["dock"] = "float"
	_windows[id]["float_rect"] = _clamp_float(rect, _windows[id])
	relayout()
	_commit()


func get_state(id: String) -> Dictionary:
	if not _windows.has(id): return {}
	var entry: Dictionary = _windows[id]
	return {"dock": entry["dock"], "rect": _panel_rect(entry), "float_rect": entry["float_rect"], "dock_width": entry["dock_width"]}


func relayout() -> void:
	if _root == null or not is_instance_valid(_root): return
	for side in ["left", "right"]:
		_layout_stack(side)
	for id in _windows:
		var entry: Dictionary = _windows[id]
		if entry["dock"] == "float":
			var rect: Rect2 = _clamp_float(entry["float_rect"], entry)
			entry["float_rect"] = rect
			_apply_rect(entry, _floored_float(entry, rect))
		_update_handles(id)
	root_keep_overlay_last()


func reset() -> void:
	_orders = {"left": [], "right": []}
	_saved = {}
	for id in _windows:
		var entry: Dictionary = _windows[id]
		var defaults: Dictionary = entry["default"]
		entry["dock"] = defaults["dock"]
		entry["float_rect"] = defaults["float_rect"]
		entry["dock_width"] = defaults["dock_width"]
		if entry["dock"] in ["left", "right"]: _orders[entry["dock"]].append(id)
	relayout()
	_commit()



func save() -> void:
	if config_path.is_empty():
		return
	var config := ConfigFile.new()
	config.set_value("layout", "version", LAYOUT_VERSION)
	# Keep saved entries for windows not created this session (lazy debug panels).
	for id in _saved:
		if not _windows.has(id):
			config.set_value("windows", id, _saved[id])
	for id in _windows:
		var entry: Dictionary = _windows[id]
		var side: String = entry["dock"]
		var value := {"dock": side, "float_rect": entry["float_rect"],
			"dock_width": entry["dock_width"], "order": _orders[side].find(id) if side in ["left", "right"] else -1}
		config.set_value("windows", id, value)
		_saved[id] = value
	config.save(config_path)



func load() -> bool:
	if config_path.is_empty():
		return false
	var config := ConfigFile.new()
	if config.load(config_path) != OK or not config.has_section_key("layout", "version") or typeof(config.get_value("layout", "version")) != TYPE_INT or config.get_value("layout", "version") != LAYOUT_VERSION:
		return false
	var previous_orders: Dictionary = {"left": _orders["left"].duplicate(), "right": _orders["right"].duplicate()}
	var pending: Dictionary = {}
	_saved = {}
	var saved_ids: PackedStringArray = config.get_section_keys("windows") if config.has_section("windows") else PackedStringArray()
	for id in saved_ids:
		var value: Variant = config.get_value("windows", id)
		if typeof(value) != TYPE_DICTIONARY: continue
		if not value.has("dock") or typeof(value["dock"]) != TYPE_STRING: continue
		if not value.has("float_rect") or typeof(value["float_rect"]) != TYPE_RECT2: continue
		if not value.has("dock_width") or typeof(value["dock_width"]) not in [TYPE_FLOAT, TYPE_INT]: continue
		if value.has("order") and typeof(value["order"]) not in [TYPE_FLOAT, TYPE_INT]: continue
		if not value["dock"] in ["left", "right", "float"]: continue
		if not _finite_rect(value["float_rect"]) or not is_finite(float(value["dock_width"])) or float(value["dock_width"]) < 0: continue
		_saved[id] = value
		if _windows.has(id):
			pending[id] = value
	if pending.is_empty(): return not _saved.is_empty()
	for id in pending:
		var value: Dictionary = pending[id]
		var entry: Dictionary = _windows[id]
		entry["dock"] = value["dock"]
		entry["float_rect"] = value["float_rect"]
		entry["dock_width"] = float(value["dock_width"])
	_orders = {"left": [], "right": []}
	for id in _windows:
		var side: String = _windows[id]["dock"]
		if side in ["left", "right"]: _orders[side].append(id)
	for side in ["left", "right"]:
		_orders[side].sort_custom(func(a: String, b: String) -> bool:
			var a_saved: bool = pending.has(a)
			var b_saved: bool = pending.has(b)
			if a_saved != b_saved: return a_saved
			if a_saved:
				var a_order: int = int(pending[a].get("order", 9999))
				var b_order: int = int(pending[b].get("order", 9999))
				if a_order != b_order: return a_order < b_order
			var a_previous: int = previous_orders[side].find(a)
			var b_previous: int = previous_orders[side].find(b)
			if a_previous >= 0 and b_previous >= 0: return a_previous < b_previous
			return a < b)
		relayout()
	layout_changed.emit()
	return true


func is_interacting() -> bool:
	return _interaction != ""


## Ends any drag/resize without docking (focus loss, menus). A window being
## dragged stays floating where it is; the change is committed.
func cancel_interaction() -> void:
	if _interaction == "":
		return
	var committed := _dragging or _interaction == "resize"
	if _dragging and _windows.has(_active_id):
		_windows[_active_id]["dock"] = "float"
		_windows[_active_id]["float_rect"] = _panel_rect(_windows[_active_id])
	_interaction = ""
	_active_id = ""
	_dragging = false
	if _highlight != null:
		_highlight.visible = false
	relayout()
	if committed:
		_commit()


## True when the point (root-local) is over a resize handle of a visible window.
func is_over_handle(point: Vector2) -> bool:
	for id in _handles:
		var group: Control = _handles[id]["group"]
		if not group.visible:
			continue
		for item: Control in _handles[id]["items"]:
			if item.visible and Rect2(item.position, item.size).has_point(point):
				return true
	return false


func root_keep_overlay_last() -> void:
	if _root == null or not is_instance_valid(_root):
		return
	_sync_handle_order()
	if _overlay != null and is_instance_valid(_overlay) and _overlay.get_index() != _root.get_child_count() - 1:
		_root.move_child(_overlay, _root.get_child_count() - 1)


func _layout_stack(side: String) -> void:
	var band: Rect2 = _area_provider.call(side)
	var visible_ids: Array = []
	for id in _orders[side]:
		if _windows.has(id) and is_instance_valid(_windows[id]["panel"]) and _windows[id]["panel"].visible:
			visible_ids.append(id)
	if visible_ids.is_empty():
		return
	var available := maxf(0.0, band.size.y - GAP * (visible_ids.size() - 1))
	var mins := 0.0
	for id in visible_ids: mins += float(_windows[id]["min_size"].y)
	# Minimums first, then share the rest equally; if the minimums alone do not
	# fit, scale them down proportionally so the stack never leaves the band
	# (it would otherwise cover the command bar).
	var extra := (available - mins) / visible_ids.size() if mins <= available else 0.0
	var scale := 1.0 if mins <= available or mins <= 0.0 else available / mins
	var y := band.position.y
	for id in visible_ids:
		var entry: Dictionary = _windows[id]
		var height: float = float(entry["min_size"].y) * scale + extra
		var width := _draw_width(entry, clampf(float(entry["dock_width"]), float(entry["min_size"].x), band.size.x), band.size.x)
		var x := band.position.x if side == "left" else band.end.x - width
		_apply_rect(entry, Rect2(x, y, width, height))
		y += height + GAP



func _minimum(id: String) -> Vector2:
	return _windows[id]["min_size"]



func _clamp_float(rect: Rect2, entry: Dictionary) -> Rect2:
	var area: Rect2 = _area_provider.call("float")
	var minimum: Vector2 = entry["min_size"]
	var width := maxf(minimum.x, minf(rect.size.x, area.size.x))
	var height := maxf(minimum.y, minf(rect.size.y, area.size.y))
	var x := clampf(rect.position.x, area.position.x, maxf(area.position.x, area.end.x - width))
	var y := clampf(rect.position.y, area.position.y, maxf(area.position.y, area.end.y - height))
	return Rect2(x, y, width, height)


## Displayed width: the stored width raised to any temporary floor, within limit.
func _draw_width(entry: Dictionary, width: float, limit: float) -> float:
	return minf(maxf(width, float(entry["width_floor"])), maxf(limit, width))



func _minimum_for_entry(entry: Dictionary) -> Vector2:
	return entry["min_size"]



func _panel_rect(entry: Dictionary) -> Rect2:
	var panel: Control = entry["panel"]
	return Rect2(panel.position, panel.size)


## A floating rect widened to the width floor, kept inside the float area.
func _floored_float(entry: Dictionary, rect: Rect2) -> Rect2:
	var area: Rect2 = _area_provider.call("float")
	rect.size.x = _draw_width(entry, rect.size.x, area.size.x)
	rect.position.x = clampf(rect.position.x, area.position.x, maxf(area.position.x, area.end.x - rect.size.x))
	return rect



func _apply_rect(entry: Dictionary, rect: Rect2) -> void:
	var panel: Control = entry["panel"]
	if not is_instance_valid(panel): return
	panel.position = rect.position
	panel.size = Vector2.ZERO
	panel.size = rect.size


func _remove_order(id: String) -> void:
	for side in ["left", "right"]: _orders[side].erase(id)


func _commit() -> void:
	save()
	layout_changed.emit()


func _on_visibility_changed() -> void:
	if _interaction != "" and _windows.has(_active_id) and not _windows[_active_id]["panel"].visible:
		cancel_interaction()
		return
	relayout()


func _queue_relayout() -> void:
	if _relayout_queued:
		return
	_relayout_queued = true
	_deferred_relayout.call_deferred()


func _deferred_relayout() -> void:
	_relayout_queued = false
	# Interactions end with a relayout, so a skipped one is not lost.
	if _interaction == "":
		relayout()



func _add_handles(id: String) -> void:
	var group := Control.new()
	group.mouse_filter = Control.MOUSE_FILTER_IGNORE
	group.name = "Handles_" + id
	# Directly above its own panel (not in the shared overlay) so a window in
	# front also covers the resize handles of windows behind it.
	_root.add_child(group)
	var set: Array = []
	for edge in ["n", "s", "e", "w", "ne", "nw", "se", "sw"]:
		var handle := Control.new()
		handle.mouse_filter = Control.MOUSE_FILTER_STOP
		handle.mouse_default_cursor_shape = _cursor_for(edge)
		handle.gui_input.connect(_on_resize_input.bind(id, edge, handle))
		group.add_child(handle)
		set.append(handle)
	_handles[id] = {"group": group, "items": set}
	_sync_handle_order()


## Each handle group sits right after its panel in root, so stacking matches.
func _sync_handle_order() -> void:
	var ids: Array = _handles.keys()
	ids.sort_custom(func(a: String, b: String) -> bool:
		return _windows[a]["panel"].get_index() < _windows[b]["panel"].get_index())
	for id in ids:
		var panel: Control = _windows[id]["panel"]
		var group: Control = _handles[id]["group"]
		if not is_instance_valid(panel) or not is_instance_valid(group) or panel.get_parent() != _root:
			continue
		var target := panel.get_index() + 1
		if group.get_index() > target:
			_root.move_child(group, target)
		elif group.get_index() < target:
			_root.move_child(group, target - 1)



func _cursor_for(edge: String) -> Control.CursorShape:
	if edge in ["n", "s"]: return Control.CURSOR_VSIZE
	if edge in ["e", "w"]: return Control.CURSOR_HSIZE
	if edge in ["ne", "sw"]: return Control.CURSOR_BDIAGSIZE
	return Control.CURSOR_FDIAGSIZE


func _update_handles(id: String) -> void:
	if not _handles.has(id): return
	var entry: Dictionary = _windows[id]
	var group: Control = _handles[id]["group"]
	var panel: Control = entry["panel"]
	group.visible = panel.visible
	var rect := _panel_rect(entry)
	var items: Array = _handles[id]["items"]
	if entry["dock"] in ["left", "right"]:
		for i in range(items.size()): items[i].visible = false
		var idx := 2 if entry["dock"] == "left" else 3
		var h: Control = items[idx]
		h.visible = true
		h.position = rect.position + Vector2(rect.size.x - 3 if idx == 2 else -3, 0)
		h.size = Vector2(6, rect.size.y)
		return
	var positions := [Rect2(rect.position + Vector2(12, 0), Vector2(maxf(0, rect.size.x - 24), 6)),
		Rect2(rect.position + Vector2(12, rect.size.y - 6), Vector2(maxf(0, rect.size.x - 24), 6)),
		Rect2(rect.position + Vector2(rect.size.x - 6, 12), Vector2(6, maxf(0, rect.size.y - 24))),
		Rect2(rect.position + Vector2(0, 12), Vector2(6, maxf(0, rect.size.y - 24))),
		Rect2(rect.position + Vector2(rect.size.x - 12, 0), Vector2(12, 12)),
		Rect2(rect.position, Vector2(12, 12)),
		Rect2(rect.position + Vector2(rect.size.x - 12, rect.size.y - 12), Vector2(12, 12)),
		Rect2(rect.position + Vector2(0, rect.size.y - 12), Vector2(12, 12))]
	for i in range(items.size()):
		items[i].visible = true
		items[i].position = positions[i].position
		items[i].size = positions[i].size


## Presses arrive here in handle-local coordinates; motion and release are
## handled in _input (viewport canvas coordinates) so drags continue outside it.
func _on_handle_input(event: InputEvent, id: String) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		_interaction = "drag_pending"
		_active_id = id
		_press_pos = _local_to_root(_windows[id]["handle"], event.position)
		var r := _panel_rect(_windows[id])
		_pointer_offset = _press_pos - r.position
		_dragging = false
		_root.get_viewport().set_input_as_handled()


func _raise_floating_at(point: Vector2) -> void:
	# Walk root children front to back: the first managed visible window under
	# the pointer is the one the click will reach; raise it only if it floats.
	for index in range(_root.get_child_count() - 1, -1, -1):
		var child := _root.get_child(index)
		for id in _windows:
			var entry: Dictionary = _windows[id]
			if entry["panel"] != child:
				continue
			if not child.visible or not _panel_rect(entry).has_point(point):
				break
			if entry["dock"] == "float":
				child.move_to_front()
				root_keep_overlay_last()
			return



func _on_panel_input(event: InputEvent, id: String) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		var entry: Dictionary = _windows[id]
		if entry["dock"] == "float":
			entry["panel"].move_to_front()
			root_keep_overlay_last()


func _start_drag() -> void:
	var entry: Dictionary = _windows[_active_id]
	var old: Rect2 = _panel_rect(entry)
	if entry["dock"] != "float":
		_remove_order(_active_id)
		entry["dock"] = "float"
		old.size = entry["float_rect"].size
		_pointer_offset.x = clampf(_pointer_offset.x, 0, old.size.x)
		_pointer_offset.y = clampf(_pointer_offset.y, 0, 48)
		old.position = _press_pos - _pointer_offset
	entry["float_rect"] = _clamp_float(old, entry)
	_dragging = true
	_interaction = "drag"


func _move_drag(event: InputEvent) -> void:
	var entry: Dictionary = _windows[_active_id]
	var rect: Rect2 = entry["float_rect"]
	rect.position = _root_mouse_pos(event) - _pointer_offset
	entry["float_rect"] = _clamp_float(rect, entry)
	_apply_rect(entry, entry["float_rect"])
	_update_handles(_active_id)
	var side := _dock_candidate(_root_mouse_pos(event))
	_highlight.visible = side != ""
	if side != "":
		var band: Rect2 = _area_provider.call(side)
		_highlight.position = Vector2(band.position.x if side == "left" else band.end.x - minf(rect.size.x, band.size.x), band.position.y)
		_highlight.size = Vector2(minf(rect.size.x, band.size.x), band.size.y)


func _finish_drag(event: InputEvent) -> void:
	if _dragging:
		var side := _dock_candidate(_root_mouse_pos(event))
		if side != "":
			dock(_active_id, side, _index_for_y(side, _root_mouse_pos(event).y))
		else:
			var entry: Dictionary = _windows[_active_id]
			entry["dock"] = "float"
			# Position from the panel; size stays the stored (unfloored) size.
			var rect: Rect2 = entry["float_rect"]
			rect.position = _panel_rect(entry).position
			entry["float_rect"] = rect
			_commit()
	_interaction = ""
	_active_id = ""
	_dragging = false
	_highlight.visible = false
	relayout()



func _dock_candidate(point: Vector2) -> String:
	# Measured from the screen-side edges of the root, so a window flung against
	# the screen edge (past a band inset such as the depth gauge) still docks.
	for side in ["left", "right"]:
		var band: Rect2 = _area_provider.call(side)
		if point.y < band.position.y or point.y > band.end.y:
			continue
		if side == "left" and point.x <= band.position.x + DOCK_EDGE_DISTANCE:
			return side
		if side == "right" and point.x >= band.end.x - DOCK_EDGE_DISTANCE:
			return side
	return ""



func _index_for_y(side: String, y: float) -> int:
	var list: Array = _orders[side]
	for i in range(list.size()):
		var rect := _panel_rect(_windows[list[i]])
		if y < rect.position.y + rect.size.y * 0.5: return i
	return list.size()


func _on_resize_input(event: InputEvent, id: String, edge: String, handle: Control) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		_interaction = "resize"
		_active_id = id
		_resize_edges = edge
		_press_pos = _local_to_root(handle, event.position)
		_start_rect = _panel_rect(_windows[id])
		_start_width = float(_windows[id]["dock_width"])
		_root.get_viewport().set_input_as_handled()


func _input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed and _interaction == "":
		_raise_floating_at(_root_mouse_pos(event))
	if _interaction == "resize" and event is InputEventMouseMotion:
		_resize_motion(_root_mouse_pos(event) - _press_pos)
	elif _interaction == "resize" and event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and not event.pressed:
		_interaction = ""
		_active_id = ""
		relayout()
		_commit()
	elif _interaction.begins_with("drag") and event is InputEventMouseMotion:
		if not _dragging and _root_mouse_pos(event).distance_to(_press_pos) > DRAG_THRESHOLD: _start_drag()
		if _dragging: _move_drag(event)
	elif _interaction.begins_with("drag") and event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and not event.pressed:
		_finish_drag(event)


func _resize_motion(delta: Vector2) -> void:
	var entry: Dictionary = _windows[_active_id]
	if entry["dock"] in ["left", "right"]:
		var side: String = entry["dock"]
		var direction := 1.0 if side == "left" else -1.0
		var band: Rect2 = _area_provider.call(side)
		# Start from the stored width (not the floored display width) so a temporary
		# floor is never baked into the saved width.
		entry["dock_width"] = clampf(_start_width + delta.x * direction, float(entry["min_size"].x), band.size.x)
		relayout()
		return
	var rect := _start_rect
	if "e" in _resize_edges: rect.size.x += delta.x
	if "s" in _resize_edges: rect.size.y += delta.y
	if "w" in _resize_edges: rect.position.x += delta.x; rect.size.x -= delta.x
	if "n" in _resize_edges: rect.position.y += delta.y; rect.size.y -= delta.y
	var minimum: Vector2 = _minimum(_active_id)
	if rect.size.x < minimum.x:
		if "w" in _resize_edges: rect.position.x -= minimum.x - rect.size.x
		rect.size.x = minimum.x
	if rect.size.y < minimum.y:
		if "n" in _resize_edges: rect.position.y -= minimum.y - rect.size.y
		rect.size.y = minimum.y
	entry["float_rect"] = _clamp_float(rect, entry)
	_apply_rect(entry, entry["float_rect"])
	_update_handles(_active_id)


## Root-local point for an event seen in _input: event.position is already in
## viewport canvas coordinates there (window stretch applied), unlike
## global_position, which stays in window pixels.
func _root_mouse_pos(event: InputEvent = null) -> Vector2:
	var point := get_viewport().get_mouse_position()
	if event is InputEventMouse: point = event.position
	return _root.get_global_transform_with_canvas().affine_inverse() * point


func _local_to_root(control: Control, local: Vector2) -> Vector2:
	return _root.get_global_transform().affine_inverse() * (control.get_global_transform() * local)


func _finite_rect(rect: Rect2) -> bool:
	return is_finite(rect.position.x) and is_finite(rect.position.y) and is_finite(rect.size.x) and is_finite(rect.size.y) and rect.size.x > 0 and rect.size.y > 0