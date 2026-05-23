extends RefCounted
class_name WorldGenerationPipeline
## Full finite-world generation pipeline that builds intermediate maps before baking chunks.

#region Constants
const SEED_MIX_FACTOR := 0x45d9f3b
const SEED_MASK := 0x7fffffff
const TERRAIN_CELL_SIZE := 4
const FLAT_NOISE_FREQUENCY := 0.02
const SMALL_NOISE_FREQUENCY := 0.01
const LARGE_NOISE_FREQUENCY := 0.005
const MACRO_NOISE_FREQUENCY := 0.0015
const MOISTURE_NOISE_FREQUENCY := 0.011
const TEMPERATURE_NOISE_FREQUENCY := 0.008
const GEOLOGY_NOISE_FREQUENCY := 0.014
const TREE_NOISE_FREQUENCY := 0.025
const CAVE_NOISE_FREQUENCY := 0.038
const CAVE_DETAIL_NOISE_FREQUENCY := 0.075
const AQUIFER_NOISE_FREQUENCY := 0.045
const COAL_NOISE_FREQUENCY := 0.052
const IRON_NOISE_FREQUENCY := 0.06
const FLAT_AMPLITUDE := 1
const SMALL_AMPLITUDE := 4
const LARGE_AMPLITUDE := 10
const MACRO_FLAT_CUTOFF := 0.88
const MACRO_SMALL_CUTOFF := 0.96
const TOPSOIL_DEPTH_MIN := 2
const TOPSOIL_DEPTH_MAX := 4
const TREE_CELL_SIZE := 8
const TREE_RESERVATION_RADIUS := 2
const TREE_INFLUENCE_RADIUS := 7
const FLOWER_BASE_CHANCE := 0.008
const FLOWER_TREE_BONUS := 0.095
const FLOWER_BIOME_BONUS := 0.025
const PASS_NAMES := [
	"climate_maps",
	"biome_map",
	"geology_maps",
	"fill_solid_terrain",
	"carve_caves",
	"add_static_water",
	"add_ores",
	"apply_surface_blocks",
	"apply_ramps",
	"place_trees",
	"place_flowers",
	"final_cleanup",
	"bake_chunks",
]
enum Biome {
	PLAINS,
	FOREST,
	WETLAND,
	DRY,
	COLD,
}
#endregion

#region State
var world_seed: int = 0
var chunk_size: int = World.CHUNK_SIZE
var world_chunks_x: int = World.WORLD_CHUNKS_X
var world_chunks_y: int = World.WORLD_CHUNKS_Y
var world_chunks_z: int = World.WORLD_CHUNKS_Z
var world_min_chunk_x: int = World.WORLD_MIN_CHUNK_X
var world_max_chunk_x: int = World.WORLD_MAX_CHUNK_X
var world_min_chunk_z: int = World.WORLD_MIN_CHUNK_Z
var world_max_chunk_z: int = World.WORLD_MAX_CHUNK_Z
var world_min_block_x: int = World.WORLD_MIN_BLOCK_X
var world_min_block_z: int = World.WORLD_MIN_BLOCK_Z
var world_size_x: int = World.WORLD_CHUNKS_X * World.CHUNK_SIZE
var world_size_y: int = World.WORLD_CHUNKS_Y * World.CHUNK_SIZE
var world_size_z: int = World.WORLD_CHUNKS_Z * World.CHUNK_SIZE
var sea_level: int = 0

var elevation := PackedInt32Array()
var moisture := PackedFloat32Array()
var temperature := PackedFloat32Array()
var biome := PackedByteArray()
var soil_region := PackedByteArray()
var tree_density := PackedFloat32Array()
var feature_reserved := PackedByteArray()
var pipeline_metrics: Dictionary = {}
var progress_callback := Callable()

var height_noise_flat := FastNoiseLite.new()
var height_noise_small := FastNoiseLite.new()
var height_noise_large := FastNoiseLite.new()
var height_noise_macro := FastNoiseLite.new()
var moisture_noise := FastNoiseLite.new()
var temperature_noise := FastNoiseLite.new()
var geology_noise := FastNoiseLite.new()
var tree_noise := FastNoiseLite.new()
var cave_noise := FastNoiseLite.new()
var cave_detail_noise := FastNoiseLite.new()
var aquifer_noise := FastNoiseLite.new()
var coal_noise := FastNoiseLite.new()
var iron_noise := FastNoiseLite.new()
#endregion


