extends RefCounted
## SEE-ADR-014: UI/lifecycle adapter; no gameplay-control operations.
const Service = preload("res://scripts/diagnostics/live_diagnostics_service.gd")
const Snapshot = preload("res://scripts/diagnostics/live_world_snapshot.gd")
const Transport = preload("res://scripts/diagnostics/live_diagnostics_transport.gd")
const Writer = preload("res://scripts/diagnostics/bug_capture_writer.gd")
const FrameCapture = preload("res://scripts/diagnostics/frame_capture.gd")
const ErrorLogger = preload("res://scripts/diagnostics/live_diagnostics_logger.gd")
const CAPTURE_COOLDOWN_USEC := 5000000
var main
var service = Service.new()
var inspector = Snapshot.new()
var transport = Transport.new()
var writer = Writer.new()
var indicator: Label
var enable_checkbox: CheckBox
var logger: Logger
var errors: Array = []
var dropped_errors := 0
var capture: Dictionary = {"state": "idle"}
var _pending: Dictionary = {}
var _snapshot: Dictionary = {}
var _last_capture_usec := -CAPTURE_COOLDOWN_USEC
var _last_request_key := ""
var _status_until := 0
var _message := ""
var _operation := ""
var _focused := true
var collection_usec := 0
var service_usec := 0

func initialize(owner) -> void:
	main = owner
	inspector.main = main
	inspector.service = service
	service.snapshot_provider = inspector.query
	service.capture_provider = request_capture
	service.capture_status_provider = get_capture_status
	main.world.live_diagnostics = service
	main.world.item_store.live_diagnostics = service
	main.world.stockpile_store.live_diagnostics = service
	main.world.task_queue.diagnostics_world = weakref(main.world)
	if not OS.is_debug_build():
		return
	var layer := CanvasLayer.new()
	layer.name = "LiveDiagnosticsStatus"
	layer.layer = 128
	main.add_child(layer)
	indicator = Label.new()
	indicator.mouse_filter = Control.MOUSE_FILTER_IGNORE
	indicator.focus_mode = Control.FOCUS_NONE
	layer.add_child(indicator)
	indicator.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	indicator.offset_left = 12
	indicator.offset_right = -12
	indicator.offset_top = 34
	indicator.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	indicator.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	indicator.hide()
	enable_checkbox = CheckBox.new()
	enable_checkbox.text = "Enable live diagnostics"
	enable_checkbox.toggled.connect(set_enabled)
	main.menu_vbox.add_child(enable_checkbox)
	var button := Button.new()
	button.text = "Capture bug report [F1]"
	button.pressed.connect(func(): request_capture({}))
	main.menu_vbox.add_child(button)
	RenderingServer.frame_pre_draw.connect(_pre_draw)
	RenderingServer.frame_post_draw.connect(_post_draw)

func set_enabled(value: bool) -> void:
	if not OS.is_debug_build():
		return
	if value == service.enabled:
		return
	if value:
		if transport.start(service.session_id) != OK:
			_show("Diagnostics connection failed: " + transport.last_error)
			enable_checkbox.set_pressed_no_signal(false)
			return
		logger = ErrorLogger.new()
		OS.add_logger(logger)
	else:
		transport.stop()
		if logger != null:
			OS.remove_logger(logger)
			logger = null
	service.set_enabled(value)
	errors.clear()
	dropped_errors = 0
	# Renderer owns this potentially immutable worker snapshot. Toggling an
	# observer must not clear rendering evidence or mutate worker-owned data.
	enable_checkbox.set_pressed_no_signal(value)
	_show("Live diagnostics enabled | F1 capture" if value else "Live diagnostics disabled")

