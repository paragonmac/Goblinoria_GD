extends Node3D
class_name World
## Voxel world managing chunks, blocks, workers, and game state.

signal inventory_changed
signal stockpiles_changed
signal player_mode_changed(mode: int)
signal render_level_changed(level: int)

# Runtime-only identity, independent of optional diagnostics and persistence.
var runtime_epoch := 0
var light_field_async_max_frame_ms := 0.0
var light_field_async_total_ms := 0.0
var light_field_reveal_pump_ms := 0.0
var light_field_task_id := -1
var light_field_build_active := false
var defer_light_build_on_start := false
var defer_light_build_on_load := false

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
const AnomalyWatchdogScript = preload("res://scripts/diagnostics/anomaly_watchdog.gd")
const WorkerRolesScript = preload("res://scripts/worker_roles.gd")
const StairFlightScript = preload("res://scripts/stair_flight.gd")
const LightFieldScript = preload("res://scripts/world/light_field.gd")
const GoblinLightScript = preload("res://scripts/world/goblin_light.gd")
const TorchStoreScript = preload("res://scripts/world/torch_store.gd")
const TreeStoreScript = preload("res://scripts/world/tree_store.gd")
const ChunkDataType = ChunkDataScript
#endregion

#region Constants - World Size
const CHUNK_SIZE := 8
const CHUNK_VOLUME := CHUNK_SIZE * CHUNK_SIZE * CHUNK_SIZE
static var WORLD_CHUNKS_X := 32
const WORLD_CHUNKS_Y := 32
static var WORLD_CHUNKS_Z := 32
static var WORLD_MIN_CHUNK_X := -16
static var WORLD_MAX_CHUNK_X := 15
static var WORLD_MIN_CHUNK_Z := -16
static var WORLD_MAX_CHUNK_Z := 15
static var WORLD_MIN_BLOCK_X := WORLD_MIN_CHUNK_X * CHUNK_SIZE
static var WORLD_MAX_BLOCK_X := (WORLD_MAX_CHUNK_X + 1) * CHUNK_SIZE - 1
static var WORLD_MIN_BLOCK_Z := WORLD_MIN_CHUNK_Z * CHUNK_SIZE
static var WORLD_MAX_BLOCK_Z := (WORLD_MAX_CHUNK_Z + 1) * CHUNK_SIZE - 1
static var _dimension_jobs_in_flight := 0
static var _dimension_worlds: Array = []


func _init() -> void:
	var live_worlds: Array = []
	for world_ref: WeakRef in _dimension_worlds:
		if world_ref.get_ref() != null:
			live_worlds.append(world_ref)
	_dimension_worlds = live_worlds
	_dimension_worlds.append(weakref(self))


static func configure_dimensions(chunks_x: int, chunks_z: int) -> bool:
	if chunks_x < 16 or chunks_x > 128 or chunks_z < 16 or chunks_z > 128 \
			or not _is_power_of_two(chunks_x) or not _is_power_of_two(chunks_z):
		push_error("World dimensions must be powers of two from 16 to 128 chunks")
		return false
	if chunks_x == WORLD_CHUNKS_X and chunks_z == WORLD_CHUNKS_Z:
		return true
	if _dimension_jobs_in_flight > 0:
		push_error("Cannot reconfigure world dimensions while worker jobs are in flight")
		return false
	WORLD_CHUNKS_X = chunks_x
	WORLD_CHUNKS_Z = chunks_z
	WORLD_MIN_CHUNK_X = -chunks_x / 2
	WORLD_MAX_CHUNK_X = WORLD_MIN_CHUNK_X + chunks_x - 1
	WORLD_MIN_CHUNK_Z = -chunks_z / 2
	WORLD_MAX_CHUNK_Z = WORLD_MIN_CHUNK_Z + chunks_z - 1
	WORLD_MIN_BLOCK_X = WORLD_MIN_CHUNK_X * CHUNK_SIZE
	WORLD_MAX_BLOCK_X = (WORLD_MAX_CHUNK_X + 1) * CHUNK_SIZE - 1
	WORLD_MIN_BLOCK_Z = WORLD_MIN_CHUNK_Z * CHUNK_SIZE
	WORLD_MAX_BLOCK_Z = (WORLD_MAX_CHUNK_Z + 1) * CHUNK_SIZE - 1
	for world_ref: WeakRef in _dimension_worlds:
		var world = world_ref.get_ref()
		if world != null:
			world.world_size_x = CHUNK_SIZE * WORLD_CHUNKS_X
			world.world_size_y = CHUNK_SIZE * WORLD_CHUNKS_Y
			world.world_size_z = CHUNK_SIZE * WORLD_CHUNKS_Z
	return true


static func _is_power_of_two(value: int) -> bool:
	return value > 0 and (value & (value - 1)) == 0


static func register_dimension_job_started() -> void:
	_dimension_jobs_in_flight += 1


static func register_dimension_job_finished() -> void:
	_dimension_jobs_in_flight = maxi(0, _dimension_jobs_in_flight - 1)
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
const STAIR_FLIGHT_LOWER_BASE_ID := 124
const STAIR_FLIGHT_UPPER_BASE_ID := 128
const STAIR_FLIGHT_BLOCK_IDS := [124, 125, 126, 127, 128, 129, 130, 131]
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
	124,
	125,
	126,
	127,
	128,
	129,
	130,
	131,
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
const MAX_WORKERS := 200
const NEW_WORKER_WORK_PRIORITY := 2
const ITEM_MAX_FALL_CELLS := 64
const WORKER_ACTIVITY_GRACE_SEC := 0.75
const WORKER_SPAWN_OFFSETS := [
	Vector2i(-10, -10),
	Vector2i(10, -10),
	Vector2i(-10, 10),
	Vector2i(10, 10),
]
#endregion

