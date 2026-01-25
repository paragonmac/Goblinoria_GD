extends RefCounted
class_name MainCameraController
## Camera movement, projection helpers, and stream view calculations.

#region Constants - Camera
const MOVE_EPSILON := 0.0001
const CAMERA_OFFSET := Vector3(0.0, 60.0, 60.0)
const CAMERA_ORTHO_SIZE_MULT := 0.5
const CAMERA_ORTHO_SIZE_DEFAULT := 40.0
const CAMERA_ZOOM_MAX_MULT := 0.4
const CAM_SPEED_DEFAULT := 20.0
const CAM_FAST_MULTIPLIER_DEFAULT := 3.0
const CAM_MOUSE_SENSITIVITY_DEFAULT := 0.2
const CAM_PAN_SPEED_DEFAULT := 1.0
const CAM_ZOOM_MIN_DEFAULT := 5.0
const CAM_ZOOM_STEP_DEFAULT := 1.15
const ISO_PITCH_DEG := -35.0
const ISO_YAW_DEG := 45.0
const MOVE_VERTICAL_UNIT := 1.0
const DUMMY_FLOAT := 666.0
#endregion

#region State
var camera: Camera3D
var viewport: Viewport

var cam_speed := CAM_SPEED_DEFAULT
var cam_fast_multiplier := CAM_FAST_MULTIPLIER_DEFAULT
var cam_mouse_sensitivity := CAM_MOUSE_SENSITIVITY_DEFAULT
var cam_pan_speed := CAM_PAN_SPEED_DEFAULT
var cam_pitch := ISO_PITCH_DEG
var cam_yaw := ISO_YAW_DEG
var cam_zoom_min := CAM_ZOOM_MIN_DEFAULT
var cam_zoom_max := DUMMY_FLOAT
var cam_zoom_step := CAM_ZOOM_STEP_DEFAULT

var right_mouse_down := false
var prev_mouse_pos := Vector2.ZERO
#endregion


func initialize(camera_ref: Camera3D, viewport_ref: Viewport) -> void:
	camera = camera_ref
	viewport = viewport_ref


func reset_mouse_state() -> void:
	right_mouse_down = false
	prev_mouse_pos = Vector2.ZERO


func setup_camera(world: World) -> void:
	if camera == null:
		return
	var center := Vector3(0.0, world.top_render_y, 0.0)
	camera.position = center + CAMERA_OFFSET
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.current = true
	camera.size = CAMERA_ORTHO_SIZE_DEFAULT

	var base_radius := 8
	if world != null:
		var streaming_obj: Object = world.get("streaming") as Object
		if streaming_obj != null:
			base_radius = int(streaming_obj.get("stream_radius_base"))
	var base_span := float(base_radius * World.CHUNK_SIZE * 2 + World.CHUNK_SIZE)
	cam_zoom_max = max(CAMERA_ORTHO_SIZE_DEFAULT, base_span * CAMERA_ORTHO_SIZE_MULT * CAMERA_ZOOM_MAX_MULT)
	_apply_isometric_rotation()


func update_camera(dt: float) -> void:
	_apply_isometric_rotation()
	_update_camera_pan()
	_update_camera_keyboard_movement(dt)


func handle_zoom_input(event: InputEvent) -> void:
	if camera == null:
		return
	if not event is InputEventMouseButton:
		return

	var mouse_event := event as InputEventMouseButton
	match mouse_event.button_index:
		MOUSE_BUTTON_WHEEL_UP:
			camera.size = clamp(camera.size / cam_zoom_step, cam_zoom_min, cam_zoom_max)
		MOUSE_BUTTON_WHEEL_DOWN:
			camera.size = clamp(camera.size * cam_zoom_step, cam_zoom_min, cam_zoom_max)


