extends Node3D
## Main game controller handling camera, input, menu, and game state.

#region Preloads
const MainCameraControllerScript = preload("res://scripts/main_camera_controller.gd")
const MainSelectionControllerScript = preload("res://scripts/main_selection_controller.gd")
const MainHudControllerScript = preload("res://scripts/main_hud_controller.gd")
const MainWorkerWindowControllerScript = preload("res://scripts/main_worker_window_controller.gd")
#endregion

#region Constants - Engine & General
const ENGINE_MAX_FPS := 1000
#endregion

#region Constants - Save System
const SAVE_DIR := "user://saves"
const SAVE_PATH := "user://saves/world.save"
const SAVE_META_FILE_NAME := "world_meta.dat"
const STARTUP_GENERATION_RESULT_BUDGET := 128
const STARTUP_MESH_RESULT_BUDGET := 128
const STARTUP_MESH_QUEUE_BUDGET := 128
const ARENA_COOK_MERGE_BUDGET := 256
const STARTUP_REVEAL_BAND_RADIUS := 1
const STARTUP_GENERATION_NEIGHBOR_BAND_RADIUS := 1
const Y_REVEAL_READY_MARGIN_CHUNKS := 1
const Y_DIRECTIONAL_PREWARM_BLOCKS_AHEAD := 8
const Y_DIRECTIONAL_PREWARM_GENERATION_RESULT_BUDGET := 8
const Y_DIRECTIONAL_PREWARM_MESH_RESULT_BUDGET := 4
const Y_DIRECTIONAL_PREWARM_MESH_QUEUE_BUDGET := 32
const BACKGROUND_WARMUP_GENERATION_RESULT_BUDGET := 16
const BACKGROUND_WARMUP_MESH_RESULT_BUDGET := 8
const BACKGROUND_WARMUP_MESH_QUEUE_BUDGET := 32
#endregion

#region User Settings
## True generates every finite chunk and full-chunk mesh cache before revealing a new world.
@export var generate_full_map_on_startup: bool = true
#endregion

#region Node References
@onready var world: World = $World
@onready var camera: Camera3D = $Camera3D
@onready var hud_label: Label = $HUD/ModeLabel
@onready var hud_layer: CanvasLayer = $HUD
@onready var menu_layer: CanvasLayer = $Menu
@onready var resume_button: Button = $Menu/Panel/VBox/ResumeButton
@onready var save_button: Button = $Menu/Panel/VBox/SaveButton
@onready var load_button: Button = $Menu/Panel/VBox/LoadButton
@onready var quit_button: Button = $Menu/Panel/VBox/QuitButton
@onready var menu_status_label: Label = $Menu/Panel/VBox/StatusLabel
@onready var menu_vbox: VBoxContainer = $Menu/Panel/VBox
@onready var world_environment: WorldEnvironment = $WorldEnvironment
var loading_layer: CanvasLayer
var loading_status_label: Label
var loading_progress_bar: ProgressBar
var full_map_generation_check_box: CheckBox
#endregion

#region Controllers
var camera_controller: MainCameraController
var selection_controller: MainSelectionController
var hud_controller: MainHudController
var worker_window_controller
#endregion

#region Input State
var key_state: Dictionary = {}
#endregion

#region Game State
var debug_overlay: DebugOverlay
var menu_open := false
var loading_active := false
var world_started := false
var default_bg_mode: int = -1
var default_bg_color: Color = Color.BLACK
var prepared_chunk_bands: Dictionary = {}
var background_warmup_queue: Array[int] = []
var background_warmup_generation_targets: Array[Vector3i] = []
var background_warmup_mesh_targets: Array[Vector3i] = []
var background_warmup_mesh_index: int = 0
var background_warmup_band: int = -1
var background_warmup_meshes_queued := false
var y_prewarm_generation_targets: Array[Vector3i] = []
var y_prewarm_mesh_targets: Array[Vector3i] = []
var y_prewarm_mesh_index: int = 0
var y_prewarm_render_y: int = -1
var y_prewarm_direction: int = 0
var y_prewarm_meshes_queued := false
var last_startup_load_metrics: Dictionary = {}
var last_render_y_ready_profile: Dictionary = {}
#endregion


#region Lifecycle
func _ready() -> void:
	Engine.max_fps = ENGINE_MAX_FPS
	_initialize_controllers()
	_setup_camera()
	_setup_hud()
	_setup_debug_overlay()
	_setup_menu()
	_setup_loading_screen()
	_cache_environment_defaults()
	_set_world_draw_enabled(false)
	open_menu()


func _process(dt: float) -> void:
	_handle_global_input()
	if loading_active:
		return
	if menu_open:
		return
	_handle_gameplay_input()
	_run_frame_updates(dt)
	_pump_directional_y_prewarm()
	_pump_background_level_warmup()


func _input(event: InputEvent) -> void:
	if menu_open or loading_active:
		return
	_handle_zoom_input(event)
#endregion


#region Controllers
func _initialize_controllers() -> void:
	var viewport := get_viewport()
	camera_controller = MainCameraControllerScript.new()
	camera_controller.initialize(camera, viewport)
	selection_controller = MainSelectionControllerScript.new()
	selection_controller.initialize(world, camera, viewport, camera_controller)
	hud_controller = MainHudControllerScript.new()
	worker_window_controller = MainWorkerWindowControllerScript.new()
#endregion


#region Camera Setup & Updates
func _setup_camera() -> void:
	if camera_controller != null:
		camera_controller.setup_camera(world)


func update_camera(dt: float) -> void:
	if camera_controller != null:
		camera_controller.update_camera(dt)


func get_stream_view_rect() -> Rect2:
	if world == null:
		return Rect2()
	return get_stream_view_rect_for_y(world.top_render_y)


func get_stream_view_rect_for_y(render_y: int) -> Rect2:
	if camera_controller == null or world == null:
		return Rect2()
	return camera_controller.get_stream_view_rect(float(render_y))


func get_stream_target() -> Vector3:
	if camera_controller == null or world == null:
		return Vector3.ZERO
	return camera_controller.get_stream_target(float(world.top_render_y))
#endregion


#region Input Handling
func _handle_global_input() -> void:
	if loading_active:
		return
	if is_key_just_pressed(KEY_ESCAPE):
		toggle_menu()


func _handle_gameplay_input() -> void:
	_handle_worker_window_toggle()
	_handle_mode_selection()
	_handle_debug_keys()
	_handle_render_layer_keys()


func _handle_worker_window_toggle() -> void:
	if worker_window_controller == null:
		return
	if is_key_just_pressed(KEY_W):
		worker_window_controller.toggle()


func _handle_mode_selection() -> void:
	if is_key_just_pressed(KEY_1):
		world.player_mode = World.PlayerMode.INFORMATION
	elif is_key_just_pressed(KEY_2):
		world.player_mode = World.PlayerMode.DIG
	elif is_key_just_pressed(KEY_3):
		world.player_mode = World.PlayerMode.PLACE
	elif is_key_just_pressed(KEY_4):
		world.player_mode = World.PlayerMode.STAIRS


func _handle_debug_keys() -> void:
	if debug_overlay == null:
		return
	if is_key_just_pressed(KEY_F2):
		debug_overlay.toggle_profiler()
	if is_key_just_pressed(KEY_F3):
		debug_overlay.toggle_draw_burden()
	if is_key_just_pressed(KEY_F4):
		debug_overlay.toggle_debug_timings()
	if is_key_just_pressed(KEY_F5):
		debug_overlay.toggle_streaming_stats()
	if is_key_just_pressed(KEY_F6):
		debug_overlay.toggle_streaming_capture()
	if is_key_just_pressed(KEY_F7):
		debug_overlay.dump_ramp_counts()
	if is_key_just_pressed(KEY_F8):
		if world != null and world.renderer != null:
			world.renderer.toggle_debug_normals()
	if is_key_just_pressed(KEY_F9):
		debug_overlay.export_map_snapshot()
	if is_key_just_pressed(KEY_F10):
		debug_overlay.toggle_debug_timings_log()


