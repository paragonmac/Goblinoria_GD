extends RefCounted
class_name MainContextMenuController
## GUI-owned contextual actions and the world right-click/pan gesture.

signal input_barrier_changed
signal cell_inspected(block_id: int, pos: Vector3i)
signal action_feedback(message: String)
var external_inspector := false

const ToolCatalog = preload("res://scripts/main_tool_catalog.gd")
const UiIconAtlas = preload("res://scripts/ui/ui_icon_atlas.gd")
const PAN_THRESHOLD := 6.0
const RAYCAST_DISTANCE := 500.0
const ACTION_INSPECT := 100
const ACTION_CANCEL_TASKS := 101
const ACTION_REMOVE_STOCKPILE := 102
const ACTION_WORKERS := 103
const ACTION_REMOVE_STAIRS := 104

# Embedded windows receive their own input before the main viewport does.
class ContextPopup extends PopupMenu:
	var input_observer: Callable

	func _input(event: InputEvent) -> void:
		if input_observer.is_valid() and input_observer.call(event):
			set_input_as_handled()

var world: World
var camera: Camera3D
var viewport: Viewport
var input_state = preload("res://scripts/game_input_state.gd").new()
var selection: MainSelectionController
var camera_controller: MainCameraController
var workers: MainWorkerWindowController
var popup: PopupMenu
var snapshot_panel: PanelContainer
var snapshot_label: Label
var status_label: Label
var status_timer: Timer

var right_pending := false
var right_panning := false
var right_start := Vector2.ZERO
var released_right_event_id := 0
var _guard_buttons: Dictionary = {}
var _guard_keys: Dictionary = {}
var _close_barrier := false
var _barrier_serial := 0
var _last_event_id := 0
var _closed_event_id := 0
var _external_popup_event_id := 0
var _action_dispatched := false
var _hit: Dictionary = {}
var _pending_target: Dictionary = {}
var _stockpile_target: Dictionary = {}
var _stair_target: Dictionary = {}


func initialize(world_ref: World, camera_ref: Camera3D, viewport_ref: Viewport,
		hud_layer: CanvasLayer, selection_ref: MainSelectionController,
		camera_controller_ref: MainCameraController, workers_ref: MainWorkerWindowController) -> void:
	world = world_ref
	camera = camera_ref
	viewport = viewport_ref
	selection = selection_ref
	camera_controller = camera_controller_ref
	workers = workers_ref
	workers.popup_dismissed_by_right_click.connect(_on_other_popup_right_dismissed)
	# Force in-game windows even when the project defaults to native windows.
	viewport.gui_embed_subwindows = true
	var context_popup := ContextPopup.new()
	context_popup.name = "WorldContextMenu"
	context_popup.force_native = false
	context_popup.prefer_native_menu = false
	context_popup.input_observer = _observe_popup_input
	context_popup.add_theme_constant_override("icon_max_width", 20)
	popup = context_popup
	popup.id_pressed.connect(_on_action_selected)
	popup.popup_hide.connect(_on_popup_hidden)
	hud_layer.add_child(popup)
	_setup_snapshot(hud_layer)
	status_label = Label.new()
	status_label.name = "ContextStatus"
	status_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	status_label.position = Vector2(12, 52)
	status_label.hide()
	hud_layer.add_child(status_label)
	status_timer = Timer.new()
	status_timer.name = "ContextStatusTimer"
	status_timer.one_shot = true
	status_timer.wait_time = 3.0
	status_timer.timeout.connect(status_label.hide)
	hud_layer.add_child(status_timer)


func is_visible() -> bool:
	return is_instance_valid(popup) and popup.visible


func blocks_world_input() -> bool:
	return is_visible() or right_pending or _close_barrier \
		or not _guard_buttons.is_empty() or not _guard_keys.is_empty()