func generate(config: Dictionary) -> Dictionary:
	_apply_config(config)
	_set_progress_callback(config.get("progress_callback", Callable()))
	_configure_noises()
	_resize_maps()
	pipeline_metrics = {
		"world_seed": world_seed,
		"world_size_x": world_size_x,
		"world_size_y": world_size_y,
		"world_size_z": world_size_z,
		"pass_count": 0,
		"pass_total": PASS_NAMES.size(),
		"passes": [],
	}
	var total_start_usec: int = Time.get_ticks_usec()
	var volume := PackedByteArray()
	volume.resize(world_size_x * world_size_y * world_size_z)
	volume.fill(World.BLOCK_ID_AIR)
	_run_pass("climate_maps", Callable(self, "_build_climate_maps").bind())
	_run_pass("biome_map", Callable(self, "_build_biome_map").bind())
	_run_pass("geology_maps", Callable(self, "_build_geology_maps").bind())
	_run_pass("fill_solid_terrain", Callable(self, "_fill_solid_terrain").bind(volume))
	_run_pass("carve_caves", Callable(self, "_carve_caves").bind(volume))
	_run_pass("add_static_water", Callable(self, "_add_static_water").bind(volume))
	_run_pass("add_ores", Callable(self, "_add_ores").bind(volume))
	_run_pass("apply_surface_blocks", Callable(self, "_apply_surface_blocks").bind(volume))
	_run_pass("apply_ramps", Callable(self, "_apply_ramps").bind(volume))
	_run_pass("place_trees", Callable(self, "_place_trees").bind(volume))
	_run_pass("place_flowers", Callable(self, "_place_flowers").bind(volume))
	_run_pass("final_cleanup", Callable(self, "_final_cleanup").bind(volume))
	var chunks: Dictionary = {}
	_run_pass("bake_chunks", Callable(self, "_bake_chunks").bind(volume, chunks))
	pipeline_metrics["total_ms"] = _elapsed_ms(total_start_usec)
	return {
		"chunks": chunks,
		"maps": {
			"elevation": elevation,
			"moisture": moisture,
			"temperature": temperature,
			"biome": biome,
			"soil_region": soil_region,
			"tree_density": tree_density,
			"feature_reserved": feature_reserved,
		},
		"metrics": pipeline_metrics,
	}

func _set_progress_callback(value: Variant) -> void:
	if typeof(value) == TYPE_CALLABLE:
		progress_callback = value
	else:
		progress_callback = Callable()


func _apply_config(config: Dictionary) -> void:
	world_seed = int(config.get("world_seed", 0))
	chunk_size = int(config.get("chunk_size", World.CHUNK_SIZE))
	world_chunks_x = int(config.get("world_chunks_x", World.WORLD_CHUNKS_X))
	world_chunks_y = int(config.get("world_chunks_y", World.WORLD_CHUNKS_Y))
	world_chunks_z = int(config.get("world_chunks_z", World.WORLD_CHUNKS_Z))
	world_min_chunk_x = int(config.get("world_min_chunk_x", World.WORLD_MIN_CHUNK_X))
	world_max_chunk_x = int(config.get("world_max_chunk_x", World.WORLD_MAX_CHUNK_X))
	world_min_chunk_z = int(config.get("world_min_chunk_z", World.WORLD_MIN_CHUNK_Z))
	world_max_chunk_z = int(config.get("world_max_chunk_z", World.WORLD_MAX_CHUNK_Z))
	world_size_x = chunk_size * world_chunks_x
	world_size_y = int(config.get("world_size_y", chunk_size * world_chunks_y))
	world_size_z = chunk_size * world_chunks_z
	world_min_block_x = world_min_chunk_x * chunk_size
	world_min_block_z = world_min_chunk_z * chunk_size
	sea_level = clampi(int(config.get("sea_level", world_size_y - World.SEA_LEVEL_DEPTH)), 0, world_size_y - 1)


func _resize_maps() -> void:
	var map_size: int = world_size_x * world_size_z
	elevation.resize(map_size)
	moisture.resize(map_size)
	temperature.resize(map_size)
	biome.resize(map_size)
	soil_region.resize(map_size)
	tree_density.resize(map_size)
	feature_reserved.resize(map_size)
	tree_density.fill(0.0)
	feature_reserved.fill(0)


