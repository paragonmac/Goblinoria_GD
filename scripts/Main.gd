extends Node3D
## Main game controller handling camera, input, menu, and game state.

#region Constants - Engine & General
const ENGINE_MAX_FPS := 1000
const MOVE_EPSILON := 0.0001
const SCREEN_CENTER_FACTOR := 0.5
const DRAG_CLICK_THRESHOLD := 5.0
const ROUND_HALF := 0.5
const DUMMY_FLOAT := 666.0
#endregion

#region Constants - Camera
const CAMERA_OFFSET := Vector3(0.0, 60.0, 60.0)
const CAMERA_ORTHO_SIZE_MULT := 0.5
const CAMERA_ORTHO_SIZE_DEFAULT := 40.0
const CAMERA_ZOOM_MAX_MULT := 0.4
const CAMERA_RAYCAST_DISTANCE := 500.0
const CAM_SPEED_DEFAULT := 20.0
const CAM_FAST_MULTIPLIER_DEFAULT := 3.0
const CAM_MOUSE_SENSITIVITY_DEFAULT := 0.2
const CAM_PAN_SPEED_DEFAULT := 1.0
const CAM_ZOOM_MIN_DEFAULT := 5.0
const CAM_ZOOM_STEP_DEFAULT := 1.15
const ISO_PITCH_DEG := -35.264
const ISO_YAW_DEG := 45.0
const MOVE_VERTICAL_UNIT := 1.0
const PLACE_HEIGHT_OFFSET := 1.0
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

#region Camera State
var cam_speed := CAM_SPEED_DEFAULT
var cam_fast_multiplier := CAM_FAST_MULTIPLIER_DEFAULT
var cam_mouse_sensitivity := CAM_MOUSE_SENSITIVITY_DEFAULT
var cam_pan_speed := CAM_PAN_SPEED_DEFAULT
var cam_pitch := ISO_PITCH_DEG
var cam_yaw := ISO_YAW_DEG
var cam_zoom_min := CAM_ZOOM_MIN_DEFAULT
var cam_zoom_max := DUMMY_FLOAT
var cam_zoom_step := CAM_ZOOM_STEP_DEFAULT
#endregion

#region Input State
var key_state: Dictionary = {}
var prev_mouse_down := false
var right_mouse_down := false
var prev_mouse_pos := Vector2.ZERO
#endregion

#region Drag State
var is_dragging := false
var drag_start: Vector2
var drag_plane_y: float
#endregion

#region Game State
var debug_overlay: DebugOverlay
var info_block_id: int = -1
var info_block_pos := Vector3i(-1, -1, -1)
var menu_open := false
var world_started := false
#endregion


#region Lifecycle
func _ready() -> void:
	Engine.max_fps = ENGINE_MAX_FPS
	_setup_camera()
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


#region Camera Setup & Updates
func _setup_camera() -> void:
	var center := Vector3(
		world.world_size_x / 2.0,
		world.top_render_y,
		world.world_size_z / 2.0
	)
	camera.position = center + CAMERA_OFFSET
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.current = true
	camera.size = CAMERA_ORTHO_SIZE_DEFAULT
	cam_zoom_max = float(max(world.world_size_x, world.world_size_z)) * CAMERA_ORTHO_SIZE_MULT * CAMERA_ZOOM_MAX_MULT
	_apply_isometric_rotation()


func _apply_isometric_rotation() -> void:
	cam_pitch = ISO_PITCH_DEG
	cam_yaw = ISO_YAW_DEG
	camera.rotation = Vector3(deg_to_rad(cam_pitch), deg_to_rad(cam_yaw), 0.0)


func update_camera(dt: float) -> void:
	_apply_isometric_rotation()
	_update_camera_pan()
	_update_camera_keyboard_movement(dt)


func _update_camera_pan() -> void:
	var down := Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT)

	if down and not right_mouse_down:
		prev_mouse_pos = get_viewport().get_mouse_position()

	if down:
		var mouse_pos := get_viewport().get_mouse_position()
		var delta := mouse_pos - prev_mouse_pos
		_apply_camera_pan(delta)
		prev_mouse_pos = mouse_pos

	right_mouse_down = down