func _handle_render_layer_keys() -> void:
	if is_key_just_pressed(KEY_BRACKETLEFT):
		_handle_render_layer_change(-1)
	elif is_key_just_pressed(KEY_BRACKETRIGHT):
		_handle_render_layer_change(1)


func _handle_render_layer_change(delta: int) -> void:
	var from_y: int = world.top_render_y
	var target_y: int = clampi(from_y + delta, 0, world.world_size_y - 1)
	if target_y == from_y:
		return
	var snapshot_before: Dictionary = _capture_y_transition_snapshot()
	var mesh_targets: Array[Vector3i] = _build_reveal_chunk_targets(target_y)
	var mesh_ready_before: int = _count_ready_startup_chunks(mesh_targets)
	if mesh_targets.is_empty() or mesh_ready_before < mesh_targets.size():
		_change_render_layer_with_loading(delta, from_y, target_y, snapshot_before, mesh_targets, mesh_ready_before)
		return
	if debug_overlay != null:
		debug_overlay.run_timed("World.set_top_render_y", Callable(self, "_apply_render_y").bind(target_y))
	else:
		_apply_render_y(target_y)
	_log_render_height_change(delta)
	_record_instant_y_transition(from_y, target_y, delta, snapshot_before, mesh_targets, mesh_ready_before)
	_schedule_directional_y_prewarm(delta, target_y)


func _apply_render_y(target_y: int) -> void:
	world.set_top_render_y(target_y)


func _change_render_layer_with_loading(delta: int, from_y: int, target_y: int, snapshot_before: Dictionary, mesh_targets_before: Array[Vector3i], mesh_ready_before: int) -> void:
	var blocked_start_usec: int = Time.get_ticks_usec()
	var generation_targets_before: Array[Vector3i] = _build_reveal_generation_targets(target_y)
	var generation_ready_before: int = _count_generated_startup_chunks(generation_targets_before)
	_show_loading_screen("Building level...")
	await get_tree().process_frame
	var ready_profile: Dictionary = await _ensure_render_y_ready(target_y, "Building level %d" % target_y)
	if debug_overlay != null:
		debug_overlay.run_timed("World.set_top_render_y", Callable(self, "_apply_render_y").bind(target_y))
	else:
		_apply_render_y(target_y)
	_log_render_height_change(delta)
	var view_rect: Rect2 = Rect2()
	if camera_controller != null:
		view_rect = camera_controller.get_stream_view_rect(float(world.top_render_y))
	world.update_streaming(view_rect, float(world.top_render_y), 0.0)
	var snapshot_after: Dictionary = _capture_y_transition_snapshot()
	ready_profile["mesh_total"] = mesh_targets_before.size()
	ready_profile["mesh_ready_before"] = mesh_ready_before
	ready_profile["generation_total"] = generation_targets_before.size()
	ready_profile["generation_ready_before"] = generation_ready_before
	ready_profile["total_blocked_ms"] = float(Time.get_ticks_usec() - blocked_start_usec) / 1000.0
	ready_profile["frames_waited"] = int(ready_profile.get("frames_waited", 0)) + 1
	_record_y_transition_profile(from_y, target_y, delta, true, ready_profile, snapshot_before, snapshot_after)
	_set_world_draw_enabled(true)
	_hide_loading_screen()
	_schedule_directional_y_prewarm(delta, target_y)


func _log_render_height_change(delta: int) -> void:
	if debug_overlay == null or not debug_overlay.show_debug_timings:
		return
	var direction := "down" if delta < 0 else "up"
	print("Render height %s: y=%d" % [direction, world.top_render_y])


func _record_instant_y_transition(from_y: int, target_y: int, delta: int, snapshot_before: Dictionary, mesh_targets: Array[Vector3i], mesh_ready_before: int) -> void:
	var generation_targets: Array[Vector3i] = _build_reveal_generation_targets(target_y)
	var generated: int = _count_generated_startup_chunks(generation_targets)
	var profile := {
		"target_chunk_y": _chunk_y_for_render_y(target_y),
		"mesh_total": mesh_targets.size(),
		"mesh_ready_before": mesh_ready_before,
		"mesh_ready_after": _count_ready_startup_chunks(mesh_targets),
		"generation_total": generation_targets.size(),
		"generation_ready_before": generated,
		"generation_ready_after": generated,
		"request_ms": 0.0,
		"generation_load_ms": 0.0,
		"mesh_wait_ms": 0.0,
		"total_blocked_ms": 0.0,
		"frames_waited": 0,
	}
	_record_y_transition_profile(from_y, target_y, delta, false, profile, snapshot_before, _capture_y_transition_snapshot())


func _record_y_transition_profile(from_y: int, target_y: int, delta: int, blocked: bool, profile: Dictionary, snapshot_before: Dictionary, snapshot_after: Dictionary) -> void:
	if debug_overlay == null:
		return
	var row := {
		"t_ms": Time.get_ticks_msec(),
		"from_y": from_y,
		"target_y": target_y,
		"delta": delta,
		"target_chunk_y": int(profile.get("target_chunk_y", _chunk_y_for_render_y(target_y))),
		"blocked": 1 if blocked else 0,
		"mesh_total": int(profile.get("mesh_total", 0)),
		"mesh_ready_before": int(profile.get("mesh_ready_before", 0)),
		"mesh_ready_after": int(profile.get("mesh_ready_after", 0)),
		"generation_total": int(profile.get("generation_total", 0)),
		"generation_ready_before": int(profile.get("generation_ready_before", 0)),
		"generation_ready_after": int(profile.get("generation_ready_after", 0)),
		"request_ms": "%.3f" % float(profile.get("request_ms", 0.0)),
		"generation_load_ms": "%.3f" % float(profile.get("generation_load_ms", 0.0)),
		"mesh_wait_ms": "%.3f" % float(profile.get("mesh_wait_ms", 0.0)),
		"total_blocked_ms": "%.3f" % float(profile.get("total_blocked_ms", 0.0)),
		"frames_waited": int(profile.get("frames_waited", 0)),
	}
	_add_y_transition_snapshot_fields(row, snapshot_before, "before")
	_add_y_transition_snapshot_fields(row, snapshot_after, "after")
	row["mesh_cache_hits_delta"] = _snapshot_int(snapshot_after, "mesh_cache_hits") - _snapshot_int(snapshot_before, "mesh_cache_hits")
	row["mesh_cache_misses_delta"] = _snapshot_int(snapshot_after, "mesh_cache_misses") - _snapshot_int(snapshot_before, "mesh_cache_misses")
	row["mesh_cache_imports_delta"] = _snapshot_int(snapshot_after, "mesh_cache_imports") - _snapshot_int(snapshot_before, "mesh_cache_imports")
	row["mesh_build_ms_delta"] = "%.3f" % (_snapshot_float(snapshot_after, "mesh_build_ms") - _snapshot_float(snapshot_before, "mesh_build_ms"))
	row["mesh_upload_ms_delta"] = "%.3f" % (_snapshot_float(snapshot_after, "mesh_upload_ms") - _snapshot_float(snapshot_before, "mesh_upload_ms"))
	debug_overlay.record_y_transition(row)


func _add_y_transition_snapshot_fields(row: Dictionary, snapshot: Dictionary, suffix: String) -> void:
	row["generator_queued_%s" % [suffix]] = _snapshot_int(snapshot, "generator_queued")
	row["generator_results_%s" % [suffix]] = _snapshot_int(snapshot, "generator_results")
	row["generator_active_%s" % [suffix]] = _snapshot_int(snapshot, "generator_active")
	row["stream_build_queue_%s" % [suffix]] = _snapshot_int(snapshot, "stream_build_queue")
	row["stream_pending_%s" % [suffix]] = _snapshot_int(snapshot, "stream_pending")
	row["stream_min_y_%s" % [suffix]] = _snapshot_int(snapshot, "stream_min_y")
	row["stream_max_y_%s" % [suffix]] = _snapshot_int(snapshot, "stream_max_y")
	row["mesh_job_queue_%s" % [suffix]] = _snapshot_int(snapshot, "mesh_job_queue")
	row["mesh_result_queue_%s" % [suffix]] = _snapshot_int(snapshot, "mesh_result_queue")
	row["mesh_job_set_%s" % [suffix]] = _snapshot_int(snapshot, "mesh_job_set")
	row["mesh_prefetch_set_%s" % [suffix]] = _snapshot_int(snapshot, "mesh_prefetch_set")
	row["loaded_chunks_%s" % [suffix]] = _snapshot_int(snapshot, "loaded_chunks")
	row["mem_static_mb_%s" % [suffix]] = "%.3f" % _snapshot_float(snapshot, "mem_static_mb")