#region Constants - Misc
const TORCH_HORIZONTAL_DIRECTIONS := [Vector3i.LEFT, Vector3i.RIGHT, Vector3i.FORWARD, Vector3i.BACK]
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
var light_field: LightFieldScript = LightFieldScript.new()
var light_field_built: bool = false
var light_field_arena_cook_seen: bool = false
var goblin_light: GoblinLightScript = GoblinLightScript.new()
var torch_store = TorchStoreScript.new()
var tree_store = TreeStoreScript.new()
var streaming: WorldStreamingScript
var raycaster: WorldRaycasterScript
var debug_profiler: DebugProfiler
# Main owns the recorder. Keep untyped so headless loading needs no class cache.
var performance_recorder = null
var live_diagnostics = null
var diagnostics_workers_revision := 0
var diagnostics_workers_by_id: Dictionary = {}
var worker_trace = WorkerTraceScript.new()
# Debug builds only; logs suspicious states, never changes gameplay.
var anomaly_watchdog = AnomalyWatchdogScript.new()
const MAX_SIM_SPEED := 10
var sim_speed := 1
# Camera view handed in by Main before saving, and read back by the last load.
var saved_view_state: Dictionary = {}
var loaded_view_state: Dictionary = {}
#endregion

#region Worker State
var workers: Array = []
var worker_chunk_cache: Dictionary = {}
var worker_activity_timer: float = 0.0
#endregion

#region Player State
enum PlayerMode {INFORMATION, DIG, PLACE, UP_STAIRS, DOWN_STAIRS, ERASE, STOCKPILE, TORCH, CHOP}
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
	anomaly_watchdog.setup(self)
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
func init_world(seed_world_flag: bool = true) -> bool:
	if not _drain_world_jobs():
		push_error("Cannot initialize world because worker jobs could not be drained")
		return false
	if not configure_dimensions(WORLD_CHUNKS_X, WORLD_CHUNKS_Z):
		return false
	world_size_x = CHUNK_SIZE * WORLD_CHUNKS_X
	world_size_y = CHUNK_SIZE * WORLD_CHUNKS_Y
	world_size_z = CHUNK_SIZE * WORLD_CHUNKS_Z
	if torch_store != null:
		torch_store.clear()
	goblin_light = GoblinLightScript.new()
	torch_store = TorchStoreScript.new()
	torch_store.bind_world(self)
	if tree_store != null:
		tree_store.clear()
	tree_store = TreeStoreScript.new()
	tree_store.set_chunk_size(CHUNK_SIZE)
	light_field_built = false
	light_field_arena_cook_seen = false
	runtime_epoch += 1
	if live_diagnostics != null:
		live_diagnostics.begin_world("world_initialized")
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
		light_field.clear_sources_for_build()
		light_field.build(self)
		light_field_built = true
		torch_store.register_light_sources()
		spawn_initial_workers()
	return true


## SEE-ADR-021: one full light build once every block of a started/loaded world
## is present. Chunks streamed in during loading queue per-chunk relights that
## would take minutes to drain; the build replaces them.
func rebuild_light_field() -> void:
	var initial_explored := save_load.get_pending_explored_bytes() if save_load != null else PackedByteArray()
	light_field.clear_sources_for_build()
	light_field.build(self, initial_explored)
	light_field_built = true
	light_field_arena_cook_seen = false
	goblin_light = GoblinLightScript.new()
	torch_store.register_light_sources()
	if save_load != null:
		save_load.apply_final_light_snapshots()


func rebuild_light_field_async() -> bool:
	if _dimension_jobs_in_flight > 0 or light_field_task_id >= 0:
		push_error("Cannot rebuild light field while dimension or light build jobs are in flight")
		return false
	var expected_epoch := runtime_epoch
	var build_started_usec := Time.get_ticks_usec()
	var previous_frame_usec := build_started_usec
	light_field_async_max_frame_ms = 0.0
	light_field_async_total_ms = 0.0
	var build_world = self
	var candidate = LightFieldScript.new()
	var initial_explored := save_load.get_pending_explored_bytes() if save_load != null else PackedByteArray()
	light_field_task_id = WorkerThreadPool.add_task(Callable(candidate, "build").bind(build_world, initial_explored), true, "LightField build")
	if light_field_task_id < 0:
		light_field_task_id = -1
		return false
	light_field_build_active = true
	while not WorkerThreadPool.is_task_completed(light_field_task_id):
		await get_tree().process_frame
		var frame_usec := Time.get_ticks_usec()
		light_field_async_max_frame_ms = maxf(light_field_async_max_frame_ms,
			float(frame_usec - previous_frame_usec) / 1000.0)
		previous_frame_usec = frame_usec
	WorkerThreadPool.wait_for_task_completion(light_field_task_id)
	light_field_task_id = -1
	light_field_build_active = false
	light_field_async_total_ms = float(Time.get_ticks_usec() - build_started_usec) / 1000.0
	if is_queued_for_deletion() or runtime_epoch != expected_epoch or build_world != self:
		return false
	if int(candidate.get("build_count")) != 1:
		return false
	light_field = candidate
	light_field_built = true
	light_field_arena_cook_seen = false
	goblin_light = GoblinLightScript.new()
	torch_store.register_light_sources()
	if save_load != null:
		save_load.apply_final_light_snapshots()
	return true