func _apply_camera_pan(delta: Vector2) -> void:
	var viewport_height := float(get_viewport().get_visible_rect().size.y)
	if viewport_height <= 0.0:
		return

	var units_per_pixel := camera.size / viewport_height
	var right := _get_camera_right_flat()
	var forward := _get_camera_forward_flat()
	var pan := (right * -delta.x + forward * delta.y) * units_per_pixel * cam_pan_speed
	camera.position += pan


func _update_camera_keyboard_movement(dt: float) -> void:
	var move_dir := _get_keyboard_movement_direction()
	if move_dir.length_squared() <= MOVE_EPSILON:
		return

	var speed := cam_speed
	if Input.is_key_pressed(KEY_SHIFT):
		speed *= cam_fast_multiplier
	camera.position += move_dir.normalized() * speed * dt


func _get_keyboard_movement_direction() -> Vector3:
	var move_dir := Vector3.ZERO
	var forward := _get_camera_forward_flat()
	var right := _get_camera_right_flat()

	if Input.is_key_pressed(KEY_E) or Input.is_key_pressed(KEY_UP):
		move_dir += forward
	if Input.is_key_pressed(KEY_D) or Input.is_key_pressed(KEY_DOWN):
		move_dir -= forward
	if Input.is_key_pressed(KEY_F) or Input.is_key_pressed(KEY_RIGHT):
		move_dir += right
	if Input.is_key_pressed(KEY_S) or Input.is_key_pressed(KEY_LEFT):
		move_dir -= right
	if Input.is_key_pressed(KEY_R) or Input.is_key_pressed(KEY_PAGEUP):
		move_dir.y += MOVE_VERTICAL_UNIT
	if Input.is_key_pressed(KEY_Q) or Input.is_key_pressed(KEY_PAGEDOWN):
		move_dir.y -= MOVE_VERTICAL_UNIT

	return move_dir


func _get_camera_forward_flat() -> Vector3:
	var forward := -camera.global_transform.basis.z
	forward.y = 0.0
	return forward.normalized() if forward.length_squared() > MOVE_EPSILON else Vector3.ZERO


func _get_camera_right_flat() -> Vector3:
	var right := camera.global_transform.basis.x
	right.y = 0.0
	return right.normalized() if right.length_squared() > MOVE_EPSILON else Vector3.ZERO


func get_stream_target() -> Vector3:
	var screen_center := get_viewport().get_visible_rect().size * SCREEN_CENTER_FACTOR
	return _raycast_to_plane(screen_center, float(world.top_render_y))
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


func _handle_render_layer_keys() -> void:
	if is_key_just_pressed(KEY_BRACKETLEFT):
		world.set_top_render_y(world.top_render_y - 1)
	elif is_key_just_pressed(KEY_BRACKETRIGHT):
		world.set_top_render_y(world.top_render_y + 1)


func _handle_zoom_input(event: InputEvent) -> void:
	if not event is InputEventMouseButton:
		return

	var mouse_event := event as InputEventMouseButton
	match mouse_event.button_index:
		MOUSE_BUTTON_WHEEL_UP:
			camera.size = clamp(camera.size / cam_zoom_step, cam_zoom_min, cam_zoom_max)
		MOUSE_BUTTON_WHEEL_DOWN:
			camera.size = clamp(camera.size * cam_zoom_step, cam_zoom_min, cam_zoom_max)


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
	debug_overlay.run_timed("World.update_streaming", Callable(world, "update_streaming").bind(get_stream_target(), dt))
	debug_overlay.run_timed("Main.handle_mouse", Callable(self, "handle_mouse"))
	debug_overlay.run_timed("Main.update_hover_preview", Callable(self, "update_hover_preview"))
	debug_overlay.run_timed("Main.update_info_hover", Callable(self, "update_info_hover"))
	debug_overlay.run_timed("Main.update_hud", Callable(self, "update_hud"))
	debug_overlay.update_draw_burden()
	debug_overlay.step_world(dt)


func _run_direct_updates(dt: float) -> void:
	update_camera(dt)
	world.update_streaming(get_stream_target(), dt)
	handle_mouse()
	update_hover_preview()
	update_info_hover()
	update_hud()
	world.update_world(dt)
#endregion


