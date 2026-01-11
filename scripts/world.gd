extends Node3D
class_name World

const BlockRegistryScript = preload("res://scripts/block_registry.gd")
const ChunkDataScript = preload("res://scripts/chunk_data.gd")
const ChunkDataType = ChunkDataScript

const CHUNK_SIZE := 8
const CHUNK_VOLUME := CHUNK_SIZE * CHUNK_SIZE * CHUNK_SIZE
const WORLD_CHUNKS_X := 32
const WORLD_CHUNKS_Y := 32
const WORLD_CHUNKS_Z := 32
const BLOCK_ID_AIR := 0
const BLOCK_ID_GRANITE := 1
const BLOCK_ID_DIRT := 2
const BLOCK_ID_GRASS := 10
const STAIR_BLOCK_ID := 100
const DEFAULT_MATERIAL := BLOCK_ID_GRANITE
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
const STREAM_HEIGHT_DEFAULT := 1
const STREAM_FULL_WORLD_DEFAULT := false
const STREAM_LEAD_TIME_DEFAULT := 0.4
const STREAM_MAX_BUFFER_CHUNKS_DEFAULT := 12
const VISIBILITY_Y_OFFSET := 1.0
const RAYCAST_VOXEL_OFFSET := Vector3(0.5, 0.5, 0.5)
const RAYCAST_STEP_POSITIVE := 1
const RAYCAST_STEP_NEGATIVE := -1
const SAVE_MAGIC := 0x474F424C
const SAVE_VERSION := 1
const SEED_MIX_FACTOR := 0x45d9f3b
const SEED_MASK := 0x7fffffff
const TOPSOIL_DEPTH_MIN := 2
const TOPSOIL_DEPTH_MAX := 4

var world_size_x := CHUNK_SIZE * WORLD_CHUNKS_X
var world_size_y := CHUNK_SIZE * WORLD_CHUNKS_Y
var world_size_z := CHUNK_SIZE * WORLD_CHUNKS_Z

var sea_level := DUMMY_INT
var top_render_y := DUMMY_INT
var vertical_scroll := DUMMY_INT
var world_seed: int = 0

var chunks: Dictionary = {}
var chunk_access_tick: int = 0
var renderer: WorldRenderer
var block_registry = BlockRegistryScript.new()

var task_queue := TaskQueue.new()
var task_manager: TaskManager
var pathfinder := Pathfinder.new()
var workers: Array = []
var worker_chunk_cache: Dictionary = {}
var chunk_build_queue: Array = []
var chunk_build_set: Dictionary = {}
var chunks_per_frame: int = CHUNKS_PER_FRAME_DEFAULT
var stream_queue_budget: int = STREAM_QUEUE_BUDGET_DEFAULT
var stream_radius_base: int = STREAM_RADIUS_DEFAULT
var stream_radius_chunks: int = STREAM_RADIUS_DEFAULT
var stream_full_world_xz: bool = STREAM_FULL_WORLD_DEFAULT
var stream_height_chunks: int = STREAM_HEIGHT_DEFAULT
var stream_lead_time: float = STREAM_LEAD_TIME_DEFAULT
var stream_max_buffer_chunks: int = STREAM_MAX_BUFFER_CHUNKS_DEFAULT
var last_stream_chunk := Vector2i(-DUMMY_INT, -DUMMY_INT)
var last_stream_max_cy := -DUMMY_INT
var last_stream_target := Vector3.ZERO
var last_stream_target_valid: bool = false
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
	init_world(false)

func init_world(seed_world: bool = true) -> void:
	chunks.clear()
	chunk_access_tick = 0
	sea_level = max(world_size_y - SEA_LEVEL_DEPTH, SEA_LEVEL_MIN)
	top_render_y = sea_level
	if renderer != null:
		renderer.reset_stats()
	reset_streaming_state()
	worker_chunk_cache.clear()
	if seed_world:
		if world_seed == 0:
			world_seed = generate_world_seed()
		seed_world()
		spawn_initial_workers()

func start_new_world(seed_value: int = -1) -> void:
	init_world(false)
	world_seed = seed_value if seed_value >= 0 else generate_world_seed()
	prime_spawn_chunks()
	spawn_initial_workers()

func prime_spawn_chunks() -> void:
	var center_x: int = int(world_size_x / 2.0)
	var center_z: int = int(world_size_z / 2.0)
	var sample_y: int = clampi(sea_level - 1, 0, world_size_y - 1)
	for offset in WORKER_SPAWN_OFFSETS:
		var spawn_x: int = clampi(center_x + offset.x, 0, world_size_x - 1)
		var spawn_z: int = clampi(center_z + offset.y, 0, world_size_z - 1)
		var coord := world_to_chunk_coords(spawn_x, sample_y, spawn_z)
		ensure_chunk_generated(coord)