func start_new_world(seed_value: int = -1, chunks_x: int = 32, chunks_z: int = 32) -> bool:
	var defer_build := defer_light_build_on_start
	defer_light_build_on_start = false
	return _start_new_world(seed_value, chunks_x, chunks_z, defer_build)


func _start_new_world(seed_value: int, chunks_x: int, chunks_z: int, defer_light_build: bool) -> bool:
	if not _drain_world_jobs():
		push_error("Cannot start a new world because worker jobs could not be drained")
		return false
	if not configure_dimensions(chunks_x, chunks_z):
		return false
	world_size_x = CHUNK_SIZE * WORLD_CHUNKS_X
	world_size_z = CHUNK_SIZE * WORLD_CHUNKS_Z
	world_size_y = CHUNK_SIZE * WORLD_CHUNKS_Y
	if save_load != null:
		save_load.clear_world_dir()
	if not init_world(false):
		return false
	world_seed = seed_value if seed_value >= 0 else generator.generate_world_seed()
	generator.prime_spawn_chunks()
	if defer_light_build:
		light_field_built = false
	else:
		light_field.clear_sources_for_build()
		light_field.build(self)
		light_field_built = true
		torch_store.register_light_sources()
	spawn_initial_workers()
	return true
#endregion


#region Save/Load
func save_world(path: String) -> bool:
	if live_diagnostics != null:
		live_diagnostics.mark_event("saving_started")
	var ok := save_load.save_world(path)
	if live_diagnostics != null:
		live_diagnostics.mark_event("saving_finished", {"success": ok})
	return ok


func load_world(path: String) -> bool:
	var defer_build := defer_light_build_on_load
	defer_light_build_on_load = false
	return _load_world_with_light_option(path, defer_build)


func _load_world_with_light_option(path: String, defer_light_build: bool) -> bool:
	if not _drain_world_jobs():
		push_error("Cannot load a world because worker jobs could not be drained")
		return false
	if live_diagnostics != null:
		live_diagnostics.mark_event("loading_started")
	var ok := save_load.load_world(path)
	if live_diagnostics != null:
		live_diagnostics.mark_event("loading_finished", {"success": ok})
	if ok:
		if torch_store != null:
			torch_store.clear()
		goblin_light = GoblinLightScript.new()
		torch_store = TorchStoreScript.new()
		torch_store.bind_world(self)
		if tree_store != null:
			tree_store.clear()
		tree_store = TreeStoreScript.new()
		tree_store.set_chunk_size(CHUNK_SIZE)
		clear_tasks()
		save_load.restore_saved_tasks()
	if ok and renderer != null:
		renderer.set_top_render_y(top_render_y)
		renderer.set_min_render_y(get_min_render_y())
	if ok and generator != null:
		generator.reset_generation_jobs()
	if ok:
		if defer_light_build:
			light_field_built = false
		else:
			light_field.clear_sources_for_build()
			light_field.build(self, save_load.get_pending_explored_bytes())
			light_field_built = true
			torch_store.register_light_sources()
	return ok


func _drain_world_jobs() -> bool:
	if generator != null:
		generator.reset_generation_jobs()
	if renderer != null:
		renderer.clear_chunks()
		if renderer.visibility_state != null:
			renderer.visibility_state.clear()
	return _dimension_jobs_in_flight == 0
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
	if light_field != null and light_field_built:
		light_field.notify_chunk_loaded(coord)
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
	if light_field != null and light_field_built:
		light_field.notify_block_changed(x, y, z, prev, value)
	if goblin_light != null and light_field_built:
		goblin_light.notify_block_changed(x, y, z)
	# Torch support checks use the changed cell, cell above, and four neighbours.
	# Each candidate uses a direct store lookup, keeping terrain edits cheap.
	if torch_store != null:
		var changed_pos := Vector3i(x, y, z)
		if torch_store.has_torch(changed_pos) and is_block_solid_id(value):
			torch_store.remove_torch(changed_pos)
		if is_block_solid_id(prev) and not is_block_solid_id(value):
			var supported_pos := changed_pos + Vector3i.UP
			if torch_store.has_torch(supported_pos) and torch_store.facing(supported_pos) == Vector3i.ZERO:
				_reassess_torch_support(supported_pos)
			for direction: Vector3i in TORCH_HORIZONTAL_DIRECTIONS:
				var wall_torch_pos := changed_pos + direction
				if torch_store.has_torch(wall_torch_pos) and torch_store.facing(wall_torch_pos) == -direction:
					_reassess_torch_support(wall_torch_pos)
	if tree_store != null:
		var changed_pos := Vector3i(x, y, z)
		if tree_store.has_tree(changed_pos) and is_block_solid_id(value):
			remove_tree(changed_pos, false)
		if is_block_solid_id(prev) and not is_block_solid_id(value):
			var supported_tree := changed_pos + Vector3i.UP
			if tree_store.has_tree(supported_tree):
				remove_tree(supported_tree, true)
	# Path snapshots key on block content, not on render state.
	chunk.block_revision += 1
	if mark_dirty:
		if performance_recorder != null and performance_recorder.enabled:
			performance_recorder.add_counter("terrain_change")
		chunk.dirty = true
		chunk.generated = true
		chunk.mesh_state = ChunkDataScript.MESH_STATE_NONE
		chunk.mesh_revision += 1
		if live_diagnostics != null and live_diagnostics.enabled:
			live_diagnostics.invalidate("chunk", coord, "terrain_changed")
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


