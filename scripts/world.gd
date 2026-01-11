extends Node3D
class_name World

const BlockRegistryScript = preload("res://scripts/block_registry.gd")

const CHUNK_SIZE := 8
const WORLD_CHUNKS_X := 32
const WORLD_CHUNKS_Y := 32
const WORLD_CHUNKS_Z := 32
const BLOCK_ID_AIR := 0
const STAIR_BLOCK_ID := 100
const DEFAULT_MATERIAL := 1
const DUMMY_INT := 666
const BLOCK_DATA_PATH := "res://data/blocks.csv"
const SEA_LEVEL_DEPTH := 30
const SEA_LEVEL_MIN := 8
const SEA_LEVEL_FILL_OFFSET := 1
const WORKER_SPAWN_HEIGHT_OFFSET := 1.0
const WORKER_SPAWN_OFFSETS := [
	Vector2i(-10, -10),
	Vector2i(10, -10),
	Vector2i(-10, 10),
	Vector2i(10, 10),
]
const CHUNKS_PER_FRAME_DEFAULT := 6
const STREAM_QUEUE_BUDGET_DEFAULT := 6000
const STREAM_RADIUS_DEFAULT := 8
const STREAM_HEIGHT_DEFAULT := 0
const STREAM_FULL_WORLD_DEFAULT := false
const VISIBILITY_Y_OFFSET := 1.0
const RAYCAST_VOXEL_OFFSET := Vector3(0.5, 0.5, 0.5)
const RAYCAST_STEP_POSITIVE := 1
const RAYCAST_STEP_NEGATIVE := -1
const SAVE_MAGIC := 0x474F424C
const SAVE_VERSION := 1

var world_size_x := CHUNK_SIZE * WORLD_CHUNKS_X
var world_size_y := CHUNK_SIZE * WORLD_CHUNKS_Y
var world_size_z := CHUNK_SIZE * WORLD_CHUNKS_Z

var sea_level := DUMMY_INT
var top_render_y := DUMMY_INT
var vertical_scroll := DUMMY_INT

var blocks := PackedByteArray()
var renderer: WorldRenderer
var block_registry = BlockRegistryScript.new()

var task_queue := TaskQueue.new()
var task_manager: TaskManager
var pathfinder := Pathfinder.new()
var workers: Array = []
var chunk_build_queue: Array = []
var chunk_build_set: Dictionary = {}
var chunks_per_frame: int = CHUNKS_PER_FRAME_DEFAULT
var stream_queue_budget: int = STREAM_QUEUE_BUDGET_DEFAULT
var stream_radius_chunks: int = STREAM_RADIUS_DEFAULT
var stream_full_world_xz: bool = STREAM_FULL_WORLD_DEFAULT
var stream_height_chunks: int = STREAM_HEIGHT_DEFAULT
var last_stream_chunk := Vector2i(-DUMMY_INT, -DUMMY_INT)
var last_stream_max_cy := -DUMMY_INT
var stream_min_x: int = DUMMY_INT
var stream_max_x: int = -DUMMY_INT
var stream_min_z: int = DUMMY_INT
var stream_max_z: int = -DUMMY_INT
var stream_min_y: int = DUMMY_INT
var stream_max_y: int = -DUMMY_INT
var stream_pending: bool = false
var stream_plane_index: int = 0
var stream_plane_size: int = 0
var stream_layer_y: int = 0
var stream_layer_remaining: int = 0
var stream_x_offsets: Array = []
var stream_z_offsets: Array = []

enum PlayerMode { INFORMATION, DIG, PLACE, STAIRS }
var player_mode := PlayerMode.DIG
var selected_blocks: Dictionary = {}

func _ready() -> void:
	block_registry.load_from_csv(BLOCK_DATA_PATH)
	task_manager = TaskManager.new(self, task_queue)
	renderer = WorldRenderer.new()
	add_child(renderer)
	renderer.initialize(self)
	init_world()

func init_world() -> void:
	blocks.resize(world_size_x * world_size_y * world_size_z)
	blocks.fill(BLOCK_ID_AIR)
	sea_level = max(world_size_y - SEA_LEVEL_DEPTH, SEA_LEVEL_MIN)
	top_render_y = sea_level
	if renderer != null:
		renderer.reset_stats()
	reset_streaming_state()

	seed_world()
	spawn_initial_workers()

