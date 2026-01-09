extends Node3D
class_name World

const CHUNK_SIZE := 8
const WORLD_CHUNKS_X := 8
const WORLD_CHUNKS_Y := 8
const WORLD_CHUNKS_Z := 8
const STAIR_BLOCK_ID := 100
const DEFAULT_MATERIAL := 1

var world_size_x := CHUNK_SIZE * WORLD_CHUNKS_X
var world_size_y := CHUNK_SIZE * WORLD_CHUNKS_Y
var world_size_z := CHUNK_SIZE * WORLD_CHUNKS_Z

var sea_level := 0
var top_render_y := 0
var vertical_scroll := 0

var blocks := PackedByteArray()
var renderer: WorldRenderer

var task_queue := TaskQueue.new()
var task_manager: TaskManager
var pathfinder := Pathfinder.new()
var workers: Array = []

enum PlayerMode { INFORMATION, DIG, PLACE, STAIRS }
var player_mode := PlayerMode.DIG

var selected_blocks: Dictionary = {}

func _ready() -> void:
	task_manager = TaskManager.new(self, task_queue)
	renderer = WorldRenderer.new()
	add_child(renderer)
	renderer.initialize(self)
	init_world()

func init_world() -> void:
	blocks.resize(world_size_x * world_size_y * world_size_z)
	blocks.fill(0)
	sea_level = max(world_size_y - 30, 8)
	top_render_y = sea_level
	if renderer != null:
		renderer.reset_stats()

	seed_world()
	if renderer != null:
		renderer.build_all_chunks()
	spawn_initial_workers()

func world_index(x: int, y: int, z: int) -> int:
	return (z * world_size_y + y) * world_size_x + x

func get_block(x: int, y: int, z: int) -> int:
	if x < 0 or y < 0 or z < 0:
		return 0
	if x >= world_size_x or y >= world_size_y or z >= world_size_z:
		return 0
	return blocks[world_index(x, y, z)]

func set_block(x: int, y: int, z: int, value: int) -> void:
	if x < 0 or y < 0 or z < 0:
		return
	if x >= world_size_x or y >= world_size_y or z >= world_size_z:
		return
	blocks[world_index(x, y, z)] = value
	if renderer != null:
		renderer.regenerate_chunk(int(x / float(CHUNK_SIZE)), int(y / float(CHUNK_SIZE)), int(z / float(CHUNK_SIZE)))

func is_solid(x: int, y: int, z: int) -> bool:
	return get_block(x, y, z) != 0

func seed_world() -> void:
	blocks.fill(0)
	var max_y: int = min(sea_level + 1, world_size_y)
	for y in range(max_y):
		for x in range(world_size_x):
			for z in range(world_size_z):
				blocks[world_index(x, y, z)] = DEFAULT_MATERIAL

func get_draw_burden_stats() -> Dictionary:
	if renderer == null:
		return {"drawn": 0, "culled": 0, "percent": 0.0}
	return renderer.get_draw_burden_stats()

func get_camera_tris_rendered(camera: Camera3D) -> Dictionary:
	if renderer == null:
		return {"rendered": 0, "total": 0, "percent": 0.0}
	return renderer.get_camera_tris_rendered(camera)

func update_world(dt: float) -> void:
	update_workers(dt)
	update_task_queue()
	update_task_overlays_phase()
	update_blocked_tasks(dt)

func update_workers(dt: float) -> void:
	for worker in workers:
		worker.update_worker(dt, self, task_queue, pathfinder)
		worker.visible = is_visible_at_level(worker.position.y)

func update_task_queue() -> void:
	if task_manager != null:
		task_manager.update_task_queue()

func update_task_overlays_phase() -> void:
	if renderer == null:
		return
	var blocked: Array = []
	if task_manager != null:
		blocked = task_manager.blocked_tasks
	renderer.update_task_overlays(task_queue.tasks, blocked)

func update_blocked_tasks(dt: float) -> void:
	if task_manager != null:
		task_manager.update_blocked_tasks(dt)

func reassess_waiting_tasks() -> void:
	if task_manager != null:
		task_manager.reassess_waiting_tasks()