func torch_mount_facing(pos: Vector3i) -> Vector3i:
	for direction: Vector3i in TORCH_HORIZONTAL_DIRECTIONS:
		var wall_pos := pos + direction
		if is_block_solid_id(get_block_no_generate(wall_pos.x, wall_pos.y, wall_pos.z)):
			return direction
	return Vector3i.ZERO


func is_cell_obstructed(pos: Vector3i) -> bool:
	return tree_store != null and tree_store.has_tree(pos)


func add_generated_tree(base: Vector3i, kind: int, variant: int, height: int) -> bool:
	return _add_tree_attachment(base, kind, variant, height)


func add_tree(base: Vector3i, kind: int, variant: int, height: int) -> bool:
	return _add_tree_attachment(base, kind, variant, height)


func _add_tree_attachment(base: Vector3i, kind: int, variant: int, height: int) -> bool:
	if tree_store == null or not tree_store.add_tree(base, kind, variant, height):
		return false
	_bump_attachment_path_revision(base)
	return true


func remove_tree(base: Vector3i, drop_logs: bool = false) -> bool:
	if tree_store == null:
		return false
	var tree: Dictionary = tree_store.tree_at(base)
	if tree.is_empty() or not tree_store.remove_tree(base):
		return false
	_bump_attachment_path_revision(base)
	if task_manager != null and task_queue != null:
		for task in task_queue.get_active_tasks_at(base):
			if task.type != TaskQueue.TaskType.CHOP:
				continue
			if task.status == TaskQueue.TaskStatus.IN_PROGRESS and task.assigned_worker != null:
				task.assigned_worker.interrupt_task_and_idle(task_queue, self)
			if task.status == TaskQueue.TaskStatus.PENDING:
				task_manager.cancel_pending_task(task.id, task)
	if drop_logs:
		spawn_tree_drops(tree, base)
	return true


func _bump_attachment_path_revision(pos: Vector3i) -> void:
	var chunk: ChunkDataType = get_chunk(world_to_chunk_coords(pos.x, pos.y, pos.z))
	if chunk != null:
		chunk.block_revision += 1
	if task_manager != null:
		task_manager.invalidate_task_accessibility(pos)


func spawn_tree_drops(tree: Dictionary, pos: Vector3i) -> Array[int]:
	var kind := int(tree.get("kind", -1))
	var count := 0
	match kind:
		TreeStoreScript.KIND_OAK:
			count = drop_rng.randi_range(3, 4)
		TreeStoreScript.KIND_PINE:
			count = drop_rng.randi_range(4, 5)
	if count <= 0:
		return []
	var item_id := item_store.add_stack(BLOCK_ID_LOG, count, item_rest_cell(pos))
	if item_id < 0:
		return []
	trace_system_event("item_drop_spawned", "item_id=%d material=%d count=%d pos=%d,%d,%d source=tree" % [item_id, BLOCK_ID_LOG, count, pos.x, pos.y, pos.z])
	return [item_id]


func _reassess_torch_support(pos: Vector3i) -> void:
	var facing: Vector3i = torch_store.facing(pos)
	var support_pos := pos + facing if facing != Vector3i.ZERO else pos + Vector3i.DOWN
	if is_block_solid_id(get_block_no_generate(support_pos.x, support_pos.y, support_pos.z)):
		return
	var wall_facing := torch_mount_facing(pos)
	if wall_facing != Vector3i.ZERO:
		torch_store.set_facing(pos, wall_facing)
	elif pos.y > 0 and is_block_solid_id(get_block_no_generate(pos.x, pos.y - 1, pos.z)):
		torch_store.set_facing(pos, Vector3i.ZERO)
	else:
		torch_store.remove_torch(pos)


func is_block_empty_id(block_id: int) -> bool:
	return block_id == BLOCK_ID_AIR


func is_empty(x: int, y: int, z: int) -> bool:
	if not is_block_coord_valid(x, y, z):
		return false
	return is_block_empty_id(get_block(x, y, z))


func is_diggable_at(x: int, y: int, z: int) -> bool:
	if not is_block_coord_valid(x, y, z):
		return false
	if not stair_dig_reject_reason(Vector3i(x, y, z)).is_empty():
		return false
	return block_registry.get_hardness(get_block(x, y, z)) > 0.0


func stair_dig_reject_reason(pos: Vector3i) -> String:
	if PLAYER_STAIR_BLOCK_IDS.has(get_block_no_generate(pos.x, pos.y, pos.z)):
		return "stairs_require_removal"
	if PLAYER_STAIR_BLOCK_IDS.has(get_block_no_generate(pos.x, pos.y + 1, pos.z)):
		return "stair_support_protected"
	return ""


func get_stair_removal_spec(pos: Vector3i) -> Dictionary:
	return preload("res://scripts/stair_removal.gd").get_spec(self, pos)


func queue_stair_removal(pos: Vector3i) -> bool:
	return preload("res://scripts/stair_removal.gd").queue(self, pos)


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