func _run_pass(pass_name: String, callback: Callable) -> void:
	var passes: Array = pipeline_metrics.get("passes", [])
	var pass_index: int = passes.size()
	_report_progress(pass_name, pass_index, PASS_NAMES.size(), "running")
	var start_usec: int = Time.get_ticks_usec()
	callback.call()
	var elapsed: float = _elapsed_ms(start_usec)
	passes.append({"name": pass_name, "ms": elapsed})
	pipeline_metrics["passes"] = passes
	pipeline_metrics["pass_count"] = passes.size()
	pipeline_metrics["%s_ms" % pass_name] = elapsed
	_report_progress(pass_name, pass_index + 1, PASS_NAMES.size(), "done")


func _report_progress(pass_name: String, completed: int, total: int, state: String) -> void:
	if not progress_callback.is_valid():
		return
	progress_callback.call({
		"pass_name": pass_name,
		"pass_completed": completed,
		"pass_total": total,
		"state": state,
	})


func _build_climate_maps() -> void:
	for local_z in range(world_size_z):
		var wz: int = _world_z(local_z)
		for local_x in range(world_size_x):
			var wx: int = _world_x(local_x)
			var idx: int = _map_index(local_x, local_z)
			elevation[idx] = _height_at(wx, wz)
			var moist: float = _normalized_noise_2d(moisture_noise, wx, wz)
			var temp_latitude: float = 1.0 - absf((float(local_z) / maxf(1.0, float(world_size_z - 1))) * 2.0 - 1.0) * 0.35
			var temp_noise: float = _normalized_noise_2d(temperature_noise, wx, wz)
			moisture[idx] = clampf(moist * 0.82 + _normalized_noise_2d(tree_noise, wx + 97, wz - 47) * 0.18, 0.0, 1.0)
			temperature[idx] = clampf(temp_noise * 0.55 + temp_latitude * 0.45, 0.0, 1.0)


func _build_biome_map() -> void:
	for local_z in range(world_size_z):
		for local_x in range(world_size_x):
			var idx: int = _map_index(local_x, local_z)
			var elevation_value: int = elevation[idx]
			var moist: float = moisture[idx]
			var temp: float = temperature[idx]
			var biome_id: int = Biome.PLAINS
			if elevation_value <= sea_level - 2 and moist > 0.70:
				biome_id = Biome.WETLAND
			elif moist < 0.28 and temp > 0.40:
				biome_id = Biome.DRY
			elif temp < 0.24:
				biome_id = Biome.COLD
			elif moist > 0.54:
				biome_id = Biome.FOREST
			biome[idx] = biome_id


func _build_geology_maps() -> void:
	for local_z in range(world_size_z):
		var wz: int = _world_z(local_z)
		for local_x in range(world_size_x):
			var wx: int = _world_x(local_x)
			var idx: int = _map_index(local_x, local_z)
			var geology: float = _normalized_noise_2d(geology_noise, wx, wz)
			if geology < 0.18:
				soil_region[idx] = World.BLOCK_ID_SLATE
			elif geology < 0.35:
				soil_region[idx] = World.BLOCK_ID_BASALT
			elif geology < 0.53:
				soil_region[idx] = World.BLOCK_ID_LIMESTONE
			elif geology < 0.70:
				soil_region[idx] = World.BLOCK_ID_SANDSTONE
			else:
				soil_region[idx] = World.BLOCK_ID_GRANITE


func _fill_solid_terrain(volume: PackedByteArray) -> void:
	for local_z in range(world_size_z):
		for local_x in range(world_size_x):
			var map_idx: int = _map_index(local_x, local_z)
			var surface_y: int = elevation[map_idx]
			var topsoil_depth: int = _topsoil_depth(local_x, local_z)
			for y in range(surface_y + 1):
				var block_id: int = _stone_block_for(map_idx, y, surface_y)
				if y == surface_y:
					block_id = _surface_block_for_biome(biome[map_idx])
				elif y >= surface_y - topsoil_depth:
					block_id = _subsurface_block_for_biome(biome[map_idx])
				volume[_volume_index(local_x, y, local_z)] = block_id


