extends RefCounted
class_name WorldGenerationPipeline
## Full finite-world generation pipeline that builds intermediate maps before baking chunks.

const WorldGenerationSharedScript = preload("res://scripts/world/world_generation_shared.gd")
const WorldTerrainHeightSamplerScript = preload("res://scripts/world/world_terrain_height_sampler.gd")
const WorldRampRulesScript = preload("res://scripts/world/world_ramp_rules.gd")
const WorldCaveGeneratorScript = preload("res://scripts/world/world_cave_generator.gd")
const WorldTerrainMaterialGeneratorScript = preload("res://scripts/world/world_terrain_material_generator.gd")
const WorldVegetationGeneratorScript = preload("res://scripts/world/world_vegetation_generator.gd")

#region Constants
const MOISTURE_NOISE_FREQUENCY := 0.011
const TEMPERATURE_NOISE_FREQUENCY := 0.008
const MOISTURE_DETAIL_NOISE_FREQUENCY := 0.025
const BIOME_COUNT := 5
const GENERATION_REGION_SIZE := 32
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
	"place_flowers",
	"final_cleanup",
	"collect_generation_stats",
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
var world_chunks_x: int = 0
var world_chunks_y: int = World.WORLD_CHUNKS_Y
var world_chunks_z: int = 0
var world_min_chunk_x: int = 0
var world_max_chunk_x: int = 0
var world_min_chunk_z: int = 0
var world_max_chunk_z: int = 0
var world_min_block_x: int = 0
var world_min_block_z: int = 0
var world_size_x: int = 0
var world_size_y: int = World.WORLD_CHUNKS_Y * World.CHUNK_SIZE
var world_size_z: int = 0
var sea_level: int = 0

var elevation := PackedInt32Array()
var moisture := PackedFloat32Array()
var temperature := PackedFloat32Array()
var biome := PackedByteArray()
var soil_region := PackedByteArray()
var feature_reserved := PackedByteArray()
var generated_trees: Dictionary = {}
var pipeline_metrics: Dictionary = {}
var progress_callback := Callable()
var biome_counts := PackedInt32Array()
var cave_stats: Dictionary = {}
# Region jobs are output-identical and cut 512^2 total generation from 62.0 s
# to 23.5 s on the measured machine.
var parallel_generation: bool = true
var generation_workers: int = 0
var generation_region_size: int = GENERATION_REGION_SIZE
var report_region_progress: bool = false
var region_mutex := Mutex.new()
var active_regions: Array = []
var region_completed: int = 0
var region_thread_ids: Dictionary = {}
var terrain_material_generator = WorldTerrainMaterialGeneratorScript.new()
var vegetation_generator = WorldVegetationGeneratorScript.new()

var height_noise_flat := FastNoiseLite.new()
var height_noise_small := FastNoiseLite.new()
var height_noise_large := FastNoiseLite.new()
var height_noise_macro := FastNoiseLite.new()
var moisture_noise := FastNoiseLite.new()
var temperature_noise := FastNoiseLite.new()
var moisture_detail_noise := FastNoiseLite.new()
#endregion