func can_place_stair_flight(anchor: Vector3i, rotation: int, up: bool, ignored_task_id: int = -1) -> bool:
	if rotation < 0 or rotation >= StairFlightScript.ROTATION_COUNT:
		return false
	var flight_cells := StairFlightScript.cells(anchor, rotation)
	for cell: Vector3i in flight_cells:
		if not is_block_coord_valid(cell.x, cell.y, cell.z) \
				or cell.y <= 0 or cell.y + 1 >= world_size_y \
				or not _is_loaded_generated_cell(cell) \
				or not _is_loaded_generated_cell(cell + Vector3i.DOWN) \
				or not _is_loaded_generated_cell(cell + Vector3i.UP):
			return false
		if task_queue != null:
			for existing_task in task_queue.get_active_tasks_at(cell):
				if existing_task.id == ignored_task_id:
					continue
				if existing_task.type != TaskQueue.TaskType.DIG \
						or existing_task.status == TaskQueue.TaskStatus.IN_PROGRESS:
					return false
		var block_id := get_block_no_generate(cell.x, cell.y, cell.z)
		if up:
			if not is_block_empty_id(block_id):
				return false
		else:
			if is_block_empty_id(block_id) or is_ramp_block_id(block_id) \
					or not block_registry.is_replaceable(block_id):
				return false
		var support_id := get_block_no_generate(cell.x, cell.y - 1, cell.z)
		if not is_block_solid_id(support_id) or is_ramp_block_id(support_id):
			return false
		var headroom_id := get_block_no_generate(cell.x, cell.y + 1, cell.z)
		if is_block_solid_id(headroom_id) and not is_ramp_block_id(headroom_id):
			return false
	return true


func _is_loaded_generated_cell(pos: Vector3i) -> bool:
	var chunk := get_chunk(world_to_chunk_coords(pos.x, pos.y, pos.z))
	return chunk != null and chunk.generated


func complete_stair_flight(task) -> bool:
	if task == null or task.type != TaskQueue.TaskType.STAIRS:
		return false
	if bool(task.data.get("remove_stairs", false)):
		return preload("res://scripts/stair_removal.gd").complete(self, task)
	if task_queue.get_task(task.id) != task:
		return false
	if not bool(task.data.get("flight", false)):
		return false
	var anchor: Vector3i = task.pos
	var rotation := int(task.data.get("rotation", -1))
	var up := bool(task.data.get("up", false))
	var flight_cells := StairFlightScript.cells(anchor, rotation)
	if task.material != StairFlightScript.lower_id(rotation) or task.data.get("footprint", []) != flight_cells:
		return false
	if not can_place_stair_flight(anchor, rotation, up, task.id):
		return false
	var materials: Array = [StairFlightScript.lower_id(rotation), StairFlightScript.upper_id(rotation)]
	if task.expected_blocks.size() != 2:
		return false
	for index in 2:
		var cell: Vector3i = flight_cells[index]
		if not get_workers_blocking_dig(cell).is_empty():
			return false
		if get_block_no_generate(cell.x, cell.y, cell.z) != task.expected_blocks[index]:
			return false
	# Preflight above is complete before either cell is mutated. Both writes occur
	# on the main thread and use the task's immutable footprint/material pair.
	set_block(flight_cells[0].x, flight_cells[0].y, flight_cells[0].z, int(materials[0]))
	set_block(flight_cells[1].x, flight_cells[1].y, flight_cells[1].z, int(materials[1]))
	cancel_digs_protected_by_stairs(flight_cells)
	return true


## Returns why a flight task cannot complete yet even though its site may still
## be valid. Workers wait in place on a reason; an empty reason followed by a
## failed completion means the site itself changed and the task is stale.
func stair_task_wait_reason(task) -> String:
	var removal := bool(task.data.get("remove_stairs", false))
	for cell: Vector3i in task.data.get("footprint", [task.pos]):
		for probe: Vector3i in [cell, cell + Vector3i.DOWN, cell + Vector3i.UP]:
			if is_block_coord_valid(probe.x, probe.y, probe.z) and not _is_loaded_generated_cell(probe):
				return "chunk_unloaded"
		if removal:
			if preload("res://scripts/stair_removal.gd").is_cell_occupied(self, cell):
				return "occupied"
		elif not get_workers_blocking_dig(cell).is_empty():
			return "occupied"
		if task_queue != null:
			for other in task_queue.get_active_tasks_at(cell):
				if other != task and other.status == TaskQueue.TaskStatus.IN_PROGRESS:
					return "task_in_progress"
	return ""


## Finished stairs make pending digs on their cells and supports stale; drop
## them now instead of after a worker walks over and spends a full dig timer.
func cancel_digs_protected_by_stairs(cells: Array) -> void:
	if task_queue == null:
		return
	for cell: Vector3i in cells:
		for target: Vector3i in [cell, cell + Vector3i.DOWN]:
			var reason := stair_dig_reject_reason(target)
			if reason.is_empty():
				continue
			for removed in task_queue.remove_pending_tasks_at(target, [TaskQueue.TaskType.DIG]):
				trace_task_event(removed, "task_cancelled", "reason=%s" % reason)


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
## Debug builds only: simulation steps per frame (1 = normal speed).
func set_sim_speed(speed: int) -> int:
	sim_speed = clampi(speed, 1, MAX_SIM_SPEED) if OS.is_debug_build() else 1
	return sim_speed


func update_world(dt: float) -> void:
	update_world_controlled(dt, true)


