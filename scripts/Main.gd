extends Node3D

const DUMMY_FLOAT := 666.0
const ENGINE_MAX_FPS := 1000
const CAMERA_OFFSET := Vector3(0.0, 60.0, 60.0)
const CAMERA_ORTHO_SIZE_MULT := 0.5
const CAMERA_ZOOM_MAX_MULT := 0.4
const CAM_SPEED_DEFAULT := 20.0
const CAM_FAST_MULTIPLIER_DEFAULT := 3.0
const CAM_MOUSE_SENSITIVITY_DEFAULT := 0.2
const CAM_PAN_SPEED_DEFAULT := 1.0
const CAM_ZOOM_MIN_DEFAULT := 5.0
const CAM_ZOOM_STEP_DEFAULT := 1.15
const ISO_PITCH_DEG := -35.264
const ISO_YAW_DEG := 45.0
const MOVE_EPSILON := 0.0001
const CAMERA_RAYCAST_DISTANCE := 500.0
const DRAG_CLICK_THRESHOLD := 5.0
const SCREEN_CENTER_FACTOR := 0.5
const MOVE_VERTICAL_UNIT := 1.0
const PLACE_HEIGHT_OFFSET := 1.0
const ROUND_HALF := 0.5

@onready var world: World = $World
@onready var camera: Camera3D = $Camera3D
@onready var hud_label: Label = $HUD/ModeLabel
@onready var hud_layer: CanvasLayer = $HUD

var drag_start: Vector2
var is_dragging := false
var drag_plane_y: float
var prev_mouse_down := false
var key_state: Dictionary = {}
var cam_speed: float = CAM_SPEED_DEFAULT
var cam_fast_multiplier: float = CAM_FAST_MULTIPLIER_DEFAULT
var cam_mouse_sensitivity: float = CAM_MOUSE_SENSITIVITY_DEFAULT
var cam_pan_speed: float = CAM_PAN_SPEED_DEFAULT
var cam_pitch: float = ISO_PITCH_DEG
var cam_yaw: float = ISO_YAW_DEG
var cam_zoom_min: float = CAM_ZOOM_MIN_DEFAULT
var cam_zoom_max: float = DUMMY_FLOAT
var cam_zoom_step: float = CAM_ZOOM_STEP_DEFAULT
var right_mouse_down: bool = false
var prev_mouse_pos: Vector2 = Vector2.ZERO
var debug_overlay: DebugOverlay

func _ready() -> void:
	Engine.max_fps = ENGINE_MAX_FPS
	var center := Vector3(world.world_size_x / 2.0, world.top_render_y, world.world_size_z / 2.0)
	camera.position = center + CAMERA_OFFSET
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.current = true
	camera.size = float(max(world.world_size_x, world.world_size_z)) * CAMERA_ORTHO_SIZE_MULT
	cam_zoom_max = camera.size * CAMERA_ZOOM_MAX_MULT
	cam_pitch = ISO_PITCH_DEG
	cam_yaw = ISO_YAW_DEG
	camera.rotation = Vector3(deg_to_rad(cam_pitch), deg_to_rad(cam_yaw), 0.0)
	camera.size = 40.0 
	debug_overlay = DebugOverlay.new()
	if hud_layer != null:
		debug_overlay.layer = hud_layer.layer + 1
	add_child(debug_overlay)
	debug_overlay.initialize(world, camera)

func _process(dt: float) -> void:
	if is_key_just_pressed(KEY_1):
		world.player_mode = World.PlayerMode.INFORMATION
	if is_key_just_pressed(KEY_2):
		world.player_mode = World.PlayerMode.DIG
	if is_key_just_pressed(KEY_3):
		world.player_mode = World.PlayerMode.PLACE
	if is_key_just_pressed(KEY_4):
		world.player_mode = World.PlayerMode.STAIRS

	if is_key_just_pressed(KEY_F2):
		if debug_overlay != null:
			debug_overlay.toggle_profiler()
	if is_key_just_pressed(KEY_F3):
		if debug_overlay != null:
			debug_overlay.toggle_draw_burden()
	if is_key_just_pressed(KEY_F4):
		if debug_overlay != null:
			debug_overlay.toggle_debug_timings()

	if is_key_just_pressed(KEY_BRACKETLEFT):
		world.set_top_render_y(world.top_render_y - 1)
	if is_key_just_pressed(KEY_BRACKETRIGHT):
		world.set_top_render_y(world.top_render_y + 1)

	if debug_overlay != null:
		debug_overlay.run_timed("Main.update_camera", Callable(self, "update_camera").bind(dt))
		debug_overlay.run_timed("World.update_streaming", Callable(world, "update_streaming").bind(get_stream_target()))
		debug_overlay.run_timed("Main.handle_mouse", Callable(self, "handle_mouse"))
		debug_overlay.run_timed("Main.update_hover_preview", Callable(self, "update_hover_preview"))
		debug_overlay.run_timed("Main.update_hud", Callable(self, "update_hud"))
		debug_overlay.update_draw_burden()
		debug_overlay.step_world(dt)
	else:
		update_camera(dt)
		world.update_streaming(get_stream_target())
		handle_mouse()
		update_hover_preview()
		update_hud()
		world.update_world(dt)