func generate(config: Dictionary) -> Dictionary:
	_apply_config(config)
	_set_progress_callback(config.get("progress_callback", Callable()))
	_configure_noises()
	_resize_maps()
	_reset_generation_stats()
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
	_configure_terrain_material_generator()
	_run_pass("geology_maps", Callable(self, "_build_geology_maps").bind())
	_run_pass("fill_solid_terrain", Callable(self, "_fill_solid_terrain").bind(volume))
	_run_pass("carve_caves", Callable(self, "_carve_caves").bind(volume))
	_run_pass("add_static_water", Callable(self, "_add_static_water").bind(volume))
	_run_pass("add_ores", Callable(self, "_add_ores").bind(volume))
	_run_pass("apply_surface_blocks", Callable(self, "_apply_surface_blocks").bind(volume))
	_run_pass("apply_ramps", Callable(self, "_apply_ramps").bind(volume))
	_configure_vegetation_generator()
	_run_pass("place_flowers", Callable(self, "_place_flowers").bind(volume))
	_run_pass("final_cleanup", Callable(self, "_final_cleanup").bind(volume))
	_run_pass("collect_generation_stats", Callable(self, "_collect_generation_stats").bind(volume))
	var chunks: Dictionary = {}
	_run_pass("bake_chunks", Callable(self, "_bake_chunks").bind(volume, chunks))
	pipeline_metrics["total_ms"] = _elapsed_ms(total_start_usec)
	return {
		"chunks": chunks,
		"trees": generated_trees,
		"maps": {
			"elevation": elevation,
			"moisture": moisture,
			"temperature": temperature,
			"biome": biome,
			"soil_region": soil_region,
			"feature_reserved": feature_reserved,
		},
		"metrics": pipeline_metrics,
	}


func generate_tree_attachments(config: Dictionary) -> Dictionary:
	_apply_config(config)
	_configure_noises()
	_resize_maps()
	_reset_generation_stats()
	_build_climate_maps()
	_build_biome_map()
	_configure_terrain_material_generator()
	_build_geology_maps()
	var volume := PackedByteArray()
	volume.resize(world_size_x * world_size_y * world_size_z)
	volume.fill(World.BLOCK_ID_AIR)
	for local_z in range(world_size_z):
		for local_x in range(world_size_x):
			var surface_y: int = elevation[_map_index(local_x, local_z)]
			volume[_volume_index(local_x, surface_y, local_z)] = World.BLOCK_ID_GRANITE
	_apply_surface_blocks(volume)
	_apply_ramps(volume)
	_configure_vegetation_generator()
	vegetation_generator.place_flowers(volume)
	generated_trees = vegetation_generator.place_trees(volume, world_min_block_x, world_min_block_z, 0, 0)
	return generated_trees.duplicate(true)

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
	parallel_generation = bool(config.get("parallel_generation", true))
	generation_workers = int(config.get("generation_workers", 0))
	generation_region_size = maxi(1, int(config.get("generation_region_size", GENERATION_REGION_SIZE)))
	report_region_progress = bool(config.get("report_region_progress", false))


func _resize_maps() -> void:
	var map_size: int = world_size_x * world_size_z
	elevation.resize(map_size)
	moisture.resize(map_size)
	temperature.resize(map_size)
	biome.resize(map_size)
	soil_region.resize(map_size)
	feature_reserved.resize(map_size)
	feature_reserved.fill(0)


func _configure_terrain_material_generator() -> void:
	terrain_material_generator.configure(
		world_seed,
		sea_level,
		world_size_x,
		world_size_y,
		world_size_z,
		world_min_block_x,
		world_min_block_z,
		elevation,
		biome,
		soil_region,
		Biome.WETLAND,
		Biome.DRY,
		Biome.COLD
	)


func _configure_vegetation_generator() -> void:
	vegetation_generator.configure(
		world_seed,
		world_size_x,
		world_size_y,
		world_size_z,
		elevation,
		biome,
		feature_reserved,
		{
			"plains": Biome.PLAINS,
			"forest": Biome.FOREST,
		}
	)


func _reset_generation_stats() -> void:
	biome_counts.resize(BIOME_COUNT)
	biome_counts.fill(0)
	cave_stats.clear()


func _run_pass(pass_name: String, callback: Callable) -> void:
	var passes: Array = pipeline_metrics.get("passes", [])
	var pass_index: int = passes.size()
	pipeline_metrics["active_pass"] = pass_name
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
	var row: Dictionary = {
		"pass_name": pass_name,
		"pass_completed": completed,
		"pass_total": total,
		"state": state,
	}
	var stats_value = pipeline_metrics.get("generation_stats", {})
	if typeof(stats_value) == TYPE_DICTIONARY:
		row["generation_stats"] = stats_value.duplicate(true)
	progress_callback.call(row)


