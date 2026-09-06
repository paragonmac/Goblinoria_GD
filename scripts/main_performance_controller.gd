extends RefCounted
## Main owns this adapter; the recorder has no UI or gameplay-control dependency.
# SEE-ADR-013: Record observations, never drive or pause the simulation.

const RecorderScript = preload("res://scripts/diagnostics/passive_performance_recorder.gd")

var recorder = RecorderScript.new()
var capture_root := "user://diagnostics/gameplay"
var main
var indicator: Label
var _world: World
var _capture_renderer: WorldRenderer
var _mesh_capture_enabled := false
var _focused := true
var _operation := ""
var _status_until_usec := 0
var _status_message := ""
var _last_status_usec := 0
var _was_recording := false
var _last_diagnostics: Dictionary = {}


func initialize(main_ref) -> void:
	main = main_ref
	var layer := CanvasLayer.new()
	layer.name = "PerformanceCaptureStatus"
	layer.layer = 128
	main.add_child(layer)
	indicator = Label.new()
	indicator.name = "CaptureStatus"
	indicator.mouse_filter = Control.MOUSE_FILTER_IGNORE
	indicator.focus_mode = Control.FOCUS_NONE
	indicator.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	indicator.offset_left = 12
	indicator.offset_right = -12
	indicator.offset_top = 8
	indicator.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	indicator.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	indicator.add_theme_color_override("font_color", Color(1.0, 0.85, 0.35))
	indicator.hide()
	layer.add_child(indicator)
	attach_world(main.world)


func attach_world(world_ref: World) -> void:
	_set_mesh_capture(false)
	if is_instance_valid(_world):
		if _world.render_level_changed.is_connected(_on_render_level_changed):
			_world.render_level_changed.disconnect(_on_render_level_changed)
		_world.performance_recorder = null
	_world = world_ref
	if _world != null:
		_world.performance_recorder = recorder
		_world.render_level_changed.connect(_on_render_level_changed)


func handle_unhandled_input(event: InputEvent) -> bool:
	if not event is InputEventKey:
		return false
	var key := event as InputEventKey
	if (key.keycode != KEY_F12 and key.physical_keycode != KEY_F12) \
			or key.ctrl_pressed or key.alt_pressed or key.meta_pressed:
		return false
	if main._context_blocks_world_input() or _popup_visible():
		return false
	if not key.pressed or key.echo:
		return true
	if key.shift_pressed:
		if recorder.enabled:
			recorder.mark_moment()
			_show_status("Moment marked", 3.0)
		return true
	if recorder.enabled:
		_set_mesh_capture(false)
		recorder.stop("manual")
		_show_status("Capture saved: %s" % recorder.output_path, 8.0)
	elif main.world_started and main.world != null:
		if recorder.start(_metadata(), -1, capture_root):
			_set_mesh_capture(true)
			sync_segment()
			_last_diagnostics = _diagnostics()
			_show_status("F12 stop | Shift+F12 mark", 3.0)
		else:
			_show_status("Capture failed: %s" % recorder.last_error, 8.0)
	else:
		_show_status("Start a world before recording", 3.0)
	_update_indicator(true)
	return true


func begin_frame(dt: float) -> void:
	if recorder.enabled:
		sync_segment()
		recorder.begin_frame(dt)


func end_frame(main_update_ms: float) -> void:
	if recorder.enabled:
		_set_mesh_capture(true)
		if is_instance_valid(_capture_renderer):
			_capture_renderer.drain_performance_capture()
		if recorder.wants_workload_sample():
			var values: Dictionary = main.world.get_performance_snapshot() if main.world != null else {}
			values["render_level"] = main.world.top_render_y if main.world != null else null
			if main.camera != null:
				values["camera_x"] = main.camera.position.x
				values["camera_y"] = main.camera.position.y
				values["camera_z"] = main.camera.position.z
				values["camera_size"] = main.camera.size
			recorder.sample_workload(values)
			var diagnostics := _diagnostics()
			if diagnostics != _last_diagnostics:
				recorder.mark_event("diagnostics_changed", diagnostics)
				_last_diagnostics = diagnostics
		recorder.end_frame(main_update_ms)
		recorder.pump_output()
	if not recorder.enabled:
		_set_mesh_capture(false)
	_update_indicator()


func sync_segment() -> void:
	if not recorder.enabled:
		return
	var next := "gameplay"
	if not _focused:
		next = "unfocused"
	elif not _operation.is_empty():
		next = _operation
	elif main.loading_active:
		next = "loading"
	elif main.menu_open:
		next = "menu"
	recorder.set_segment(next)


func set_focused(focused: bool) -> void:
	_focused = focused
	sync_segment()


func begin_operation(operation: String) -> void:
	_operation = operation
	sync_segment()
	recorder.mark_event("%s_started" % operation)