func _capture_y_transition_snapshot() -> Dictionary:
	var snapshot := {
		"generator_queued": 0,
		"generator_results": 0,
		"generator_active": 0,
		"stream_build_queue": 0,
		"stream_pending": 0,
		"stream_min_y": 0,
		"stream_max_y": 0,
		"mesh_job_queue": 0,
		"mesh_result_queue": 0,
		"mesh_job_set": 0,
		"mesh_prefetch_set": 0,
		"mesh_cache_hits": 0,
		"mesh_cache_misses": 0,
		"mesh_cache_imports": 0,
		"mesh_build_ms": 0.0,
		"mesh_upload_ms": 0.0,
		"loaded_chunks": 0,
		"mem_static_mb": float(Performance.get_monitor(Performance.MEMORY_STATIC)) / 1048576.0,
	}
	if world == null:
		return snapshot
	snapshot["loaded_chunks"] = world.chunks.size()
	if world.generator != null:
		var generation_stats: Dictionary = world.generator.get_generation_stats()
		snapshot["generator_queued"] = int(generation_stats.get("queued", 0))
		snapshot["generator_results"] = int(generation_stats.get("results", 0))
		snapshot["generator_active"] = int(generation_stats.get("active", 0))
	if world.streaming != null:
		var streaming: WorldStreaming = world.streaming
		snapshot["stream_build_queue"] = streaming.chunk_build_queue.size()
		snapshot["stream_pending"] = 1 if streaming.stream_pending else 0
		if streaming.stream_min_y != streaming.DUMMY_INT:
			snapshot["stream_min_y"] = streaming.stream_min_y * World.CHUNK_SIZE
			snapshot["stream_max_y"] = ((streaming.stream_max_y + 1) * World.CHUNK_SIZE) - 1
	if world.renderer != null:
		var mesh_stats: Dictionary = world.renderer.get_mesh_work_stats()
		snapshot["mesh_job_queue"] = int(mesh_stats.get("job_queue", 0))
		snapshot["mesh_result_queue"] = int(mesh_stats.get("result_queue", 0))
		snapshot["mesh_job_set"] = int(mesh_stats.get("job_set", 0))
		snapshot["mesh_prefetch_set"] = int(mesh_stats.get("prefetch_set", 0))
		snapshot["mesh_cache_hits"] = int(mesh_stats.get("cache_hits", 0))
		snapshot["mesh_cache_misses"] = int(mesh_stats.get("cache_misses", 0))
		snapshot["mesh_cache_imports"] = int(mesh_stats.get("cache_imports", 0))
		snapshot["mesh_build_ms"] = float(mesh_stats.get("mesh_build_ms", 0.0))
		snapshot["mesh_upload_ms"] = float(mesh_stats.get("mesh_upload_ms", 0.0))
	return snapshot


func _snapshot_int(snapshot: Dictionary, key: String) -> int:
	return int(snapshot.get(key, 0))


func _snapshot_float(snapshot: Dictionary, key: String) -> float:
	return float(snapshot.get(key, 0.0))


func _handle_zoom_input(event: InputEvent) -> void:
	if camera_controller != null:
		camera_controller.handle_zoom_input(event)


func is_key_just_pressed(keycode: int) -> bool:
	var down := Input.is_key_pressed(keycode)
	var was_down := bool(key_state.get(keycode, false))
	key_state[keycode] = down
	return down and not was_down
#endregion


#region Frame Updates
func _run_frame_updates(dt: float) -> void:
	if debug_overlay != null:
		_run_timed_updates(dt)
	else:
		_run_direct_updates(dt)


func _run_timed_updates(dt: float) -> void:
	debug_overlay.run_timed("Main.update_camera", Callable(self, "update_camera").bind(dt))
	var view_rect: Rect2 = get_stream_view_rect()
	var plane_y: float = float(world.top_render_y)
	debug_overlay.run_timed("World.update_streaming", Callable(world, "update_streaming").bind(view_rect, plane_y, dt))
	debug_overlay.run_timed("Main.handle_mouse", Callable(self, "handle_mouse"))
	debug_overlay.run_timed("Main.update_hover_preview", Callable(self, "update_hover_preview"))
	debug_overlay.run_timed("Main.update_info_hover", Callable(self, "update_info_hover"))
	debug_overlay.run_timed("Main.update_hud", Callable(self, "update_hud"))
	debug_overlay.update_draw_burden()
	debug_overlay.update_streaming_stats()
	debug_overlay.update_streaming_capture(dt)
	debug_overlay.step_world(dt)
	_update_depth_limit_background()


func _run_direct_updates(dt: float) -> void:
	update_camera(dt)
	var view_rect: Rect2 = get_stream_view_rect()
	var plane_y: float = float(world.top_render_y)
	world.update_streaming(view_rect, plane_y, dt)
	handle_mouse()
	update_hover_preview()
	update_info_hover()
	update_hud()
	world.update_world(dt)
	_update_depth_limit_background()
#endregion


func _cache_environment_defaults() -> void:
	if world_environment == null or world_environment.environment == null:
		return
	default_bg_mode = world_environment.environment.background_mode
	default_bg_color = world_environment.environment.background_color


func _update_depth_limit_background() -> void:
	if world_environment == null or world_environment.environment == null or world == null:
		return
	var min_y: int = world.get_min_render_y()
	var restricted: bool = world.top_render_y < min_y
	if restricted:
		world_environment.environment.background_mode = Environment.BG_COLOR
		world_environment.environment.background_color = Color(0.0, 0.0, 0.0, 1.0)
	else:
		if default_bg_mode >= 0:
			world_environment.environment.background_mode = default_bg_mode
		world_environment.environment.background_color = default_bg_color


#region Mouse Interaction
func handle_mouse() -> void:
	if selection_controller != null:
		selection_controller.handle_mouse()


func update_hover_preview() -> void:
	if selection_controller != null:
		selection_controller.update_hover_preview()


func update_info_hover() -> void:
	if selection_controller != null:
		selection_controller.update_info_hover()
#endregion


#region Menu System
func _setup_menu() -> void:
	_setup_full_map_generation_option()
	if resume_button:
		resume_button.pressed.connect(_on_resume_pressed)
	if save_button:
		save_button.pressed.connect(_on_save_pressed)
	if load_button:
		load_button.pressed.connect(_on_load_pressed)
	if quit_button:
		quit_button.pressed.connect(_on_quit_pressed)
	_refresh_menu_buttons()


func _setup_full_map_generation_option() -> void:
	if menu_vbox == null:
		return
	full_map_generation_check_box = CheckBox.new()
	full_map_generation_check_box.name = "FullMapGenerationCheckBox"
	full_map_generation_check_box.text = "Generate and cache full map"
	full_map_generation_check_box.tooltip_text = "Off uses limited streaming. On generates and stores every finite chunk and full-chunk mesh before reveal."
	full_map_generation_check_box.button_pressed = generate_full_map_on_startup
	full_map_generation_check_box.toggled.connect(_on_full_map_generation_toggled)
	var insert_index: int = menu_vbox.get_child_count()
	if menu_status_label != null:
		insert_index = menu_status_label.get_index()
	menu_vbox.add_child(full_map_generation_check_box)
	menu_vbox.move_child(full_map_generation_check_box, insert_index)