func _carve_caves(volume: PackedByteArray) -> void:
	for local_z in range(world_size_z):
		var wz: int = _world_z(local_z)
		for local_x in range(world_size_x):
			var wx: int = _world_x(local_x)
			var map_idx: int = _map_index(local_x, local_z)
			var surface_y: int = elevation[map_idx]
			var max_cave_y: int = max(4, surface_y - 4)
			for y in range(4, max_cave_y):
				var depth: int = surface_y - y
				if depth < 7:
					continue
				var broad: float = _normalized_noise_3d(cave_noise, wx, y, wz)
				var detail: float = absf(cave_detail_noise.get_noise_3d(float(wx), float(y), float(wz)))
				var depth_bias: float = clampf(float(depth) / 42.0, 0.0, 1.0)
				if broad > 0.70 - depth_bias * 0.10 or detail < 0.035 + depth_bias * 0.018:
					volume[_volume_index(local_x, y, local_z)] = World.BLOCK_ID_AIR


func _add_static_water(volume: PackedByteArray) -> void:
	var max_water_y: int = clampi(sea_level - 7, 0, world_size_y - 1)
	for local_z in range(world_size_z):
		var wz: int = _world_z(local_z)
		for local_x in range(world_size_x):
			var wx: int = _world_x(local_x)
			var surface_y: int = elevation[_map_index(local_x, local_z)]
			var pocket_level: int = clampi(max_water_y - int(_normalized_noise_2d(aquifer_noise, wx, wz) * 9.0), 4, max_water_y)
			var upper_y: int = mini(surface_y - 9, pocket_level)
			if upper_y <= 4:
				continue
			for y in range(4, upper_y + 1):
				var idx: int = _volume_index(local_x, y, local_z)
				if volume[idx] != World.BLOCK_ID_AIR:
					continue
				var aquifer: float = _normalized_noise_3d(aquifer_noise, wx, y, wz)
				if aquifer > 0.56:
					volume[idx] = World.BLOCK_ID_WATER


func _add_ores(volume: PackedByteArray) -> void:
	for local_z in range(world_size_z):
		var wz: int = _world_z(local_z)
		for local_x in range(world_size_x):
			var wx: int = _world_x(local_x)
			var surface_y: int = elevation[_map_index(local_x, local_z)]
			for y in range(2, max(2, surface_y - 3)):
				var idx: int = _volume_index(local_x, y, local_z)
				if not _is_ore_replaceable(volume[idx]):
					continue
				var depth: int = surface_y - y
				var depth_factor: float = clampf(float(depth) / 70.0, 0.0, 1.0)
				var coal_value: float = _normalized_noise_3d(coal_noise, wx, y, wz)
				if coal_value > 0.79 - depth_factor * 0.04:
					volume[idx] = World.BLOCK_ID_COAL
					continue
				if y < sea_level - 10:
					var iron_value: float = _normalized_noise_3d(iron_noise, wx, y, wz)
					if iron_value > 0.82 - depth_factor * 0.06:
						volume[idx] = World.BLOCK_ID_IRON_ORE


func _apply_surface_blocks(volume: PackedByteArray) -> void:
	for local_z in range(world_size_z):
		for local_x in range(world_size_x):
			var map_idx: int = _map_index(local_x, local_z)
			var surface_y: int = elevation[map_idx]
			var surface_idx: int = _volume_index(local_x, surface_y, local_z)
			if volume[surface_idx] == World.BLOCK_ID_AIR or volume[surface_idx] == World.BLOCK_ID_WATER:
				continue
			volume[surface_idx] = _surface_block_for_biome(biome[map_idx])
			var topsoil_depth: int = _topsoil_depth(local_x, local_z)
			for y in range(maxi(0, surface_y - topsoil_depth), surface_y):
				var idx: int = _volume_index(local_x, y, local_z)
				if _is_ore_replaceable(volume[idx]):
					volume[idx] = _subsurface_block_for_biome(biome[map_idx])


func _apply_ramps(volume: PackedByteArray) -> void:
	for local_z in range(world_size_z - 1):
		for local_x in range(world_size_x - 1):
			var h_nw: int = elevation[_map_index(local_x, local_z)]
			var h_ne: int = elevation[_map_index(local_x + 1, local_z)]
			var h_sw: int = elevation[_map_index(local_x, local_z + 1)]
			var h_se: int = elevation[_map_index(local_x + 1, local_z + 1)]
			var result: Dictionary = _get_marching_squares_ramp(h_nw, h_ne, h_sw, h_se)
			var ramp_id: int = int(result.get("ramp_id", -1))
			if ramp_id < 0:
				continue
			var ramp_y: int = int(result.get("ramp_y", -1))
			if ramp_y < 0 or ramp_y >= world_size_y:
				continue
			var idx: int = _volume_index(local_x, ramp_y, local_z)
			if volume[idx] == World.BLOCK_ID_WATER or volume[idx] == World.BLOCK_ID_LOG or volume[idx] == World.BLOCK_ID_LEAVES:
				continue
			volume[idx] = ramp_id


