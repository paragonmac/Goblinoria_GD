extends Node3D

@onready var world: World = $World
@onready var camera: Camera3D = $Camera3D
@onready var hud_label: Label = $HUD/ModeLabel
@onready var hud_layer: CanvasLayer = $HUD

var drag_start: Vector2
var is_dragging := false
var drag_plane_y: float
var prev_mouse_down := false
var key_state: Dictionary = {}
var cam_speed: float = 20.0
var cam_fast_multiplier: float = 3.0
var cam_mouse_sensitivity: float = 0.2
var cam_pitch: float = -30.0
var cam_yaw: float = 45.0
var right_mouse_down: bool = false
var prev_mouse_pos: Vector2 = Vector2.ZERO
var show_profiler: bool = false
var profiler_label: Label
var profiler_samples: Array = []
var profiler_window_sec: float = 3.0

func _ready() -> void:
	var center := Vector3(world.world_size_x / 2.0, world.top_render_y, world.world_size_z / 2.0)
	camera.position = center + Vector3(0, 60, 60)
	camera.look_at(center, Vector3.UP)
	var rot := camera.rotation
	cam_pitch = rad_to_deg(rot.x)
	cam_yaw = rad_to_deg(rot.y)
	setup_profiler_label()

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
		show_profiler = not show_profiler
		if profiler_label != null:
			profiler_label.visible = show_profiler
		if show_profiler:
			profiler_samples.clear()

	if is_key_just_pressed(KEY_BRACKETLEFT):
		world.set_top_render_y(world.top_render_y - 1)
	if is_key_just_pressed(KEY_BRACKETRIGHT):
		world.set_top_render_y(world.top_render_y + 1)

	update_camera(dt)
	handle_mouse()
	update_hud()
	update_profiler(dt)
	world.update_world(dt)

func update_camera(dt: float) -> void:
	update_camera_rotation()

	var move_dir := Vector3.ZERO
	var forward := -camera.global_transform.basis.z
	var right := camera.global_transform.basis.x
	forward.y = 0.0
	right.y = 0.0
	if forward.length_squared() > 0.0001:
		forward = forward.normalized()
	if right.length_squared() > 0.0001:
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
		move_dir.y += 1.0
	if Input.is_key_pressed(KEY_Q) or Input.is_key_pressed(KEY_PAGEDOWN):
		move_dir.y -= 1.0

	if move_dir.length_squared() > 0.0001:
		var speed: float = cam_speed
		if Input.is_key_pressed(KEY_SHIFT):
			speed *= cam_fast_multiplier
		camera.position += move_dir.normalized() * speed * dt

func update_camera_rotation() -> void:
	var down: bool = Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT)
	if down and not right_mouse_down:
		prev_mouse_pos = get_viewport().get_mouse_position()
	if down:
		var mouse_pos: Vector2 = get_viewport().get_mouse_position()
		var delta: Vector2 = mouse_pos - prev_mouse_pos
		cam_yaw -= delta.x * cam_mouse_sensitivity
		cam_pitch -= delta.y * cam_mouse_sensitivity
		cam_pitch = clamp(cam_pitch, -85.0, 85.0)
		camera.rotation = Vector3(deg_to_rad(cam_pitch), deg_to_rad(cam_yaw), 0.0)
		prev_mouse_pos = mouse_pos
	right_mouse_down = down

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

func get_drag_plane_y(screen_pos: Vector2) -> float:
	var ray_origin := camera.project_ray_origin(screen_pos)
	var ray_dir := camera.project_ray_normal(screen_pos)
	var hit: Dictionary = world.raycast_block(ray_origin, ray_dir, 500.0)
	if bool(hit.get("hit", false)):
		var hit_pos: Vector3i = hit["pos"]
		var base_y: float = float(hit_pos.y)
		if world.player_mode == World.PlayerMode.PLACE:
			base_y += 1.0
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
	if abs(ray_dir.y) < 0.0001:
		return null
	var t := (plane_y - ray_origin.y) / ray_dir.y
	if t < 0:
		return null
	return ray_origin + ray_dir * t

func commit_selection(start: Vector2, end: Vector2, rect: Dictionary) -> void:
	var dx: float = abs(end.x - start.x)
	var dy: float = abs(end.y - start.y)
	var is_click: bool = dx < 5.0 and dy < 5.0

	if is_click:
		handle_click(start)
		return

	if rect.is_empty():
		return

	var min_x: int = int(floor(float(rect["min_x"]) + 0.5))
	var max_x: int = int(floor(float(rect["max_x"]) + 0.5))
	var min_z: int = int(floor(float(rect["min_z"]) + 0.5))
	var max_z: int = int(floor(float(rect["max_z"]) + 0.5))
	var y: int = int(rect["y"])

	for x in range(min_x, max_x + 1):
		for z in range(min_z, max_z + 1):
			enqueue_task_at(x, y, z)

func handle_click(screen_pos: Vector2) -> void:
	var ray_origin := camera.project_ray_origin(screen_pos)
	var ray_dir := camera.project_ray_normal(screen_pos)
	var hit: Dictionary = world.raycast_block(ray_origin, ray_dir, 500.0)
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

func setup_profiler_label() -> void:
	profiler_label = Label.new()
	profiler_label.name = "ProfilerLabel"
	profiler_label.offset_left = 10.0
	profiler_label.offset_top = 34.0
	profiler_label.offset_right = 700.0
	profiler_label.offset_bottom = 58.0
	profiler_label.text = ""
	profiler_label.visible = show_profiler
	hud_layer.add_child(profiler_label)

func update_profiler(dt: float) -> void:
	if profiler_label == null:
		return
	if not show_profiler:
		return

	var now: float = Time.get_ticks_msec() / 1000.0
	var process_ms: float = Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0
	var physics_ms: float = Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0
	var current_ms: float = process_ms + physics_ms

	profiler_samples.append({"t": now, "total": current_ms, "process": process_ms, "physics": physics_ms})
	var cutoff: float = now - profiler_window_sec
	var pruned: Array = []
	for sample in profiler_samples:
		if float(sample["t"]) >= cutoff:
			pruned.append(sample)
	profiler_samples = pruned

	var peak_ms: float = current_ms
	for sample in profiler_samples:
		var sample_ms: float = float(sample["total"])
		if sample_ms > peak_ms:
			peak_ms = sample_ms

	profiler_label.text = "CPU Frame (Main Thread)\nProcess+Physics: %.1f ms | Peak %.0fs: %.1f ms" % [
		current_ms,
		profiler_window_sec,
		peak_ms
	]