func generate_world_seed() -> int:
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	return int(rng.randi() & SEED_MASK)

func chunk_seed_from_coord(coord: Vector3i) -> int:
	var h: int = mix_seed(world_seed ^ coord.x)
	h = mix_seed(h ^ coord.y)
	h = mix_seed(h ^ coord.z)
	return h

func mix_seed(value: int) -> int:
	var v: int = value & 0xffffffff
	v = int(((v >> 16) ^ v) * SEED_MIX_FACTOR) & 0xffffffff
	v = int(((v >> 16) ^ v) * SEED_MIX_FACTOR) & 0xffffffff
	v = int((v >> 16) ^ v) & 0xffffffff
	return v & SEED_MASK

func reset_streaming_state() -> void:
	chunk_build_queue.clear()
	chunk_build_set.clear()
	stream_radius_chunks = stream_radius_base
	last_stream_chunk = Vector2i(-DUMMY_INT, -DUMMY_INT)
	last_stream_max_cy = -DUMMY_INT
	last_stream_target = Vector3.ZERO
	last_stream_target_valid = false
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
	var buffer := serialize_blocks()
	file.store_32(SAVE_MAGIC)
	file.store_32(SAVE_VERSION)
	file.store_32(world_size_x)
	file.store_32(world_size_y)
	file.store_32(world_size_z)
	file.store_32(CHUNK_SIZE)
	file.store_32(sea_level)
	file.store_32(top_render_y)
	file.store_32(buffer.size())
	file.store_buffer(buffer)
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
	load_blocks_from_buffer(buffer)
	sea_level = clamp(saved_sea_level, 0, world_size_y - 1)
	top_render_y = clamp(saved_top_render_y, 0, world_size_y - 1)
	reset_streaming_state()
	for worker in workers:
		worker.queue_free()
	workers.clear()
	worker_chunk_cache.clear()
	spawn_initial_workers()
	if renderer != null:
		renderer.clear_chunks()
		renderer.reset_stats()
	return true

func world_to_chunk_coords(x: int, y: int, z: int) -> Vector3i:
	return Vector3i(
		int(floor(float(x) / float(CHUNK_SIZE))),
		int(floor(float(y) / float(CHUNK_SIZE))),
		int(floor(float(z) / float(CHUNK_SIZE)))
	)

func chunk_to_local_coords(x: int, y: int, z: int) -> Vector3i:
	return Vector3i(x % CHUNK_SIZE, y % CHUNK_SIZE, z % CHUNK_SIZE)

func chunk_index(lx: int, ly: int, lz: int) -> int:
	return (lz * CHUNK_SIZE + ly) * CHUNK_SIZE + lx

func get_chunk(coord: Vector3i) -> ChunkDataType:
	if chunks.has(coord):
		var chunk: ChunkDataType = chunks[coord]
		return chunk
	return null

func ensure_chunk(coord: Vector3i) -> ChunkDataType:
	if chunks.has(coord):
		var existing: ChunkDataType = chunks[coord]
		return existing
	var chunk: ChunkDataType = ChunkDataScript.new(CHUNK_SIZE, BLOCK_ID_AIR)
	chunks[coord] = chunk
	return chunk

func ensure_chunk_generated(coord: Vector3i) -> ChunkDataType:
	var chunk := ensure_chunk(coord)
	if chunk.generated:
		return chunk
	generate_chunk(coord, chunk)
	return chunk

func touch_chunk(chunk: ChunkDataType) -> void:
	chunk_access_tick += 1
	chunk.last_access_tick = chunk_access_tick

func generate_chunk(coord: Vector3i, chunk: ChunkDataType) -> void:
	var chunk_size: int = CHUNK_SIZE
	var base_y: int = coord.y * chunk_size
	var max_y: int = min(sea_level + SEA_LEVEL_FILL_OFFSET, world_size_y)
	if base_y >= max_y:
		chunk.generated = true
		touch_chunk(chunk)
		return
	var fill_y_max: int = min(chunk_size, max_y - base_y)
	var rng := RandomNumberGenerator.new()
	rng.seed = chunk_seed_from_coord(coord)
	var dirt_depth: int = rng.randi_range(TOPSOIL_DEPTH_MIN, TOPSOIL_DEPTH_MAX)
	var surface_y: int = min(sea_level, world_size_y - 1)
	for ly in range(fill_y_max):
		var world_y: int = base_y + ly
		for lx in range(chunk_size):
			for lz in range(chunk_size):
				var idx := chunk_index(lx, ly, lz)
				var block_id: int = DEFAULT_MATERIAL
				if world_y == surface_y:
					block_id = BLOCK_ID_GRASS
				elif world_y >= surface_y - dirt_depth:
					block_id = BLOCK_ID_DIRT
				chunk.blocks[idx] = block_id
	chunk.generated = true
	touch_chunk(chunk)