func _place_trees(volume: PackedByteArray) -> void:
	for cell_z in range(int(ceil(float(world_size_z) / float(TREE_CELL_SIZE)))):
		for cell_x in range(int(ceil(float(world_size_x) / float(TREE_CELL_SIZE)))):
			var local_x: int = cell_x * TREE_CELL_SIZE + _hash_range(cell_x, cell_z, 0x7101, TREE_CELL_SIZE)
			var local_z: int = cell_z * TREE_CELL_SIZE + _hash_range(cell_x, cell_z, 0x7102, TREE_CELL_SIZE)
			if local_x < 1 or local_z < 1 or local_x >= world_size_x - 1 or local_z >= world_size_z - 1:
				continue
			var map_idx: int = _map_index(local_x, local_z)
			var biome_id: int = biome[map_idx]
			var density: float = _tree_chance_for(map_idx)
			if _rand01(local_x, local_z, 0x7103) > density:
				continue
			if _local_slope(local_x, local_z) > 1:
				continue
			if _has_reservation_near(local_x, local_z, TREE_RESERVATION_RADIUS):
				continue
			var surface_y: int = elevation[map_idx]
			if surface_y + 8 >= world_size_y:
				continue
			var surface_block: int = volume[_volume_index(local_x, surface_y, local_z)]
			if surface_block != World.BLOCK_ID_GRASS and surface_block != World.BLOCK_ID_MOSS:
				continue
			if biome_id == Biome.DRY and _rand01(local_x, local_z, 0x7104) > 0.12:
				continue
			_place_tree_at(volume, local_x, surface_y + 1, local_z, 3 + _hash_range(local_x, local_z, 0x7105, 3))
			_reserve_radius(local_x, local_z, TREE_RESERVATION_RADIUS)
			_paint_tree_density(local_x, local_z, TREE_INFLUENCE_RADIUS)


func _place_flowers(volume: PackedByteArray) -> void:
	for local_z in range(1, world_size_z - 1):
		for local_x in range(1, world_size_x - 1):
			var map_idx: int = _map_index(local_x, local_z)
			if feature_reserved[map_idx] != 0:
				continue
			var surface_y: int = elevation[map_idx]
			var surface_idx: int = _volume_index(local_x, surface_y, local_z)
			var surface_block: int = volume[surface_idx]
			if surface_block != World.BLOCK_ID_GRASS and surface_block != World.BLOCK_ID_MOSS:
				continue
			var chance: float = FLOWER_BASE_CHANCE + tree_density[map_idx] * FLOWER_TREE_BONUS
			if biome[map_idx] == Biome.FOREST or biome[map_idx] == Biome.PLAINS:
				chance += FLOWER_BIOME_BONUS
			chance = clampf(chance, 0.0, 0.24)
			if _rand01(local_x, local_z, 0x9101) <= chance:
				volume[surface_idx] = World.BLOCK_ID_FLOWER


func _final_cleanup(volume: PackedByteArray) -> void:
	for local_z in range(world_size_z):
		for local_x in range(world_size_x):
			var surface_y: int = elevation[_map_index(local_x, local_z)]
			if surface_y < 0 or surface_y >= world_size_y:
				continue
			var idx: int = _volume_index(local_x, surface_y, local_z)
			if volume[idx] == World.BLOCK_ID_FLOWER and surface_y + 1 < world_size_y:
				var above_idx: int = _volume_index(local_x, surface_y + 1, local_z)
				if volume[above_idx] != World.BLOCK_ID_AIR:
					volume[idx] = World.BLOCK_ID_GRASS


func _bake_chunks(volume: PackedByteArray, chunks: Dictionary) -> void:
	for cy in range(world_chunks_y):
		for cx in range(world_min_chunk_x, world_max_chunk_x + 1):
			for cz in range(world_min_chunk_z, world_max_chunk_z + 1):
				var coord := Vector3i(cx, cy, cz)
				var blocks := PackedByteArray()
				blocks.resize(chunk_size * chunk_size * chunk_size)
				for lx in range(chunk_size):
					var local_x: int = cx * chunk_size + lx - world_min_block_x
					for ly in range(chunk_size):
						var y: int = cy * chunk_size + ly
						for lz in range(chunk_size):
							var local_z: int = cz * chunk_size + lz - world_min_block_z
							var chunk_idx: int = (lz * chunk_size + ly) * chunk_size + lx
							blocks[chunk_idx] = volume[_volume_index(local_x, y, local_z)]
				chunks[coord] = blocks