func observe_input(event: InputEvent) -> bool:
	_last_event_id = event.get_instance_id()
	released_right_event_id = 0
	if event is InputEventMouseButton:
		if _guard_buttons.has(event.button_index):
			if not event.pressed:
				_guard_buttons.erase(event.button_index)
				_hold_close_barrier()
			return true
	elif event is InputEventKey:
		var key := _event_key(event)
		if _guard_keys.has(key):
			if not event.pressed:
				_guard_keys.erase(key)
				_hold_close_barrier()
			return true

	# A world-owned right drag keeps its ownership across GUI boundaries. Main
	# skips its polled camera/selection updates while this gesture is pending.
	if right_pending and event is InputEventMouseMotion:
		if not right_panning and right_start.distance_to(event.position) >= PAN_THRESHOLD:
			right_panning = true
			camera_controller.begin_pan(right_start)
		if right_panning:
			camera_controller.update_pan(event.position)
		return true
	# End ownership before GUI dispatch. Only this exact unhandled release can
	# open the menu; a release consumed by a Control leaves no pending gesture.
	if right_pending and event is InputEventMouseButton \
			and event.button_index == MOUSE_BUTTON_RIGHT and not event.pressed:
		var was_panning := right_panning
		if not was_panning:
			released_right_event_id = event.get_instance_id()
		right_pending = false
		right_panning = false
		camera_controller.end_pan()
		input_barrier_changed.emit()
		return was_panning

	if is_visible():
		if event is InputEventKey:
			return _handle_menu_key(event)
		if event is InputEventMouseButton and event.pressed \
				and not Rect2(Vector2(popup.position), Vector2(popup.size)).has_point(event.position):
			if _is_held_button(event.button_index):
				_guard_buttons[event.button_index] = true
			popup.hide()
			return true
		# Mouse clicks inside the popup must reach its normal GUI selection path.
		return false
	if blocks_world_input():
		# F1 bug capture must work mid-gesture (e.g. while right-drag panning).
		if event is InputEventKey and _event_key(event) == KEY_F1:
			return false
		if event is InputEventMouseButton and event.pressed and _is_held_button(event.button_index):
			_guard_buttons[event.button_index] = true
		return true
	if event is InputEventMouseButton and event.pressed and _other_popup_visible():
		_external_popup_event_id = event.get_instance_id()
		# Leave native dropdown item/dismissal handling untouched, but prevent the
		# same press from acquiring world ownership if the popup hides during GUI.
		if event.button_index == MOUSE_BUTTON_RIGHT:
			_guard_buttons[MOUSE_BUTTON_RIGHT] = true
			input_barrier_changed.emit()
		return false

	return false


func handle_unhandled_input(event: InputEvent) -> bool:
	if blocks_world_input() or event.get_instance_id() == _closed_event_id \
			or event.get_instance_id() == _external_popup_event_id:
		return true
	if not event is InputEventMouseButton or event.button_index != MOUSE_BUTTON_RIGHT:
		return false
	# SEE-ADR-006: GUI-origin gestures never acquire world selection ownership.
	if viewport.gui_get_hovered_control() != null or _other_popup_visible():
		right_pending = false
		right_panning = false
		released_right_event_id = 0
		camera_controller.end_pan()
		return false
	if event.pressed:
		if selection.is_dragging:
			selection.cancel_drag_and_clear_preview()
			_guard_buttons = _pressed_mouse_buttons()
			_guard_buttons[MOUSE_BUTTON_RIGHT] = true
			input_barrier_changed.emit()
			return true
		right_pending = true
		right_panning = false
		right_start = event.position
		input_barrier_changed.emit()
		return true
	if released_right_event_id == event.get_instance_id():
		released_right_event_id = 0
		if right_start.distance_to(event.position) >= PAN_THRESHOLD:
			camera_controller.begin_pan(right_start)
			camera_controller.update_pan(event.position)
			camera_controller.end_pan()
			return true
		open_at(event.position)
		return true
	return false


func cancel(clear_snapshot: bool = false) -> void:
	right_pending = false
	right_panning = false
	released_right_event_id = 0
	if camera_controller != null:
		camera_controller.end_pan()
	if is_visible():
		popup.hide()
	_guard_buttons.clear()
	_guard_keys.clear()
	_hit.clear()
	_pending_target.clear()
	_stockpile_target.clear()
	_stair_target.clear()
	_action_dispatched = true
	if clear_snapshot:
		if is_instance_valid(snapshot_panel):
			snapshot_panel.hide()
		if is_instance_valid(status_label):
			status_label.hide()
	_hold_close_barrier()


func open_at(screen_pos: Vector2) -> void:
	if world == null or camera == null or not is_instance_valid(popup):
		return
	right_pending = false
	right_panning = false
	released_right_event_id = 0
	camera_controller.end_pan()
	selection.cancel_drag_and_clear_preview()
	_capture_targets(screen_pos)
	_action_dispatched = false
	_rebuild_menu()
	var available := Vector2i(viewport.get_visible_rect().size)
	popup.max_size = Vector2i(maxi(available.x, 1), maxi(available.y, 1))
	popup.size = Vector2i.ZERO
	popup.popup()
	var popup_size := Vector2i(mini(popup.size.x, available.x), mini(popup.size.y, available.y))
	popup.size = popup_size
	popup.position = Vector2i(
		clampi(int(screen_pos.x) + 2, 0, maxi(available.x - popup.size.x, 0)),
		clampi(int(screen_pos.y) + 2, 0, maxi(available.y - popup.size.y, 0)))
	input_barrier_changed.emit()