func _on_full_map_generation_toggled(enabled: bool) -> void:
	generate_full_map_on_startup = enabled
	_set_menu_status("Full map generation: %s" % ("On" if enabled else "Off"))


func toggle_menu() -> void:
	if menu_open:
		if not world_started:
			return
		close_menu()
	else:
		open_menu()


func open_menu() -> void:
	menu_open = true
	if menu_layer:
		menu_layer.visible = true
	_refresh_menu_buttons()
	if menu_status_label:
		menu_status_label.text = ""
	if camera_controller != null:
		camera_controller.reset_mouse_state()
	if selection_controller != null:
		selection_controller.cancel_drag_and_clear_preview()
	elif world != null:
		world.clear_drag_preview()
	if worker_window_controller != null:
		worker_window_controller.close()


func close_menu() -> void:
	if not world_started:
		return
	menu_open = false
	if menu_layer:
		menu_layer.visible = false


func _on_resume_pressed() -> void:
	if loading_active:
		return
	if not world_started:
		await _start_new_world_with_loading()
		return
	close_menu()


func _on_save_pressed() -> void:
	if loading_active:
		return
	if not world_started:
		_set_menu_status("Start a world before saving.")
		_refresh_menu_buttons()
		return
	var result := DirAccess.make_dir_recursive_absolute(SAVE_DIR)
	if result != OK:
		_set_menu_status("Save folder error.")
		return

	var ok := world.save_world(SAVE_PATH)
	_set_menu_status("Saved." if ok else "Save failed.")
	_refresh_menu_buttons()


func _on_load_pressed() -> void:
	if loading_active:
		return
	if not _has_save_game():
		_set_menu_status("No saved world found.")
		_refresh_menu_buttons()
		return
	await _load_world_with_loading()


func _on_quit_pressed() -> void:
	if loading_active:
		return
	get_tree().quit()


func _set_menu_status(text: String) -> void:
	if menu_status_label:
		menu_status_label.text = text


func _setup_loading_screen() -> void:
	loading_layer = CanvasLayer.new()
	loading_layer.name = "LoadingScreen"
	loading_layer.layer = 100
	if menu_layer != null:
		loading_layer.layer = menu_layer.layer + 10
	loading_layer.visible = false
	add_child(loading_layer)

	var backdrop := ColorRect.new()
	backdrop.name = "Backdrop"
	backdrop.color = Color(0.0, 0.0, 0.0, 0.92)
	backdrop.anchor_right = 1.0
	backdrop.anchor_bottom = 1.0
	loading_layer.add_child(backdrop)

	var panel := PanelContainer.new()
	panel.name = "StatusWindow"
	panel.anchor_left = 0.5
	panel.anchor_top = 0.5
	panel.anchor_right = 0.5
	panel.anchor_bottom = 0.5
	panel.offset_left = -220.0
	panel.offset_top = -80.0
	panel.offset_right = 220.0
	panel.offset_bottom = 80.0
	loading_layer.add_child(panel)

	var box := VBoxContainer.new()
	box.name = "Content"
	box.add_theme_constant_override("separation", 10)
	panel.add_child(box)

	var title := Label.new()
	title.name = "Title"
	title.text = "Loading"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(title)

	loading_status_label = Label.new()
	loading_status_label.name = "StatusLabel"
	loading_status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	loading_status_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	loading_status_label.text = "Loading..."
	box.add_child(loading_status_label)

	loading_progress_bar = ProgressBar.new()
	loading_progress_bar.name = "ProgressBar"
	loading_progress_bar.min_value = 0.0
	loading_progress_bar.max_value = 1.0
	loading_progress_bar.value = 0.0
	box.add_child(loading_progress_bar)


func _show_loading_screen(text: String) -> void:
	loading_active = true
	_set_world_draw_enabled(false)
	_set_loading_status(text)
	if loading_layer != null:
		loading_layer.visible = true
	_refresh_menu_buttons()


func _hide_loading_screen() -> void:
	loading_active = false
	if loading_layer != null:
		loading_layer.visible = false
	_refresh_menu_buttons()


func _set_loading_status(text: String) -> void:
	if loading_status_label != null:
		loading_status_label.text = text
	_set_menu_status(text)


func _set_loading_progress(ready: int, total: int) -> void:
	if loading_progress_bar == null:
		return
	loading_progress_bar.max_value = maxf(float(total), 1.0)
	loading_progress_bar.value = clampf(float(ready), 0.0, loading_progress_bar.max_value)


func _set_world_draw_enabled(enabled: bool) -> void:
	if world != null:
		world.visible = enabled
	if hud_layer != null:
		hud_layer.visible = enabled


func _finish_world_start_or_load(status_prefix: String, schedule_full_map_warmup: bool) -> void:
	_set_render_level_base()
	if camera_controller != null:
		camera_controller.setup_camera(world)
	await _prepare_world_for_reveal(status_prefix)
	if schedule_full_map_warmup:
		_schedule_background_level_warmup(_chunk_y_for_render_y(world.top_render_y))
	world_started = true
	_set_world_draw_enabled(true)
	_refresh_menu_buttons()


func _start_new_world_with_loading() -> void:
	var load_start_usec: int = Time.get_ticks_usec()
	_show_loading_screen("Starting new world...")
	await get_tree().process_frame
	world.start_new_world()
	_reset_level_loading_state()
	if generate_full_map_on_startup:
		await _prepare_full_map_arena_cook("Generating and caching full finite map")
		var save_ms: float = await _save_generated_world_after_create()
		if world != null and world.arena_cooker != null:
			world.arena_cooker.set_save_ms(save_ms)
			var diagnostics_path: String = world.arena_cooker.write_diagnostics()
			if not diagnostics_path.is_empty():
				_set_loading_status("Arena cook diagnostics saved:\n%s" % diagnostics_path)
				await get_tree().process_frame
	_set_loading_status("Preparing view...")
	await get_tree().process_frame
	await _finish_world_start_or_load("Generating startup view", generate_full_map_on_startup)
	_report_load_metrics("New world", load_start_usec)
	_hide_loading_screen()
	close_menu()


func _load_world_with_loading() -> void:
	var load_start_usec: int = Time.get_ticks_usec()
	var reveal_previous_world := world_started
	_show_loading_screen("Loading world...")
	await get_tree().process_frame
	var ok := world.load_world(SAVE_PATH)
	if not ok:
		_hide_loading_screen()
		_set_world_draw_enabled(reveal_previous_world)
		_set_menu_status("Load failed.")
		_refresh_menu_buttons()
		return
	_reset_level_loading_state()
	if generate_full_map_on_startup:
		await _prepare_full_map_block_data("Loading full finite map")
	_set_loading_status("Preparing view...")
	await get_tree().process_frame
	await _finish_world_start_or_load("Loading startup view", generate_full_map_on_startup)
	_report_load_metrics("Load world", load_start_usec)
	_hide_loading_screen()
	close_menu()


func _prepare_world_for_reveal(status_prefix: String) -> void:
	var view_rect: Rect2 = get_stream_view_rect_for_y(world.top_render_y)
	var plane_y: float = float(world.top_render_y)
	await _ensure_render_y_ready(world.top_render_y, status_prefix)
	world.update_streaming(view_rect, plane_y, 0.0)