func _place_tree_at(volume: PackedByteArray, local_x: int, base_y: int, local_z: int, trunk_height: int) -> void:
	for y in range(base_y, mini(base_y + trunk_height, world_size_y)):
		_set_volume_block(volume, local_x, y, local_z, World.BLOCK_ID_LOG)
	var crown_y: int = base_y + trunk_height
	for dy in range(-1, 3):
		var y: int = crown_y + dy
		if y < 0 or y >= world_size_y:
			continue
		var radius: int = 2 if dy <= 1 else 1
		for dz in range(-radius, radius + 1):
			for dx in range(-radius, radius + 1):
				if abs(dx) + abs(dz) > radius + 1:
					continue
				if dx == 0 and dz == 0 and dy < 1:
					continue
				var target_x: int = local_x + dx
				var target_z: int = local_z + dz
				if not _is_local_xz_valid(target_x, target_z):
					continue
				var idx: int = _volume_index(target_x, y, target_z)
				if volume[idx] == World.BLOCK_ID_AIR:
					volume[idx] = World.BLOCK_ID_LEAVES


func _set_volume_block(volume: PackedByteArray, local_x: int, y: int, local_z: int, block_id: int) -> void:
	if not _is_local_block_valid(local_x, y, local_z):
		return
	volume[_volume_index(local_x, y, local_z)] = block_id


func _tree_chance_for(map_idx: int) -> float:
	var biome_id: int = biome[map_idx]
	var moist: float = moisture[map_idx]
	var temp: float = temperature[map_idx]
	var base: float = 0.0
	match biome_id:
		Biome.FOREST:
			base = 0.82
		Biome.PLAINS:
			base = 0.28
		Biome.WETLAND:
			base = 0.22
		Biome.DRY:
			base = 0.08
		Biome.COLD:
			base = 0.06
	return clampf(base * clampf(moist + 0.20, 0.0, 1.0) * clampf(temp + 0.35, 0.0, 1.0), 0.0, 0.95)


func _local_slope(local_x: int, local_z: int) -> int:
	var center: int = elevation[_map_index(local_x, local_z)]
	var max_delta: int = 0
	for dz in range(-1, 2):
		for dx in range(-1, 2):
			var x: int = clampi(local_x + dx, 0, world_size_x - 1)
			var z: int = clampi(local_z + dz, 0, world_size_z - 1)
			max_delta = maxi(max_delta, abs(elevation[_map_index(x, z)] - center))
	return max_delta


func _has_reservation_near(local_x: int, local_z: int, radius: int) -> bool:
	for dz in range(-radius, radius + 1):
		for dx in range(-radius, radius + 1):
			var x: int = local_x + dx
			var z: int = local_z + dz
			if not _is_local_xz_valid(x, z):
				continue
			if feature_reserved[_map_index(x, z)] != 0:
				return true
	return false


func _reserve_radius(local_x: int, local_z: int, radius: int) -> void:
	for dz in range(-radius, radius + 1):
		for dx in range(-radius, radius + 1):
			var x: int = local_x + dx
			var z: int = local_z + dz
			if _is_local_xz_valid(x, z):
				feature_reserved[_map_index(x, z)] = 1


func _paint_tree_density(local_x: int, local_z: int, radius: int) -> void:
	for dz in range(-radius, radius + 1):
		for dx in range(-radius, radius + 1):
			var dist_sq: int = dx * dx + dz * dz
			if dist_sq > radius * radius:
				continue
			var x: int = local_x + dx
			var z: int = local_z + dz
			if not _is_local_xz_valid(x, z):
				continue
			var idx: int = _map_index(x, z)
			var dist: float = sqrt(float(dist_sq))
			tree_density[idx] = clampf(tree_density[idx] + (1.0 - dist / float(radius + 1)), 0.0, 1.0)