func _build_climate_maps() -> void:
	if parallel_generation:
		_run_parallel_regions(Callable(self, "_build_climate_region"))
		return
	for local_z in range(world_size_z):
		var wz: int = _world_z(local_z)
		for local_x in range(world_size_x):
			var wx: int = _world_x(local_x)
			var idx: int = _map_index(local_x, local_z)
			elevation[idx] = _height_at(wx, wz)
			var moist: float = _normalized_noise_2d(moisture_noise, wx, wz)
			var temp_latitude: float = 1.0 - absf((float(local_z) / maxf(1.0, float(world_size_z - 1))) * 2.0 - 1.0) * 0.35
			var temp_noise: float = _normalized_noise_2d(temperature_noise, wx, wz)
			moisture[idx] = clampf(moist * 0.82 + _normalized_noise_2d(moisture_detail_noise, wx + 97, wz - 47) * 0.18, 0.0, 1.0)
			temperature[idx] = clampf(temp_noise * 0.55 + temp_latitude * 0.45, 0.0, 1.0)


func _build_climate_region(x0: int, z0: int, x1: int, z1: int, _region_index: int) -> void:
	for local_z in range(z0, z1):
		var wz: int = _world_z(local_z)
		for local_x in range(x0, x1):
			var wx: int = _world_x(local_x)
			var idx: int = _map_index(local_x, local_z)
			elevation[idx] = _height_at(wx, wz)
			var moist: float = _normalized_noise_2d(moisture_noise, wx, wz)
			var temp_latitude: float = 1.0 - absf((float(local_z) / maxf(1.0, float(world_size_z - 1))) * 2.0 - 1.0) * 0.35
			var temp_noise: float = _normalized_noise_2d(temperature_noise, wx, wz)
			moisture[idx] = clampf(moist * 0.82 + _normalized_noise_2d(moisture_detail_noise, wx + 97, wz - 47) * 0.18, 0.0, 1.0)
			temperature[idx] = clampf(temp_noise * 0.55 + temp_latitude * 0.45, 0.0, 1.0)


func _build_biome_map() -> void:
	if parallel_generation:
		var counts: Array = []
		counts.resize(_region_count())
		for region_index in range(counts.size()):
			counts[region_index] = PackedInt32Array()
		_run_parallel_regions(Callable(self, "_build_biome_region").bind(counts))
		biome_counts.fill(0)
		for region_index in range(counts.size()):
			var values: PackedInt32Array = counts[region_index]
			for biome_id in range(BIOME_COUNT):
				biome_counts[biome_id] += values[biome_id]
		return
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
			biome_counts[biome_id] += 1


func _build_biome_region(x0: int, z0: int, x1: int, z1: int, region_index: int, counts: Array) -> void:
	var local_counts := PackedInt32Array()
	local_counts.resize(BIOME_COUNT)
	local_counts.fill(0)
	for local_z in range(z0, z1):
		for local_x in range(x0, x1):
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
			local_counts[biome_id] += 1
	counts[region_index] = local_counts


func _build_geology_maps() -> void:
	if parallel_generation:
		_run_parallel_regions(Callable(terrain_material_generator, "build_geology_region"))
	else:
		terrain_material_generator.build_geology_maps()
	soil_region = terrain_material_generator.get_soil_region()


func _fill_solid_terrain(volume: PackedByteArray) -> void:
	if parallel_generation:
		_run_parallel_regions(Callable(terrain_material_generator, "fill_solid_terrain_region").bind(volume))
	else:
		terrain_material_generator.fill_solid_terrain(volume)


func _carve_caves(volume: PackedByteArray) -> void:
	var cave_generator = WorldCaveGeneratorScript.new()
	cave_stats = cave_generator.carve(
		volume,
		elevation,
		world_seed,
		world_size_x,
		world_size_y,
		world_size_z
	)

func _add_static_water(volume: PackedByteArray) -> void:
	terrain_material_generator.add_static_water(volume)