func _ensure_render_y_ready(render_y: int, status_prefix: String) -> Dictionary:
	var startup_start_usec: int = Time.get_ticks_usec()
	var mesh_targets: Array[Vector3i] = _build_reveal_chunk_targets(render_y)
	var profile := {
		"target_chunk_y": _chunk_y_for_render_y(render_y),
		"mesh_total": mesh_targets.size(),
		"mesh_ready_before": _count_ready_startup_chunks(mesh_targets),
		"mesh_ready_after": 0,
		"generation_total": 0,
		"generation_ready_before": 0,
		"generation_ready_after": 0,
		"request_ms": 0.0,
		"generation_load_ms": 0.0,
		"mesh_wait_ms": 0.0,
		"total_blocked_ms": 0.0,
		"frames_waited": 0,
	}
	if mesh_targets.is_empty():
		_set_loading_progress(1, 1)
		profile["mesh_ready_after"] = 0
		last_startup_load_metrics = {
			"startup_request_ms": 0.0,
			"startup_generation_load_ms": 0.0,
			"startup_ready_ms": float(Time.get_ticks_usec() - startup_start_usec) / 1000.0,
		}
		last_render_y_ready_profile = profile
		return profile

	var generation_targets: Array[Vector3i] = _build_reveal_generation_targets(render_y)
	var generation_total: int = generation_targets.size()
	var mesh_total: int = mesh_targets.size()
	profile["generation_total"] = generation_total
	profile["generation_ready_before"] = _count_generated_startup_chunks(generation_targets)
	var request_start_usec: int = Time.get_ticks_usec()
	_request_startup_chunk_generation(generation_targets, false)
	var request_ms: float = float(Time.get_ticks_usec() - request_start_usec) / 1000.0
	profile["request_ms"] = request_ms
	var meshes_queued: bool = false
	var mesh_queue_index: int = 0
	var generation_load_ms: float = 0.0
	var frames_waited := 0
	while true:
		_pump_startup_loading_work()
		var ready: int = _count_ready_startup_chunks(mesh_targets)
		var generated: int = _count_generated_startup_chunks(generation_targets)
		if not meshes_queued and generated >= generation_total:
			if generation_load_ms <= 0.0:
				generation_load_ms = float(Time.get_ticks_usec() - startup_start_usec) / 1000.0
			var processed: int = 0
			while mesh_queue_index < mesh_targets.size() and processed < STARTUP_MESH_QUEUE_BUDGET:
				var coord: Vector3i = mesh_targets[mesh_queue_index]
				_queue_startup_chunk_mesh(coord, true)
				mesh_queue_index += 1
				processed += 1
			if mesh_queue_index >= mesh_targets.size():
				meshes_queued = true
		_set_loading_progress(generated + ready, generation_total + mesh_total)
		_set_loading_status(_format_startup_loading_status(status_prefix, ready, mesh_total, generated, generation_total))
		if ready >= mesh_total:
			profile["mesh_ready_after"] = ready
			profile["generation_ready_after"] = generated
			break
		frames_waited += 1
		await get_tree().process_frame
	if generation_load_ms <= 0.0:
		generation_load_ms = float(Time.get_ticks_usec() - startup_start_usec) / 1000.0
	var total_ready_ms: float = float(Time.get_ticks_usec() - startup_start_usec) / 1000.0
	profile["generation_load_ms"] = generation_load_ms
	profile["mesh_wait_ms"] = maxf(total_ready_ms - generation_load_ms, 0.0)
	profile["total_blocked_ms"] = total_ready_ms
	profile["frames_waited"] = frames_waited
	last_startup_load_metrics = {
		"startup_request_ms": request_ms,
		"startup_generation_load_ms": generation_load_ms,
		"startup_ready_ms": total_ready_ms,
	}
	last_render_y_ready_profile = profile
	return profile


func _build_reveal_chunk_targets(render_y: int) -> Array[Vector3i]:
	return _build_chunk_targets_for_bands_in_bounds(
		_build_reveal_mesh_bands(render_y),
		_build_reveal_chunk_xz_bounds(render_y, false)
	)


func _build_reveal_generation_targets(render_y: int) -> Array[Vector3i]:
	return _build_chunk_targets_for_bands_in_bounds(
		_build_generation_bands_for_mesh_bands(_build_reveal_mesh_bands(render_y)),
		_build_reveal_chunk_xz_bounds(render_y, false)
	)


func _build_directional_y_prewarm_mesh_targets(render_y: int) -> Array[Vector3i]:
	return _build_chunk_targets_for_bands_in_bounds(
		_build_reveal_mesh_bands(render_y),
		_build_reveal_chunk_xz_bounds(render_y, true)
	)


func _build_directional_y_prewarm_generation_targets(render_y: int) -> Array[Vector3i]:
	return _build_chunk_targets_for_bands_in_bounds(
		_build_generation_bands_for_mesh_bands(_build_reveal_mesh_bands(render_y)),
		_build_reveal_chunk_xz_bounds(render_y, true)
	)


func _build_reveal_mesh_bands(render_y: int) -> Array[int]:
	return _build_band_range(_chunk_y_for_render_y(render_y), STARTUP_REVEAL_BAND_RADIUS)


func _build_generation_bands_for_mesh_bands(mesh_bands: Array[int]) -> Array[int]:
	var band_set: Dictionary = {}
	var bands: Array[int] = []
	for cy_value in mesh_bands:
		var cy: int = int(cy_value)
		var min_cy: int = maxi(0, cy - STARTUP_GENERATION_NEIGHBOR_BAND_RADIUS)
		var max_cy: int = mini(World.WORLD_CHUNKS_Y - 1, cy + STARTUP_GENERATION_NEIGHBOR_BAND_RADIUS)
		for generation_cy: int in range(min_cy, max_cy + 1):
			if band_set.has(generation_cy):
				continue
			band_set[generation_cy] = true
			bands.append(generation_cy)
	return bands


func _build_band_range(center_cy: int, radius: int) -> Array[int]:
	var bands: Array[int] = []
	var min_cy: int = maxi(0, center_cy - radius)
	var max_cy: int = mini(World.WORLD_CHUNKS_Y - 1, center_cy + radius)
	for cy: int in range(min_cy, max_cy + 1):
		bands.append(cy)
	return bands


func _chunk_y_for_render_y(render_y: int) -> int:
	if world == null:
		return 0
	var clamped_y: int = clampi(render_y, 0, world.world_size_y - 1)
	return clampi(int(floor(float(clamped_y) / float(World.CHUNK_SIZE))), 0, World.WORLD_CHUNKS_Y - 1)


func _build_reveal_chunk_xz_bounds(render_y: int, include_render_buffer: bool) -> Dictionary:
	var rect: Rect2 = get_stream_view_rect_for_y(render_y)
	var chunk_size: int = World.CHUNK_SIZE
	var render_radius_chunks := 0
	var render_view_scale := 0.0
	if include_render_buffer and world != null and world.streaming != null:
		render_radius_chunks = world.streaming.render_radius_chunks
		render_view_scale = maxf(world.streaming.render_view_scale, 0.0)
	var render_pad: float = float(render_radius_chunks * chunk_size)
	var render_buffer_x: float = render_pad
	var render_buffer_z: float = render_pad
	if render_view_scale > 0.0:
		render_buffer_x = maxf(render_buffer_x, rect.size.x * render_view_scale)
		render_buffer_z = maxf(render_buffer_z, rect.size.y * render_view_scale)
	var min_cx: int = _chunk_coord_from_world_value(rect.position.x - render_buffer_x) - Y_REVEAL_READY_MARGIN_CHUNKS
	var max_cx: int = _chunk_coord_from_world_value(rect.position.x + rect.size.x + render_buffer_x) + Y_REVEAL_READY_MARGIN_CHUNKS
	var min_cz: int = _chunk_coord_from_world_value(rect.position.y - render_buffer_z) - Y_REVEAL_READY_MARGIN_CHUNKS
	var max_cz: int = _chunk_coord_from_world_value(rect.position.y + rect.size.y + render_buffer_z) + Y_REVEAL_READY_MARGIN_CHUNKS
	return {
		"min_x": clampi(min_cx, World.WORLD_MIN_CHUNK_X, World.WORLD_MAX_CHUNK_X),
		"max_x": clampi(max_cx, World.WORLD_MIN_CHUNK_X, World.WORLD_MAX_CHUNK_X),
		"min_z": clampi(min_cz, World.WORLD_MIN_CHUNK_Z, World.WORLD_MAX_CHUNK_Z),
		"max_z": clampi(max_cz, World.WORLD_MIN_CHUNK_Z, World.WORLD_MAX_CHUNK_Z),
	}