func handle_unhandled_input(event: InputEvent) -> bool:
	if not OS.is_debug_build() or not event is InputEventKey:
		return false
	if event.keycode != KEY_F1 and event.physical_keycode != KEY_F1:
		return false
	if event.ctrl_pressed or event.alt_pressed or event.meta_pressed or event.shift_pressed:
		return false
	# Only typing or an open popup owns F1. World-input gates (right-drag panning,
	# a pending context click) must not block evidence capture mid-gesture.
	if (main.colony_ui != null and main.colony_ui.keyboard_owned()) or main.performance_controller._popup_visible():
		return false
	if event.pressed and not event.echo:
		request_capture({})
	return true

func process_frame() -> void:
	var start := Time.get_ticks_usec()
	if logger != null:
		var batch: Dictionary = logger.drain()
		dropped_errors += int(batch.dropped)
		for row in batch.rows:
			row["world_epoch"] = service.world_epoch
			row["frame_id"] = service.frame_id
			row["attribution"] = "main_thread_drain; timestamp_is_callback_time"
			errors.append(row)
		while errors.size() > 256 or (not errors.is_empty() and service.now_usec - int(errors[0].monotonic_usec) > Service.HISTORY_USEC):
			errors.pop_front()
			dropped_errors += 1
	if service.enabled:
		transport.poll(service.dispatch, service.now_usec)
	writer.poll()
	if capture.state == "writing" and writer.status.state != "writing":
		capture = writer.status.duplicate(true)
		_show("Bug report saved: " + str(capture.get("path", "")) if capture.state == "complete" else "Bug capture failed: " + str(capture.get("error", "unknown")))
	# Headless renderers may not emit draw signals. Keep metadata-only captures usable.
	if not _pending.is_empty() and DisplayServer.get_name() == "headless":
		_pre_draw()
		_post_draw()
	if not _pending.is_empty() and service.now_usec - int(_pending.requested_usec) > 2000000:
		_pre_draw()
		_snapshot["screenshot"] = {"available": false, "reason": "render_timeout"}
		_finish_capture(null)
	if is_instance_valid(indicator):
		indicator.text = _message if Time.get_ticks_usec() < _status_until else ("LIVE DIAGNOSTICS | F1 capture" if service.enabled else "")
		indicator.visible = not indicator.text.is_empty()
	service_usec += Time.get_ticks_usec() - start

func request_capture(args: Dictionary) -> Dictionary:
	if not OS.is_debug_build():
		return {"error": "development_only"}
	var request_key := str(args.get("request_key", "")).left(128)
	if not request_key.is_empty() and request_key == _last_request_key:
		return get_capture_status()
	if capture.state in ["pending", "writing"]:
		return {"error": "capture_busy"}
	var now := Time.get_ticks_usec()
	if now - _last_capture_usec < CAPTURE_COOLDOWN_USEC:
		return {"error": "capture_cooldown"}
	_last_capture_usec = now
	_last_request_key = request_key
	var id: String = Time.get_datetime_string_from_system(true).replace(":", "-") + "-" + service.session_id.left(8) + "-" + str(now)
	_pending = {"capture_id": id, "requested_usec": now, "world_epoch": service.world_epoch,
		"view_id": inspector.view_id(), "note": str(args.get("note", "")).left(1024)}
	capture = {"state": "pending", "capture_id": id}
	service.mark_event("bug_capture_requested", {"capture_id": id})
	if main.performance_controller != null and main.performance_controller.recorder.enabled:
		main.performance_controller.recorder.mark_event("bug_capture", {"capture_id": id})
	_show("Capturing bug report...")
	return get_capture_status()

func get_capture_status() -> Dictionary:
	return capture.duplicate(true)

func _pre_draw() -> void:
	if _pending.is_empty() or not _snapshot.is_empty():
		return
	var start := Time.get_ticks_usec()
	_snapshot = inspector.capture_snapshot()
	_snapshot["note"] = _pending.note
	_snapshot["capture_id"] = _pending.capture_id
	_snapshot["request_world_epoch"] = _pending.world_epoch
	_snapshot["request_view_id"] = _pending.view_id
	_snapshot["pre_draw_frame"] = Engine.get_frames_drawn()
	_snapshot["view_id"] = inspector.view_id()
	_snapshot["capture_collection_usec"] = Time.get_ticks_usec() - start
	collection_usec += Time.get_ticks_usec() - start