func reset_streaming_state() -> void:
	chunk_build_queue.clear()
	chunk_build_set.clear()
	last_stream_chunk = Vector2i(-DUMMY_INT, -DUMMY_INT)
	last_stream_max_cy = -DUMMY_INT
	stream_min_x = DUMMY_INT
	stream_max_x = -DUMMY_INT
	stream_min_z = DUMMY_INT
	stream_max_z = -DUMMY_INT
	stream_min_y = DUMMY_INT
	stream_max_y = -DUMMY_INT
	stream_pending = false
	stream_plane_index = 0
	stream_plane_size = 0
	stream_layer_y = 0
	stream_layer_remaining = 0
	stream_x_offsets.clear()
	stream_z_offsets.clear()

func save_world(path: String) -> bool:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		push_error("World save failed: %s" % path)
		return false
	file.store_32(SAVE_MAGIC)
	file.store_32(SAVE_VERSION)
	file.store_32(world_size_x)
	file.store_32(world_size_y)
	file.store_32(world_size_z)
	file.store_32(CHUNK_SIZE)
	file.store_32(sea_level)
	file.store_32(top_render_y)
	file.store_32(blocks.size())
	file.store_buffer(blocks)
	file.flush()
	return true

func load_world(path: String) -> bool:
	if not FileAccess.file_exists(path):
		push_warning("World load failed: missing %s" % path)
		return false
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		push_warning("World load failed: cannot open %s" % path)
		return false
	var magic: int = file.get_32()
	if magic != SAVE_MAGIC:
		push_warning("World load failed: bad magic")
		return false
	var version: int = file.get_32()
	if version != SAVE_VERSION:
		push_warning("World load failed: version %d != %d" % [version, SAVE_VERSION])
		return false
	var size_x: int = file.get_32()
	var size_y: int = file.get_32()
	var size_z: int = file.get_32()
	var chunk_size: int = file.get_32()
	if size_x != world_size_x or size_y != world_size_y or size_z != world_size_z or chunk_size != CHUNK_SIZE:
		push_warning("World load failed: size mismatch")
		return false
	var saved_sea_level: int = file.get_32()
	var saved_top_render_y: int = file.get_32()
	var block_count: int = file.get_32()
	var expected_count: int = world_size_x * world_size_y * world_size_z
	if block_count != expected_count:
		push_warning("World load failed: block count mismatch")
		return false
	var buffer := file.get_buffer(block_count)
	if buffer.size() != block_count:
		push_warning("World load failed: incomplete block data")
		return false
	blocks = buffer
	sea_level = clamp(saved_sea_level, 0, world_size_y - 1)
	top_render_y = clamp(saved_top_render_y, 0, world_size_y - 1)
	reset_streaming_state()
	for worker in workers:
		worker.queue_free()
	workers.clear()
	spawn_initial_workers()
	if renderer != null:
		renderer.clear_chunks()
		renderer.reset_stats()
	return true

func world_index(x: int, y: int, z: int) -> int:
	return (z * world_size_y + y) * world_size_x + x

func get_block(x: int, y: int, z: int) -> int:
	if x < 0 or y < 0 or z < 0:
		return BLOCK_ID_AIR
	if x >= world_size_x or y >= world_size_y or z >= world_size_z:
		return BLOCK_ID_AIR
	return blocks[world_index(x, y, z)]

func set_block(x: int, y: int, z: int, value: int) -> void:
	if x < 0 or y < 0 or z < 0:
		return
	if x >= world_size_x or y >= world_size_y or z >= world_size_z:
		return
	if value < 0 or value >= BlockRegistryScript.TABLE_SIZE:
		return
	blocks[world_index(x, y, z)] = value
	if renderer != null:
		renderer.regenerate_chunk(int(x / float(CHUNK_SIZE)), int(y / float(CHUNK_SIZE)), int(z / float(CHUNK_SIZE)))

func is_solid(x: int, y: int, z: int) -> bool:
	return is_block_solid_id(get_block(x, y, z))

func is_block_solid_id(block_id: int) -> bool:
	return block_registry.is_solid(block_id)

func is_block_empty_id(block_id: int) -> bool:
	return block_id == BLOCK_ID_AIR