func _add_ores(volume: PackedByteArray) -> void:
	if parallel_generation:
		terrain_material_generator.add_ores_regions_prepare(_region_count())
		_run_parallel_regions(Callable(terrain_material_generator, "add_ores_region").bind(volume))
		terrain_material_generator.finish_add_ores_regions()
	else:
		terrain_material_generator.add_ores(volume)


func _apply_surface_blocks(volume: PackedByteArray) -> void:
	if parallel_generation:
		_run_parallel_regions(Callable(terrain_material_generator, "apply_surface_blocks_region").bind(volume))
	else:
		terrain_material_generator.apply_surface_blocks(volume)


func _apply_ramps(volume: PackedByteArray) -> void:
	if parallel_generation:
		_run_parallel_regions(Callable(self, "_apply_ramp_region").bind(volume))
		return
	for local_z in range(world_size_z - 1):
		for local_x in range(world_size_x - 1):
			var h_nw: int = elevation[_map_index(local_x, local_z)]
			var h_ne: int = elevation[_map_index(local_x + 1, local_z)]
			var h_sw: int = elevation[_map_index(local_x, local_z + 1)]
			var h_se: int = elevation[_map_index(local_x + 1, local_z + 1)]
			var result: Dictionary = WorldRampRulesScript.marching_squares_ramp(h_nw, h_ne, h_sw, h_se)
			var ramp_id: int = int(result.get("ramp_id", -1))
			if ramp_id < 0:
				continue
			var ramp_y: int = int(result.get("ramp_y", -1))
			if ramp_y < 0 or ramp_y >= world_size_y:
				continue
			var idx: int = _volume_index(local_x, ramp_y, local_z)
			if volume[idx] == World.BLOCK_ID_WATER:
				continue
			volume[idx] = World.terrain_slope_id_for_shape(ramp_id)


func _apply_ramp_region(x0: int, z0: int, x1: int, z1: int, _region_index: int, volume: PackedByteArray) -> void:
	for local_z in range(z0, mini(z1, world_size_z - 1)):
		for local_x in range(x0, mini(x1, world_size_x - 1)):
			var h_nw: int = elevation[_map_index(local_x, local_z)]
			var h_ne: int = elevation[_map_index(local_x + 1, local_z)]
			var h_sw: int = elevation[_map_index(local_x, local_z + 1)]
			var h_se: int = elevation[_map_index(local_x + 1, local_z + 1)]
			var result: Dictionary = WorldRampRulesScript.marching_squares_ramp(h_nw, h_ne, h_sw, h_se)
			var ramp_id: int = int(result.get("ramp_id", -1))
			if ramp_id < 0:
				continue
			var ramp_y: int = int(result.get("ramp_y", -1))
			if ramp_y < 0 or ramp_y >= world_size_y:
				continue
			var idx: int = _volume_index(local_x, ramp_y, local_z)
			if volume[idx] != World.BLOCK_ID_WATER:
				volume[idx] = World.terrain_slope_id_for_shape(ramp_id)


func _place_flowers(volume: PackedByteArray) -> void:
	if parallel_generation:
		vegetation_generator.prepare_flower_regions(_region_count())
		_run_parallel_regions(Callable(vegetation_generator, "place_flowers_region").bind(volume))
		vegetation_generator.finish_flower_regions()
	else:
		vegetation_generator.place_flowers(volume)
	feature_reserved = vegetation_generator.get_feature_reserved()
	generated_trees = vegetation_generator.place_trees(volume, world_min_block_x, world_min_block_z, 0, 0)


func _final_cleanup(volume: PackedByteArray) -> void:
	if parallel_generation:
		_run_parallel_regions(Callable(vegetation_generator, "final_cleanup_region").bind(volume))
	else:
		vegetation_generator.final_cleanup(volume)

