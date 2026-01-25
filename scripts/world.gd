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
const RAMP_NORTH_ID := 100
const RAMP_SOUTH_ID := 101
const RAMP_EAST_ID := 102
const RAMP_WEST_ID := 103
const RAMP_NORTHEAST_ID := 104
const RAMP_NORTHWEST_ID := 105
const RAMP_SOUTHEAST_ID := 106
const RAMP_SOUTHWEST_ID := 107
const INNER_SOUTHWEST_ID := 108
const INNER_SOUTHEAST_ID := 109
const INNER_NORTHWEST_ID := 110
const INNER_NORTHEAST_ID := 111
const STAIR_BLOCK_ID := RAMP_NORTH_ID
const RAMP_BLOCK_IDS := [
	RAMP_NORTH_ID,
	RAMP_SOUTH_ID,
	RAMP_EAST_ID,
	RAMP_WEST_ID,
	RAMP_NORTHEAST_ID,
	RAMP_NORTHWEST_ID,
	RAMP_SOUTHEAST_ID,
	RAMP_SOUTHWEST_ID,
	INNER_SOUTHWEST_ID,
	INNER_SOUTHEAST_ID,
	INNER_NORTHWEST_ID,
	INNER_NORTHEAST_ID,
]
const DEFAULT_MATERIAL := BLOCK_ID_GRANITE
# Marching squares lookup: index = nw_high*1 + ne_high*2 + sw_high*4 + se_high*8
# Maps 4-bit corner configuration to ramp ID (-1 = no ramp)
const MARCHING_SQUARES_RAMP := [
	-1,                  # 0:  0000 - all low, no ramp
	RAMP_NORTHWEST_ID,   # 1:  0001 - NW high (outer corner)
	RAMP_NORTHEAST_ID,   # 2:  0010 - NE high (outer corner)
	RAMP_NORTH_ID,       # 3:  0011 - NW+NE high (north edge)
	RAMP_SOUTHWEST_ID,   # 4:  0100 - SW high (outer corner)
	RAMP_WEST_ID,        # 5:  0101 - NW+SW high (west edge)
	-1,                  # 6:  0110 - NE+SW high (saddle point)
	INNER_SOUTHEAST_ID,  # 7:  0111 - NW+NE+SW high, SE low (inner corner)
	RAMP_SOUTHEAST_ID,   # 8:  1000 - SE high (outer corner)
	-1,                  # 9:  1001 - NW+SE high (saddle point)
	RAMP_EAST_ID,        # 10: 1010 - NE+SE high (east edge)
	INNER_SOUTHWEST_ID,  # 11: 1011 - NW+NE+SE high, SW low (inner corner)
	RAMP_SOUTH_ID,       # 12: 1100 - SW+SE high (south edge)
	INNER_NORTHEAST_ID,  # 13: 1101 - NW+SW+SE high, NE low (inner corner)
	INNER_NORTHWEST_ID,  # 14: 1110 - NE+SW+SE high, NW low (inner corner)
	-1,                  # 15: 1111 - all high, no ramp
]
#endregion

#region Constants - World Generation
const BLOCK_DATA_PATH := "res://data/blocks.csv"
const SEA_LEVEL_DEPTH := 30
const SEA_LEVEL_MIN := 8
#endregion

#region Constants - Workers
const WORKER_SPAWN_HEIGHT_OFFSET := 1.0
const WORKER_ACTIVITY_GRACE_SEC := 0.75
const WORKER_SPAWN_OFFSETS := [
	Vector2i(-10, -10),
	Vector2i(10, -10),
	Vector2i(-10, 10),
	Vector2i(10, 10),
]
#endregion

#region Constants - Misc
const VISIBILITY_Y_OFFSET := 1.0
const RENDER_HEIGHT_CHUNKS_PER_FRAME := 16
const GENERATION_APPLY_BUDGET := 8
const PREWARM_SYNC_RADIUS_CHUNKS_MIN := 6
const PREWARM_SYNC_RADIUS_CHUNKS_MAX := 16
const PREWARM_SYNC_LAYERS := 1
const DEPTH_VISIBILITY_PADDING := 1
const DUMMY_INT := 666
#endregion

#region World State
var world_size_y := CHUNK_SIZE * WORLD_CHUNKS_Y
var sea_level := DUMMY_INT
var top_render_y := DUMMY_INT
var world_seed: int = 0
var spawn_coord := Vector3i.ZERO
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
var debug_profiler: DebugProfiler
#endregion

#region Worker State
var workers: Array = []
var worker_chunk_cache: Dictionary = {}
var worker_activity_timer: float = 0.0
#endregion