func is_chunk_coord_valid(coord: Vector3i) -> bool:
	var max_cx: int = int(floor(float(world_size_x) / float(CHUNK_SIZE)))
	var max_cy: int = int(floor(float(world_size_y) / float(CHUNK_SIZE)))
	var max_cz: int = int(floor(float(world_size_z) / float(CHUNK_SIZE)))
	return coord.x >= 0 and coord.x < max_cx and coord.y >= 0 and coord.y < max_cy and coord.z >= 0 and coord.z < max_cz

func ensure_chunk_buffer_for_pos(pos: Vector3i) -> void:
	var coord := world_to_chunk_coords(pos.x, pos.y, pos.z)
	ensure_chunk_buffer_for_chunk(coord)

func ensure_chunk_buffer_for_chunk(coord: Vector3i) -> void:
	for dy in [0, -1]:
		var cy: int = coord.y + dy
		if cy < 0:
			continue
		for dx in range(-1, 2):
			for dz in range(-1, 2):
				var target := Vector3i(coord.x + dx, cy, coord.z + dz)
				if not is_chunk_coord_valid(target):
					continue
				ensure_chunk_generated(target)

func debug_verify_chunk(coord: Vector3i) -> bool:
	var existing: ChunkDataType = ensure_chunk_generated(coord)
	var temp: ChunkDataType = ChunkDataScript.new(CHUNK_SIZE, BLOCK_ID_AIR)
	generate_chunk(coord, temp)
	if temp.blocks.size() != existing.blocks.size():
		return false
	for i in range(temp.blocks.size()):
		if temp.blocks[i] != existing.blocks[i]:
			return false
	return true

func set_block_raw(x: int, y: int, z: int, value: int, mark_dirty: bool) -> void:
	if x < 0 or y < 0 or z < 0:
		return
	if x >= world_size_x or y >= world_size_y or z >= world_size_z:
		return
	var coord := world_to_chunk_coords(x, y, z)
	var local := chunk_to_local_coords(x, y, z)
	var chunk: ChunkDataType = ensure_chunk(coord)
	chunk.blocks[chunk_index(local.x, local.y, local.z)] = value
	if mark_dirty:
		chunk.dirty = true
		chunk.generated = true
	touch_chunk(chunk)

func serialize_blocks() -> PackedByteArray:
	var total: int = world_size_x * world_size_y * world_size_z
	var buffer := PackedByteArray()
	buffer.resize(total)
	for z in range(world_size_z):
		for y in range(world_size_y):
			for x in range(world_size_x):
				var idx := world_index(x, y, z)
				buffer[idx] = get_block_no_generate(x, y, z)
	return buffer

func load_blocks_from_buffer(buffer: PackedByteArray) -> void:
	chunks.clear()
	chunk_access_tick = 0
	var total: int = world_size_x * world_size_y * world_size_z
	if buffer.size() < total:
		return
	for z in range(world_size_z):
		for y in range(world_size_y):
			for x in range(world_size_x):
				var idx := world_index(x, y, z)
				set_block_raw(x, y, z, buffer[idx], false)
	for chunk in chunks.values():
		var entry: ChunkDataType = chunk
		entry.generated = true

func world_index(x: int, y: int, z: int) -> int:
	return (z * world_size_y + y) * world_size_x + x

func get_block(x: int, y: int, z: int) -> int:
	if x < 0 or y < 0 or z < 0:
		return BLOCK_ID_AIR
	if x >= world_size_x or y >= world_size_y or z >= world_size_z:
		return BLOCK_ID_AIR
	var coord := world_to_chunk_coords(x, y, z)
	var chunk: ChunkDataType = ensure_chunk_generated(coord)
	touch_chunk(chunk)
	var local := chunk_to_local_coords(x, y, z)
	return chunk.blocks[chunk_index(local.x, local.y, local.z)]