func _collect_generation_stats(volume: PackedByteArray) -> void:
	var water_blocks: int = volume.count(World.BLOCK_ID_WATER)
	var flower_blocks: int = volume.count(World.BLOCK_ID_FLOWER)
	var coal_blocks: int = volume.count(World.BLOCK_ID_COAL)
	var iron_blocks: int = volume.count(World.BLOCK_ID_IRON_ORE)
	var moss_blocks: int = volume.count(World.BLOCK_ID_MOSS)
	var terrain_material_stats: Dictionary = terrain_material_generator.get_stats()
	var vegetation_stats: Dictionary = vegetation_generator.get_stats()
	pipeline_metrics["generation_stats"] = {
		"biome_plains": _biome_count(Biome.PLAINS),
		"biome_forest": _biome_count(Biome.FOREST),
		"biome_wetland": _biome_count(Biome.WETLAND),
		"biome_dry": _biome_count(Biome.DRY),
		"biome_cold": _biome_count(Biome.COLD),
		"cave_systems_started": int(cave_stats.get("cave_systems_started", 0)),
		"cave_branches_spawned": int(cave_stats.get("cave_branches_spawned", 0)),
		"cave_rooms_carved": int(cave_stats.get("cave_rooms_carved", 0)),
		"cave_carved_cells": int(cave_stats.get("cave_carved_cells", 0)),
		"cave_walker_steps": int(cave_stats.get("cave_walker_steps", 0)),
		"cave_brush_calls": int(cave_stats.get("cave_brush_calls", 0)),
		"static_water_enabled": int(terrain_material_stats.get("static_water_enabled", 0)),
		"water_cells_placed": int(terrain_material_stats.get("water_cells_placed", 0)),
		"coal_ore_cells_placed": int(terrain_material_stats.get("coal_ore_cells_placed", 0)),
		"iron_ore_cells_placed": int(terrain_material_stats.get("iron_ore_cells_placed", 0)),
		"flowers_placed": int(vegetation_stats.get("flowers_placed", 0)),
		"water_blocks": water_blocks,
		"flower_blocks": flower_blocks,
		"coal_blocks": coal_blocks,
		"iron_blocks": iron_blocks,
		"moss_blocks": moss_blocks,
	}


func _biome_count(biome_id: int) -> int:
	if biome_id < 0 or biome_id >= biome_counts.size():
		return 0
	return biome_counts[biome_id]


func _bake_chunks(volume: PackedByteArray, chunks: Dictionary) -> void:
	if parallel_generation:
		var region_chunks: Array = []
		region_chunks.resize(_region_count())
		for region_index in range(region_chunks.size()):
			region_chunks[region_index] = {}
		_run_parallel_regions(Callable(self, "_bake_region").bind(volume, region_chunks))
		for region_chunk_map in region_chunks:
			var chunk_map: Dictionary = region_chunk_map
			for coord in chunk_map:
				chunks[coord] = chunk_map[coord]
		return
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


func _bake_region(x0: int, z0: int, x1: int, z1: int, region_index: int, volume: PackedByteArray, region_chunks: Array) -> void:
	var local_chunks: Dictionary = {}
	var min_cx: int = world_min_chunk_x + int(x0 / chunk_size)
	var max_cx: int = world_min_chunk_x + int(ceil(float(x1) / float(chunk_size))) - 1
	var min_cz: int = world_min_chunk_z + int(z0 / chunk_size)
	var max_cz: int = world_min_chunk_z + int(ceil(float(z1) / float(chunk_size))) - 1
	for cy in range(world_chunks_y):
		for cx in range(min_cx, max_cx + 1):
			for cz in range(min_cz, max_cz + 1):
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
				local_chunks[coord] = blocks
	region_chunks[region_index] = local_chunks


func _height_at(wx: int, wz: int) -> int:
	return WorldTerrainHeightSamplerScript.height_at(
		wx,
		wz,
		sea_level,
		world_size_y,
		height_noise_flat,
		height_noise_small,
		height_noise_large,
		height_noise_macro,
		true
	)