func queue_task_request(task_type: int, pos: Vector3i, material: int) -> void:
	if task_manager != null:
		task_manager.queue_task_request(task_type, pos, material)

func spawn_initial_workers() -> void:
	var center_x: int = int(world_size_x / 2.0)
	var center_z: int = int(world_size_z / 2.0)
	var offsets: Array[Vector2i] = [Vector2i(-10, -10), Vector2i(10, -10), Vector2i(-10, 10), Vector2i(10, 10)]
	for offset in offsets:
		var spawn_x: int = clampi(center_x + offset.x, 0, world_size_x - 1)
		var spawn_z: int = clampi(center_z + offset.y, 0, world_size_z - 1)
		var surface_y := find_surface_y(spawn_x, spawn_z)
		var worker := Worker.new()
		worker.position = Vector3(spawn_x, surface_y + 1, spawn_z)
		add_child(worker)
		workers.append(worker)

func find_surface_y(x: int, z: int) -> int:
	for y in range(world_size_y - 1, -1, -1):
		if get_block(x, y, z) != 0:
			return y
	return 0

func set_drag_preview(rect: Dictionary, mode: int) -> void:
	if renderer != null:
		renderer.set_drag_preview(rect, mode)

func clear_drag_preview() -> void:
	if renderer != null:
		renderer.clear_drag_preview()

func set_top_render_y(new_y: int) -> void:
	var old_y: int = top_render_y
	top_render_y = clamp(new_y, 0, world_size_y - 1)
	if top_render_y == old_y:
		return
	if renderer != null:
		renderer.update_render_height(old_y, top_render_y)

func is_visible_at_level(y_value: float) -> bool:
	return y_value <= top_render_y + 1

func raycast_block(ray_origin: Vector3, ray_dir: Vector3, max_distance: float) -> Dictionary:
	var pos := ray_origin
	var dir := ray_dir

	pos += Vector3(0.5, 0.5, 0.5)

	var voxel := Vector3i(int(floor(pos.x)), int(floor(pos.y)), int(floor(pos.z)))
	var step_x: int = 1 if dir.x >= 0.0 else -1
	var step_y: int = 1 if dir.y >= 0.0 else -1
	var step_z: int = 1 if dir.z >= 0.0 else -1
	var step := Vector3i(step_x, step_y, step_z)

	var next_x: float = floor(pos.x) + (1.0 if dir.x >= 0.0 else 0.0)
	var next_y: float = floor(pos.y) + (1.0 if dir.y >= 0.0 else 0.0)
	var next_z: float = floor(pos.z) + (1.0 if dir.z >= 0.0 else 0.0)

	var t_max_x: float = INF if dir.x == 0.0 else (next_x - pos.x) / dir.x
	var t_max_y: float = INF if dir.y == 0.0 else (next_y - pos.y) / dir.y
	var t_max_z: float = INF if dir.z == 0.0 else (next_z - pos.z) / dir.z

	var t_delta_x: float = INF if dir.x == 0.0 else abs(1.0 / dir.x)
	var t_delta_y: float = INF if dir.y == 0.0 else abs(1.0 / dir.y)
	var t_delta_z: float = INF if dir.z == 0.0 else abs(1.0 / dir.z)

	var distance := 0.0

	while distance < max_distance:
		if voxel.x >= 0 and voxel.y >= 0 and voxel.z >= 0 and voxel.x < world_size_x and voxel.y < world_size_y and voxel.z < world_size_z:
			if voxel.y <= top_render_y and get_block(voxel.x, voxel.y, voxel.z) != 0:
				return {"hit": true, "pos": voxel}

		if t_max_x < t_max_y:
			if t_max_x < t_max_z:
				voxel.x += step.x
				distance = t_max_x
				t_max_x += t_delta_x
			else:
				voxel.z += step.z
				distance = t_max_z
				t_max_z += t_delta_z
		else:
			if t_max_y < t_max_z:
				voxel.y += step.y
				distance = t_max_y
				t_max_y += t_delta_y
			else:
				voxel.z += step.z
				distance = t_max_z
				t_max_z += t_delta_z

	return {"hit": false}