func _input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mouse_event := event as InputEventMouseButton
		if mouse_event.button_index == MOUSE_BUTTON_WHEEL_UP:
			camera.size = clamp(camera.size / cam_zoom_step, cam_zoom_min, cam_zoom_max)
		elif mouse_event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			camera.size = clamp(camera.size * cam_zoom_step, cam_zoom_min, cam_zoom_max)

func update_camera(dt: float) -> void:
	update_camera_rotation()
	update_camera_pan()

	var move_dir := Vector3.ZERO
	var forward := -camera.global_transform.basis.z
	var right := camera.global_transform.basis.x
	forward.y = 0.0
	right.y = 0.0
	if forward.length_squared() > MOVE_EPSILON:
		forward = forward.normalized()
	if right.length_squared() > MOVE_EPSILON:
		right = right.normalized()

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

	if move_dir.length_squared() > MOVE_EPSILON:
		var speed: float = cam_speed
		if Input.is_key_pressed(KEY_SHIFT):
			speed *= cam_fast_multiplier
		camera.position += move_dir.normalized() * speed * dt

func update_camera_rotation() -> void:
	cam_pitch = ISO_PITCH_DEG
	cam_yaw = ISO_YAW_DEG
	camera.rotation = Vector3(deg_to_rad(cam_pitch), deg_to_rad(cam_yaw), 0.0)

func update_camera_pan() -> void:
	var down: bool = Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT)
	if down and not right_mouse_down:
		prev_mouse_pos = get_viewport().get_mouse_position()
	if down:
		var mouse_pos: Vector2 = get_viewport().get_mouse_position()
		var delta: Vector2 = mouse_pos - prev_mouse_pos
		var viewport_height: float = float(get_viewport().get_visible_rect().size.y)
		if viewport_height > 0.0:
			var units_per_pixel: float = camera.size / viewport_height
			var right := camera.global_transform.basis.x
			var forward := -camera.global_transform.basis.z
			right.y = 0.0
			forward.y = 0.0
			if right.length_squared() > MOVE_EPSILON:
				right = right.normalized()
			if forward.length_squared() > MOVE_EPSILON:
				forward = forward.normalized()
			var pan := (right * -delta.x + forward * delta.y) * units_per_pixel * cam_pan_speed
			camera.position += pan
		prev_mouse_pos = mouse_pos
	right_mouse_down = down

func get_stream_target() -> Vector3:
	var viewport_size: Vector2 = get_viewport().get_visible_rect().size
	var screen_center := viewport_size * SCREEN_CENTER_FACTOR
	var ray_origin := camera.project_ray_origin(screen_center)
	var ray_dir := camera.project_ray_normal(screen_center)
	if abs(ray_dir.y) < MOVE_EPSILON:
		return Vector3(ray_origin.x, world.top_render_y, ray_origin.z)
	var plane_y: float = float(world.top_render_y)
	var t := (plane_y - ray_origin.y) / ray_dir.y
	if t < 0.0:
		return Vector3(ray_origin.x, plane_y, ray_origin.z)
	var hit := ray_origin + ray_dir * t
	return Vector3(hit.x, plane_y, hit.z)

func handle_mouse() -> void:
	var mouse_down: bool = Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT)
	var just_pressed: bool = mouse_down and not prev_mouse_down
	var just_released: bool = (not mouse_down) and prev_mouse_down
	prev_mouse_down = mouse_down

	if just_pressed:
		if not is_dragging:
			drag_start = get_viewport().get_mouse_position()
			is_dragging = true
			drag_plane_y = get_drag_plane_y(drag_start)
	if just_released and is_dragging:
		var drag_end: Vector2 = get_viewport().get_mouse_position()
		var drag_rect: Dictionary = get_drag_rect(drag_start, drag_end, drag_plane_y)
		commit_selection(drag_start, drag_end, drag_rect)
		is_dragging = false
		world.clear_drag_preview()
		return

	if is_dragging:
		var drag_now: Vector2 = get_viewport().get_mouse_position()
		var drag_rect: Dictionary = get_drag_rect(drag_start, drag_now, drag_plane_y)
		world.set_drag_preview(drag_rect, world.player_mode)

func update_hover_preview() -> void:
	if is_dragging:
		return
	if world.player_mode != World.PlayerMode.STAIRS:
		world.clear_drag_preview()
		return
	var mouse_pos: Vector2 = get_viewport().get_mouse_position()
	var ray_origin := camera.project_ray_origin(mouse_pos)
	var ray_dir := camera.project_ray_normal(mouse_pos)
	var hit: Dictionary = world.raycast_block(ray_origin, ray_dir, CAMERA_RAYCAST_DISTANCE)
	if not bool(hit.get("hit", false)):
		world.clear_drag_preview()
		return
	var pos: Vector3i = hit["pos"]
	if not world.is_solid(pos.x, pos.y, pos.z):
		world.clear_drag_preview()
		return
	if world.get_block(pos.x, pos.y, pos.z) == World.STAIR_BLOCK_ID:
		world.clear_drag_preview()
		return
	var rect := {
		"min_x": pos.x,
		"max_x": pos.x,
		"min_z": pos.z,
		"max_z": pos.z,
		"y": pos.y,
	}
	world.set_drag_preview(rect, world.player_mode)

