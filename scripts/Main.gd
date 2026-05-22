extends Node3D
## Main game controller handling camera, input, menu, and game state.

#region Preloads
const MainCameraControllerScript = preload("res://scripts/main_camera_controller.gd")
const MainSelectionControllerScript = preload("res://scripts/main_selection_controller.gd")
const MainHudControllerScript = preload("res://scripts/main_hud_controller.gd")
const MainWorkerWindowControllerScript = preload("res://scripts/main_worker_window_controller.gd")
const MainLoadingControllerScript = preload("res://scripts/main_loading_controller.gd")
const MainRenderLevelControllerScript = preload("res://scripts/main_render_level_controller.gd")
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
var loading_controller: MainLoadingController
var render_level_controller: MainRenderLevelController
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
	loading_controller = MainLoadingControllerScript.new()
	render_level_controller = MainRenderLevelControllerScript.new()
	render_level_controller.initialize(self, world)
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
	if render_level_controller == null:
		return
	render_level_controller.update_world(world)
	render_level_controller.handle_render_layer_change(delta)

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
	if loading_controller == null:
		return
	loading_controller.initialize(self, world, hud_layer, menu_layer)
	loading_controller.setup_loading_screen()
	loading_layer = loading_controller.loading_layer
	loading_status_label = loading_controller.loading_status_label
	loading_progress_bar = loading_controller.loading_progress_bar


func _show_loading_screen(text: String) -> void:
	loading_active = true
	if loading_controller != null:
		loading_controller.show(text)
	else:
		_set_world_draw_enabled(false)
		if loading_status_label != null:
			loading_status_label.text = text
		if loading_layer != null:
			loading_layer.visible = true
	_set_menu_status(text)
	_refresh_menu_buttons()


func _hide_loading_screen() -> void:
	loading_active = false
	if loading_controller != null:
		loading_controller.hide()
	elif loading_layer != null:
		loading_layer.visible = false
	_refresh_menu_buttons()


func _set_loading_status(text: String) -> void:
	if loading_controller != null:
		loading_controller.set_status(text)
	elif loading_status_label != null:
		loading_status_label.text = text
	_set_menu_status(text)


func _set_loading_progress(ready: int, total: int) -> void:
	if loading_controller != null:
		loading_controller.set_progress(ready, total)
		return
	if loading_progress_bar == null:
		return
	loading_progress_bar.max_value = maxf(float(total), 1.0)
	loading_progress_bar.value = clampf(float(ready), 0.0, loading_progress_bar.max_value)


func _set_world_draw_enabled(enabled: bool) -> void:
	if loading_controller != null:
		loading_controller.set_world_draw_enabled(enabled)
		return
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


func _empty_chunk_target_array() -> Array[Vector3i]:
	var empty: Array[Vector3i] = []
	return empty


func _empty_int_array() -> Array[int]:
	var empty: Array[int] = []
	return empty

func _prepare_world_for_reveal(status_prefix: String) -> void:
	if render_level_controller == null:
		return
	render_level_controller.update_world(world)
	await render_level_controller.prepare_world_for_reveal(status_prefix)


func _ensure_render_y_ready(render_y: int, status_prefix: String) -> Dictionary:
	if render_level_controller == null:
		return {}
	render_level_controller.update_world(world)
	return await render_level_controller._ensure_render_y_ready(render_y, status_prefix)


func _build_reveal_chunk_targets(render_y: int) -> Array[Vector3i]:
	if render_level_controller == null:
		return _empty_chunk_target_array()
	return render_level_controller._build_reveal_chunk_targets(render_y)


func _build_reveal_generation_targets(render_y: int) -> Array[Vector3i]:
	if render_level_controller == null:
		return _empty_chunk_target_array()
	return render_level_controller._build_reveal_generation_targets(render_y)


func _build_directional_y_prewarm_mesh_targets(render_y: int) -> Array[Vector3i]:
	if render_level_controller == null:
		return _empty_chunk_target_array()
	return render_level_controller._build_directional_y_prewarm_mesh_targets(render_y)


func _build_directional_y_prewarm_generation_targets(render_y: int) -> Array[Vector3i]:
	if render_level_controller == null:
		return _empty_chunk_target_array()
	return render_level_controller._build_directional_y_prewarm_generation_targets(render_y)


func _build_reveal_mesh_bands(render_y: int) -> Array[int]:
	if render_level_controller == null:
		return _empty_int_array()
	return render_level_controller._build_reveal_mesh_bands(render_y)


func _build_generation_bands_for_mesh_bands(mesh_bands: Array[int]) -> Array[int]:
	if render_level_controller == null:
		return _empty_int_array()
	return render_level_controller._build_generation_bands_for_mesh_bands(mesh_bands)


func _build_band_range(center_cy: int, radius: int) -> Array[int]:
	if render_level_controller == null:
		return _empty_int_array()
	return render_level_controller._build_band_range(center_cy, radius)


func _chunk_y_for_render_y(render_y: int) -> int:
	if render_level_controller == null:
		return 0
	return render_level_controller._chunk_y_for_render_y(render_y)