func _observe_popup_input(event: InputEvent) -> bool:
	# Popup window events are local; observation uses parent viewport positions.
	var translated := event
	if event is InputEventMouse:
		translated = event.duplicate()
		translated.position = event.position + Vector2(popup.position)
	return observe_input(translated)


func _event_key(event: InputEventKey) -> int:
	return event.keycode if event.keycode != 0 else event.physical_keycode


func _is_held_button(button: int) -> bool:
	return button in [MOUSE_BUTTON_LEFT, MOUSE_BUTTON_RIGHT, MOUSE_BUTTON_MIDDLE,
		MOUSE_BUTTON_XBUTTON1, MOUSE_BUTTON_XBUTTON2]


func _pressed_mouse_buttons() -> Dictionary:
	var result: Dictionary = {}
	for button in [MOUSE_BUTTON_LEFT, MOUSE_BUTTON_RIGHT, MOUSE_BUTTON_MIDDLE,
			MOUSE_BUTTON_XBUTTON1, MOUSE_BUTTON_XBUTTON2]:
		if input_state.is_mouse_button_pressed(button):
			result[button] = true
	return result


func _handle_menu_key(event: InputEventKey) -> bool:
	var key := _event_key(event)
	if key == KEY_ESCAPE or key == KEY_W or _tool_for_key(key) >= 0:
		if event.pressed and not event.echo:
			_guard_keys[key] = true
			if key == KEY_ESCAPE:
				popup.hide()
			elif key == KEY_W:
				_on_action_selected(ACTION_WORKERS)
			else:
				_on_action_selected(_tool_for_key(key))
		return true
	# Let PopupMenu handle arrows, Enter, and native keyboard navigation.
	return false


func _tool_for_key(key: int) -> int:
	for tool: Dictionary in ToolCatalog.TOOLS:
		if int(tool.key) == key:
			return int(tool.mode)
	return -1


func _other_popup_visible() -> bool:
	for window: Window in viewport.get_embedded_subwindows():
		if window != popup and window.visible and window.popup_window:
			return true
	return false


func _on_other_popup_right_dismissed() -> void:
	right_pending = false
	right_panning = false
	released_right_event_id = 0
	camera_controller.end_pan()
	_guard_buttons[MOUSE_BUTTON_RIGHT] = true
	_hold_close_barrier()


func _on_popup_hidden() -> void:
	_closed_event_id = _last_event_id
	# Releases can go to another embedded window, bypassing Main entirely.
	# Sample global button state here rather than retaining stale local presses.
	for button in _pressed_mouse_buttons():
		_guard_buttons[button] = true
	_hold_close_barrier()


func _hold_close_barrier() -> void:
	_close_barrier = true
	_barrier_serial += 1
	_release_close_barrier.call_deferred(_barrier_serial)
	input_barrier_changed.emit()


func _release_close_barrier(serial: int) -> void:
	if serial != _barrier_serial:
		return
	_close_barrier = false
	if not is_visible():
		_action_dispatched = true
	input_barrier_changed.emit()


func _rebuild_menu() -> void:
	popup.clear()
	popup.add_separator("Tools")
	for tool: Dictionary in ToolCatalog.TOOLS:
		popup.add_check_item("%s [%s]" % [tool.label, OS.get_keycode_string(tool.key)], int(tool.mode))
		var tool_icon := "inspect"
		match int(tool.mode):
			World.PlayerMode.DIG: tool_icon = "dig"
			World.PlayerMode.PLACE: tool_icon = "build"
			World.PlayerMode.UP_STAIRS: tool_icon = "stairs_up"
			World.PlayerMode.DOWN_STAIRS: tool_icon = "stairs_down"
			World.PlayerMode.ERASE: tool_icon = "erase"
			World.PlayerMode.STOCKPILE: tool_icon = "stockpile"
		popup.set_item_icon(popup.item_count - 1, UiIconAtlas.texture(tool_icon))
		popup.set_item_checked(popup.item_count - 1, tool.mode == world.player_mode)
	popup.add_separator("This location")
	# Fog of war: unexplored hits expose no cell information or cell actions.
	var hit_unexplored := not _hit.is_empty() and not _is_explored(_hit["pos"])
	_add_context_item("Inspect clicked cell", ACTION_INSPECT, not _hit.is_empty() and not hit_unexplored, "Unexplored" if hit_unexplored else "No visible loaded block here.", "inspect")
	_add_context_item("Cancel pending tasks", ACTION_CANCEL_TASKS, not _pending_target.is_empty() and not hit_unexplored, "Unexplored" if hit_unexplored else "No pending tasks at this location.", "erase")
	_add_context_item("Remove stockpile designation", ACTION_REMOVE_STOCKPILE, not _stockpile_target.is_empty() and not hit_unexplored, "Unexplored" if hit_unexplored else "No stockpile designation at this location.", "stockpile")
	_add_context_item("Remove stairs", ACTION_REMOVE_STAIRS, not _stair_target.is_empty() and not hit_unexplored, "Unexplored" if hit_unexplored else "No player stairs at this location.", "stairs")
	popup.add_separator("Colony")
	popup.add_item("Open Workers [W]", ACTION_WORKERS)
	popup.set_item_icon(popup.item_count - 1, UiIconAtlas.texture("workers"))