#region Mouse Interaction
func handle_mouse() -> void:
	var mouse_down := Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT)
	var just_pressed := mouse_down and not prev_mouse_down
	var just_released := not mouse_down and prev_mouse_down
	prev_mouse_down = mouse_down

	if just_pressed and not is_dragging:
		_start_drag()

	if just_released and is_dragging:
		_end_drag()
		return

	if is_dragging:
		_update_drag_preview()


func _start_drag() -> void:
	drag_start = get_viewport().get_mouse_position()
	is_dragging = true
	drag_plane_y = _get_drag_plane_y(drag_start)


func _end_drag() -> void:
	var drag_end := get_viewport().get_mouse_position()
	var drag_rect := _get_drag_rect(drag_start, drag_end, drag_plane_y)
	_commit_selection(drag_start, drag_end, drag_rect)
	is_dragging = false
	world.clear_drag_preview()


func _update_drag_preview() -> void:
	var drag_now := get_viewport().get_mouse_position()
	var drag_rect := _get_drag_rect(drag_start, drag_now, drag_plane_y)
	world.set_drag_preview(drag_rect, world.player_mode)


func update_hover_preview() -> void:
	if is_dragging:
		return
	if world.player_mode != World.PlayerMode.STAIRS:
		world.clear_drag_preview()
		return

	var hit := _raycast_block_at_mouse()
	if not hit.get("hit", false):
		world.clear_drag_preview()
		return

	var pos: Vector3i = hit["pos"]
	if not world.can_place_stairs_at(pos.x, pos.y, pos.z):
		world.clear_drag_preview()
		return

	var rect := {"min_x": pos.x, "max_x": pos.x, "min_z": pos.z, "max_z": pos.z, "y": pos.y}
	world.set_drag_preview(rect, world.player_mode)


func update_info_hover() -> void:
	if world.player_mode != World.PlayerMode.INFORMATION:
		info_block_id = -1
		return

	var hit := _raycast_block_at_mouse()
	if not hit.get("hit", false):
		info_block_id = -1
		return

	var pos: Vector3i = hit["pos"]
	info_block_id = world.get_block(pos.x, pos.y, pos.z)
	info_block_pos = pos
#endregion


#region Raycast Utilities
func _raycast_block_at_mouse() -> Dictionary:
	var mouse_pos := get_viewport().get_mouse_position()
	var ray_origin := camera.project_ray_origin(mouse_pos)
	var ray_dir := camera.project_ray_normal(mouse_pos)
	return world.raycast_block(ray_origin, ray_dir, CAMERA_RAYCAST_DISTANCE)


func _raycast_to_plane(screen_pos: Vector2, plane_y: float) -> Vector3:
	var ray_origin := camera.project_ray_origin(screen_pos)
	var ray_dir := camera.project_ray_normal(screen_pos)

	if abs(ray_dir.y) < MOVE_EPSILON:
		return Vector3(ray_origin.x, plane_y, ray_origin.z)

	var t := (plane_y - ray_origin.y) / ray_dir.y
	if t < 0.0:
		return Vector3(ray_origin.x, plane_y, ray_origin.z)

	var hit := ray_origin + ray_dir * t
	return Vector3(hit.x, plane_y, hit.z)


func _screen_to_plane(screen_pos: Vector2, plane_y: float) -> Variant:
	var ray_origin := camera.project_ray_origin(screen_pos)
	var ray_dir := camera.project_ray_normal(screen_pos)

	if abs(ray_dir.y) < MOVE_EPSILON:
		return null

	var t := (plane_y - ray_origin.y) / ray_dir.y
	if t < 0:
		return null

	return ray_origin + ray_dir * t


func _get_drag_plane_y(screen_pos: Vector2) -> float:
	var ray_origin := camera.project_ray_origin(screen_pos)
	var ray_dir := camera.project_ray_normal(screen_pos)
	var hit := world.raycast_block(ray_origin, ray_dir, CAMERA_RAYCAST_DISTANCE)

	if hit.get("hit", false):
		var hit_pos: Vector3i = hit["pos"]
		var base_y := float(hit_pos.y)
		if world.player_mode == World.PlayerMode.PLACE:
			base_y += PLACE_HEIGHT_OFFSET
		return base_y

	return float(world.top_render_y)