func _configure_noises() -> void:
	WorldGenerationSharedScript.configure_height_noises(
		world_seed,
		height_noise_flat,
		height_noise_small,
		height_noise_large,
		height_noise_macro
	)
	WorldGenerationSharedScript.configure_noise(
		moisture_noise,
		WorldGenerationSharedScript.mix_seed(world_seed ^ 0x101),
		MOISTURE_NOISE_FREQUENCY
	)
	WorldGenerationSharedScript.configure_noise(
		temperature_noise,
		WorldGenerationSharedScript.mix_seed(world_seed ^ 0x102),
		TEMPERATURE_NOISE_FREQUENCY
	)
	WorldGenerationSharedScript.configure_noise(
		moisture_detail_noise,
		WorldGenerationSharedScript.mix_seed(world_seed ^ 0x104),
		MOISTURE_DETAIL_NOISE_FREQUENCY
	)


func _normalized_noise_2d(noise: FastNoiseLite, wx: int, wz: int) -> float:
	return clampf((noise.get_noise_2d(float(wx), float(wz)) + 1.0) * 0.5, 0.0, 1.0)


func _world_x(local_x: int) -> int:
	return world_min_block_x + local_x


func _world_z(local_z: int) -> int:
	return world_min_block_z + local_z


func _map_index(local_x: int, local_z: int) -> int:
	return local_z * world_size_x + local_x


func _volume_index(local_x: int, y: int, local_z: int) -> int:
	return (local_z * world_size_y + y) * world_size_x + local_x


func _elapsed_ms(start_usec: int) -> float:
	return float(Time.get_ticks_usec() - start_usec) / 1000.0


func _region_count() -> int:
	var count_x: int = int(ceil(float(world_size_x) / float(generation_region_size)))
	var count_z: int = int(ceil(float(world_size_z) / float(generation_region_size)))
	return count_x * count_z


func _run_parallel_regions(region_callback: Callable) -> void:
	active_regions.clear()
	for z0 in range(0, world_size_z, generation_region_size):
		for x0 in range(0, world_size_x, generation_region_size):
			active_regions.append(Vector4i(x0, z0, mini(x0 + generation_region_size, world_size_x), mini(z0 + generation_region_size, world_size_z)))
	region_mutex.lock()
	region_completed = 0
	region_thread_ids.clear()
	region_mutex.unlock()
	if not parallel_generation or active_regions.size() <= 1 or generation_workers == 1:
		for region_index in range(active_regions.size()):
			_call_region(region_index, region_callback)
		pipeline_metrics["region_thread_count"] = region_thread_ids.size()
		return
	var max_workers: int = generation_workers
	if max_workers <= 0:
		max_workers = maxi(1, OS.get_processor_count() - 1)
	var task_id: int = WorkerThreadPool.add_group_task(
		Callable(self, "_call_region").bind(region_callback),
		active_regions.size(),
		max_workers,
		false,
		"World generation regions"
	)
	WorkerThreadPool.wait_for_group_task_completion(task_id)
	pipeline_metrics["region_thread_count"] = region_thread_ids.size()


func _call_region(region_index: int, region_callback: Callable) -> void:
	var bounds: Vector4i = active_regions[region_index]
	region_callback.call(bounds.x, bounds.y, bounds.z, bounds.w, region_index)
	region_mutex.lock()
	region_thread_ids[OS.get_thread_caller_id()] = true
	if report_region_progress and progress_callback.is_valid():
		region_completed += 1
		var completed := region_completed
		var total := active_regions.size()
		region_mutex.unlock()
		progress_callback.call({
			"pass_name": str(pipeline_metrics.get("active_pass", "")),
			"pass_completed": int(pipeline_metrics.get("pass_count", 0)),
			"pass_total": PASS_NAMES.size(),
			"state": "regions",
			"regions_completed": completed,
			"regions_total": total,
		})
	else:
		region_mutex.unlock()