#region Player State
enum PlayerMode {INFORMATION, DIG, PLACE, STAIRS}
var player_mode := PlayerMode.DIG
var selected_blocks: Dictionary = {}
#endregion

#region Depth Visibility
var deepest_structure_y: int = DUMMY_INT
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
	clear_tasks()
	clear_workers()
	if renderer != null:
		renderer.clear_chunks()
	chunks.clear()
	chunk_access_tick = 0
	sea_level = max(world_size_y - SEA_LEVEL_DEPTH, SEA_LEVEL_MIN)
	top_render_y = sea_level
	spawn_coord = Vector3i(0, sea_level, 0)
	deepest_structure_y = sea_level
	if generator != null:
		generator.reset_generation_jobs()
	if renderer != null:
		renderer.reset_stats()
		renderer.set_top_render_y(top_render_y)
		renderer.set_min_render_y(get_min_render_y())
	reset_streaming_state()
	if seed_world_flag:
		if world_seed == 0:
			world_seed = generator.generate_world_seed()
		generator.prime_spawn_chunks()
		spawn_initial_workers()


func start_new_world(seed_value: int = -1) -> void:
	if save_load != null:
		save_load.clear_world_dir()
	init_world(false)
	world_seed = seed_value if seed_value >= 0 else generator.generate_world_seed()
	generator.prime_spawn_chunks()
	spawn_initial_workers()
#endregion


#region Save/Load
func save_world(path: String) -> bool:
	return save_load.save_world(path)


func load_world(path: String) -> bool:
	var ok := save_load.load_world(path)
	if ok:
		clear_tasks()
	if ok and renderer != null:
		renderer.set_top_render_y(top_render_y)
	if ok and generator != null:
		generator.reset_generation_jobs()
	return ok
#endregion


#region Chunk Utilities
func world_to_chunk_coords(x: int, y: int, z: int) -> Vector3i:
	return Vector3i(
		floor_div(x, CHUNK_SIZE),
		floor_div(y, CHUNK_SIZE),
		floor_div(z, CHUNK_SIZE)
	)

func chunk_to_local_coords(x: int, y: int, z: int) -> Vector3i:
	return Vector3i(
		positive_mod(x, CHUNK_SIZE),
		positive_mod(y, CHUNK_SIZE),
		positive_mod(z, CHUNK_SIZE)
	)

func floor_div(a: int, b: int) -> int:
	return int(floor(float(a) / float(b)))

func positive_mod(a: int, b: int) -> int:
	var r := a % b
	return r + b if r < 0 else r

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
	if save_load != null and save_load.load_chunk_into(coord, chunk):
		touch_chunk(chunk)
		return chunk
	generator.generate_chunk(coord, chunk)
	return chunk


func request_chunk_generation_async(coord: Vector3i, high_priority: bool = false) -> bool:
	if not is_chunk_coord_valid(coord):
		return false
	var chunk := ensure_chunk(coord)
	if chunk.generated:
		return true
	if save_load != null and save_load.load_chunk_into(coord, chunk):
		touch_chunk(chunk)
		return true
	if generator != null:
		generator.queue_chunk_generation(coord, high_priority)
	return false


func unload_chunk(coord: Vector3i) -> void:
	var chunk: ChunkDataType = get_chunk(coord)
	if chunk == null:
		return
	if chunk.dirty and save_load != null:
		save_load.save_chunk_current(coord, chunk)
	if renderer != null:
		renderer.clear_chunk(coord)
	chunks.erase(coord)

func touch_chunk(chunk: ChunkDataType) -> void:
	chunk_access_tick += 1
	chunk.last_access_tick = chunk_access_tick


func is_chunk_coord_valid(coord: Vector3i) -> bool:
	var max_cy: int = int(floor(float(world_size_y) / float(CHUNK_SIZE)))
	return coord.y >= 0 and coord.y < max_cy


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
	if y < 0 or y >= world_size_y:
		return
	var coord := world_to_chunk_coords(x, y, z)
	var local := chunk_to_local_coords(x, y, z)
	var chunk: ChunkDataType = ensure_chunk(coord)
	var idx := chunk_index(local.x, local.y, local.z)
	var prev := int(chunk.blocks[idx])
	if prev == value:
		touch_chunk(chunk)
		return
	chunk.blocks[idx] = value
	if mark_dirty:
		chunk.dirty = true
		chunk.generated = true
		chunk.mesh_state = ChunkDataScript.MESH_STATE_NONE
		chunk.mesh_revision += 1
		if renderer != null:
			renderer.invalidate_chunk_mesh_cache(coord)
		_update_depth_visibility_from_change(y)
	touch_chunk(chunk)