func _get_drag_rect(start: Vector2, end: Vector2, plane_y: float) -> Dictionary:
	var a: Variant = _screen_to_plane(start, plane_y)
	var b: Variant = _screen_to_plane(end, plane_y)

	if a == null or b == null:
		return {}

	var a_pos: Vector3 = a
	var b_pos: Vector3 = b
	return {
		"min_x": min(a_pos.x, b_pos.x),
		"max_x": max(a_pos.x, b_pos.x),
		"min_z": min(a_pos.z, b_pos.z),
		"max_z": max(a_pos.z, b_pos.z),
		"y": plane_y,
	}
#endregion


#region Selection & Tasks
func _commit_selection(start: Vector2, end: Vector2, rect: Dictionary) -> void:
	var is_click := _is_click(start, end)

	if is_click:
		_handle_click(start)
		return

	if rect.is_empty():
		return

	_enqueue_rect_tasks(rect)


func _is_click(start: Vector2, end: Vector2) -> bool:
	return abs(end.x - start.x) < DRAG_CLICK_THRESHOLD and abs(end.y - start.y) < DRAG_CLICK_THRESHOLD


func _enqueue_rect_tasks(rect: Dictionary) -> void:
	var min_x := int(floor(float(rect["min_x"]) + ROUND_HALF))
	var max_x := int(floor(float(rect["max_x"]) + ROUND_HALF))
	var min_z := int(floor(float(rect["min_z"]) + ROUND_HALF))
	var max_z := int(floor(float(rect["max_z"]) + ROUND_HALF))
	var y := int(rect["y"])

	for x in range(min_x, max_x + 1):
		for z in range(min_z, max_z + 1):
			_enqueue_task_at(x, y, z)


func _handle_click(screen_pos: Vector2) -> void:
	var ray_origin := camera.project_ray_origin(screen_pos)
	var ray_dir := camera.project_ray_normal(screen_pos)
	var hit := world.raycast_block(ray_origin, ray_dir, CAMERA_RAYCAST_DISTANCE)

	if not hit.get("hit", false):
		return

	var pos: Vector3i = hit["pos"]
	if world.player_mode == World.PlayerMode.PLACE:
		pos.y += 1

	_enqueue_task_at(pos.x, pos.y, pos.z)


func _enqueue_task_at(x: int, y: int, z: int) -> void:
	if not _is_valid_position(x, y, z):
		return

	match world.player_mode:
		World.PlayerMode.DIG:
			if world.is_diggable_at(x, y, z):
				world.queue_task_request(TaskQueue.TaskType.DIG, Vector3i(x, y, z), 0)
		World.PlayerMode.PLACE:
			if world.is_empty(x, y, z):
				world.queue_task_request(TaskQueue.TaskType.PLACE, Vector3i(x, y, z), 8)
		World.PlayerMode.STAIRS:
			if world.can_place_stairs_at(x, y, z):
				world.queue_task_request(TaskQueue.TaskType.STAIRS, Vector3i(x, y, z), World.STAIR_BLOCK_ID)


func _is_valid_position(x: int, y: int, z: int) -> bool:
	return x >= 0 and y >= 0 and z >= 0 \
		and x < world.world_size_x \
		and y < world.world_size_y \
		and z < world.world_size_z
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
	is_dragging = false
	world.clear_drag_preview()


func close_menu() -> void:
	menu_open = false
	if menu_layer:
		menu_layer.visible = false


func _on_resume_pressed() -> void:
	if not world_started:
		_set_menu_status("Loading...")
		world.start_new_world()
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
func update_hud() -> void:
	var mode_name := _get_mode_display_name()
	var info_text := _get_info_display_text()
	var task_count := world.task_queue.active_count()
	hud_label.text = "Mode: %s%s | Tasks: %d" % [mode_name, info_text, task_count]


func _get_mode_display_name() -> String:
	match world.player_mode:
		World.PlayerMode.INFORMATION:
			return "Info"
		World.PlayerMode.DIG:
			return "Dig"
		World.PlayerMode.PLACE:
			return "Place"
		World.PlayerMode.STAIRS:
			return "Stairs"
		_:
			return "?"


func _get_info_display_text() -> String:
	if world.player_mode != World.PlayerMode.INFORMATION or info_block_id < 0:
		return ""

	var block_name := world.get_block_name(info_block_id)
	return " | %s (%d) @ %d,%d,%d" % [
		block_name,
		info_block_id,
		info_block_pos.x,
		info_block_pos.y,
		info_block_pos.z,
	]
#endregion
