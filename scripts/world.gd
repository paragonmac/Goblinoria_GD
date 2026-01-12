extends Node3D
class_name World
## Voxel world managing chunks, blocks, workers, and game state.

#region Preloads
const BlockRegistryScript = preload("res://scripts/block_registry.gd")
const ChunkDataScript = preload("res://scripts/chunk_data.gd")
const WorldGeneratorScript = preload("res://scripts/world_generator.gd")
const WorldSaveLoadScript = preload("res://scripts/world_save_load.gd")
const WorldStreamingScript = preload("res://scripts/world_streaming.gd")
const WorldRaycasterScript = preload("res://scripts/world_raycaster.gd")
const ChunkDataType = ChunkDataScript
#endregion

#region Constants - World Size
const CHUNK_SIZE := 8
const CHUNK_VOLUME := CHUNK_SIZE * CHUNK_SIZE * CHUNK_SIZE
const WORLD_CHUNKS_X := 32
const WORLD_CHUNKS_Y := 32
const WORLD_CHUNKS_Z := 32
#endregion

#region Constants - Block IDs
const BLOCK_ID_AIR := 0
const BLOCK_ID_GRANITE := 1
const BLOCK_ID_DIRT := 2
const BLOCK_ID_GRASS := 10
const STAIR_BLOCK_ID := 100
const DEFAULT_MATERIAL := BLOCK_ID_GRANITE
#endregion

#region Constants - World Generation
const BLOCK_DATA_PATH := "res://data/blocks.csv"
const SEA_LEVEL_DEPTH := 30
const SEA_LEVEL_MIN := 8
#endregion

#region Constants - Workers
const WORKER_SPAWN_HEIGHT_OFFSET := 1.0
const WORKER_SPAWN_OFFSETS := [
	Vector2i(-10, -10),
	Vector2i(10, -10),
	Vector2i(-10, 10),
	Vector2i(10, 10),
]
#endregion

#region Constants - Misc
const VISIBILITY_Y_OFFSET := 1.0
const DUMMY_INT := 666
#endregion

#region World State
var world_size_x := CHUNK_SIZE * WORLD_CHUNKS_X
var world_size_y := CHUNK_SIZE * WORLD_CHUNKS_Y
var world_size_z := CHUNK_SIZE * WORLD_CHUNKS_Z
var sea_level := DUMMY_INT
var top_render_y := DUMMY_INT
var vertical_scroll := DUMMY_INT
var world_seed: int = 0
#endregion

#region Chunk State
var chunks: Dictionary = {}
var chunk_access_tick: int = 0
#endregion

#region Systems
var renderer: WorldRenderer
var block_registry = BlockRegistryScript.new()
var task_queue := TaskQueue.new()
var task_manager: TaskManager
var pathfinder := Pathfinder.new()
var generator: WorldGeneratorScript
var save_load: WorldSaveLoadScript
var streaming: WorldStreamingScript
var raycaster: WorldRaycasterScript
#endregion

#region Worker State
var workers: Array = []
var worker_chunk_cache: Dictionary = {}
#endregion

#region Player State
enum PlayerMode {INFORMATION, DIG, PLACE, STAIRS}
var player_mode := PlayerMode.DIG
var selected_blocks: Dictionary = {}
#endregion


#region Lifecycle
func _ready() -> void:
	block_registry.load_from_csv(BLOCK_DATA_PATH)
	task_manager = TaskManager.new(self, task_queue)
	generator = WorldGeneratorScript.new(self)
	save_load = WorldSaveLoadScript.new(self)
	streaming = WorldStreamingScript.new(self)
	raycaster = WorldRaycasterScript.new(self)
	renderer = WorldRenderer.new()
	add_child(renderer)
	renderer.initialize(self)
	init_world(false)
#endregion


#region World Initialization
func init_world(seed_world_flag: bool = true) -> void:
	chunks.clear()
	chunk_access_tick = 0
	sea_level = max(world_size_y - SEA_LEVEL_DEPTH, SEA_LEVEL_MIN)
	top_render_y = sea_level
	if renderer != null:
		renderer.reset_stats()
	reset_streaming_state()
	worker_chunk_cache.clear()
	if seed_world_flag:
		if world_seed == 0:
			world_seed = generator.generate_world_seed()
		generator.seed_all_chunks()
		spawn_initial_workers()


func start_new_world(seed_value: int = -1) -> void:
	init_world(false)
	world_seed = seed_value if seed_value >= 0 else generator.generate_world_seed()
	generator.prime_spawn_chunks()
	spawn_initial_workers()
#endregion


#region Save/Load
func save_world(path: String) -> bool:
	return save_load.save_world(path)


func load_world(path: String) -> bool:
	return save_load.load_world(path)
#endregion


#region Chunk Utilities
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
	generator.generate_chunk(coord, chunk)
	return chunk

func touch_chunk(chunk: ChunkDataType) -> void:
	chunk_access_tick += 1
	chunk.last_access_tick = chunk_access_tick


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
	generator.generate_chunk(coord, temp)
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
#endregion


#region Block Access
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
#endregion


#region Rendering Stats
func get_draw_burden_stats() -> Dictionary:
	if renderer == null:
		return {"drawn": 0, "culled": 0, "percent": 0.0}
	return renderer.get_draw_burden_stats()


func get_camera_tris_rendered(camera: Camera3D) -> Dictionary:
	if renderer == null:
		return {"rendered": 0, "total": 0, "percent": 0.0}
	return renderer.get_camera_tris_rendered(camera)
#endregion


#region World Update Loop
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
#endregion


#region Streaming
func reset_streaming_state() -> void:
	if streaming != null:
		streaming.reset_state()


func update_streaming(camera_pos: Vector3, dt: float) -> void:
	if streaming != null:
		streaming.update_streaming(camera_pos, dt)
#endregion


#region Workers
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


func clear_and_respawn_workers() -> void:
	for worker in workers:
		worker.queue_free()
	workers.clear()
	worker_chunk_cache.clear()
	spawn_initial_workers()
#endregion


#region Drag Preview
func set_drag_preview(rect: Dictionary, mode: int) -> void:
	if renderer != null:
		renderer.set_drag_preview(rect, mode)


func clear_drag_preview() -> void:
	if renderer != null:
		renderer.clear_drag_preview()
#endregion


#region Render Height
func set_top_render_y(new_y: int) -> void:
	var old_y: int = top_render_y
	top_render_y = clamp(new_y, 0, world_size_y - 1)
	if top_render_y == old_y:
		return
	if streaming != null and streaming.last_stream_target_valid:
		var target_x: int = int(floor(streaming.last_stream_target.x))
		var target_z: int = int(floor(streaming.last_stream_target.z))
		var target_coord := world_to_chunk_coords(target_x, top_render_y, target_z)
		ensure_chunk_buffer_for_chunk(target_coord)
	if renderer != null:
		if streaming != null and streaming.stream_min_x <= streaming.stream_max_x and streaming.stream_min_z <= streaming.stream_max_z:
			renderer.update_render_height_in_range(old_y, top_render_y, streaming.stream_min_x, streaming.stream_max_x, streaming.stream_min_z, streaming.stream_max_z)
		else:
			renderer.update_render_height(old_y, top_render_y)


func is_visible_at_level(y_value: float) -> bool:
	return y_value <= top_render_y + VISIBILITY_Y_OFFSET
#endregion


#region Raycasting
func raycast_block(ray_origin: Vector3, ray_dir: Vector3, max_distance: float) -> Dictionary:
	if raycaster != null:
		return raycaster.raycast_block(ray_origin, ray_dir, max_distance)
	return {"hit": false}
#endregion