#endregion


#region Block Access
func get_block(x: int, y: int, z: int) -> int:
	if y < 0 or y >= world_size_y:
		return BLOCK_ID_AIR
	var coord := world_to_chunk_coords(x, y, z)
	var chunk: ChunkDataType = ensure_chunk_generated(coord)
	touch_chunk(chunk)
	var local := chunk_to_local_coords(x, y, z)
	return chunk.blocks[chunk_index(local.x, local.y, local.z)]


func get_block_no_generate(x: int, y: int, z: int) -> int:
	if y < 0 or y >= world_size_y:
		return BLOCK_ID_AIR
	var coord := world_to_chunk_coords(x, y, z)
	var chunk: ChunkDataType = get_chunk(coord)
	if chunk == null:
		return BLOCK_ID_AIR
	var local := chunk_to_local_coords(x, y, z)
	return chunk.blocks[chunk_index(local.x, local.y, local.z)]


func set_block(x: int, y: int, z: int, value: int) -> void:
	if y < 0 or y >= world_size_y:
		return
	if value < 0 or value >= BlockRegistryScript.TABLE_SIZE:
		return
	set_block_raw(x, y, z, value, true)
	if renderer != null:
		var coord := world_to_chunk_coords(x, y, z)
		renderer.queue_chunk_mesh_build(coord, -1, false, true)
		var local := chunk_to_local_coords(x, y, z)
		_queue_neighbor_mesh_updates(coord, local)


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
	return not is_ramp_block_id(block_id) and block_registry.is_replaceable(block_id)


func is_stairs_at(x: int, y: int, z: int) -> bool:
	return is_ramp_block_id(get_block(x, y, z))


func is_ramp_block_id(block_id: int) -> bool:
	return RAMP_BLOCK_IDS.has(block_id)


func get_block_color(block_id: int) -> Color:
	return block_registry.get_color(block_id)


func get_block_name(block_id: int) -> String:
	return block_registry.get_name(block_id)
#endregion


func _queue_neighbor_mesh_updates(coord: Vector3i, local: Vector3i) -> void:
	var chunk_size := CHUNK_SIZE
	if local.x == 0:
		_queue_mesh_if_loaded(Vector3i(coord.x - 1, coord.y, coord.z))
	if local.x == chunk_size - 1:
		_queue_mesh_if_loaded(Vector3i(coord.x + 1, coord.y, coord.z))
	if local.y == 0:
		_queue_mesh_if_loaded(Vector3i(coord.x, coord.y - 1, coord.z))
	if local.y == chunk_size - 1:
		_queue_mesh_if_loaded(Vector3i(coord.x, coord.y + 1, coord.z))
	if local.z == 0:
		_queue_mesh_if_loaded(Vector3i(coord.x, coord.y, coord.z - 1))
	if local.z == chunk_size - 1:
		_queue_mesh_if_loaded(Vector3i(coord.x, coord.y, coord.z + 1))


func _queue_mesh_if_loaded(coord: Vector3i) -> void:
	if not is_chunk_coord_valid(coord):
		return
	var chunk: ChunkDataType = get_chunk(coord)
	if chunk == null or not chunk.generated:
		return
	chunk.mesh_state = ChunkDataScript.MESH_STATE_NONE
	chunk.mesh_revision += 1
	if renderer != null:
		renderer.invalidate_chunk_mesh_cache(coord)
		renderer.queue_chunk_mesh_build(coord, -1, false, true)


#region Rendering Stats
func get_draw_burden_stats() -> Dictionary:
	if renderer == null:
		return {"drawn": 0, "culled": 0, "percent": 0.0}
	return renderer.get_draw_burden_stats()


func get_chunk_draw_stats() -> Dictionary:
	if renderer == null:
		return {"loaded": 0, "meshed": 0, "visible": 0, "zone": 0}
	return renderer.get_chunk_draw_stats()


func get_camera_tris_rendered(camera: Camera3D) -> Dictionary:
	if renderer == null:
		return {"rendered": 0, "total": 0, "percent": 0.0}
	return renderer.get_camera_tris_rendered(camera)


func get_generation_stats() -> Dictionary:
	if generator == null:
		return {"queued": 0, "results": 0, "active": 0}
	return generator.get_generation_stats()
#endregion


#region World Update Loop
func update_world(dt: float) -> void:
	process_generation_results()
	update_render_height_queue()
	update_workers(dt)
	update_task_queue()
	update_task_overlays_phase()
	update_blocked_tasks(dt)
	update_reassign_tasks(dt)