func _build_reveal_chunk_xz_bounds(render_y: int, include_render_buffer: bool) -> Dictionary:
	if render_level_controller == null:
		return {}
	return render_level_controller._build_reveal_chunk_xz_bounds(render_y, include_render_buffer)


func _chunk_coord_from_world_value(value: float) -> int:
	if render_level_controller == null:
		return 0
	return render_level_controller._chunk_coord_from_world_value(value)


func _build_chunk_targets_for_bands_in_bounds(bands: Array[int], bounds: Dictionary) -> Array[Vector3i]:
	if render_level_controller == null:
		return _empty_chunk_target_array()
	return render_level_controller._build_chunk_targets_for_bands_in_bounds(bands, bounds)


func _build_chunk_targets_for_bands(bands: Array[int]) -> Array[Vector3i]:
	if render_level_controller == null:
		return _empty_chunk_target_array()
	return render_level_controller._build_chunk_targets_for_bands(bands)


func _build_all_world_chunk_targets() -> Array[Vector3i]:
	if render_level_controller == null:
		return _empty_chunk_target_array()
	return render_level_controller._build_all_world_chunk_targets()

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
	if render_level_controller == null:
		return 0
	return render_level_controller._pump_startup_loading_work()


func _request_startup_chunk_generation(targets: Array[Vector3i], queue_mesh_on_complete: bool, high_priority: bool = true) -> void:
	if render_level_controller != null:
		render_level_controller._request_startup_chunk_generation(targets, queue_mesh_on_complete, high_priority)


func _queue_startup_chunk_mesh(coord: Vector3i, high_priority: bool) -> bool:
	if render_level_controller == null:
		return false
	return render_level_controller._queue_startup_chunk_mesh(coord, high_priority)


func _queue_startup_chunk_mesh_cache(coord: Vector3i, high_priority: bool) -> bool:
	if render_level_controller == null:
		return false
	return render_level_controller._queue_startup_chunk_mesh_cache(coord, high_priority)


func _chunk_full_top_y(coord: Vector3i) -> int:
	if render_level_controller == null:
		return coord.y * World.CHUNK_SIZE + World.CHUNK_SIZE - 1
	return render_level_controller._chunk_full_top_y(coord)


func _count_cached_full_mesh_chunks(targets: Array[Vector3i]) -> int:
	if render_level_controller == null:
		return 0
	return render_level_controller._count_cached_full_mesh_chunks(targets)


func _count_ready_startup_chunks(targets: Array[Vector3i]) -> int:
	if render_level_controller == null:
		return 0
	return render_level_controller._count_ready_startup_chunks(targets)


func _count_generated_startup_chunks(targets: Array[Vector3i]) -> int:
	if render_level_controller == null:
		return 0
	return render_level_controller._count_generated_startup_chunks(targets)


func _is_render_y_ready(render_y: int) -> bool:
	if render_level_controller == null:
		return false
	return render_level_controller._is_render_y_ready(render_y)


func _mark_prepared_bands(bands: Array[int]) -> void:
	if render_level_controller != null:
		render_level_controller._mark_prepared_bands(bands)

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
	var startup_metrics: Dictionary = {}
	if render_level_controller != null:
		startup_metrics = render_level_controller.get_last_startup_load_metrics()
	var message := "%s timings: total_to_reveal=%.1fms, bulk_blocks=%.1fms, startup_ready=%.1fms, startup_chunk_load=%.1fms, mesh_cache_load=%.1fms, bulk_entries=%d fill/%d raw/%d zstd/%d, cache_entries=%d/%d imported, cache_hits=%d, cache_misses=%d, mesh_build=%.1fms, mesh_upload=%.1fms" % [
		label,
		total_ms,
		float(save_metrics.get("bulk_blocks_ms", 0.0)),
		float(startup_metrics.get("startup_ready_ms", 0.0)),
		float(startup_metrics.get("startup_generation_load_ms", 0.0)),
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
	if render_level_controller != null:
		render_level_controller._schedule_directional_y_prewarm(delta, current_y)


func _pump_directional_y_prewarm() -> void:
	if render_level_controller != null:
		render_level_controller._pump_directional_y_prewarm(world_started)


func _clear_directional_y_prewarm() -> void:
	if render_level_controller != null:
		render_level_controller._clear_directional_y_prewarm()


func _reset_level_loading_state() -> void:
	if render_level_controller != null:
		render_level_controller._reset_level_loading_state()


func _schedule_background_level_warmup(center_cy: int) -> void:
	if render_level_controller != null:
		render_level_controller._schedule_background_level_warmup(center_cy)


func _pump_background_level_warmup() -> void:
	if render_level_controller != null:
		render_level_controller._pump_background_level_warmup(world_started)


func _clear_background_warmup_active() -> void:
	if render_level_controller != null:
		render_level_controller._clear_background_warmup_active()


func _is_chunk_band_ready(cy: int) -> bool:
	if render_level_controller == null:
		return false
	return render_level_controller._is_chunk_band_ready(cy)

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