func get_stream_view_rect(plane_y: float) -> Rect2:
	if viewport == null:
		return Rect2()
	var viewport_size := viewport.get_visible_rect().size
	var points: Array = [
		raycast_to_plane(Vector2(0.0, 0.0), plane_y),
		raycast_to_plane(Vector2(viewport_size.x, 0.0), plane_y),
		raycast_to_plane(Vector2(viewport_size.x, viewport_size.y), plane_y),
		raycast_to_plane(Vector2(0.0, viewport_size.y), plane_y),
	]
	var min_x: float = 1e20
	var max_x: float = -1e20
	var min_z: float = 1e20
	var max_z: float = -1e20
	for point: Vector3 in points:
		min_x = minf(min_x, point.x)
		max_x = maxf(max_x, point.x)
		min_z = minf(min_z, point.z)
		max_z = maxf(max_z, point.z)
	return Rect2(Vector2(min_x, min_z), Vector2(max_x - min_x, max_z - min_z))


func get_stream_target(plane_y: float) -> Vector3:
	var rect: Rect2 = get_stream_view_rect(plane_y)
	var center_2d: Vector2 = rect.position + rect.size * 0.5
	return Vector3(center_2d.x, plane_y, center_2d.y)


func raycast_to_plane(screen_pos: Vector2, plane_y: float) -> Vector3:
	if camera == null:
		return Vector3(0.0, plane_y, 0.0)
	var ray_origin := camera.project_ray_origin(screen_pos)
	var ray_dir := camera.project_ray_normal(screen_pos)

	if abs(ray_dir.y) < MOVE_EPSILON:
		return Vector3(ray_origin.x, plane_y, ray_origin.z)

	var t := (plane_y - ray_origin.y) / ray_dir.y
	if t < 0.0:
		return Vector3(ray_origin.x, plane_y, ray_origin.z)

	var hit := ray_origin + ray_dir * t
	return Vector3(hit.x, plane_y, hit.z)


func screen_to_plane(screen_pos: Vector2, plane_y: float) -> Variant:
	if camera == null:
		return null
	var ray_origin := camera.project_ray_origin(screen_pos)
	var ray_dir := camera.project_ray_normal(screen_pos)

	if abs(ray_dir.y) < MOVE_EPSILON:
		return null

	var t := (plane_y - ray_origin.y) / ray_dir.y
	if t < 0.0:
		return null

	return ray_origin + ray_dir * t


func _apply_isometric_rotation() -> void:
	cam_pitch = ISO_PITCH_DEG
	cam_yaw = ISO_YAW_DEG
	if camera != null:
		camera.rotation = Vector3(deg_to_rad(cam_pitch), deg_to_rad(cam_yaw), 0.0)


func _update_camera_pan() -> void:
	if viewport == null:
		return
	var down := Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT)

	if down and not right_mouse_down:
		prev_mouse_pos = viewport.get_mouse_position()

	if down:
		var mouse_pos := viewport.get_mouse_position()
		var delta := mouse_pos - prev_mouse_pos
		_apply_camera_pan(delta)
		prev_mouse_pos = mouse_pos

	right_mouse_down = down


func _apply_camera_pan(delta: Vector2) -> void:
	if viewport == null or camera == null:
		return
	var viewport_height := float(viewport.get_visible_rect().size.y)
	if viewport_height <= 0.0:
		return

	var units_per_pixel := camera.size / viewport_height
	var right := _get_camera_right_flat()
	var forward := _get_camera_forward_flat()
	var pan := (right * -delta.x + forward * delta.y) * units_per_pixel * cam_pan_speed
	camera.position += pan


func _update_camera_keyboard_movement(dt: float) -> void:
	if camera == null:
		return
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
	if camera == null:
		return Vector3.ZERO
	var forward := -camera.global_transform.basis.z
	forward.y = 0.0
	return forward.normalized() if forward.length_squared() > MOVE_EPSILON else Vector3.ZERO


func _get_camera_right_flat() -> Vector3:
	if camera == null:
		return Vector3.ZERO
	var right := camera.global_transform.basis.x
	right.y = 0.0
	return right.normalized() if right.length_squared() > MOVE_EPSILON else Vector3.ZERO