func _surface_block_for_biome(biome_id: int) -> int:
	match biome_id:
		Biome.DRY:
			return World.BLOCK_ID_SANDSTONE
		Biome.WETLAND:
			return World.BLOCK_ID_MOSS
		Biome.COLD:
			return World.BLOCK_ID_SLATE
		_:
			return World.BLOCK_ID_GRASS


func _subsurface_block_for_biome(biome_id: int) -> int:
	match biome_id:
		Biome.DRY:
			return World.BLOCK_ID_SANDSTONE
		Biome.WETLAND:
			return World.BLOCK_ID_CLAY
		_:
			return World.BLOCK_ID_DIRT


func _stone_block_for(map_idx: int, y: int, surface_y: int) -> int:
	var depth: int = surface_y - y
	var region: int = soil_region[map_idx]
	if depth > 90:
		return World.BLOCK_ID_BASALT
	if depth > 55 and region != World.BLOCK_ID_SANDSTONE:
		return World.BLOCK_ID_SLATE
	if depth > 28:
		return region
	return World.BLOCK_ID_GRANITE if region == World.BLOCK_ID_BASALT else region


func _is_ore_replaceable(block_id: int) -> bool:
	return block_id == World.BLOCK_ID_GRANITE \
		or block_id == World.BLOCK_ID_LIMESTONE \
		or block_id == World.BLOCK_ID_BASALT \
		or block_id == World.BLOCK_ID_SLATE \
		or block_id == World.BLOCK_ID_SANDSTONE


func _topsoil_depth(local_x: int, local_z: int) -> int:
	return TOPSOIL_DEPTH_MIN + _hash_range(local_x, local_z, 0x2201, TOPSOIL_DEPTH_MAX - TOPSOIL_DEPTH_MIN + 1)


func _height_at(wx: int, wz: int) -> int:
	var cell_x := floori(float(wx) / float(TERRAIN_CELL_SIZE))
	var cell_z := floori(float(wz) / float(TERRAIN_CELL_SIZE))
	var frac_x := (float(wx) - float(cell_x * TERRAIN_CELL_SIZE)) / float(TERRAIN_CELL_SIZE)
	var frac_z := (float(wz) - float(cell_z * TERRAIN_CELL_SIZE)) / float(TERRAIN_CELL_SIZE)
	var h00 := _raw_height_at(cell_x * TERRAIN_CELL_SIZE, cell_z * TERRAIN_CELL_SIZE)
	var h10 := _raw_height_at((cell_x + 1) * TERRAIN_CELL_SIZE, cell_z * TERRAIN_CELL_SIZE)
	var h01 := _raw_height_at(cell_x * TERRAIN_CELL_SIZE, (cell_z + 1) * TERRAIN_CELL_SIZE)
	var h11 := _raw_height_at((cell_x + 1) * TERRAIN_CELL_SIZE, (cell_z + 1) * TERRAIN_CELL_SIZE)
	var h0 := lerpf(h00, h10, frac_x)
	var h1 := lerpf(h01, h11, frac_x)
	return clampi(int(round(lerpf(h0, h1, frac_z))), 0, world_size_y - 1)


func _raw_height_at(wx: int, wz: int) -> float:
	var macro_value := _normalized_noise_2d(height_noise_macro, wx, wz)
	var amplitude := FLAT_AMPLITUDE
	var n := 0.0
	if macro_value < MACRO_FLAT_CUTOFF:
		n = height_noise_flat.get_noise_2d(float(wx), float(wz))
		amplitude = FLAT_AMPLITUDE
	elif macro_value < MACRO_SMALL_CUTOFF:
		n = height_noise_small.get_noise_2d(float(wx), float(wz))
		amplitude = SMALL_AMPLITUDE
	else:
		n = height_noise_large.get_noise_2d(float(wx), float(wz))
		amplitude = LARGE_AMPLITUDE
	return float(sea_level) + n * float(amplitude)


func _get_marching_squares_ramp(h_nw: int, h_ne: int, h_sw: int, h_se: int) -> Dictionary:
	var min_h := mini(mini(h_nw, h_ne), mini(h_sw, h_se))
	var max_h := maxi(maxi(h_nw, h_ne), maxi(h_sw, h_se))
	if max_h - min_h != 1:
		return {"ramp_id": -1, "ramp_y": -1}
	var index := 0
	if h_nw == max_h:
		index += 1
	if h_ne == max_h:
		index += 2
	if h_sw == max_h:
		index += 4
	if h_se == max_h:
		index += 8
	return {"ramp_id": World.MARCHING_SQUARES_RAMP[index], "ramp_y": min_h + 1}