func _chunk_coord_from_world_value(value: float) -> int:
	return int(floor(value / float(World.CHUNK_SIZE)))


func _build_chunk_targets_for_bands_in_bounds(bands: Array[int], bounds: Dictionary) -> Array[Vector3i]:
	var targets: Array[Vector3i] = []
	if world == null:
		return targets
	var min_cx: int = int(bounds.get("min_x", World.WORLD_MIN_CHUNK_X))
	var max_cx: int = int(bounds.get("max_x", World.WORLD_MAX_CHUNK_X))
	var min_cz: int = int(bounds.get("min_z", World.WORLD_MIN_CHUNK_Z))
	var max_cz: int = int(bounds.get("max_z", World.WORLD_MAX_CHUNK_Z))
	if min_cx > max_cx or min_cz > max_cz:
		return targets
	for cy_value in bands:
		var cy: int = int(cy_value)
		for cx: int in range(min_cx, max_cx + 1):
			for cz: int in range(min_cz, max_cz + 1):
				var coord := Vector3i(cx, cy, cz)
				if world.is_chunk_coord_valid(coord):
					targets.append(coord)
	return targets


func _build_chunk_targets_for_bands(bands: Array[int]) -> Array[Vector3i]:
	var targets: Array[Vector3i] = []
	if world == null:
		return targets
	for cy_value in bands:
		var cy: int = int(cy_value)
		for cx: int in range(World.WORLD_MIN_CHUNK_X, World.WORLD_MAX_CHUNK_X + 1):
			for cz: int in range(World.WORLD_MIN_CHUNK_Z, World.WORLD_MAX_CHUNK_Z + 1):
				var coord := Vector3i(cx, cy, cz)
				if world.is_chunk_coord_valid(coord):
					targets.append(coord)
	return targets


func _build_all_world_chunk_targets() -> Array[Vector3i]:
	var bands: Array[int] = []
	for cy: int in range(World.WORLD_CHUNKS_Y):
		bands.append(cy)
	return _build_chunk_targets_for_bands(bands)


func _prepare_full_map_arena_cook(status_prefix: String) -> void:
	if world == null or world.arena_cooker == null:
		return
	var cooker: WorldArenaCooker = world.arena_cooker
	cooker.start_generation()
	var progress: Dictionary = cooker.get_progress()
	var total: int = int(progress.get("total", 0))
	_set_loading_progress(0, total)
	_set_loading_status(_format_arena_cook_status(status_prefix, "Generating blocks", progress))
	await get_tree().process_frame
	while not cooker.is_generation_done():
		progress = cooker.get_progress()
		_set_loading_progress(int(progress.get("done", 0)), int(progress.get("total", total)))
		_set_loading_status(_format_arena_cook_status(status_prefix, "Generating blocks", progress))
		await get_tree().process_frame
	while not cooker.is_generation_merge_done():
		cooker.merge_generation_results_step(ARENA_COOK_MERGE_BUDGET)
		progress = cooker.get_progress()
		total = maxi(int(progress.get("total", total)), 1)
		_set_loading_progress(int(progress.get("chunks_generated", 0)), total)
		_set_loading_status(_format_arena_cook_status(status_prefix, "Merging block arena", progress))
		await get_tree().process_frame
	cooker.start_mesh()
	progress = cooker.get_progress()
	_set_loading_progress(0, int(progress.get("total", total)))
	_set_loading_status(_format_arena_cook_status(status_prefix, "Building raw mesh cache", progress))
	await get_tree().process_frame
	while not cooker.is_mesh_done():
		progress = cooker.get_progress()
		_set_loading_progress(int(progress.get("done", 0)), int(progress.get("total", total)))
		_set_loading_status(_format_arena_cook_status(status_prefix, "Building raw mesh cache", progress))
		await get_tree().process_frame
	while not cooker.is_done():
		cooker.merge_mesh_results_step(ARENA_COOK_MERGE_BUDGET)
		progress = cooker.get_progress()
		total = maxi(int(progress.get("meshes_built", progress.get("total", total))), 1)
		_set_loading_progress(int(progress.get("meshes_merged", 0)), total)
		_set_loading_status(_format_arena_cook_status(status_prefix, "Merging raw mesh cache", progress))
		await get_tree().process_frame
	_set_loading_progress(1, 1)
	_set_loading_status(_format_arena_cook_status(status_prefix, "Arena cook complete", cooker.get_progress()))
	await get_tree().process_frame

func _prepare_full_map_block_data(status_prefix: String) -> void:
	var targets: Array[Vector3i] = _build_all_world_chunk_targets()
	var total: int = targets.size()
	if total <= 0:
		_set_loading_progress(1, 1)
		return
	_set_loading_progress(0, total)
	_set_loading_status(_format_full_map_loading_status(status_prefix, 0, total))
	await get_tree().process_frame
	_request_startup_chunk_generation(targets, false, false)
	var generated: int = _count_generated_startup_chunks(targets)
	while true:
		generated = mini(total, generated + _pump_startup_loading_work())
		_set_loading_progress(generated, total)
		_set_loading_status(_format_full_map_loading_status(status_prefix, generated, total))
		if generated >= total:
			break
		await get_tree().process_frame


func _prepare_full_map_mesh_cache(status_prefix: String) -> void:
	if world == null or world.renderer == null:
		return
	var targets: Array[Vector3i] = _build_all_world_chunk_targets()
	var total: int = targets.size()
	if total <= 0:
		_set_loading_progress(1, 1)
		return
	var mesh_index: int = 0
	var cached: int = _count_cached_full_mesh_chunks(targets)
	_set_loading_progress(cached, total)
	_set_loading_status(_format_full_map_mesh_cache_status(status_prefix, cached, total))
	await get_tree().process_frame
	while cached < total:
		var queued: int = 0
		while mesh_index < total and queued < STARTUP_MESH_QUEUE_BUDGET:
			var coord: Vector3i = targets[mesh_index]
			mesh_index += 1
			if _queue_startup_chunk_mesh_cache(coord, false):
				queued += 1
		world.renderer.process_mesh_results(STARTUP_MESH_RESULT_BUDGET)
		cached = _count_cached_full_mesh_chunks(targets)
		_set_loading_progress(cached, total)
		_set_loading_status(_format_full_map_mesh_cache_status(status_prefix, cached, total))
		if cached >= total:
			break
		if mesh_index >= total and not world.renderer.has_pending_mesh_work(true):
			push_warning("Full mesh cache preparation stopped early: %d/%d chunks cached." % [cached, total])
			break
		await get_tree().process_frame


func _save_generated_world_after_create() -> float:
	if world == null:
		return 0.0
	_set_loading_progress(0, 1)
	_set_loading_status("Saving generated world and mesh cache...")
	await get_tree().process_frame
	var save_start_usec: int = Time.get_ticks_usec()
	var ok := world.save_world(SAVE_PATH)
	var elapsed_ms := float(Time.get_ticks_usec() - save_start_usec) / 1000.0
	if not ok:
		push_warning("Generated world save failed.")
		_set_menu_status("Initial world save failed.")
	_set_loading_progress(1, 1)
	await get_tree().process_frame
	return elapsed_ms

func _pump_startup_loading_work() -> int:
	var generated: int = 0
	if world.generator != null:
		generated = world.generator.process_generation_results(STARTUP_GENERATION_RESULT_BUDGET)
	if world.renderer != null:
		world.renderer.process_mesh_results(STARTUP_MESH_RESULT_BUDGET)
	return generated


func _request_startup_chunk_generation(targets: Array[Vector3i], queue_mesh_on_complete: bool, high_priority: bool = true) -> void:
	if world == null:
		return
	for coord in targets:
		var chunk: ChunkData = world.ensure_chunk(coord)
		if chunk == null:
			continue
		if not chunk.generated:
			world.request_chunk_generation_async(coord, high_priority, queue_mesh_on_complete)