func finish_operation(operation: String, success: bool) -> void:
	recorder.mark_event("%s_finished" % operation, {"success": success})
	_operation = ""
	sync_segment()


func world_replaced(reason: String) -> void:
	attach_world(main.world)
	if recorder.enabled:
		var metadata := _world_metadata()
		metadata["reason"] = reason
		recorder.begin_world(metadata)
		_set_mesh_capture(true)
		sync_segment()


func shutdown() -> void:
	_set_mesh_capture(false)
	recorder.stop("quit")
	if is_instance_valid(_world):
		if _world.render_level_changed.is_connected(_on_render_level_changed):
			_world.render_level_changed.disconnect(_on_render_level_changed)
		_world.performance_recorder = null
	_world = null
	main = null
	_capture_renderer = null


func _set_mesh_capture(enabled: bool) -> void:
	var target: WorldRenderer = _world.renderer if is_instance_valid(_world) else null
	if target != _capture_renderer:
		if is_instance_valid(_capture_renderer):
			_capture_renderer.set_performance_capture_enabled(false)
		_capture_renderer = target
		_mesh_capture_enabled = false
	if is_instance_valid(_capture_renderer) and _mesh_capture_enabled != enabled:
		_capture_renderer.set_performance_capture_enabled(enabled)
		_mesh_capture_enabled = enabled


func _popup_visible() -> bool:
	for window in main.get_viewport().get_embedded_subwindows():
		if window.visible and window.popup_window:
			return true
	return false


func _on_render_level_changed(level: int) -> void:
	recorder.mark_event("render_level_changed", {"level": level})


func _world_metadata() -> Dictionary:
	if main.world == null:
		return {}
	return {
		"seed": main.world.world_seed,
		"chunk_size": World.CHUNK_SIZE,
		"world_size": [main.world.world_size_x, main.world.world_size_y, main.world.world_size_z],
		"render_level": main.world.top_render_y,
		"full_map_startup": main.generate_full_map_on_startup,
	}


func _metadata() -> Dictionary:
	var viewport_size: Vector2 = main.get_viewport().get_visible_rect().size
	return {
		"engine": Engine.get_version_info(),
		"build": "debug" if OS.is_debug_build() else "release",
		"revision": ProjectSettings.get_setting("application/config/build_revision", "unknown"),
		"dirty_state": "unknown",
		"os": OS.get_name(),
		"cpu": OS.get_processor_name(),
		"logical_processors": OS.get_processor_count(),
		"display_driver": DisplayServer.get_name(),
		"gpu": RenderingServer.get_video_adapter_name() if DisplayServer.get_name() != "headless" else "unavailable",
		"renderer": ProjectSettings.get_setting("rendering/renderer/rendering_method", "unknown"),
		"viewport": [viewport_size.x, viewport_size.y],
		"max_fps": Engine.max_fps,
		"vsync": DisplayServer.window_get_vsync_mode() if DisplayServer.get_name() != "headless" else null,
		"world": _world_metadata(),
		"diagnostics": _diagnostics(),
	}


func _diagnostics() -> Dictionary:
	var overlay = main.debug_overlay
	if overlay == null:
		return {"debug_overlay": false}
	return {
		"debug_overlay": true,
		"profiler_ui": overlay.show_profiler,
		"timings_ui": overlay.show_debug_timings,
		"timings_log": overlay.debug_timings_log_enabled,
		"streaming_capture": overlay.streaming_capture_enabled,
		"streaming_ui": overlay.show_streaming_stats,
		"draw_burden": overlay.show_draw_burden,
		"worker_trace": main.world.worker_trace.enabled if main.world != null and main.world.worker_trace != null else false,
	}


func _show_status(message: String, seconds: float) -> void:
	_status_message = message
	_status_until_usec = Time.get_ticks_usec() + int(seconds * 1000000.0)
	_update_indicator(true)


func _update_indicator(force := false) -> void:
	var now := Time.get_ticks_usec()
	if not force and now - _last_status_usec < 250000:
		return
	_last_status_usec = now
	if not is_instance_valid(indicator):
		return
	var status: Dictionary = recorder.get_status(now)
	if _was_recording and not recorder.enabled and status.get("reason", "") == "size_limit":
		_status_message = "Capture stopped at size limit: %s" % recorder.output_path
		_status_until_usec = now + 8000000
	_was_recording = recorder.enabled
	if not recorder.last_error.is_empty():
		indicator.text = "Capture stopped: %s" % recorder.last_error
	elif recorder.enabled:
		indicator.text = "REC %ds [%s]  %s" % [int(status.get("elapsed_sec", 0.0)), recorder.segment,
			_status_message if now < _status_until_usec else "F12 stop | Shift+F12 mark"]
	else:
		indicator.text = _status_message if now < _status_until_usec else ""
	indicator.visible = not indicator.text.is_empty()
