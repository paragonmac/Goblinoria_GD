extends Node3D
class_name World
## Voxel world managing chunks, blocks, workers, and game state.

signal inventory_changed
signal stockpiles_changed
signal player_mode_changed(mode: int)
signal render_level_changed(level: int)

const OVERLAY_REFRESH_TASKS := 1
const OVERLAY_REFRESH_ITEMS := 2
const OVERLAY_REFRESH_STOCKPILES := 4
const OVERLAY_REFRESH_ALL := \
	OVERLAY_REFRESH_TASKS | OVERLAY_REFRESH_ITEMS | OVERLAY_REFRESH_STOCKPILES

#region Preloads
const BlockRegistryScript = preload("res://scripts/block_registry.gd")
const ChunkDataScript = preload("res://scripts/chunk_data.gd")
const WorldGeneratorScript = preload("res://scripts/world_generator.gd")
const WorldSaveLoadScript = preload("res://scripts/world_save_load.gd")
const WorldArenaCookerScript = preload("res://scripts/world_arena_cooker.gd")
const WorldStreamingScript = preload("res://scripts/world_streaming.gd")
const WorldRaycasterScript = preload("res://scripts/world_raycaster.gd")
const WorldInventoryScript = preload("res://scripts/world/world_inventory.gd")
const BlockDropTableScript = preload("res://scripts/world/block_drop_table.gd")
const ItemStackStoreScript = preload("res://scripts/world/item_stack_store.gd")
const StockpileStoreScript = preload("res://scripts/world/stockpile_store.gd")
const WorldChunkSpaceScript = preload("res://scripts/world/world_chunk_space.gd")
const WorkerTraceScript = preload("res://scripts/diagnostics/worker_trace.gd")
const ChunkDataType = ChunkDataScript
#endregion

#region Constants - World Size
const CHUNK_SIZE := 8
const CHUNK_VOLUME := CHUNK_SIZE * CHUNK_SIZE * CHUNK_SIZE
const WORLD_CHUNKS_X := 32
const WORLD_CHUNKS_Y := 32
const WORLD_CHUNKS_Z := 32
const WORLD_MIN_CHUNK_X := -16
const WORLD_MAX_CHUNK_X := 15
const WORLD_MIN_CHUNK_Z := -16
const WORLD_MAX_CHUNK_Z := 15
const WORLD_MIN_BLOCK_X := WORLD_MIN_CHUNK_X * CHUNK_SIZE
const WORLD_MAX_BLOCK_X := (WORLD_MAX_CHUNK_X + 1) * CHUNK_SIZE - 1
const WORLD_MIN_BLOCK_Z := WORLD_MIN_CHUNK_Z * CHUNK_SIZE
const WORLD_MAX_BLOCK_Z := (WORLD_MAX_CHUNK_Z + 1) * CHUNK_SIZE - 1
#endregion