func update_world_controlled(dt: float, advance_simulation: bool) -> void:
	# SEE-ADR-013: Keep one phase sequence, independent of either timing sink.
	run_performance_timed("World.process_generation_results", process_generation_results)
	if arena_cooker != null and arena_cooker.stage > WorldArenaCooker.Stage.IDLE and arena_cooker.stage < WorldArenaCooker.Stage.DONE:
		light_field_arena_cook_seen = true
	if light_field_arena_cook_seen and arena_cooker.stage == WorldArenaCooker.Stage.DONE:
		light_field.build(self)
		light_field_built = true
		torch_store.register_light_sources()
		light_field_arena_cook_seen = false
	if light_field != null:
		run_performance_timed("World.process_light_events", light_field.process_events)
	if light_field_built and goblin_light != null:
		run_performance_timed("World.update_goblin_light", goblin_light.update.bind(self))
	run_performance_timed("World.update_render_height_queue", update_render_height_queue)
	if advance_simulation:
		# Debug speed runs whole extra steps rather than scaling dt, so movement,
		# support checks and timers behave exactly as at 1x.
		for _step in sim_speed:
			run_performance_timed("World.update_task_assignments", update_task_assignments)
			run_performance_timed("World.update_workers", update_workers.bind(dt))
			run_performance_timed("World.update_task_queue", update_task_queue)
			run_performance_timed("World.update_task_accessibility", update_task_accessibility)
			run_performance_timed("World.update_reassign_tasks", update_reassign_tasks.bind(dt))
	run_performance_timed("World.update_task_overlays", update_task_overlays_phase)
	run_performance_timed("World.anomaly_watchdog", anomaly_watchdog.tick.bind(dt, advance_simulation, sim_speed))


func run_performance_timed(label: String, callback: Callable) -> void:
	var started_usec := begin_performance_timing()
	callback.call()
	end_performance_timing(label, started_usec)


## Main-thread spans; disabled sinks avoid clock reads and metric allocation.
func begin_performance_timing() -> int:
	if (debug_profiler != null and debug_profiler.enabled) or (performance_recorder != null and performance_recorder.enabled):
		return Time.get_ticks_usec()
	return -1


func end_performance_timing(label: String, started_usec: int) -> void:
	if started_usec < 0:
		return
	var elapsed_ms := float(Time.get_ticks_usec() - started_usec) / 1000.0
	if debug_profiler != null and debug_profiler.enabled:
		debug_profiler.add_sample(label, elapsed_ms)
	if performance_recorder != null and performance_recorder.enabled:
		performance_recorder.add_timing(label, elapsed_ms)


## Main-thread only; call at the recorder's once-per-second sampling cadence.
## No task/terrain/geometry scans. Missing subsystems are unavailable, not idle.
func get_performance_snapshot() -> Dictionary:
	var generation_stats: Dictionary = generator.get_generation_stats() if generator != null else {}
	var mesh_stats: Dictionary = renderer.get_performance_snapshot() if renderer != null else {}
	var path_stats: Dictionary = task_manager.path_search_scheduler.get_performance_snapshot() if task_manager != null else {}
	var snapshot := {
		"workers": workers.size(),
		"active_tasks": task_queue.active_count() if task_queue != null else null,
		"loaded_chunks": chunks.size(),
		"top_render_y": top_render_y,
		"memory_static_bytes": OS.get_static_memory_usage() if OS.is_debug_build() else null,
		"generation_queued": generation_stats.get("queued"),
		"generation_results_pending": generation_stats.get("results"),
		"generation_executing": generation_stats.get("active"),
		"path_queued": path_stats.get("queued"),
		"path_results_pending": path_stats.get("results_pending"),
		"path_executing": path_stats.get("executing"),
		"haul_rebuilds_total": task_manager.haul_rebuild_count if task_manager != null else null,
		"accessibility_checks_total": task_manager.accessibility_check_count if task_manager != null else null,
	}
	for key in ["queued", "results_pending", "in_flight", "visible_records", "prefetch_records", "cache_hits_total", "cache_misses_total", "cache_imports_total", "build_ms_total", "upload_ms_total", "pending_neighbor_remesh_chunks"]:
		snapshot["mesh_" + key] = mesh_stats.get(key)
	var visibility: Dictionary = renderer.get_visibility_snapshot() if renderer != null else {}
	for key in ["pending", "in_flight", "result_pending", "fallback", "application_pending", "application_remaining", "requested_sequence", "accepted_sequence", "applied_sequence", "result_age_ms"]:
		snapshot["visibility_" + key] = visibility.get(key)
	return snapshot


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


func torch_site_reject_reason(pos: Vector3i) -> String:
	if not is_block_coord_valid(pos.x, pos.y, pos.z):
		return "invalid_position"
	if get_block_no_generate(pos.x, pos.y, pos.z) != BLOCK_ID_AIR:
		return "not_empty"
	if pos.y <= 0 or not is_block_solid_id(get_block_no_generate(pos.x, pos.y - 1, pos.z)) \
			or pathfinder == null or not pathfinder.is_walkable(self, pos.x, pos.y, pos.z):
		return "unsupported"
	if torch_store != null and torch_store.has_torch(pos):
		return "torch_exists"
	return ""


func queue_stair_flight(anchor: Vector3i, rotation: int, up: bool) -> bool:
	if task_manager == null:
		return false
	return task_manager.queue_stair_flight(anchor, rotation, up)


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


## Where a loose item comes to rest: the first cell at or below pos that a
## worker can stand on, or the stair/slope surface it lies on. Unloaded terrain
## and solid cells leave the position unchanged rather than guessing.
func item_rest_cell(pos: Vector3i) -> Vector3i:
	if pathfinder == null:
		return pos
	# An item embedded in solid terrain stays put; it must not sink through.
	if _is_loaded_generated_cell(pos) and pathfinder.is_blocking(self, get_block_no_generate(pos.x, pos.y, pos.z)):
		return pos
	var cell := pos
	for _step in ITEM_MAX_FALL_CELLS:
		if not _is_loaded_generated_cell(cell):
			return pos
		if pathfinder.is_walkable(self, cell.x, cell.y, cell.z):
			return cell
		var below := cell + Vector3i.DOWN
		if not is_block_coord_valid(below.x, below.y, below.z) or not _is_loaded_generated_cell(below):
			return pos
		var below_id := get_block_no_generate(below.x, below.y, below.z)
		if is_ramp_block_id(below_id):
			return below if pathfinder.is_walkable(self, below.x, below.y, below.z) else pos
		if is_block_solid_id(below_id):
			return pos
		cell = below
	return pos