func _post_draw() -> void:
	if _snapshot.is_empty():
		return
	var start := Time.get_ticks_usec()
	var reason := ""
	var pixels: Image
	if service.world_epoch != int(_pending.world_epoch) or service.world_epoch != int(_snapshot.world_epoch):
		reason = "world_changed"
	elif inspector.view_id() != _snapshot.view_id:
		reason = "view_changed_between_draw_boundaries"
	elif service.frame_id != int(_snapshot.frame_id):
		reason = "frame_changed_between_draw_boundaries"
	elif DisplayServer.get_name() == "headless":
		reason = "headless"
	elif DisplayServer.window_get_mode() == DisplayServer.WINDOW_MODE_MINIMIZED:
		reason = "minimized"
	else:
		var readback: Dictionary = FrameCapture.read_viewport_image(main)
		var readback_metadata: Dictionary = readback.get("metadata", {}) if readback.get("metadata", {}) is Dictionary else {}
		pixels = readback.get("image") as Image
		if pixels == null:
			reason = str(readback_metadata.get("reason", "image_unavailable"))
	_snapshot["screenshot"] = {"available": pixels != null, "reason": reason,
		"post_draw_frame": Engine.get_frames_drawn(), "main_frame_id": service.frame_id,
		"readback_usec": Time.get_ticks_usec() - start}
	collection_usec += Time.get_ticks_usec() - start
	_finish_capture(pixels)

func _finish_capture(pixels: Image) -> void:
	var id: String = _pending.capture_id
	writer.start(id, _snapshot, service.recent_events(Service.MAX_ENTRIES), {"rows": errors.duplicate(true), "dropped": dropped_errors}, pixels)
	capture = writer.status.duplicate(true)
	_pending = {}
	_snapshot = {}

func begin_operation(operation: String) -> void:
	_operation = operation
	service.mark_event(operation + "_started")

func set_operation(operation: String) -> void:
	# World save/load hooks own the corresponding storage-outcome events.
	_operation = operation

func finish_operation(operation: String, success: bool) -> void:
	service.mark_event(operation + "_finished", {"success": success})
	_operation = ""

func set_focused(value: bool) -> void:
	_focused = value
	service.mark_event("focus_changed", {"focused": value})

func current_segment() -> String:
	if not _focused:
		return "unfocused"
	if main.loading_active:
		return "loading"
	if not _operation.is_empty():
		return _operation
	return "menu" if main.menu_open else "gameplay"

func shutdown() -> void:
	transport.stop()
	if logger != null:
		OS.remove_logger(logger)
		logger = null
	if not _pending.is_empty():
		# Children may already have exited. Do not read cameras or live world here.
		if _snapshot.is_empty():
			_snapshot = service.stamp()
			_snapshot["capture_id"] = _pending.capture_id
			_snapshot["note"] = _pending.note
			_snapshot["world_data"] = {"unavailable": "tree_exit_before_snapshot"}
		_snapshot["screenshot"] = {"available": false, "reason": "tree_exit"}
		_finish_capture(null)
	writer.shutdown()
	service.set_enabled(false)
	if RenderingServer.frame_pre_draw.is_connected(_pre_draw):
		RenderingServer.frame_pre_draw.disconnect(_pre_draw)
	if RenderingServer.frame_post_draw.is_connected(_post_draw):
		RenderingServer.frame_post_draw.disconnect(_post_draw)
	if is_instance_valid(main) and is_instance_valid(main.world):
		main.world.live_diagnostics = null
		main.world.item_store.live_diagnostics = null
		main.world.stockpile_store.live_diagnostics = null
		main.world.task_queue.diagnostics_world = null
	inspector.main = null
	service.snapshot_provider = Callable()
	service.capture_provider = Callable()
	service.capture_status_provider = Callable()
	main = null

func _show(message: String) -> void:
	_message = message
	_status_until = Time.get_ticks_usec() + 8000000