func _queue_startup_chunk_mesh(coord: Vector3i, high_priority: bool) -> bool:
	if world == null or world.renderer == null:
		return false
	var chunk: ChunkData = world.get_chunk(coord)
	if chunk == null or not chunk.generated:
		return false
	if chunk.mesh_state == ChunkData.MESH_STATE_READY:
		return false
	if chunk.mesh_state == ChunkData.MESH_STATE_PENDING:
		if high_priority:
			world.renderer.queue_chunk_mesh_build(coord, _chunk_full_top_y(coord), false, true)
		return false
	world.renderer.queue_chunk_mesh_build(coord, _chunk_full_top_y(coord), false, high_priority)
	return true


func _queue_startup_chunk_mesh_cache(coord: Vector3i, high_priority: bool) -> bool:
	if world == null or world.renderer == null:
		return false
	var chunk: ChunkData = world.get_chunk(coord)
	if chunk == null or not chunk.generated:
		return false
	return world.renderer.queue_chunk_mesh_cache_build(coord, World.CHUNK_SIZE - 1, high_priority)


func _chunk_full_top_y(coord: Vector3i) -> int:
	return coord.y * World.CHUNK_SIZE + World.CHUNK_SIZE - 1


func _count_cached_full_mesh_chunks(targets: Array[Vector3i]) -> int:
	if world == null or world.renderer == null:
		return 0
	var count := 0
	for coord in targets:
		var chunk: ChunkData = world.get_chunk(coord)
		if chunk != null and chunk.generated and world.renderer.has_cached_chunk_mesh(coord, World.CHUNK_SIZE - 1):
			count += 1
	return count


func _count_ready_startup_chunks(targets: Array[Vector3i]) -> int:
	var count := 0
	for coord in targets:
		var chunk: ChunkData = world.get_chunk(coord)
		if chunk != null and chunk.generated and chunk.mesh_state == ChunkData.MESH_STATE_READY:
			count += 1
	return count


func _count_generated_startup_chunks(targets: Array[Vector3i]) -> int:
	var count := 0
	for coord in targets:
		var chunk: ChunkData = world.get_chunk(coord)
		if chunk != null and chunk.generated:
			count += 1
	return count


func _is_render_y_ready(render_y: int) -> bool:
	var targets: Array[Vector3i] = _build_reveal_chunk_targets(render_y)
	return not targets.is_empty() and _count_ready_startup_chunks(targets) >= targets.size()


func _mark_prepared_bands(bands: Array[int]) -> void:
	for cy_value in bands:
		prepared_chunk_bands[int(cy_value)] = true


func _format_startup_loading_status(status_prefix: String, ready: int, mesh_total: int, generated: int, generation_total: int) -> String:
	var generation_left: int = maxi(generation_total - generated, 0)
	var draw_left: int = maxi(mesh_total - ready, 0)
	var percent := 0.0
	var total_work: int = generation_total + mesh_total
	if total_work > 0:
		percent = float(generated + ready) / float(total_work) * 100.0
	return "%s\nReady: %d / %d (%.0f%%)\nGeneration left: %d | Draw left: %d" % [
		status_prefix,
		ready,
		mesh_total,
		percent,
		generation_left,
		draw_left,
	]


func _format_arena_cook_status(status_prefix: String, phase: String, progress: Dictionary) -> String:
	var done: int = int(progress.get("done", 0))
	var total: int = int(progress.get("total", 0))
	if phase.begins_with("Merging block"):
		done = int(progress.get("chunks_generated", done))
	if phase.begins_with("Merging raw"):
		done = int(progress.get("meshes_merged", done))
		total = int(progress.get("meshes_built", total))
	var percent := 0.0
	if total > 0:
		percent = float(done) / float(total) * 100.0
	return "%s\n%s: %d / %d (%.0f%%)\nWorkers: %d | Chunks: %d | Meshes: %d" % [
		status_prefix,
		phase,
		done,
		total,
		percent,
		int(progress.get("workers", 1)),
		int(progress.get("chunks_generated", 0)),
		int(progress.get("meshes_built", 0)),
	]

func _format_full_map_loading_status(status_prefix: String, generated: int, total: int) -> String:
	var remaining: int = maxi(total - generated, 0)
	var percent := 0.0
	if total > 0:
		percent = float(generated) / float(total) * 100.0
	return "%s\nChunks ready: %d / %d (%.0f%%)\nGeneration left: %d" % [
		status_prefix,
		generated,
		total,
		percent,
		remaining,
	]


func _format_full_map_mesh_cache_status(status_prefix: String, cached: int, total: int) -> String:
	var remaining: int = maxi(total - cached, 0)
	var percent := 0.0
	if total > 0:
		percent = float(cached) / float(total) * 100.0
	return "%s\nMeshes cached: %d / %d (%.0f%%)\nMesh builds left: %d" % [
		status_prefix,
		cached,
		total,
		percent,
		remaining,
	]


func _report_load_metrics(label: String, start_usec: int) -> void:
	var total_ms: float = float(Time.get_ticks_usec() - start_usec) / 1000.0
	var save_metrics: Dictionary = {}
	if world != null and world.save_load != null:
		save_metrics = world.save_load.get_last_load_metrics()
	var renderer_metrics: Dictionary = {}
	if world != null and world.renderer != null:
		renderer_metrics = world.renderer.get_mesh_cache_metrics()
	var mesh_cache_metrics = save_metrics.get("mesh_cache", {})
	if typeof(mesh_cache_metrics) != TYPE_DICTIONARY:
		mesh_cache_metrics = {}
	var bulk_format_metrics = save_metrics.get("bulk_block_format", {})
	if typeof(bulk_format_metrics) != TYPE_DICTIONARY:
		bulk_format_metrics = {}
	var message := "%s timings: total_to_reveal=%.1fms, bulk_blocks=%.1fms, startup_ready=%.1fms, startup_chunk_load=%.1fms, mesh_cache_load=%.1fms, bulk_entries=%d fill/%d raw/%d zstd/%d, cache_entries=%d/%d imported, cache_hits=%d, cache_misses=%d, mesh_build=%.1fms, mesh_upload=%.1fms" % [
		label,
		total_ms,
		float(save_metrics.get("bulk_blocks_ms", 0.0)),
		float(last_startup_load_metrics.get("startup_ready_ms", 0.0)),
		float(last_startup_load_metrics.get("startup_generation_load_ms", 0.0)),
		float(save_metrics.get("mesh_cache_ms", 0.0)),
		int(bulk_format_metrics.get("entries", 0)),
		int(bulk_format_metrics.get("fill_entries", 0)),
		int(bulk_format_metrics.get("raw_entries", 0)),
		int(bulk_format_metrics.get("compressed_entries", 0)),
		int(mesh_cache_metrics.get("entries_imported", 0)),
		int(mesh_cache_metrics.get("entries_read", 0)),
		int(renderer_metrics.get("hits", 0)),
		int(renderer_metrics.get("misses", 0)),
		float(renderer_metrics.get("mesh_build_ms", 0.0)),
		float(renderer_metrics.get("mesh_upload_ms", 0.0)),
	]
	print(message)
	_set_menu_status(message)


func _schedule_directional_y_prewarm(delta: int, current_y: int) -> void:
	if world == null or delta == 0:
		return
	var direction: int = 1 if delta > 0 else -1
	var prewarm_y: int = clampi(
		current_y + direction * Y_DIRECTIONAL_PREWARM_BLOCKS_AHEAD,
		0,
		world.world_size_y - 1
	)
	if prewarm_y == current_y:
		_clear_directional_y_prewarm()
		return
	if prewarm_y == y_prewarm_render_y and direction == y_prewarm_direction:
		return
	y_prewarm_render_y = prewarm_y
	y_prewarm_direction = direction
	y_prewarm_generation_targets = _build_directional_y_prewarm_generation_targets(prewarm_y)
	y_prewarm_mesh_targets = _build_directional_y_prewarm_mesh_targets(prewarm_y)
	y_prewarm_mesh_index = 0
	y_prewarm_meshes_queued = false
	if y_prewarm_mesh_targets.is_empty():
		_clear_directional_y_prewarm()
		return
	_request_startup_chunk_generation(y_prewarm_generation_targets, false, false)