func _add_context_item(label: String, id: int, available: bool, reason: String, icon_name: String) -> void:
	popup.add_item(label, id)
	var index := popup.item_count - 1
	popup.set_item_icon(index, UiIconAtlas.texture(icon_name))
	popup.set_item_disabled(index, not available)
	if not available:
		popup.set_item_tooltip(index, reason)


func _capture_targets(screen_pos: Vector2) -> void:
	_hit.clear()
	_pending_target.clear()
	_stockpile_target.clear()
	_stair_target.clear()
	var hit := world.raycast_block(camera.project_ray_origin(screen_pos),
		camera.project_ray_normal(screen_pos), RAYCAST_DISTANCE, false)
	if not hit.get("hit", false):
		return
	var pos: Vector3i = hit.pos
	_hit = _capture_cell(pos)
	# SEE-ADR-006: Stair removal uses the visible hit, then the cell above it,
	# matching other destructive context actions without screen-space retargeting.
	for candidate: Vector3i in [pos, pos + Vector3i.UP]:
		if _stair_target.is_empty():
			var spec := _get_stair_removal_spec(candidate)
			if not spec.is_empty():
				_stair_target = _capture_stair_target(candidate, spec)
	# SEE-ADR-006: Destructive tools prefer the hit, then the cell above it.
	for candidate: Vector3i in [pos, pos + Vector3i.UP]:
		if not world.is_block_coord_valid(candidate.x, candidate.y, candidate.z):
			continue
		if _pending_target.is_empty() and world.has_pending_task_request_at(candidate):
			_pending_target = _capture_cell(candidate)
			_pending_target["tasks"] = _pending_tasks_at(candidate)
		if _stockpile_target.is_empty() and world.is_stockpile_cell(candidate):
			_stockpile_target = _capture_cell(candidate)
			_stockpile_target["stockpile_id"] = world.stockpile_store.stockpile_at(candidate)


func _is_explored(pos: Vector3i) -> bool:
	if world == null or world.light_field == null or not world.light_field_built:
		return true
	return world.light_field.is_explored(pos.x, pos.y, pos.z)


func _capture_cell(pos: Vector3i) -> Dictionary:
	var chunk = world.get_chunk(world.world_to_chunk_coords(pos.x, pos.y, pos.z))
	return {
		"pos": pos,
		"block_id": world.get_block_no_generate(pos.x, pos.y, pos.z),
		"chunk_id": chunk.get_instance_id() if chunk != null else 0,
	}


func _cell_unchanged(captured: Dictionary) -> bool:
	if captured.is_empty():
		return false
	var pos: Vector3i = captured.pos
	var current := _capture_cell(pos)
	return current.block_id == captured.block_id and current.chunk_id == captured.chunk_id


func _get_stair_removal_spec(pos: Vector3i) -> Dictionary:
	if world == null:
		return {}
	return world.get_stair_removal_spec(pos)


func _capture_stair_target(request_pos: Vector3i, spec: Dictionary) -> Dictionary:
	var footprint: Array = spec.get("footprint", [])
	if footprint.is_empty():
		return {}
	var cells: Array = []
	for raw_pos in footprint:
		if not raw_pos is Vector3i:
			return {}
		cells.append(_capture_cell(raw_pos))
	return {
		"request_pos": request_pos,
		"anchor": spec.get("anchor", request_pos),
		"footprint": footprint.duplicate(),
		"materials": (spec.get("materials", []) as Array).duplicate(),
		"rotation": int(spec.get("rotation", -1)),
		"cells": cells,
	}