func update_workers(dt: float) -> void:
	worker_activity_timer = max(0.0, worker_activity_timer - dt)
	for worker in workers:
		worker.update_worker(dt, self, task_queue, pathfinder)
		worker.visible = is_visible_at_level(worker.position.y)
		var coord: Vector3i = worker.get_block_coord()
		var last_coord: Vector3i = worker_chunk_cache.get(worker, Vector3i(-DUMMY_INT, -DUMMY_INT, -DUMMY_INT))
		if coord != last_coord:
			worker_chunk_cache[worker] = coord
			worker_activity_timer = WORKER_ACTIVITY_GRACE_SEC
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


func update_reassign_tasks(dt: float) -> void:
	if task_manager != null:
		task_manager.update_reassign_tasks(dt)


func update_render_height_queue() -> void:
	if renderer == null:
		return
	var render_budget := RENDER_HEIGHT_CHUNKS_PER_FRAME
	var mesh_budget_ms := renderer.MESH_WORK_BUDGET_MS
	if streaming != null and streaming.is_throttling():
		render_budget = max(1, int(floor(float(RENDER_HEIGHT_CHUNKS_PER_FRAME) * 0.25)))
		mesh_budget_ms = renderer.MESH_WORK_BUDGET_MS * 0.25
	renderer.process_render_height_queue(render_budget)
	renderer.process_mesh_results_time_budget(mesh_budget_ms)


func process_generation_results() -> void:
	if generator != null:
		var budget := GENERATION_APPLY_BUDGET
		if streaming != null:
			if streaming.is_throttling():
				budget = 1
			elif streaming.is_slow_moving():
				budget = 2
			elif streaming.is_moving():
				budget = 4
		generator.process_generation_results(budget)


func get_min_render_y() -> int:
	var base_y := sea_level
	if deepest_structure_y != DUMMY_INT:
		base_y = deepest_structure_y
	return clampi(base_y - DEPTH_VISIBILITY_PADDING, 0, world_size_y - 1)


func _update_depth_visibility_from_change(y: int) -> void:
	if deepest_structure_y == DUMMY_INT or y < deepest_structure_y:
		deepest_structure_y = y
		if renderer != null:
			renderer.set_min_render_y(get_min_render_y())


func is_render_height_busy() -> bool:
	if renderer == null:
		return false
	return renderer.has_pending_render_height_work()


func has_recent_worker_activity() -> bool:
	return worker_activity_timer > 0.0


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


func update_streaming(view_rect: Rect2, plane_y: float, dt: float) -> void:
	if streaming != null:
		streaming.update_streaming(view_rect, plane_y, dt)
	if renderer != null:
		var center_x: float = view_rect.position.x + view_rect.size.x * 0.5
		var center_z: float = view_rect.position.y + view_rect.size.y * 0.5
		renderer.update_render_height_anchor(Vector3(center_x, plane_y, center_z))


func prewarm_render_cache(view_rect: Rect2, plane_y: float) -> void:
	if streaming == null or renderer == null:
		return
	_prewarm_sync_chunks(view_rect, plane_y)
	streaming.warmup_streaming(view_rect, plane_y)
	renderer.flush_mesh_jobs(true, renderer.MESH_WORK_BUDGET_MS)


func _prewarm_sync_chunks(view_rect: Rect2, plane_y: float) -> void:
	if renderer == null:
		return
	if PREWARM_SYNC_LAYERS <= 0:
		return
	if view_rect.size.x <= 0.0 or view_rect.size.y <= 0.0:
		return
	var half_span_world: float = maxf(view_rect.size.x, view_rect.size.y) * 0.5
	var desired_radius: int = int(ceil(half_span_world / float(CHUNK_SIZE))) + 2
	if streaming != null:
		desired_radius = maxi(desired_radius, streaming.stream_radius_base)
	var radius_chunks: int = clampi(desired_radius, PREWARM_SYNC_RADIUS_CHUNKS_MIN, PREWARM_SYNC_RADIUS_CHUNKS_MAX)
	var center_x: float = view_rect.position.x + view_rect.size.x * 0.5
	var center_z: float = view_rect.position.y + view_rect.size.y * 0.5
	var anchor := world_to_chunk_coords(int(floor(center_x)), int(floor(plane_y)), int(floor(center_z)))
	for layer in range(PREWARM_SYNC_LAYERS):
		var cy: int = anchor.y - layer
		if cy < 0:
			continue
		for dx in range(-radius_chunks, radius_chunks + 1):
			for dz in range(-radius_chunks, radius_chunks + 1):
				var coord := Vector3i(anchor.x + dx, cy, anchor.z + dz)
				if not is_chunk_coord_valid(coord):
					continue
				ensure_chunk_generated(coord)
				renderer.queue_chunk_mesh_build(coord, -1, false, true, true)