func get_block_no_generate(x: int, y: int, z: int) -> int:
	if x < 0 or y < 0 or z < 0:
		return BLOCK_ID_AIR
	if x >= world_size_x or y >= world_size_y or z >= world_size_z:
		return BLOCK_ID_AIR
	var coord := world_to_chunk_coords(x, y, z)
	var chunk: ChunkDataType = get_chunk(coord)
	if chunk == null:
		return BLOCK_ID_AIR
	var local := chunk_to_local_coords(x, y, z)
	return chunk.blocks[chunk_index(local.x, local.y, local.z)]

func set_block(x: int, y: int, z: int, value: int) -> void:
	if x < 0 or y < 0 or z < 0:
		return
	if x >= world_size_x or y >= world_size_y or z >= world_size_z:
		return
	if value < 0 or value >= BlockRegistryScript.TABLE_SIZE:
		return
	set_block_raw(x, y, z, value, true)
	if renderer != null:
		renderer.regenerate_chunk(int(x / float(CHUNK_SIZE)), int(y / float(CHUNK_SIZE)), int(z / float(CHUNK_SIZE)))

func is_solid(x: int, y: int, z: int) -> bool:
	return is_block_solid_id(get_block(x, y, z))

func is_solid_no_generate(x: int, y: int, z: int) -> bool:
	return is_block_solid_id(get_block_no_generate(x, y, z))

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
	chunks.clear()
	chunk_access_tick = 0
	var chunk_size: int = CHUNK_SIZE
	var max_cx: int = int(floor(float(world_size_x) / float(chunk_size)))
	var max_cy: int = int(floor(float(world_size_y) / float(chunk_size)))
	var max_cz: int = int(floor(float(world_size_z) / float(chunk_size)))
	for cx in range(max_cx):
		for cy in range(max_cy):
			for cz in range(max_cz):
				ensure_chunk_generated(Vector3i(cx, cy, cz))

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
		var coord: Vector3i = worker.get_block_coord()
		var last_coord: Vector3i = worker_chunk_cache.get(worker, Vector3i(-DUMMY_INT, -DUMMY_INT, -DUMMY_INT))
		if coord != last_coord:
			worker_chunk_cache[worker] = coord
			ensure_chunk_buffer_for_pos(coord)

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
	ensure_chunk_buffer_for_pos(pos)
	if task_manager != null:
		task_manager.queue_task_request(task_type, pos, material)

func update_streaming(camera_pos: Vector3, dt: float) -> void:
	if renderer == null:
		return
	var velocity := Vector3.ZERO
	if last_stream_target_valid and dt > 0.0:
		velocity = (camera_pos - last_stream_target) / dt
	last_stream_target = camera_pos
	last_stream_target_valid = true
	var speed: float = velocity.length()
	var buffer_chunks: int = 0
	if stream_lead_time > 0.0 and speed > 0.0:
		buffer_chunks = int(ceil((speed * stream_lead_time) / float(CHUNK_SIZE)))
	buffer_chunks = clampi(buffer_chunks, 0, stream_max_buffer_chunks)
	stream_radius_chunks = stream_radius_base + buffer_chunks
	var stream_pos: Vector3 = camera_pos + velocity * stream_lead_time
	var chunk_size: int = CHUNK_SIZE
	var max_cx: int = int(floor(float(world_size_x) / float(chunk_size))) - 1
	var max_cy: int = int(floor(float(top_render_y) / float(chunk_size)))
	var max_cz: int = int(floor(float(world_size_z) / float(chunk_size))) - 1
	if max_cx < 0 or max_cy < 0 or max_cz < 0:
		return
	var min_cy: int = 0
	if stream_height_chunks > 0:
		min_cy = max(0, max_cy - stream_height_chunks + 1)

	var cx: int = clampi(int(floor(stream_pos.x / float(chunk_size))), 0, max_cx)
	var cz: int = clampi(int(floor(stream_pos.z / float(chunk_size))), 0, max_cz)
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
		ensure_chunk_generated(key)
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

func find_surface_y(_x: int, _z: int) -> int:
	return clampi(sea_level, 0, world_size_y - 1)

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
	if last_stream_target_valid:
		var target_x: int = int(floor(last_stream_target.x))
		var target_z: int = int(floor(last_stream_target.z))
		var target_coord := world_to_chunk_coords(target_x, top_render_y, target_z)
		ensure_chunk_buffer_for_chunk(target_coord)
	if renderer != null:
		if stream_min_x <= stream_max_x and stream_min_z <= stream_max_z:
			renderer.update_render_height_in_range(old_y, top_render_y, stream_min_x, stream_max_x, stream_min_z, stream_max_z)
		else:
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