func is_empty(x: int, y: int, z: int) -> bool:
	return is_block_empty_id(get_block(x, y, z))

func is_diggable_at(x: int, y: int, z: int) -> bool:
	return block_registry.get_hardness(get_block(x, y, z)) > 0.0

func can_place_stairs_at(x: int, y: int, z: int) -> bool:
	var block_id := get_block(x, y, z)
	return block_id != STAIR_BLOCK_ID and block_registry.is_replaceable(block_id)

func is_stairs_at(x: int, y: int, z: int) -> bool:
	return get_block(x, y, z) == STAIR_BLOCK_ID

func get_block_color(block_id: int) -> Color:
	return block_registry.get_color(block_id)

func get_block_name(block_id: int) -> String:
	return block_registry.get_name(block_id)

func seed_world() -> void:
	blocks.fill(BLOCK_ID_AIR)
	var max_y: int = min(sea_level + SEA_LEVEL_FILL_OFFSET, world_size_y)
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

func update_streaming(camera_pos: Vector3) -> void:
	if renderer == null:
		return
	var chunk_size: int = CHUNK_SIZE
	var max_cx: int = int(floor(float(world_size_x) / float(chunk_size))) - 1
	var max_cy: int = int(floor(float(top_render_y) / float(chunk_size)))
	var max_cz: int = int(floor(float(world_size_z) / float(chunk_size))) - 1
	if max_cx < 0 or max_cy < 0 or max_cz < 0:
		return
	var min_cy: int = 0
	if stream_height_chunks > 0:
		min_cy = max(0, max_cy - stream_height_chunks + 1)

	var cx: int = clampi(int(floor(camera_pos.x / float(chunk_size))), 0, max_cx)
	var cz: int = clampi(int(floor(camera_pos.z / float(chunk_size))), 0, max_cz)
	var anchor_cx: int = 0 if stream_full_world_xz else cx
	var anchor_cz: int = 0 if stream_full_world_xz else cz
	if anchor_cx != last_stream_chunk.x or anchor_cz != last_stream_chunk.y or max_cy != last_stream_max_cy:
		last_stream_chunk = Vector2i(anchor_cx, anchor_cz)
		last_stream_max_cy = max_cy

		if stream_full_world_xz:
			stream_min_x = 0
			stream_max_x = max_cx
			stream_min_z = 0
			stream_max_z = max_cz
		else:
			stream_min_x = clampi(cx - stream_radius_chunks, 0, max_cx)
			stream_max_x = clampi(cx + stream_radius_chunks, 0, max_cx)
			stream_min_z = clampi(cz - stream_radius_chunks, 0, max_cz)
			stream_max_z = clampi(cz + stream_radius_chunks, 0, max_cz)
		stream_min_y = min_cy
		stream_max_y = max_cy
		chunk_build_queue.clear()
		chunk_build_set.clear()
		var x_range: int = stream_max_x - stream_min_x + 1
		var z_range: int = stream_max_z - stream_min_z + 1
		var y_range: int = stream_max_y - stream_min_y + 1
		stream_plane_index = 0
		if x_range <= 0 or z_range <= 0 or y_range <= 0:
			stream_plane_size = 0
			stream_pending = false
		else:
			stream_plane_size = x_range * z_range
			stream_pending = true
		stream_x_offsets = build_center_spiral_offsets(x_range)
		stream_z_offsets = build_center_spiral_offsets(z_range)
		stream_layer_y = stream_max_y
		stream_layer_remaining = count_unbuilt_in_layer(stream_layer_y)
	enqueue_stream_chunks()
	process_chunk_queue()

func process_chunk_queue() -> void:
	if renderer == null:
		return
	var build_count: int = min(chunks_per_frame, chunk_build_queue.size())
	for _i in range(build_count):
		var key: Vector3i = chunk_build_queue.pop_front()
		chunk_build_set.erase(key)
		renderer.regenerate_chunk(key.x, key.y, key.z)
		if stream_pending and key.y == stream_layer_y and stream_layer_remaining > 0:
			stream_layer_remaining -= 1