func _pump_directional_y_prewarm() -> void:
	if world == null or not world_started:
		return
	if y_prewarm_mesh_targets.is_empty():
		return
	if world.generator != null:
		world.generator.process_generation_results(Y_DIRECTIONAL_PREWARM_GENERATION_RESULT_BUDGET)
	if world.renderer != null:
		world.renderer.process_mesh_results(Y_DIRECTIONAL_PREWARM_MESH_RESULT_BUDGET)
	var generated: int = _count_generated_startup_chunks(y_prewarm_generation_targets)
	if generated < y_prewarm_generation_targets.size():
		return
	if not y_prewarm_meshes_queued:
		var processed: int = 0
		while y_prewarm_mesh_index < y_prewarm_mesh_targets.size() and processed < Y_DIRECTIONAL_PREWARM_MESH_QUEUE_BUDGET:
			var coord: Vector3i = y_prewarm_mesh_targets[y_prewarm_mesh_index]
			_queue_startup_chunk_mesh(coord, false)
			y_prewarm_mesh_index += 1
			processed += 1
		if y_prewarm_mesh_index >= y_prewarm_mesh_targets.size():
			y_prewarm_meshes_queued = true
	if y_prewarm_meshes_queued:
		var ready: int = _count_ready_startup_chunks(y_prewarm_mesh_targets)
		if ready >= y_prewarm_mesh_targets.size():
			_clear_directional_y_prewarm()


func _clear_directional_y_prewarm() -> void:
	y_prewarm_generation_targets.clear()
	y_prewarm_mesh_targets.clear()
	y_prewarm_mesh_index = 0
	y_prewarm_render_y = -1
	y_prewarm_direction = 0
	y_prewarm_meshes_queued = false


func _reset_level_loading_state() -> void:
	prepared_chunk_bands.clear()
	background_warmup_queue.clear()
	last_startup_load_metrics.clear()
	_clear_directional_y_prewarm()
	_clear_background_warmup_active()


func _schedule_background_level_warmup(center_cy: int) -> void:
	background_warmup_queue.clear()
	_clear_background_warmup_active()
	var seen: Dictionary = {}
	for distance: int in range(0, World.WORLD_CHUNKS_Y):
		var lower_cy: int = center_cy - distance
		var upper_cy: int = center_cy + distance
		for cy_value in [lower_cy, upper_cy]:
			var cy: int = int(cy_value)
			if cy < 0 or cy >= World.WORLD_CHUNKS_Y:
				continue
			if seen.has(cy):
				continue
			seen[cy] = true
			if prepared_chunk_bands.has(cy):
				continue
			background_warmup_queue.append(cy)


func _pump_background_level_warmup() -> void:
	if world == null or not world_started:
		return
	if background_warmup_queue.is_empty() and background_warmup_mesh_targets.is_empty():
		return
	if world.generator != null:
		world.generator.process_generation_results(BACKGROUND_WARMUP_GENERATION_RESULT_BUDGET)
	if world.renderer != null:
		world.renderer.process_mesh_results(BACKGROUND_WARMUP_MESH_RESULT_BUDGET)
	if background_warmup_mesh_targets.is_empty():
		_begin_next_background_warmup_band()
		if background_warmup_mesh_targets.is_empty():
			return
	var generated: int = _count_generated_startup_chunks(background_warmup_generation_targets)
	if generated < background_warmup_generation_targets.size():
		return
	if not background_warmup_meshes_queued:
		var processed: int = 0
		while background_warmup_mesh_index < background_warmup_mesh_targets.size() and processed < BACKGROUND_WARMUP_MESH_QUEUE_BUDGET:
			var coord: Vector3i = background_warmup_mesh_targets[background_warmup_mesh_index]
			_queue_startup_chunk_mesh(coord, false)
			background_warmup_mesh_index += 1
			processed += 1
		if background_warmup_mesh_index >= background_warmup_mesh_targets.size():
			background_warmup_meshes_queued = true
	if background_warmup_meshes_queued:
		var ready: int = _count_ready_startup_chunks(background_warmup_mesh_targets)
		if ready >= background_warmup_mesh_targets.size():
			prepared_chunk_bands[background_warmup_band] = true
			_clear_background_warmup_active()


func _begin_next_background_warmup_band() -> void:
	while not background_warmup_queue.is_empty():
		var cy: int = int(background_warmup_queue.pop_front())
		if cy < 0 or cy >= World.WORLD_CHUNKS_Y:
			continue
		if _is_chunk_band_ready(cy):
			prepared_chunk_bands[cy] = true
			continue
		var mesh_bands: Array[int] = []
		mesh_bands.append(cy)
		var generation_bands: Array[int] = _build_generation_bands_for_mesh_bands(mesh_bands)
		background_warmup_generation_targets = _build_chunk_targets_for_bands(generation_bands)
		background_warmup_mesh_targets = _build_chunk_targets_for_bands(mesh_bands)
		background_warmup_mesh_index = 0
		background_warmup_band = cy
		background_warmup_meshes_queued = false
		_request_startup_chunk_generation(background_warmup_generation_targets, false)
		return


func _clear_background_warmup_active() -> void:
	background_warmup_generation_targets.clear()
	background_warmup_mesh_targets.clear()
	background_warmup_mesh_index = 0
	background_warmup_band = -1
	background_warmup_meshes_queued = false


func _is_chunk_band_ready(cy: int) -> bool:
	var bands: Array[int] = []
	bands.append(cy)
	var targets: Array[Vector3i] = _build_chunk_targets_for_bands(bands)
	return not targets.is_empty() and _count_ready_startup_chunks(targets) >= targets.size()


func _refresh_menu_buttons() -> void:
	if loading_active:
		if resume_button != null:
			resume_button.disabled = true
		if save_button != null:
			save_button.disabled = true
		if load_button != null:
			load_button.disabled = true
		if quit_button != null:
			quit_button.disabled = true
		if full_map_generation_check_box != null:
			full_map_generation_check_box.disabled = true
		return
	var has_save := _has_save_game()
	if resume_button != null:
		resume_button.text = "Resume" if world_started else "New Game"
		resume_button.disabled = false
	if save_button != null:
		save_button.disabled = not world_started
	if load_button != null:
		load_button.disabled = not has_save
	if quit_button != null:
		quit_button.disabled = false
	if full_map_generation_check_box != null:
		full_map_generation_check_box.disabled = false
		full_map_generation_check_box.set_pressed_no_signal(generate_full_map_on_startup)


func _has_save_game() -> bool:
	return FileAccess.file_exists(_save_meta_path())


func _save_meta_path() -> String:
	return _save_world_dir().path_join(SAVE_META_FILE_NAME)


func _save_world_dir() -> String:
	var base := SAVE_PATH.get_basename()
	return SAVE_PATH if base.is_empty() else base
#endregion


#region Debug Overlay
func _setup_debug_overlay() -> void:
	debug_overlay = DebugOverlay.new()
	if hud_layer:
		debug_overlay.layer = hud_layer.layer + 1
	add_child(debug_overlay)
	debug_overlay.initialize(world, camera)
#endregion


#region HUD
func _setup_hud() -> void:
	if hud_controller != null:
		hud_controller.setup(hud_layer)
	if worker_window_controller != null:
		worker_window_controller.setup(hud_layer)


func update_hud() -> void:
	if hud_controller == null:
		return
	var info_id := -1
	var info_pos := Vector3i(-1, -1, -1)
	if selection_controller != null:
		info_id = selection_controller.info_block_id
		info_pos = selection_controller.info_block_pos
	hud_controller.update_hud(world, hud_label, info_id, info_pos)
	hud_controller.update_inventory(world)
	if worker_window_controller != null:
		worker_window_controller.update_window(world)
#endregion


func _set_render_level_base() -> void:
	if hud_controller != null:
		hud_controller.set_render_level_base(world)