func _stair_target_unchanged() -> bool:
	if _stair_target.is_empty():
		return false
	var current_spec := _get_stair_removal_spec(_stair_target.request_pos)
	if current_spec.is_empty():
		return false
	if current_spec.get("anchor", null) != _stair_target.anchor \
			or current_spec.get("footprint", []) != _stair_target.footprint \
			or current_spec.get("materials", []) != _stair_target.materials \
			or int(current_spec.get("rotation", -1)) != int(_stair_target.rotation):
		return false
	var current_target := _capture_stair_target(_stair_target.request_pos, current_spec)
	if current_target.is_empty() or current_target.cells.size() != _stair_target.cells.size():
		return false
	for index in range(_stair_target.cells.size()):
		var captured: Dictionary = _stair_target.cells[index]
		var current: Dictionary = current_target.cells[index]
		if current.pos != captured.pos or current.block_id != captured.block_id \
				or current.chunk_id != captured.chunk_id:
			return false
	return true


func _pending_tasks_at(pos: Vector3i) -> Array:
	var result: Array = []
	if world.task_queue == null:
		return result
	for task in world.task_queue.get_active_tasks_at(pos):
		if task.status == TaskQueue.TaskStatus.PENDING:
			# Instance identity also prevents an ID reused after queue replacement.
			result.append(task)
	return result


func _on_action_selected(id: int) -> void:
	if _action_dispatched:
		return
	var item_index := popup.get_item_index(id)
	if item_index < 0 or popup.is_item_disabled(item_index):
		return
	_action_dispatched = true
	popup.hide()
	for tool: Dictionary in ToolCatalog.TOOLS:
		if int(tool.mode) == id:
			world.set_player_mode(tool.mode)
			return
	match id:
		ACTION_INSPECT:
			if not _cell_unchanged(_hit):
				_target_changed()
				return
			if external_inspector:
				cell_inspected.emit(int(_hit.block_id), _hit.pos)
				return
			snapshot_label.text = ToolCatalog.format_block_info(world, int(_hit.block_id), _hit.pos)
			snapshot_panel.show()
			_clamp_snapshot()
		ACTION_CANCEL_TASKS:
			if not _cell_unchanged(_pending_target) or _pending_tasks_at(_pending_target.pos) != _pending_target.tasks:
				_target_changed()
				return
			# SEE-ADR-008: Use reservation-aware pending task cancellation.
			world.cancel_pending_task_requests_at(_pending_target.pos)
		ACTION_REMOVE_STOCKPILE:
			if not _cell_unchanged(_stockpile_target) \
					or world.stockpile_store.stockpile_at(_stockpile_target.pos) != _stockpile_target.stockpile_id:
				_target_changed()
				return
			var cells: Array[Vector3i] = [_stockpile_target.pos]
			world.remove_stockpile_cells(cells)
		ACTION_REMOVE_STAIRS:
			if not _stair_target_unchanged():
				_target_changed()
				return
			var queued: bool = world.queue_stair_removal(_stair_target.anchor)
			if not queued:
				_action_failed("Could not queue stair removal; the stairs changed or already have an active task.")
		ACTION_WORKERS:
			workers.open()


func _target_changed() -> void:
	_action_failed("Target changed; reopen the menu")


func _action_failed(message: String) -> void:
	if external_inspector:
		action_feedback.emit(message)
		return
	status_label.text = message
	status_label.show()
	status_timer.start()


func _setup_snapshot(hud_layer: CanvasLayer) -> void:
	snapshot_panel = PanelContainer.new()
	snapshot_panel.name = "CellSnapshot"
	snapshot_panel.position = Vector2(12, 80)
	snapshot_panel.hide()
	var margin := MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 8)
	snapshot_panel.add_child(margin)
	var content := VBoxContainer.new()
	margin.add_child(content)
	var header := HBoxContainer.new()
	content.add_child(header)
	var title := Label.new()
	title.text = "Cell snapshot"
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(title)
	var close_button := Button.new()
	close_button.name = "CloseSnapshot"
	close_button.text = "Close"
	close_button.pressed.connect(snapshot_panel.hide)
	header.add_child(close_button)
	snapshot_label = Label.new()
	snapshot_label.name = "SnapshotText"
	content.add_child(snapshot_label)
	hud_layer.add_child(snapshot_panel)


func _clamp_snapshot() -> void:
	snapshot_panel.reset_size()
	var available := viewport.get_visible_rect().size
	snapshot_panel.position = Vector2(
		clampf(snapshot_panel.position.x, 0, maxf(available.x - snapshot_panel.size.x, 0)),
		clampf(snapshot_panel.position.y, 0, maxf(available.y - snapshot_panel.size.y, 0)))