func get_drag_plane_y(screen_pos: Vector2) -> float:
	var ray_origin := camera.project_ray_origin(screen_pos)
	var ray_dir := camera.project_ray_normal(screen_pos)
	var hit: Dictionary = world.raycast_block(ray_origin, ray_dir, CAMERA_RAYCAST_DISTANCE)
	if bool(hit.get("hit", false)):
		var hit_pos: Vector3i = hit["pos"]
		var base_y: float = float(hit_pos.y)
		if world.player_mode == World.PlayerMode.PLACE:
			base_y += PLACE_HEIGHT_OFFSET
		return base_y
	return float(world.top_render_y)

func get_drag_rect(start: Vector2, end: Vector2, plane_y: float) -> Dictionary:
	var a: Variant = screen_to_plane(start, plane_y)
	var b: Variant = screen_to_plane(end, plane_y)
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

func screen_to_plane(screen_pos: Vector2, plane_y: float) -> Variant:
	var ray_origin := camera.project_ray_origin(screen_pos)
	var ray_dir := camera.project_ray_normal(screen_pos)
	if abs(ray_dir.y) < MOVE_EPSILON:
		return null
	var t := (plane_y - ray_origin.y) / ray_dir.y
	if t < 0:
		return null
	return ray_origin + ray_dir * t

func commit_selection(start: Vector2, end: Vector2, rect: Dictionary) -> void:
	var dx: float = abs(end.x - start.x)
	var dy: float = abs(end.y - start.y)
	var is_click: bool = dx < DRAG_CLICK_THRESHOLD and dy < DRAG_CLICK_THRESHOLD

	if is_click:
		handle_click(start)
		return

	if rect.is_empty():
		return

	var min_x: int = int(floor(float(rect["min_x"]) + ROUND_HALF))
	var max_x: int = int(floor(float(rect["max_x"]) + ROUND_HALF))
	var min_z: int = int(floor(float(rect["min_z"]) + ROUND_HALF))
	var max_z: int = int(floor(float(rect["max_z"]) + ROUND_HALF))
	var y: int = int(rect["y"])

	for x in range(min_x, max_x + 1):
		for z in range(min_z, max_z + 1):
			enqueue_task_at(x, y, z)

func handle_click(screen_pos: Vector2) -> void:
	var ray_origin := camera.project_ray_origin(screen_pos)
	var ray_dir := camera.project_ray_normal(screen_pos)
	var hit: Dictionary = world.raycast_block(ray_origin, ray_dir, CAMERA_RAYCAST_DISTANCE)
	if not bool(hit.get("hit", false)):
		return

	var pos: Vector3i = hit["pos"]
	if world.player_mode == World.PlayerMode.PLACE:
		pos.y += 1

	enqueue_task_at(pos.x, pos.y, pos.z)

func enqueue_task_at(x: int, y: int, z: int) -> void:
	if x < 0 or y < 0 or z < 0:
		return
	if x >= world.world_size_x or y >= world.world_size_y or z >= world.world_size_z:
		return

	match world.player_mode:
		World.PlayerMode.DIG:
			if world.is_solid(x, y, z):
				world.queue_task_request(TaskQueue.TaskType.DIG, Vector3i(x, y, z), 0)
		World.PlayerMode.PLACE:
			if not world.is_solid(x, y, z):
				world.queue_task_request(TaskQueue.TaskType.PLACE, Vector3i(x, y, z), 8)
		World.PlayerMode.STAIRS:
			if world.is_solid(x, y, z) and world.get_block(x, y, z) != World.STAIR_BLOCK_ID:
				world.queue_task_request(TaskQueue.TaskType.STAIRS, Vector3i(x, y, z), World.STAIR_BLOCK_ID)
		_:
			pass

func update_hud() -> void:
	var mode_name: String = "?"
	match world.player_mode:
		World.PlayerMode.INFORMATION:
			mode_name = "Info"
		World.PlayerMode.DIG:
			mode_name = "Dig"
		World.PlayerMode.PLACE:
			mode_name = "Place"
		World.PlayerMode.STAIRS:
			mode_name = "Stairs"
	hud_label.text = "Mode: %s | Tasks: %d" % [mode_name, world.task_queue.active_count()]

func is_key_just_pressed(keycode: int) -> bool:
	var down: bool = Input.is_key_pressed(keycode)
	var was_down: bool = bool(key_state.get(keycode, false))
	key_state[keycode] = down
	return down and not was_down