func _configure_noises() -> void:
	_configure_noise(height_noise_flat, mix_seed(world_seed ^ 0x1f), FLAT_NOISE_FREQUENCY)
	_configure_noise(height_noise_small, mix_seed(world_seed ^ 0x2f), SMALL_NOISE_FREQUENCY)
	_configure_noise(height_noise_large, mix_seed(world_seed ^ 0x3f), LARGE_NOISE_FREQUENCY)
	_configure_noise(height_noise_macro, mix_seed(world_seed ^ 0x4f), MACRO_NOISE_FREQUENCY)
	_configure_noise(moisture_noise, mix_seed(world_seed ^ 0x101), MOISTURE_NOISE_FREQUENCY)
	_configure_noise(temperature_noise, mix_seed(world_seed ^ 0x102), TEMPERATURE_NOISE_FREQUENCY)
	_configure_noise(geology_noise, mix_seed(world_seed ^ 0x103), GEOLOGY_NOISE_FREQUENCY)
	_configure_noise(tree_noise, mix_seed(world_seed ^ 0x104), TREE_NOISE_FREQUENCY)
	_configure_noise(cave_noise, mix_seed(world_seed ^ 0x105), CAVE_NOISE_FREQUENCY)
	_configure_noise(cave_detail_noise, mix_seed(world_seed ^ 0x106), CAVE_DETAIL_NOISE_FREQUENCY)
	_configure_noise(aquifer_noise, mix_seed(world_seed ^ 0x107), AQUIFER_NOISE_FREQUENCY)
	_configure_noise(coal_noise, mix_seed(world_seed ^ 0x108), COAL_NOISE_FREQUENCY)
	_configure_noise(iron_noise, mix_seed(world_seed ^ 0x109), IRON_NOISE_FREQUENCY)


func _configure_noise(noise: FastNoiseLite, seed: int, frequency: float) -> void:
	noise.seed = seed
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	noise.frequency = frequency


func mix_seed(value: int) -> int:
	var v: int = value & 0xffffffff
	v = int(((v >> 16) ^ v) * SEED_MIX_FACTOR) & 0xffffffff
	v = int(((v >> 16) ^ v) * SEED_MIX_FACTOR) & 0xffffffff
	v = int((v >> 16) ^ v) & 0xffffffff
	return v & SEED_MASK


func _hash_range(a: int, b: int, salt: int, range_size: int) -> int:
	if range_size <= 0:
		return 0
	return _hash_u31(a, 0, b, salt) % range_size


func _rand01(a: int, b: int, salt: int) -> float:
	return float(_hash_u31(a, 0, b, salt) & 0xffff) / 65535.0


func _hash_u31(a: int, y: int, b: int, salt: int) -> int:
	var h: int = world_seed ^ salt
	h = mix_seed(h ^ (a * 374761393))
	h = mix_seed(h ^ (y * 668265263))
	h = mix_seed(h ^ (b * 2246822519))
	return h & SEED_MASK


func _normalized_noise_2d(noise: FastNoiseLite, wx: int, wz: int) -> float:
	return clampf((noise.get_noise_2d(float(wx), float(wz)) + 1.0) * 0.5, 0.0, 1.0)


func _normalized_noise_3d(noise: FastNoiseLite, wx: int, y: int, wz: int) -> float:
	return clampf((noise.get_noise_3d(float(wx), float(y), float(wz)) + 1.0) * 0.5, 0.0, 1.0)


func _world_x(local_x: int) -> int:
	return world_min_block_x + local_x


func _world_z(local_z: int) -> int:
	return world_min_block_z + local_z


func _map_index(local_x: int, local_z: int) -> int:
	return local_z * world_size_x + local_x


func _volume_index(local_x: int, y: int, local_z: int) -> int:
	return (local_z * world_size_y + y) * world_size_x + local_x


func _is_local_xz_valid(local_x: int, local_z: int) -> bool:
	return local_x >= 0 and local_x < world_size_x and local_z >= 0 and local_z < world_size_z


func _is_local_block_valid(local_x: int, y: int, local_z: int) -> bool:
	return _is_local_xz_valid(local_x, local_z) and y >= 0 and y < world_size_y


func _elapsed_ms(start_usec: int) -> float:
	return float(Time.get_ticks_usec() - start_usec) / 1000.0
