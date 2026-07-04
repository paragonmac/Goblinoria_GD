extends RefCounted
class_name WorldTerrainMaterialGenerator
## Builds geology and applies terrain materials, aquifers, and ores.

const WorldGenerationSharedScript = preload("res://scripts/world/world_generation_shared.gd")

const SEED_MASK := WorldGenerationSharedScript.SEED_MASK
const GEOLOGY_NOISE_FREQUENCY := 0.014
const AQUIFER_NOISE_FREQUENCY := 0.045
const COAL_NOISE_FREQUENCY := 0.052
const IRON_NOISE_FREQUENCY := 0.06
const STATIC_UNDERGROUND_WATER_ENABLED := false

var world_seed: int = 0
var sea_level: int = 0
var world_size_x: int = 0
var world_size_y: int = 0
var world_size_z: int = 0
var world_min_block_x: int = 0
var world_min_block_z: int = 0
var biome_wetland: int = 0
var biome_dry: int = 0
var biome_cold: int = 0

var elevation := PackedInt32Array()
var biome := PackedByteArray()
var soil_region := PackedByteArray()

var water_cells_placed: int = 0
var coal_ore_cells_placed: int = 0
var iron_ore_cells_placed: int = 0

var geology_noise := FastNoiseLite.new()
var aquifer_noise := FastNoiseLite.new()
var coal_noise := FastNoiseLite.new()
var iron_noise := FastNoiseLite.new()


func configure(
	seed: int,
	sea_level_value: int,
	size_x: int,
	size_y: int,
	size_z: int,
	min_block_x: int,
	min_block_z: int,
	elevation_map: PackedInt32Array,
	biome_map: PackedByteArray,
	soil_region_map: PackedByteArray,
	biome_wetland_id: int,
	biome_dry_id: int,
	biome_cold_id: int
) -> void:
	world_seed = seed
	sea_level = sea_level_value
	world_size_x = size_x
	world_size_y = size_y
	world_size_z = size_z
	world_min_block_x = min_block_x
	world_min_block_z = min_block_z
	elevation = elevation_map
	biome = biome_map
	soil_region = soil_region_map
	biome_wetland = biome_wetland_id
	biome_dry = biome_dry_id
	biome_cold = biome_cold_id
	water_cells_placed = 0
	coal_ore_cells_placed = 0
	iron_ore_cells_placed = 0
	WorldGenerationSharedScript.configure_noise(geology_noise, _mix_seed(world_seed ^ 0x103), GEOLOGY_NOISE_FREQUENCY)
	WorldGenerationSharedScript.configure_noise(aquifer_noise, _mix_seed(world_seed ^ 0x107), AQUIFER_NOISE_FREQUENCY)
	WorldGenerationSharedScript.configure_noise(coal_noise, _mix_seed(world_seed ^ 0x108), COAL_NOISE_FREQUENCY)
	WorldGenerationSharedScript.configure_noise(iron_noise, _mix_seed(world_seed ^ 0x109), IRON_NOISE_FREQUENCY)


func build_geology_maps() -> void:
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


func fill_solid_terrain(volume: PackedByteArray) -> void:
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


func add_static_water(volume: PackedByteArray) -> void:
	if not STATIC_UNDERGROUND_WATER_ENABLED:
		return
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
					water_cells_placed += 1


func add_ores(volume: PackedByteArray) -> void:
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
					coal_ore_cells_placed += 1
					continue
				if y < sea_level - 10:
					var iron_value: float = _normalized_noise_3d(iron_noise, wx, y, wz)
					if iron_value > 0.82 - depth_factor * 0.06:
						volume[idx] = World.BLOCK_ID_IRON_ORE
						iron_ore_cells_placed += 1


func apply_surface_blocks(volume: PackedByteArray) -> void:
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


func get_stats() -> Dictionary:
	return {
		"static_water_enabled": 1 if STATIC_UNDERGROUND_WATER_ENABLED else 0,
		"water_cells_placed": water_cells_placed,
		"coal_ore_cells_placed": coal_ore_cells_placed,
		"iron_ore_cells_placed": iron_ore_cells_placed,
	}


func get_soil_region() -> PackedByteArray:
	return soil_region


func _surface_block_for_biome(biome_id: int) -> int:
	if biome_id == biome_dry:
		return World.BLOCK_ID_SANDSTONE
	if biome_id == biome_wetland:
		return World.BLOCK_ID_MOSS
	if biome_id == biome_cold:
		return World.BLOCK_ID_SLATE
	return World.BLOCK_ID_GRASS


func _subsurface_block_for_biome(biome_id: int) -> int:
	if biome_id == biome_dry:
		return World.BLOCK_ID_SANDSTONE
	if biome_id == biome_wetland:
		return World.BLOCK_ID_CLAY
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
	return WorldGenerationSharedScript.TOPSOIL_DEPTH_MIN + _hash_range(
		local_x,
		local_z,
		0x2201,
		WorldGenerationSharedScript.TOPSOIL_DEPTH_MAX - WorldGenerationSharedScript.TOPSOIL_DEPTH_MIN + 1
	)


func _hash_range(a: int, b: int, salt: int, range_size: int) -> int:
	if range_size <= 0:
		return 0
	return _hash_u31(a, 0, b, salt) % range_size


func _hash_u31(a: int, y: int, b: int, salt: int) -> int:
	var h: int = world_seed ^ salt
	h = _mix_seed(h ^ (a * 374761393))
	h = _mix_seed(h ^ (y * 668265263))
	h = _mix_seed(h ^ (b * 2246822519))
	return h & SEED_MASK


func _mix_seed(value: int) -> int:
	return WorldGenerationSharedScript.mix_seed(value)


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