#endregion


func _exit_tree() -> void:
	if generator != null:
		generator.shutdown_generation_thread()


#region Workers
func spawn_initial_workers() -> void:
	var center_x: int = spawn_coord.x
	var center_z: int = spawn_coord.z
	for offset in WORKER_SPAWN_OFFSETS:
		var spawn_x: int = center_x + offset.x
		var spawn_z: int = center_z + offset.y
		var surface_y := find_surface_y(spawn_x, spawn_z)
		var worker := Worker.new()
		worker.position = Vector3(spawn_x, surface_y + WORKER_SPAWN_HEIGHT_OFFSET, spawn_z)
		add_child(worker)
		workers.append(worker)


func find_surface_y(x: int, z: int) -> int:
	if generator != null:
		return generator.get_surface_y(x, z)
	return clampi(sea_level, 0, world_size_y - 1)


func clear_and_respawn_workers() -> void:
	clear_workers()
	spawn_initial_workers()
#endregion


func clear_tasks() -> void:
	selected_blocks.clear()
	if task_queue != null:
		task_queue.tasks.clear()
		task_queue.next_id = 1
	if task_manager != null:
		task_manager.blocked_tasks.clear()
		task_manager.blocked_recheck_timer = 1.0
		task_manager.reassign_timer = 1.0


func clear_workers() -> void:
	for worker in workers:
		worker.queue_free()
	workers.clear()
	worker_chunk_cache.clear()


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
	top_render_y = clampi(new_y, 0, world_size_y - 1)
	if top_render_y == old_y:
		return
	if streaming != null and streaming.last_stream_target_valid:
		var target_x: int = int(floor(streaming.last_stream_target.x))
		var target_z: int = int(floor(streaming.last_stream_target.z))
		var target_coord := world_to_chunk_coords(target_x, top_render_y, target_z)
		ensure_chunk_buffer_for_chunk(target_coord)
	if renderer != null:
		renderer.set_top_render_y(top_render_y)
		renderer.clear_render_height_queue()
	return


func get_render_height_bounds() -> Dictionary:
	if streaming != null:
		var render_min_x: int = streaming.last_render_zone_min_cx
		var render_max_x: int = streaming.last_render_zone_max_cx
		var render_min_z: int = streaming.last_render_zone_min_cz
		var render_max_z: int = streaming.last_render_zone_max_cz
		if render_min_x != streaming.DUMMY_INT and render_max_x != -streaming.DUMMY_INT:
			if render_min_x <= render_max_x and render_min_z <= render_max_z:
				return {"min_x": render_min_x, "max_x": render_max_x, "min_z": render_min_z, "max_z": render_max_z}
		if streaming.stream_min_x <= streaming.stream_max_x and streaming.stream_min_z <= streaming.stream_max_z:
			var stream_min_x: int = streaming.stream_min_x
			var stream_max_x: int = streaming.stream_max_x
			var stream_min_z: int = streaming.stream_min_z
			var stream_max_z: int = streaming.stream_max_z
			return {"min_x": stream_min_x, "max_x": stream_max_x, "min_z": stream_min_z, "max_z": stream_max_z}
	var anchor := get_render_height_anchor()
	var radius := 8
	if streaming != null:
		radius = streaming.stream_radius_base
	var anchor_coord := world_to_chunk_coords(int(floor(anchor.x)), top_render_y, int(floor(anchor.z)))
	var anchor_min_x := anchor_coord.x - radius
	var anchor_max_x := anchor_coord.x + radius
	var anchor_min_z := anchor_coord.z - radius
	var anchor_max_z := anchor_coord.z + radius
	return {"min_x": anchor_min_x, "max_x": anchor_max_x, "min_z": anchor_min_z, "max_z": anchor_max_z}


func get_render_height_anchor() -> Vector3:
	if streaming != null and streaming.last_stream_target_valid:
		return streaming.last_stream_target
	return Vector3(0.0, float(top_render_y), 0.0)


func is_visible_at_level(y_value: float) -> bool:
	return y_value <= top_render_y + VISIBILITY_Y_OFFSET
#endregion


#region Raycasting
func raycast_block(ray_origin: Vector3, ray_dir: Vector3, max_distance: float) -> Dictionary:
	if raycaster != null:
		return raycaster.raycast_block(ray_origin, ray_dir, max_distance)
	return {"hit": false}
#endregion