func spawn_mining_drops(source_block_id: int, pos: Vector3i) -> Array[int]:
	var spawned: Array[int] = []
	var legacy_drop_id: int = block_registry.get_drop(source_block_id)
	var drops := block_drop_table.resolve_drops(source_block_id, drop_rng, legacy_drop_id)
	for drop: Dictionary in drops:
		var material_id := int(drop.get("material_id", 0))
		var count := int(drop.get("count", 0))
		var item_id := item_store.add_stack(material_id, count, item_rest_cell(pos))
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
	var observing: bool = live_diagnostics != null and live_diagnostics.enabled
	var rejection_counts := {"candidates": 0, "material_conflict": 0, "reservation_conflict": 0, "full": 0} if observing else {}
	for candidate: Dictionary in stockpile_store.candidate_cells_for_material(material_id):
		if observing:
			rejection_counts.candidates += 1
		var pos: Vector3i = candidate.get("pos", Vector3i.ZERO)
		var stored := item_store.stored_item_at(pos)
		if not stored.is_empty() and int(stored.get("material_id", 0)) != material_id:
			if observing:
				rejection_counts.material_conflict += 1
			continue
		var reserved := _reserved_haul_space_at(pos, material_id)
		if bool(reserved.get("blocked", false)):
			if observing:
				rejection_counts.reservation_conflict += 1
			continue
		var used := int(stored.get("count", 0)) + int(reserved.get("count", 0))
		var capacity := stockpile_store.cell_capacity(pos)
		if used >= capacity:
			if observing:
				rejection_counts.full += 1
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
	if observing:
		live_diagnostics.observe("item_destination", item.get("id", -1), "destination_selected" if not best.is_empty() else "no_destination",
			{"rejections": rejection_counts, "selected": best, "material_id": material_id})
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


func update_streaming(view_rect: Rect2, plane_y: float, dt: float, camera: Camera3D = null, render_band_rects: Dictionary = {}) -> void:
	if streaming != null:
		streaming.update_streaming(view_rect, plane_y, dt, camera, render_band_rects)
	if renderer != null:
		var anchor_started := begin_performance_timing()
		var center_x: float = view_rect.position.x + view_rect.size.x * 0.5
		var center_z: float = view_rect.position.y + view_rect.size.y * 0.5
		renderer.update_render_height_anchor(clamp_block_xz(Vector3(center_x, plane_y, center_z)))
		end_performance_timing("Streaming.height_anchor_ms", anchor_started)


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
	_wait_for_light_field_task()
	worker_trace.stop()
	anomaly_watchdog.close()
	if task_manager != null:
		task_manager.shutdown()
	if generator != null:
		generator.shutdown_generation_thread()


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		_wait_for_light_field_task()


func _wait_for_light_field_task() -> void:
	if light_field_task_id < 0:
		return
	WorkerThreadPool.wait_for_task_completion(light_field_task_id)
	light_field_task_id = -1
	light_field_build_active = false


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
		worker.role_id = WorkerRolesScript.default_spawn_role(i)
		worker.position = Vector3(spawn_x, surface_y + WORKER_SPAWN_HEIGHT_OFFSET, spawn_z)
		add_child(worker)
		workers.append(worker)
		diagnostics_workers_by_id[worker.worker_id] = worker
		diagnostics_workers_revision += 1
		trace_worker_event(worker, "spawned")
	if task_manager != null:
		task_manager.notify_worker_availability_changed()


## Debug roster control. New workers appear on an existing worker's cell (or the
## spawn point) so they start somewhere reachable. Returns the number added.
func add_workers(count: int, near: Variant = null) -> int:
	var added := 0
	# Prefer a standable cell near the requested point (the camera focus).
	var focus_cell: Variant = _find_standable_near(near) if near is Vector3i else null
	for i in clampi(count, 0, MAX_WORKERS - workers.size()):
		var worker := Worker.new()
		worker.worker_id = _next_worker_id()
		worker.role_id = WorkerRolesScript.default_spawn_role(workers.size())
		# Debug-added workers take every implemented job at the role default level.
		for work: Dictionary in WorkerRolesScript.WorkPrioritiesScript.entries():
			if work.implemented:
				worker.work_priorities[work.id] = NEW_WORKER_WORK_PRIORITY
		worker.position = Vector3(focus_cell) if focus_cell != null else _debug_spawn_position(i)
		add_child(worker)
		workers.append(worker)
		diagnostics_workers_by_id[worker.worker_id] = worker
		diagnostics_workers_revision += 1
		trace_worker_event(worker, "spawned")
		added += 1
	if added > 0 and task_manager != null:
		task_manager.notify_worker_availability_changed()
	return added


## Removes the highest-ID workers first. Their jobs return to pending and any
## carried item is released through the normal interruption path.
func remove_workers(count: int) -> int:
	var removed := 0
	for i in clampi(count, 0, workers.size()):
		var worker: Worker = workers.pop_back()
		worker._interrupt_current_task(task_queue, self)
		diagnostics_workers_by_id.erase(worker.worker_id)
		diagnostics_workers_revision += 1
		worker_chunk_cache.erase(worker)
		trace_worker_event(worker, "despawned")
		worker.queue_free()
		removed += 1
	if removed > 0 and task_manager != null:
		task_manager.reset_assignment_auction()
		task_manager.notify_worker_availability_changed()
	return removed