#region Constants - Block IDs
const BLOCK_ID_AIR := 0
const BLOCK_ID_GRANITE := 1
const BLOCK_ID_DIRT := 2
const BLOCK_ID_CLAY := 3
const BLOCK_ID_SANDSTONE := 4
const BLOCK_ID_LIMESTONE := 5
const BLOCK_ID_BASALT := 6
const BLOCK_ID_SLATE := 7
const BLOCK_ID_IRON_ORE := 8
const BLOCK_ID_COAL := 9
const BLOCK_ID_GRASS := 10
const BLOCK_ID_WATER := 11
const BLOCK_ID_LOG := 12
const BLOCK_ID_LEAVES := 13
const BLOCK_ID_FLOWER := 14
const BLOCK_ID_GRAVEL := 15
const BLOCK_ID_MOSS := 16
const PLACE_MATERIAL_ID := BLOCK_ID_IRON_ORE
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
# Generated terrain slopes deliberately use a separate ID range from player stairs.
# SEE-ADR-011: Their level-cut visibility must not inherit the player-stair exception.
const TERRAIN_SLOPE_NORTH_ID := 112
const TERRAIN_SLOPE_SOUTH_ID := 113
const TERRAIN_SLOPE_EAST_ID := 114
const TERRAIN_SLOPE_WEST_ID := 115
const TERRAIN_SLOPE_NORTHEAST_ID := 116
const TERRAIN_SLOPE_NORTHWEST_ID := 117
const TERRAIN_SLOPE_SOUTHEAST_ID := 118
const TERRAIN_SLOPE_SOUTHWEST_ID := 119
const TERRAIN_INNER_SOUTHWEST_ID := 120
const TERRAIN_INNER_SOUTHEAST_ID := 121
const TERRAIN_INNER_NORTHWEST_ID := 122
const TERRAIN_INNER_NORTHEAST_ID := 123
const STAIR_BLOCK_ID := RAMP_NORTH_ID
const PLAYER_STAIR_BLOCK_IDS := [
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
const TERRAIN_SLOPE_BLOCK_IDS := [
	TERRAIN_SLOPE_NORTH_ID,
	TERRAIN_SLOPE_SOUTH_ID,
	TERRAIN_SLOPE_EAST_ID,
	TERRAIN_SLOPE_WEST_ID,
	TERRAIN_SLOPE_NORTHEAST_ID,
	TERRAIN_SLOPE_NORTHWEST_ID,
	TERRAIN_SLOPE_SOUTHEAST_ID,
	TERRAIN_SLOPE_SOUTHWEST_ID,
	TERRAIN_INNER_SOUTHWEST_ID,
	TERRAIN_INNER_SOUTHEAST_ID,
	TERRAIN_INNER_NORTHWEST_ID,
	TERRAIN_INNER_NORTHEAST_ID,
]
const RAMP_BLOCK_IDS := PLAYER_STAIR_BLOCK_IDS + TERRAIN_SLOPE_BLOCK_IDS
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
const BLOCK_DROPS_PATH := "res://data/block_drops.csv"
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
const DEPTH_VISIBILITY_LIMIT_ENABLED := false
const DEPTH_VISIBILITY_PADDING := 1
const UNINITIALIZED_Y := -1
#endregion

#region World State
var world_size_x := CHUNK_SIZE * WORLD_CHUNKS_X
var world_size_y := CHUNK_SIZE * WORLD_CHUNKS_Y
var world_size_z := CHUNK_SIZE * WORLD_CHUNKS_Z
var sea_level := UNINITIALIZED_Y
var top_render_y := UNINITIALIZED_Y
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
var arena_cooker: WorldArenaCookerScript
var streaming: WorldStreamingScript
var raycaster: WorldRaycasterScript
var debug_profiler: DebugProfiler
var worker_trace = WorkerTraceScript.new()
#endregion

#region Worker State
var workers: Array = []
var worker_chunk_cache: Dictionary = {}
var worker_activity_timer: float = 0.0
#endregion

#region Player State
enum PlayerMode {INFORMATION, DIG, PLACE, UP_STAIRS, DOWN_STAIRS, ERASE, STOCKPILE}
var player_mode := PlayerMode.DIG
var selected_blocks: Dictionary = {}
#endregion

#region Depth Visibility
var deepest_structure_y: int = UNINITIALIZED_Y
#endregion

#region Inventory
var inventory_store = WorldInventoryScript.new()
var inventory: Dictionary = inventory_store.items
var block_drop_table = BlockDropTableScript.new()
var item_store = ItemStackStoreScript.new()
var stockpile_store = StockpileStoreScript.new()
var drop_rng := RandomNumberGenerator.new()
var overlay_refresh_mask := OVERLAY_REFRESH_ALL
var overlay_refresh_counts := {
	"tasks": 0,
	"items": 0,
	"stockpiles": 0,
}
#endregion

#region Ramp Lookup Table
var _ramp_lookup := PackedByteArray()
#endregion


#region Lifecycle
func _ready() -> void:
	_init_ramp_lookup()
	block_registry.load_from_csv(BLOCK_DATA_PATH)
	block_drop_table.load_from_csv(BLOCK_DROPS_PATH)
	drop_rng.seed = Time.get_ticks_usec()
	stockpile_store.haul_state_changed.connect(_on_stockpile_state_changed)
	task_queue.task_visual_state_changed.connect(_on_task_visual_state_changed)
	item_store.visual_state_changed.connect(_on_item_visual_state_changed)
	stockpile_store.visual_state_changed.connect(_on_stockpile_visual_state_changed)
	task_manager = TaskManager.new(self, task_queue)
	generator = WorldGeneratorScript.new(self)
	save_load = WorldSaveLoadScript.new(self)
	arena_cooker = WorldArenaCookerScript.new(self)
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
	clear_inventory()
	clear_items_and_stockpiles()
	if renderer != null:
		renderer.clear_chunks()
	request_overlay_refresh(OVERLAY_REFRESH_ALL)
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
		renderer.set_min_render_y(get_min_render_y())
	if ok and generator != null:
		generator.reset_generation_jobs()
	return ok
#endregion


#region Chunk Utilities
func world_to_chunk_coords(x: int, y: int, z: int) -> Vector3i:
	return WorldChunkSpaceScript.world_to_chunk_coords(x, y, z)

func chunk_to_local_coords(x: int, y: int, z: int) -> Vector3i:
	return WorldChunkSpaceScript.chunk_to_local_coords(x, y, z)

func floor_div(a: int, b: int) -> int:
	return WorldChunkSpaceScript.floor_div(a, b)

func positive_mod(a: int, b: int) -> int:
	return WorldChunkSpaceScript.positive_mod(a, b)

func chunk_index(lx: int, ly: int, lz: int) -> int:
	return WorldChunkSpaceScript.chunk_index(lx, ly, lz)

func get_chunk(coord: Vector3i) -> ChunkDataType:
	if not is_chunk_coord_valid(coord):
		return null
	if chunks.has(coord):
		var chunk: ChunkDataType = chunks[coord]
		return chunk
	return null

func ensure_chunk(coord: Vector3i) -> ChunkDataType:
	if not is_chunk_coord_valid(coord):
		return null
	if chunks.has(coord):
		var existing: ChunkDataType = chunks[coord]
		return existing
	var chunk: ChunkDataType = ChunkDataScript.new(CHUNK_SIZE, BLOCK_ID_AIR)
	chunks[coord] = chunk
	return chunk

func ensure_chunk_generated(coord: Vector3i) -> ChunkDataType:
	var chunk := ensure_chunk(coord)
	if chunk == null:
		return null
	if chunk.generated:
		return chunk
	if save_load != null and save_load.load_chunk_into(coord, chunk):
		touch_chunk(chunk)
		notify_chunk_loaded(coord)
		return chunk
	generator.generate_chunk(coord, chunk)
	if chunk.generated:
		notify_chunk_loaded(coord)
	return chunk


func request_chunk_generation_async(coord: Vector3i, high_priority: bool = false, queue_mesh_on_complete: bool = true) -> bool:
	if not is_chunk_coord_valid(coord):
		return false
	var chunk := ensure_chunk(coord)
	if chunk.generated:
		return true
	if save_load != null and save_load.load_chunk_into(coord, chunk):
		touch_chunk(chunk)
		notify_chunk_loaded(coord)
		return true
	if generator != null:
		generator.queue_chunk_generation(coord, high_priority, queue_mesh_on_complete)
	return false


func notify_chunk_loaded(coord: Vector3i) -> void:
	if renderer != null:
		renderer.notify_chunk_loaded(coord)


func touch_chunk(chunk: ChunkDataType) -> void:
	chunk_access_tick += 1
	chunk.last_access_tick = chunk_access_tick


func is_chunk_coord_valid(coord: Vector3i) -> bool:
	return WorldChunkSpaceScript.is_chunk_coord_valid_for_height(coord, world_size_y)


func is_block_xz_valid(x: int, z: int) -> bool:
	return WorldChunkSpaceScript.is_block_xz_valid(x, z)


func is_block_coord_valid(x: int, y: int, z: int) -> bool:
	return WorldChunkSpaceScript.is_block_coord_valid(x, y, z, world_size_y)


func clamp_block_xz(pos: Vector3) -> Vector3:
	return WorldChunkSpaceScript.clamp_block_xz(pos)


func get_world_bounds_rect() -> Rect2:
	return WorldChunkSpaceScript.world_bounds_rect(world_size_x, world_size_z)


func ensure_chunk_buffer_for_pos(pos: Vector3i) -> void:
	if not is_block_coord_valid(pos.x, pos.y, pos.z):
		return
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
	if existing == null:
		return false
	var temp: ChunkDataType = ChunkDataScript.new(CHUNK_SIZE, BLOCK_ID_AIR)
	generator.generate_chunk(coord, temp)
	if temp.blocks.size() != existing.blocks.size():
		return false
	for i in range(temp.blocks.size()):
		if temp.blocks[i] != existing.blocks[i]:
			return false
	return true


func set_block_raw(x: int, y: int, z: int, value: int, mark_dirty: bool) -> void:
	if not is_block_coord_valid(x, y, z):
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
		if task_manager != null:
			task_manager.invalidate_task_accessibility(Vector3i(x, y, z))
		if renderer != null:
			renderer.invalidate_chunk_mesh_cache(coord)
		_update_depth_visibility_from_change(y)
	touch_chunk(chunk)
#endregion


#region Block Access
func get_block(x: int, y: int, z: int) -> int:
	if not is_block_coord_valid(x, y, z):
		return BLOCK_ID_AIR
	var coord := world_to_chunk_coords(x, y, z)
	var chunk: ChunkDataType = ensure_chunk_generated(coord)
	if chunk == null:
		return BLOCK_ID_AIR
	touch_chunk(chunk)
	var local := chunk_to_local_coords(x, y, z)
	return chunk.blocks[chunk_index(local.x, local.y, local.z)]


func get_block_no_generate(x: int, y: int, z: int) -> int:
	if not is_block_coord_valid(x, y, z):
		return BLOCK_ID_AIR
	var coord := world_to_chunk_coords(x, y, z)
	var chunk: ChunkDataType = get_chunk(coord)
	if chunk == null:
		return BLOCK_ID_AIR
	var local := chunk_to_local_coords(x, y, z)
	return chunk.blocks[chunk_index(local.x, local.y, local.z)]


func set_block(x: int, y: int, z: int, value: int) -> void:
	if not is_block_coord_valid(x, y, z):
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
	if not is_block_coord_valid(x, y, z):
		return false
	return is_block_empty_id(get_block(x, y, z))


func is_diggable_at(x: int, y: int, z: int) -> bool:
	if not is_block_coord_valid(x, y, z):
		return false
	return block_registry.get_hardness(get_block(x, y, z)) > 0.0


func can_place_stairs_at(x: int, y: int, z: int) -> bool:
	if not is_block_coord_valid(x, y, z):
		return false
	var block_id := get_block(x, y, z)
	if is_ramp_block_id(block_id):
		return false
	if is_block_empty_id(block_id):
		if y <= 0:
			return false
		var below_block: int = get_block(x, y - 1, z)
		return is_block_solid_id(below_block) and not is_ramp_block_id(below_block)
	return block_registry.is_replaceable(block_id)


func is_stairs_at(x: int, y: int, z: int) -> bool:
	if not is_block_coord_valid(x, y, z):
		return false
	return is_ramp_block_id(get_block(x, y, z))


func is_ramp_block_id(block_id: int) -> bool:
	if block_id < 0 or block_id >= _ramp_lookup.size():
		return false
	return _ramp_lookup[block_id] != 0


static func is_terrain_slope_block_id(block_id: int) -> bool:
	return block_id >= TERRAIN_SLOPE_NORTH_ID and block_id <= TERRAIN_INNER_NORTHEAST_ID


static func ramp_shape_id(block_id: int) -> int:
	if is_terrain_slope_block_id(block_id):
		return block_id - (TERRAIN_SLOPE_NORTH_ID - RAMP_NORTH_ID)
	return block_id


static func terrain_slope_id_for_shape(ramp_id: int) -> int:
	var shape_id := ramp_shape_id(ramp_id)
	if shape_id < RAMP_NORTH_ID or shape_id > INNER_NORTHEAST_ID:
		return -1
	return shape_id + (TERRAIN_SLOPE_NORTH_ID - RAMP_NORTH_ID)


func _init_ramp_lookup() -> void:
	_ramp_lookup.resize(BlockRegistryScript.TABLE_SIZE)
	_ramp_lookup.fill(0)
	for ramp_id in RAMP_BLOCK_IDS:
		if ramp_id >= 0 and ramp_id < _ramp_lookup.size():
			_ramp_lookup[ramp_id] = 1


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
	update_task_assignments()
	update_workers(dt)
	update_task_queue()
	update_task_accessibility()
	update_reassign_tasks(dt)
	update_task_overlays_phase()


func update_workers(dt: float) -> void:
	worker_activity_timer = max(0.0, worker_activity_timer - dt)
	for worker in workers:
		worker.update_worker(dt, self, task_queue, pathfinder)
		worker.visible = is_visible_at_level(worker.position.y)
		var coord: Vector3i = worker.get_block_coord()
		var last_coord: Vector3i = worker_chunk_cache.get(worker, Vector3i(-999999, -999999, -999999))
		if coord != last_coord:
			worker_chunk_cache[worker] = coord
			worker_activity_timer = WORKER_ACTIVITY_GRACE_SEC
			ensure_chunk_buffer_for_pos(coord)


func update_task_assignments() -> void:
	if task_manager != null:
		task_manager.update_task_assignments()


func update_task_queue() -> void:
	if task_manager != null:
		task_manager.update_task_queue()


func update_task_overlays_phase() -> void:
	# SEE-ADR-010: Persistent overlay sections synchronize only after state changes.
	if renderer == null or overlay_refresh_mask == 0:
		return
	var refresh_mask := overlay_refresh_mask
	overlay_refresh_mask = 0
	if (refresh_mask & OVERLAY_REFRESH_TASKS) != 0:
		renderer.update_task_overlays(task_queue.tasks)
		overlay_refresh_counts["tasks"] = int(overlay_refresh_counts["tasks"]) + 1
	if (refresh_mask & OVERLAY_REFRESH_ITEMS) != 0:
		renderer.update_item_overlays(item_store.items)
		overlay_refresh_counts["items"] = int(overlay_refresh_counts["items"]) + 1
	if (refresh_mask & OVERLAY_REFRESH_STOCKPILES) != 0:
		renderer.update_stockpile_overlays(stockpile_store.stockpiles)
		overlay_refresh_counts["stockpiles"] = int(overlay_refresh_counts["stockpiles"]) + 1


func request_overlay_refresh(mask: int) -> void:
	overlay_refresh_mask |= mask


func _on_task_visual_state_changed(_task_id: int) -> void:
	request_overlay_refresh(OVERLAY_REFRESH_TASKS)


func _on_item_visual_state_changed(_reason: String) -> void:
	request_overlay_refresh(OVERLAY_REFRESH_ITEMS)


func _on_stockpile_visual_state_changed(_reason: String) -> void:
	request_overlay_refresh(OVERLAY_REFRESH_STOCKPILES)

func update_task_accessibility() -> void:
	if task_manager != null:
		task_manager.update_task_accessibility()


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
	if not DEPTH_VISIBILITY_LIMIT_ENABLED:
		return 0
	var base_y := sea_level
	if deepest_structure_y != UNINITIALIZED_Y:
		base_y = deepest_structure_y
	return clampi(base_y - DEPTH_VISIBILITY_PADDING, 0, world_size_y - 1)


func _update_depth_visibility_from_change(y: int) -> void:
	if deepest_structure_y == UNINITIALIZED_Y or y < deepest_structure_y:
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


func queue_task_request(task_type: int, pos: Vector3i, material: int) -> bool:
	if not is_block_coord_valid(pos.x, pos.y, pos.z):
		return false
	ensure_chunk_buffer_for_pos(pos)
	if task_manager != null:
		return task_manager.queue_task_request(task_type, pos, material)
	return false


func cancel_pending_task_requests_at(pos: Vector3i) -> Array:
	if task_manager == null:
		return []
	return task_manager.cancel_pending_task_requests_at(pos)


func has_pending_task_request_at(pos: Vector3i) -> bool:
	if task_queue == null:
		return false
	return task_queue.has_pending_task_at(pos)
#endregion


#region Inventory
func add_to_inventory(block_id: int, count: int = 1) -> void:
	inventory_store.add(block_id, count)
	inventory_changed.emit()


func remove_from_inventory(block_id: int, count: int = 1) -> bool:
	var removed := item_store.remove_stored_material(block_id, count)
	if removed:
		refresh_inventory_from_stockpiles()
	return removed


func get_inventory_count(block_id: int) -> int:
	return int(item_store.aggregate_stored_counts().get(block_id, 0))


func clear_inventory() -> void:
	var had_inventory := not inventory.is_empty()
	inventory_store.clear()
	if had_inventory:
		inventory_changed.emit()


func refresh_inventory_from_stockpiles() -> void:
	var previous := inventory.duplicate()
	inventory_store.clear()
	var counts := item_store.aggregate_stored_counts()
	for material_id in counts.keys():
		inventory_store.add(int(material_id), int(counts[material_id]))
	if previous != inventory:
		inventory_changed.emit()


func _on_stockpile_state_changed(_reason: String) -> void:
	stockpiles_changed.emit()


func set_player_mode(mode: int) -> void:
	if player_mode == mode:
		return
	player_mode = mode
	player_mode_changed.emit(player_mode)


func clear_items_and_stockpiles() -> void:
	item_store.clear()
	stockpile_store.clear()
	refresh_inventory_from_stockpiles()


func spawn_mining_drops(source_block_id: int, pos: Vector3i) -> Array[int]:
	var spawned: Array[int] = []
	var legacy_drop_id: int = block_registry.get_drop(source_block_id)
	var drops := block_drop_table.resolve_drops(source_block_id, drop_rng, legacy_drop_id)
	for drop: Dictionary in drops:
		var material_id := int(drop.get("material_id", 0))
		var count := int(drop.get("count", 0))
		var item_id := item_store.add_stack(material_id, count, pos)
		if item_id < 0:
			continue
		spawned.append(item_id)
		trace_system_event("item_drop_spawned", "item_id=%d material=%d count=%d pos=%d,%d,%d source_block=%d" % [
			item_id,
			material_id,
			count,
			pos.x,
			pos.y,
			pos.z,
			source_block_id,
		])
	return spawned


func create_stockpile(cells: Array[Vector3i]) -> int:
	var stockpile_id := stockpile_store.create_stockpile(cells)
	trace_system_event("stockpile_created", "stockpile_id=%d cells=%d" % [stockpile_id, cells.size()])
	return stockpile_id


func remove_stockpile_cells(cells: Array[Vector3i]) -> Array[int]:
	for pos: Vector3i in cells:
		for stored_item: Dictionary in item_store.stored_items_at(pos):
			item_store.mark_loose(int(stored_item.get("id", -1)), pos)
	var touched := stockpile_store.remove_cells(cells)
	if not touched.is_empty():
		refresh_inventory_from_stockpiles()
		trace_system_event("stockpile_cells_removed", "stockpiles=%s cells=%d" % [touched, cells.size()])
	return touched


func is_stockpile_cell(pos: Vector3i) -> bool:
	return stockpile_store.stockpile_at(pos) >= 0


func find_stockpile_destination_for_item(item: Dictionary) -> Dictionary:
	if item.is_empty():
		return {}
	var material_id := int(item.get("material_id", 0))
	var from_pos: Vector3i = item.get("pos", Vector3i.ZERO)
	var best: Dictionary = {}
	var best_priority := 3
	var best_distance := INF
	for candidate: Dictionary in stockpile_store.candidate_cells_for_material(material_id):
		var pos: Vector3i = candidate.get("pos", Vector3i.ZERO)
		var stored := item_store.stored_item_at(pos)
		if not stored.is_empty() and int(stored.get("material_id", 0)) != material_id:
			continue
		var reserved := _reserved_haul_space_at(pos, material_id)
		if bool(reserved.get("blocked", false)):
			continue
		var used := int(stored.get("count", 0)) + int(reserved.get("count", 0))
		var capacity := stockpile_store.cell_capacity(pos)
		if used >= capacity:
			continue
		var priority := 0 if not stored.is_empty() else (1 if int(reserved.get("count", 0)) > 0 else 2)
		var distance := pos.distance_squared_to(from_pos)
		if best.is_empty() or priority < best_priority or (priority == best_priority and distance < best_distance):
			best_priority = priority
			best_distance = distance
			best = {
				"stockpile_id": int(candidate.get("stockpile_id", -1)),
				"pos": pos,
				"available_capacity": capacity - used,
			}
	return best


func _reserved_haul_space_at(pos: Vector3i, material_id: int) -> Dictionary:
	var reserved_count := 0
	if task_queue == null:
		return {"count": reserved_count, "blocked": false}
	for task in task_queue.tasks:
		if task.type != TaskQueue.TaskType.HAUL or task.status == TaskQueue.TaskStatus.COMPLETED:
			continue
		if task.data.get("destination", Vector3i.ZERO) != pos:
			continue
		if task.material != material_id:
			return {"count": reserved_count, "blocked": true}
		var reserved_item := item_store.get_item(int(task.data.get("item_id", -1)))
		reserved_count += mini(
			int(reserved_item.get("count", 0)),
			stockpile_store.cell_capacity(pos)
		)
	return {"count": reserved_count, "blocked": false}


func deposit_item_to_stockpile(item_id: int, stockpile_id: int, pos: Vector3i) -> bool:
	if not item_store.has_item(item_id):
		return false
	var item := item_store.get_item(item_id)
	var material_id := int(item.get("material_id", 0))
	if not stockpile_store.accepts_material(stockpile_id, material_id):
		return false
	if stockpile_store.stockpile_at(pos) != stockpile_id:
		return false
	var result := item_store.deposit_into_cell(
		item_id,
		stockpile_id,
		pos,
		stockpile_store.cell_capacity(pos)
	)
	if result.is_empty():
		return false
	refresh_inventory_from_stockpiles()
	trace_system_event("item_deposited", "item_id=%d material=%d count=%d remaining=%d stockpile=%d pos=%d,%d,%d" % [
		item_id,
		material_id,
		int(result.get("deposited", 0)),
		int(result.get("remaining", 0)),
		stockpile_id,
		pos.x,
		pos.y,
		pos.z,
	])
	return true
#endregion


#region Streaming
func reset_streaming_state() -> void:
	if streaming != null:
		streaming.reset_state()


func update_streaming(view_rect: Rect2, plane_y: float, dt: float, camera: Camera3D = null) -> void:
	if streaming != null:
		streaming.update_streaming(view_rect, plane_y, dt, camera)
	if renderer != null:
		var center_x: float = view_rect.position.x + view_rect.size.x * 0.5
		var center_z: float = view_rect.position.y + view_rect.size.y * 0.5
		renderer.update_render_height_anchor(clamp_block_xz(Vector3(center_x, plane_y, center_z)))


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
	var clamped_center := clamp_block_xz(Vector3(center_x, plane_y, center_z))
	var anchor := world_to_chunk_coords(int(floor(clamped_center.x)), int(floor(plane_y)), int(floor(clamped_center.z)))
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
	worker_trace.stop()
	if task_manager != null:
		task_manager.shutdown()
	if generator != null:
		generator.shutdown_generation_thread()


#region Workers
func spawn_initial_workers() -> void:
	_start_worker_trace_for_spawned_workers()
	var center_x: int = spawn_coord.x
	var center_z: int = spawn_coord.z
	for i in range(WORKER_SPAWN_OFFSETS.size()):
		var offset: Vector2i = WORKER_SPAWN_OFFSETS[i]
		var spawn_x: int = center_x + offset.x
		var spawn_z: int = center_z + offset.y
		var surface_y := find_surface_y(spawn_x, spawn_z)
		var worker := Worker.new()
		worker.worker_id = i + 1
		worker.position = Vector3(spawn_x, surface_y + WORKER_SPAWN_HEIGHT_OFFSET, spawn_z)
		add_child(worker)
		workers.append(worker)
		trace_worker_event(worker, "spawned")
	if task_manager != null:
		task_manager.notify_worker_availability_changed()


func find_surface_y(x: int, z: int) -> int:
	if not is_block_xz_valid(x, z):
		var clamped := clamp_block_xz(Vector3(float(x), 0.0, float(z)))
		x = int(clamped.x)
		z = int(clamped.z)
	if generator != null:
		return generator.get_surface_y(x, z)
	return clampi(sea_level, 0, world_size_y - 1)


func clear_and_respawn_workers() -> void:
	clear_workers()
	spawn_initial_workers()
#endregion


func _start_worker_trace_for_spawned_workers() -> void:
	if worker_trace == null:
		return
	worker_trace.start(workers)
	request_overlay_refresh(OVERLAY_REFRESH_TASKS)


func clear_tasks() -> void:
	selected_blocks.clear()
	if task_queue != null:
		task_queue.clear()
	if task_manager != null:
		task_manager.reassign_timer = task_manager.REASSIGN_INTERVAL
		task_manager.reset_accessibility_state()
		task_manager.reset_assignment_auction()
		task_manager.request_haul_rebuild("tasks_cleared")


func clear_workers() -> void:
	for worker in workers:
		trace_worker_event(worker, "despawned")
		worker.queue_free()
	workers.clear()
	worker_chunk_cache.clear()


func toggle_worker_trace() -> bool:
	if worker_trace.enabled:
		worker_trace.stop()
		request_overlay_refresh(OVERLAY_REFRESH_TASKS)
		return false
	var started := worker_trace.start(workers)
	request_overlay_refresh(OVERLAY_REFRESH_TASKS)
	return started


func trace_worker_event(worker: Worker, event: String, task = null, details: String = "") -> void:
	worker_trace.record(worker, event, task, details)


func trace_task_event(task, event: String, details: String = "") -> void:
	worker_trace.record_task_event(task, event, details)


func trace_system_event(event: String, details: String = "") -> void:
	worker_trace.record_system_event(event, details)


func get_workers_blocking_dig(pos: Vector3i) -> Array:
	var blocking_workers: Array = []
	for worker: Worker in workers:
		var worker_pos := worker.get_block_coord()
		if worker_pos.x == pos.x and worker_pos.y == pos.y + 1 and worker_pos.z == pos.z:
			blocking_workers.append(worker)
			continue
		if worker.current_task_id < 0 or worker.path.is_empty():
			continue
		var work_pos: Vector3i = worker.path[worker.path.size() - 1]
		if work_pos.x == pos.x and work_pos.y == pos.y + 1 and work_pos.z == pos.z:
			blocking_workers.append(worker)
	return blocking_workers


func is_block_protected_from_dig(pos: Vector3i) -> bool:
	return not get_workers_blocking_dig(pos).is_empty()


#region Drag Preview
func set_drag_preview(rect: Dictionary, mode: int) -> void:
	if renderer != null:
		renderer.set_drag_preview(rect, mode)


func set_drag_preview_entries(entries: Array, mode: int) -> void:
	if renderer != null:
		renderer.set_drag_preview_entries(entries, mode)


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
	request_overlay_refresh(OVERLAY_REFRESH_ALL)
	render_level_changed.emit(top_render_y)


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
	return {
		"min_x": clampi(anchor_min_x, WORLD_MIN_CHUNK_X, WORLD_MAX_CHUNK_X),
		"max_x": clampi(anchor_max_x, WORLD_MIN_CHUNK_X, WORLD_MAX_CHUNK_X),
		"min_z": clampi(anchor_min_z, WORLD_MIN_CHUNK_Z, WORLD_MAX_CHUNK_Z),
		"max_z": clampi(anchor_max_z, WORLD_MIN_CHUNK_Z, WORLD_MAX_CHUNK_Z),
	}


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