func enqueue_stream_chunks() -> void:
	if not stream_pending:
		return
	var x_range: int = stream_max_x - stream_min_x + 1
	var z_range: int = stream_max_z - stream_min_z + 1
	var y_range: int = stream_max_y - stream_min_y + 1
	if x_range <= 0 or z_range <= 0 or y_range <= 0:
		stream_pending = false
		return
	while stream_pending and stream_layer_remaining <= 0:
		if stream_layer_y <= stream_min_y:
			stream_pending = false
			return
		stream_layer_y -= 1
		stream_plane_index = 0
		stream_layer_remaining = count_unbuilt_in_layer(stream_layer_y)
	var plane_size: int = stream_plane_size
	if plane_size <= 0:
		stream_pending = false
		return
	var remaining_in_plane: int = plane_size - stream_plane_index
	if remaining_in_plane <= 0:
		return
	var budget: int = min(stream_queue_budget, remaining_in_plane)
	for _i in range(budget):
		var plane_index: int = stream_plane_index
		var x_spiral_index: int = int(floor(float(plane_index) / float(z_range)))
		var z_spiral_index: int = plane_index % z_range
		var x_offset: int = stream_x_offsets[x_spiral_index]
		var z_offset: int = stream_z_offsets[z_spiral_index]
		var key := Vector3i(stream_min_x + x_offset, stream_layer_y, stream_min_z + z_offset)
		if not renderer.is_chunk_built(key) and not chunk_build_set.has(key):
			chunk_build_set[key] = true
			chunk_build_queue.append(key)
		stream_plane_index += 1

func count_unbuilt_in_layer(layer_y: int) -> int:
	if renderer == null:
		return 0
	var x_range: int = stream_max_x - stream_min_x + 1
	var z_range: int = stream_max_z - stream_min_z + 1
	if x_range <= 0 or z_range <= 0:
		return 0
	var remaining := 0
	for x_offset in stream_x_offsets:
		var x: int = stream_min_x + int(x_offset)
		for z_offset in stream_z_offsets:
			var z: int = stream_min_z + int(z_offset)
			var key := Vector3i(x, layer_y, z)
			if not renderer.is_chunk_built(key):
				remaining += 1
	return remaining

func build_center_spiral_offsets(size: int) -> Array:
	var offsets: Array = []
	if size <= 0:
		return offsets
	var center: int = int(floor(float(size - 1) / 2.0))
	offsets.append(center)
	for radius in range(1, size):
		var left: int = center - radius
		var right: int = center + radius
		var added := false
		if left >= 0:
			offsets.append(left)
			added = true
		if right < size:
			offsets.append(right)
			added = true
		if not added:
			break
	return offsets

func spawn_initial_workers() -> void:
	var center_x: int = int(world_size_x / 2.0)
	var center_z: int = int(world_size_z / 2.0)
	for offset in WORKER_SPAWN_OFFSETS:
		var spawn_x: int = clampi(center_x + offset.x, 0, world_size_x - 1)
		var spawn_z: int = clampi(center_z + offset.y, 0, world_size_z - 1)
		var surface_y := find_surface_y(spawn_x, spawn_z)
		var worker := Worker.new()
		worker.position = Vector3(spawn_x, surface_y + WORKER_SPAWN_HEIGHT_OFFSET, spawn_z)
		add_child(worker)
		workers.append(worker)

func find_surface_y(x: int, z: int) -> int:
	for y in range(world_size_y - 1, -1, -1):
		if not is_block_empty_id(get_block(x, y, z)):
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
	return y_value <= top_render_y + VISIBILITY_Y_OFFSET

func raycast_block(ray_origin: Vector3, ray_dir: Vector3, max_distance: float) -> Dictionary:
	var pos := ray_origin
	var dir := ray_dir

	pos += RAYCAST_VOXEL_OFFSET

	var voxel := Vector3i(int(floor(pos.x)), int(floor(pos.y)), int(floor(pos.z)))
	var step_x: int = RAYCAST_STEP_POSITIVE if dir.x >= 0.0 else RAYCAST_STEP_NEGATIVE
	var step_y: int = RAYCAST_STEP_POSITIVE if dir.y >= 0.0 else RAYCAST_STEP_NEGATIVE
	var step_z: int = RAYCAST_STEP_POSITIVE if dir.z >= 0.0 else RAYCAST_STEP_NEGATIVE
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
			if voxel.y <= top_render_y and not is_block_empty_id(get_block(voxel.x, voxel.y, voxel.z)):
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