## Makes the live roster exactly match saved worker IDs (used after load
## respawns the default roster). Positions and roles are applied by the caller.
func sync_worker_roster(worker_ids: Array) -> void:
	if worker_ids.is_empty():
		return
	for index in range(workers.size() - 1, -1, -1):
		var worker: Worker = workers[index]
		if not worker_ids.has(worker.worker_id):
			workers.remove_at(index)
			diagnostics_workers_by_id.erase(worker.worker_id)
			worker_chunk_cache.erase(worker)
			trace_worker_event(worker, "despawned")
			worker.queue_free()
	for worker_id in worker_ids:
		if diagnostics_workers_by_id.has(int(worker_id)) or workers.size() >= MAX_WORKERS:
			continue
		var worker := Worker.new()
		worker.worker_id = int(worker_id)
		worker.role_id = WorkerRolesScript.default_spawn_role(workers.size())
		worker.position = _debug_spawn_position(workers.size())
		add_child(worker)
		workers.append(worker)
		diagnostics_workers_by_id[worker.worker_id] = worker
		trace_worker_event(worker, "spawned")
	diagnostics_workers_revision += 1
	if task_manager != null:
		task_manager.notify_worker_availability_changed()


func _next_worker_id() -> int:
	var max_id := 0
	for worker: Worker in workers:
		max_id = maxi(max_id, worker.worker_id)
	return max_id + 1


## Nearest loaded cell a worker can stand on around `center`, searching outward
## horizontally and a few levels down/up. Returns null when none is found.
func _find_standable_near(center: Vector3i) -> Variant:
	if pathfinder == null:
		return null
	for radius in range(0, 13):
		for dy in [0, -1, -2, -3, 1]:
			for dx in range(-radius, radius + 1):
				for dz in range(-radius, radius + 1):
					if maxi(absi(dx), absi(dz)) != radius:
						continue
					var cell := Vector3i(center.x + dx, center.y + dy, center.z + dz)
					if not is_block_coord_valid(cell.x, cell.y, cell.z) or not _is_loaded_generated_cell(cell) \
							or not _is_loaded_generated_cell(cell + Vector3i.DOWN):
						continue
					if pathfinder.is_walkable(self, cell.x, cell.y, cell.z):
						return cell
	return null


func _debug_spawn_position(index: int) -> Vector3:
	for worker: Worker in workers:
		if is_instance_valid(worker) and worker.state != Worker.WorkerState.FALLING:
			var coord := worker.get_block_coord()
			if worker._can_stand_at(self, coord.x, coord.y, coord.z):
				return Vector3(coord.x, worker.position.y, coord.z)
	var offset: Vector2i = WORKER_SPAWN_OFFSETS[index % WORKER_SPAWN_OFFSETS.size()]
	var x := spawn_coord.x + offset.x
	var z := spawn_coord.z + offset.y
	return Vector3(x, find_surface_y(x, z) + WORKER_SPAWN_HEIGHT_OFFSET, z)


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


func set_worker_role(worker_id: int, role_id: int, notify: bool = true) -> bool:
	if not WorkerRolesScript.is_valid(role_id):
		return false
	for worker: Worker in workers:
		if worker == null or worker.worker_id != worker_id:
			continue
		if worker.current_task_id >= 0:
			return false
		var previous_role := worker.get_role_name()
		if not worker.set_role(role_id):
			return false
		trace_worker_event(worker, "role_changed", null, "from=%s to=%s" % [
			previous_role,
			worker.get_role_name(),
		])
		if notify:
			notify_worker_roles_changed()
		return true
	return false


func notify_worker_roles_changed() -> void:
	if task_manager != null:
		task_manager.notify_worker_availability_changed()


func set_worker_work_priority(worker_id: int, work_id: String, value: int) -> bool:
	if not WorkerRolesScript.WorkPrioritiesScript.is_valid_setting(work_id, value):
		return false
	for worker: Worker in workers:
		if not is_instance_valid(worker) or worker.worker_id != worker_id:
			continue
		worker.work_priorities[work_id] = value
		trace_worker_event(worker, "work_priority_changed", null, "%s=%d" % [work_id, value])
		# Only pending decisions are invalidated. Active work and delivery paths survive.
		notify_worker_roles_changed()
		return true
	return false
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
	diagnostics_workers_by_id.clear()
	diagnostics_workers_revision += 1
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
		# Movement finishes a validated step before checking support again.
		if worker.state == Worker.WorkerState.MOVING and worker.path_segment_validated \
				and worker.path_index > 0 and worker.path_index < worker.path.size():
			var standing_cell := pos + Vector3i.UP
			if worker.path[worker.path_index - 1] == standing_cell \
					or worker.path[worker.path_index] == standing_cell:
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
	if live_diagnostics != null and live_diagnostics.enabled and new_y != top_render_y:
		live_diagnostics.mark_event("render_level_requested", {"from": top_render_y, "to": new_y})
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
func raycast_block(ray_origin: Vector3, ray_dir: Vector3, max_distance: float, generate_missing: bool = true) -> Dictionary:
	if raycaster != null:
		return raycaster.raycast_block(ray_origin, ray_dir, max_distance, generate_missing)
	return {"hit": false}
#endregion
