extends Node3D
## Main game controller handling camera, input, menu, and game state.

#region Preloads
const MainCameraControllerScript = preload("res://scripts/main_camera_controller.gd")
const MainSelectionControllerScript = preload("res://scripts/main_selection_controller.gd")
const MainHudControllerScript = preload("res://scripts/main_hud_controller.gd")
#endregion

#region Constants - Engine & General
const ENGINE_MAX_FPS := 1000
#endregion

#region Constants - Save System
const SAVE_DIR := "user://saves"
const SAVE_PATH := "user://saves/world.save"
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
#endregion

#region Controllers
var camera_controller: MainCameraController
var selection_controller: MainSelectionController
var hud_controller: MainHudController
#endregion

#region Input State
var key_state: Dictionary = {}
#endregion

#region Game State
var debug_overlay: DebugOverlay
var menu_open := false
var world_started := false
var last_render_height_queued: int = 0
#endregion


#region Lifecycle
func _ready() -> void:
	Engine.max_fps = ENGINE_MAX_FPS
	_initialize_controllers()
	_setup_camera()
	_setup_hud()
	_setup_debug_overlay()
	_setup_menu()
	open_menu()


func _process(dt: float) -> void:
	_handle_global_input()
	if menu_open:
		return
	_handle_gameplay_input()
	_run_frame_updates(dt)


func _input(event: InputEvent) -> void:
	if menu_open:
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
#endregion


#region Camera Setup & Updates
func _setup_camera() -> void:
	if camera_controller != null:
		camera_controller.setup_camera(world)


func update_camera(dt: float) -> void:
	if camera_controller != null:
		camera_controller.update_camera(dt)


func get_stream_view_rect() -> Rect2:
	if camera_controller == null or world == null:
		return Rect2()
	return camera_controller.get_stream_view_rect(float(world.top_render_y))


func get_stream_target() -> Vector3:
	if camera_controller == null or world == null:
		return Vector3.ZERO
	return camera_controller.get_stream_target(float(world.top_render_y))
#endregion


#region Input Handling
func _handle_global_input() -> void:
	if is_key_just_pressed(KEY_ESCAPE):
		toggle_menu()


func _handle_gameplay_input() -> void:
	_handle_mode_selection()
	_handle_debug_keys()
	_handle_render_layer_keys()


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


func _handle_render_layer_keys() -> void:
	if is_key_just_pressed(KEY_BRACKETLEFT):
		_handle_render_layer_change(-1)
	elif is_key_just_pressed(KEY_BRACKETRIGHT):
		_handle_render_layer_change(1)


func _handle_render_layer_change(delta: int) -> void:
	if debug_overlay != null:
		debug_overlay.run_timed("World.set_top_render_y", Callable(self, "_apply_render_layer").bind(delta))
	else:
		_apply_render_layer(delta)
	_log_render_height_queue(delta)


func _apply_render_layer(delta: int) -> void:
	last_render_height_queued = world.set_top_render_y(world.top_render_y + delta)


func _log_render_height_queue(delta: int) -> void:
	if debug_overlay == null or not debug_overlay.show_debug_timings:
		return
	var direction := "down" if delta < 0 else "up"
	print("Render height %s: y=%d queued_chunks=%d" % [direction, world.top_render_y, last_render_height_queued])


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
#endregion


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
	if resume_button:
		resume_button.pressed.connect(_on_resume_pressed)
	if save_button:
		save_button.pressed.connect(_on_save_pressed)
	if load_button:
		load_button.pressed.connect(_on_load_pressed)
	if quit_button:
		quit_button.pressed.connect(_on_quit_pressed)


func toggle_menu() -> void:
	if menu_open:
		close_menu()
	else:
		open_menu()


func open_menu() -> void:
	menu_open = true
	if menu_layer:
		menu_layer.visible = true
	if menu_status_label:
		menu_status_label.text = ""
	if camera_controller != null:
		camera_controller.reset_mouse_state()
	if selection_controller != null:
		selection_controller.cancel_drag_and_clear_preview()
	elif world != null:
		world.clear_drag_preview()


func close_menu() -> void:
	menu_open = false
	if menu_layer:
		menu_layer.visible = false


func _on_resume_pressed() -> void:
	if not world_started:
		_set_menu_status("Loading...")
		await get_tree().process_frame
		world.start_new_world()
		_set_render_level_base()
		var view_rect: Rect2 = get_stream_view_rect()
		world.prewarm_render_cache(view_rect, float(world.top_render_y))
		world_started = true
	close_menu()


func _on_save_pressed() -> void:
	var result := DirAccess.make_dir_recursive_absolute(SAVE_DIR)
	if result != OK:
		_set_menu_status("Save folder error.")
		return

	var ok := world.save_world(SAVE_PATH)
	_set_menu_status("Saved." if ok else "Save failed.")


func _on_load_pressed() -> void:
	var ok := world.load_world(SAVE_PATH)
	_set_menu_status("Loaded." if ok else "Load failed.")
	if ok:
		_set_render_level_base()
		world_started = true
		close_menu()


func _on_quit_pressed() -> void:
	get_tree().quit()


func _set_menu_status(text: String) -> void:
	if menu_status_label:
		menu_status_label.text = text
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


func update_hud() -> void:
	if hud_controller == null:
		return
	var info_id := -1
	var info_pos := Vector3i(-1, -1, -1)
	if selection_controller != null:
		info_id = selection_controller.info_block_id
		info_pos = selection_controller.info_block_pos
	hud_controller.update_hud(world, hud_label, info_id, info_pos)
#endregion


func _set_render_level_base() -> void:
	if hud_controller != null:
		hud_controller.set_render_level_base(world)
