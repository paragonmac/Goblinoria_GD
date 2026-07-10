extends SceneTree

const PipelineScript = preload("res://scripts/world_generation_pipeline.gd")

const FIXTURE_PATH := "res://tools/fixtures/world_generation_contract.json"
const HASH_OFFSET := 2166136261
const HASH_PRIME := 16777619
const HASH_MASK := 0xffffffff
const FLOAT_SCALE := 1000000.0

const EXPECTED_PASS_NAMES := [
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

const CASES := [
	{
		"name": "centered_32x64x32_seed_12345",
		"expect_caves": true,
		"config": {
			"world_seed": 12345,
			"sea_level": 40,
			"world_size_y": 64,
			"chunk_size": 8,
			"world_chunks_x": 4,
			"world_chunks_y": 8,
			"world_chunks_z": 4,
			"world_min_chunk_x": -2,
			"world_max_chunk_x": 1,
			"world_min_chunk_z": -2,
			"world_max_chunk_z": 1,
		},
	},
	{
		"name": "edge_16x24x16_seed_98765",
		"expect_caves": false,
		"config": {
			"world_seed": 98765,
			"sea_level": 12,
			"world_size_y": 24,
			"chunk_size": 8,
			"world_chunks_x": 2,
			"world_chunks_y": 3,
			"world_chunks_z": 2,
			"world_min_chunk_x": -1,
			"world_max_chunk_x": 0,
			"world_min_chunk_z": -1,
			"world_max_chunk_z": 0,
		},
	},
]


func _init() -> void:
	var exit_code := _run()
	quit(exit_code)


func _run() -> int:
	var update_fixture := _has_arg("--update")
	var errors: Array = []
	var report := _build_report(errors)
	if not errors.is_empty():
		_print_errors(errors)
		return 1
	var actual_text := _stable_json(report) + "\n"
	if update_fixture:
		return _write_fixture(actual_text)
	return _compare_fixture(actual_text)


func _build_report(errors: Array) -> Dictionary:
	var report := {
		"schema": 1,
		"cases": [],
	}
	for case_def in CASES:
		var first_progress: Array = []
		var first_result: Dictionary = _generate_case(case_def, first_progress)
		var first_summary: Dictionary = _summarize_case(case_def, first_result, first_progress)
		var second_progress: Array = []
		var second_result: Dictionary = _generate_case(case_def, second_progress)
		var second_summary: Dictionary = _summarize_case(case_def, second_result, second_progress)
		_validate_summary(case_def, first_summary, errors)
		if _stable_json(first_summary) != _stable_json(second_summary):
			errors.append("%s: generation output is not deterministic across two runs" % case_def["name"])
		report["cases"].append({
			"name": case_def["name"],
			"summary": first_summary,
		})
	return report


func _generate_case(case_def: Dictionary, progress_rows: Array) -> Dictionary:
	var pipeline = PipelineScript.new()
	var config: Dictionary = case_def["config"].duplicate(true)
	config["progress_callback"] = Callable(self, "_record_progress").bind(progress_rows)
	return pipeline.generate(config)


func _record_progress(row: Dictionary, progress_rows: Array) -> void:
	progress_rows.append(row.duplicate(true))


func _summarize_case(case_def: Dictionary, result: Dictionary, progress_rows: Array) -> Dictionary:
	var config: Dictionary = case_def["config"]
	var chunks: Dictionary = result.get("chunks", {})
	var maps: Dictionary = result.get("maps", {})
	var metrics: Dictionary = result.get("metrics", {})
	var generation_stats: Dictionary = metrics.get("generation_stats", {})
	return {
		"config": _summary_config(config),
		"passes": _summarize_passes(metrics),
		"progress": _summarize_progress(progress_rows),
		"generation_stats": generation_stats.duplicate(true),
		"maps": _summarize_maps(maps),
		"chunks": _summarize_chunks(chunks, int(config["chunk_size"])),
	}


func _summary_config(config: Dictionary) -> Dictionary:
	return {
		"world_seed": int(config["world_seed"]),
		"sea_level": int(config["sea_level"]),
		"world_size_y": int(config["world_size_y"]),
		"chunk_size": int(config["chunk_size"]),
		"world_chunks_x": int(config["world_chunks_x"]),
		"world_chunks_y": int(config["world_chunks_y"]),
		"world_chunks_z": int(config["world_chunks_z"]),
		"world_min_chunk_x": int(config["world_min_chunk_x"]),
		"world_max_chunk_x": int(config["world_max_chunk_x"]),
		"world_min_chunk_z": int(config["world_min_chunk_z"]),
		"world_max_chunk_z": int(config["world_max_chunk_z"]),
	}


func _summarize_passes(metrics: Dictionary) -> Dictionary:
	var pass_names: Array = []
	var pass_entries: Array = metrics.get("passes", [])
	for pass_entry in pass_entries:
		if typeof(pass_entry) == TYPE_DICTIONARY:
			pass_names.append(str(pass_entry.get("name", "")))
	return {
		"pass_count": int(metrics.get("pass_count", 0)),
		"pass_total": int(metrics.get("pass_total", 0)),
		"pass_names": pass_names,
	}


func _summarize_progress(progress_rows: Array) -> Dictionary:
	var sequence: Array = []
	var running_count := 0
	var done_count := 0
	var stats_row_count := 0
	var final_stats := {}
	for row in progress_rows:
		var state := str(row.get("state", ""))
		if state == "running":
			running_count += 1
		elif state == "done":
			done_count += 1
		var stats_value = row.get("generation_stats", {})
		if typeof(stats_value) == TYPE_DICTIONARY and not stats_value.is_empty():
			stats_row_count += 1
			final_stats = stats_value.duplicate(true)
		sequence.append("%s:%s:%d/%d" % [
			state,
			str(row.get("pass_name", "")),
			int(row.get("pass_completed", 0)),
			int(row.get("pass_total", 0)),
		])
	return {
		"row_count": progress_rows.size(),
		"running_count": running_count,
		"done_count": done_count,
		"stats_row_count": stats_row_count,
		"final_generation_stats": final_stats,
		"sequence": sequence,
	}


func _summarize_maps(maps: Dictionary) -> Dictionary:
	return {
		"elevation": _summarize_int_array(maps.get("elevation", PackedInt32Array())),
		"moisture": _summarize_float_array(maps.get("moisture", PackedFloat32Array())),
		"temperature": _summarize_float_array(maps.get("temperature", PackedFloat32Array())),
		"biome": _summarize_byte_array(maps.get("biome", PackedByteArray())),
		"soil_region": _summarize_byte_array(maps.get("soil_region", PackedByteArray())),
		"feature_reserved": _summarize_byte_array(maps.get("feature_reserved", PackedByteArray())),
	}


func _summarize_chunks(chunks: Dictionary, chunk_size: int) -> Dictionary:
	var coords := chunks.keys()
	coords.sort_custom(Callable(self, "_coord_less"))
	var block_counts := {}
	var samples: Array = []
	var sample_indices := _sample_indices(coords.size())
	var coord_hash := HASH_OFFSET
	var block_hash := HASH_OFFSET
	for coord in coords:
		coord_hash = _hash_vector3i(coord_hash, coord)
		block_hash = _hash_vector3i(block_hash, coord)
		var blocks: PackedByteArray = chunks[coord]
		block_hash = _hash_int(block_hash, blocks.size())
		for block_id in blocks:
			var key := str(int(block_id))
			block_counts[key] = int(block_counts.get(key, 0)) + 1
			block_hash = _hash_byte(block_hash, int(block_id))
	for sample_index in sample_indices:
		var coord: Vector3i = coords[sample_index]
		var blocks: PackedByteArray = chunks[coord]
		samples.append({
			"coord": _coord_key(coord),
			"hash": _hash_packed_byte_array(blocks),
		})
	return {
		"count": chunks.size(),
		"volume": chunk_size * chunk_size * chunk_size,
		"coord_hash": coord_hash,
		"block_hash": block_hash,
		"block_counts": block_counts,
		"samples": samples,
	}


func _sample_indices(count: int) -> Array:
	var indices: Array = []
	if count <= 0:
		return indices
	for index in [0, count / 2, count - 1]:
		var sample_index := int(index)
		if not indices.has(sample_index):
			indices.append(sample_index)
	return indices


func _summarize_int_array(values: PackedInt32Array) -> Dictionary:
	var hash := HASH_OFFSET
	var min_value := 0
	var max_value := 0
	var sum := 0
	for i in range(values.size()):
		var value := int(values[i])
		if i == 0 or value < min_value:
			min_value = value
		if i == 0 or value > max_value:
			max_value = value
		sum += value
		hash = _hash_int(hash, value)
	return {
		"size": values.size(),
		"hash": hash,
		"min": min_value,
		"max": max_value,
		"sum": sum,
	}


func _summarize_float_array(values: PackedFloat32Array) -> Dictionary:
	var hash := HASH_OFFSET
	var min_value := 0
	var max_value := 0
	var sum := 0
	for i in range(values.size()):
		var value := _float_to_int(values[i])
		if i == 0 or value < min_value:
			min_value = value
		if i == 0 or value > max_value:
			max_value = value
		sum += value
		hash = _hash_int(hash, value)
	return {
		"size": values.size(),
		"hash": hash,
		"min_scaled": min_value,
		"max_scaled": max_value,
		"sum_scaled": sum,
	}


func _summarize_byte_array(values: PackedByteArray) -> Dictionary:
	var hash := HASH_OFFSET
	var min_value := 0
	var max_value := 0
	var sum := 0
	for i in range(values.size()):
		var value := int(values[i])
		if i == 0 or value < min_value:
			min_value = value
		if i == 0 or value > max_value:
			max_value = value
		sum += value
		hash = _hash_byte(hash, value)
	return {
		"size": values.size(),
		"hash": hash,
		"min": min_value,
		"max": max_value,
		"sum": sum,
	}


func _validate_summary(case_def: Dictionary, summary: Dictionary, errors: Array) -> void:
	var name := str(case_def["name"])
	var config: Dictionary = case_def["config"]
	var passes: Dictionary = summary["passes"]
	var progress: Dictionary = summary["progress"]
	var stats: Dictionary = summary["generation_stats"]
	var maps: Dictionary = summary["maps"]
	var chunks: Dictionary = summary["chunks"]
	var expected_map_size: int = int(config["world_chunks_x"]) * int(config["chunk_size"]) * int(config["world_chunks_z"]) * int(config["chunk_size"])
	var expected_chunk_count: int = int(config["world_chunks_x"]) * int(config["world_chunks_y"]) * int(config["world_chunks_z"])
	var expected_chunk_volume: int = int(config["chunk_size"]) * int(config["chunk_size"]) * int(config["chunk_size"])
	if passes["pass_names"] != EXPECTED_PASS_NAMES:
		errors.append("%s: pass names changed" % name)
	if int(passes["pass_count"]) != EXPECTED_PASS_NAMES.size() or int(passes["pass_total"]) != EXPECTED_PASS_NAMES.size():
		errors.append("%s: pass count does not match expected pass list" % name)
	if int(progress["row_count"]) != EXPECTED_PASS_NAMES.size() * 2:
		errors.append("%s: progress row count changed" % name)
	if int(progress["running_count"]) != EXPECTED_PASS_NAMES.size() or int(progress["done_count"]) != EXPECTED_PASS_NAMES.size():
		errors.append("%s: progress running/done counts changed" % name)
	if progress["sequence"] != _expected_progress_sequence():
		errors.append("%s: progress sequence changed" % name)
	if int(progress["stats_row_count"]) != 3:
		errors.append("%s: generation stats should appear on collect done and bake progress rows" % name)
	if _stable_json(progress["final_generation_stats"]) != _stable_json(stats):
		errors.append("%s: final progress stats do not match metrics stats" % name)
	for map_name in maps.keys():
		if int(maps[map_name].get("size", 0)) != expected_map_size:
			errors.append("%s: %s map size changed" % [name, map_name])
	if int(chunks["count"]) != expected_chunk_count:
		errors.append("%s: chunk count changed" % name)
	if int(chunks["volume"]) != expected_chunk_volume:
		errors.append("%s: chunk volume changed" % name)
	_validate_generation_stats(name, case_def, stats, chunks["block_counts"], expected_map_size, errors)


func _validate_generation_stats(name: String, case_def: Dictionary, stats: Dictionary, block_counts: Dictionary, expected_map_size: int, errors: Array) -> void:
	var biome_total := int(stats.get("biome_plains", 0)) \
		+ int(stats.get("biome_forest", 0)) \
		+ int(stats.get("biome_wetland", 0)) \
		+ int(stats.get("biome_dry", 0)) \
		+ int(stats.get("biome_cold", 0))
	if biome_total != expected_map_size:
		errors.append("%s: biome stat total does not match map size" % name)
	_assert_stat_matches_block_count(name, stats, block_counts, "water_blocks", World.BLOCK_ID_WATER, errors)
	_assert_stat_matches_block_count(name, stats, block_counts, "flower_blocks", World.BLOCK_ID_FLOWER, errors)
	_assert_stat_matches_block_count(name, stats, block_counts, "coal_blocks", World.BLOCK_ID_COAL, errors)
	_assert_stat_matches_block_count(name, stats, block_counts, "iron_blocks", World.BLOCK_ID_IRON_ORE, errors)
	_assert_stat_matches_block_count(name, stats, block_counts, "moss_blocks", World.BLOCK_ID_MOSS, errors)
	if int(block_counts.get(str(World.BLOCK_ID_LOG), 0)) != 0:
		errors.append("%s: generation should not emit log blocks" % name)
	if int(block_counts.get(str(World.BLOCK_ID_LEAVES), 0)) != 0:
		errors.append("%s: generation should not emit leaf blocks" % name)
	if int(stats.get("static_water_enabled", -1)) != 0:
		errors.append("%s: static underground water is no longer disabled" % name)
	if int(stats.get("water_cells_placed", -1)) != 0 or int(stats.get("water_blocks", -1)) != 0:
		errors.append("%s: water output changed while static underground water is disabled" % name)
	if bool(case_def.get("expect_caves", false)):
		if int(stats.get("cave_systems_started", 0)) <= 0:
			errors.append("%s: expected cave systems to start" % name)
		if int(stats.get("cave_walker_steps", 0)) <= 0 or int(stats.get("cave_carved_cells", 0)) <= 0:
			errors.append("%s: expected cave walker output" % name)
	else:
		if int(stats.get("cave_carved_cells", 0)) != 0:
			errors.append("%s: edge case should not carve caves" % name)
	if int(stats.get("cave_brush_calls", 0)) < int(stats.get("cave_walker_steps", 0)):
		errors.append("%s: cave brush calls should cover walker steps" % name)


func _assert_stat_matches_block_count(name: String, stats: Dictionary, block_counts: Dictionary, stat_name: String, block_id: int, errors: Array) -> void:
	var stat_value := int(stats.get(stat_name, 0))
	var count_value := int(block_counts.get(str(block_id), 0))
	if stat_value != count_value:
		errors.append("%s: %s=%d but block %d count=%d" % [name, stat_name, stat_value, block_id, count_value])


func _expected_progress_sequence() -> Array:
	var sequence: Array = []
	var total := EXPECTED_PASS_NAMES.size()
	for i in range(total):
		var pass_name := str(EXPECTED_PASS_NAMES[i])
		sequence.append("running:%s:%d/%d" % [pass_name, i, total])
		sequence.append("done:%s:%d/%d" % [pass_name, i + 1, total])
	return sequence


func _compare_fixture(actual_text: String) -> int:
	if not FileAccess.file_exists(FIXTURE_PATH):
		push_error("Missing fixture: %s. Run with --update to create it." % FIXTURE_PATH)
		return 1
	var file := FileAccess.open(FIXTURE_PATH, FileAccess.READ)
	if file == null:
		push_error("Could not read fixture: %s" % FIXTURE_PATH)
		return 1
	var expected_text := file.get_as_text()
	var parsed = JSON.parse_string(expected_text)
	if parsed == null:
		push_error("Fixture is not valid JSON: %s" % FIXTURE_PATH)
		return 1
	var actual_parsed = JSON.parse_string(actual_text)
	if actual_parsed == null:
		push_error("Actual generation contract report did not produce valid JSON")
		return 1
	var normalized_expected := _stable_json(parsed) + "\n"
	var normalized_actual := _stable_json(actual_parsed) + "\n"
	if normalized_actual == normalized_expected:
		print("Generation contract OK: %d cases matched %s" % [CASES.size(), FIXTURE_PATH])
		return 0
	push_error("Generation contract changed: %s" % FIXTURE_PATH)
	_print_mismatch(normalized_expected, normalized_actual)
	return 1


func _write_fixture(actual_text: String) -> int:
	var absolute_dir := ProjectSettings.globalize_path("res://tools/fixtures")
	var dir_status := DirAccess.make_dir_recursive_absolute(absolute_dir)
	if dir_status != OK:
		push_error("Could not create fixture directory: %s" % absolute_dir)
		return 1
	var file := FileAccess.open(FIXTURE_PATH, FileAccess.WRITE)
	if file == null:
		push_error("Could not write fixture: %s" % FIXTURE_PATH)
		return 1
	file.store_string(actual_text)
	print("Updated generation contract fixture: %s" % FIXTURE_PATH)
	return 0


func _print_mismatch(expected_text: String, actual_text: String) -> void:
	var limit := mini(expected_text.length(), actual_text.length())
	var index := 0
	while index < limit and expected_text[index] == actual_text[index]:
		index += 1
	var start := maxi(0, index - 120)
	var expected_end := mini(expected_text.length(), index + 240)
	var actual_end := mini(actual_text.length(), index + 240)
	print("First mismatch at byte %d" % index)
	print("Expected:")
	print(expected_text.substr(start, expected_end - start))
	print("Actual:")
	print(actual_text.substr(start, actual_end - start))


func _print_errors(errors: Array) -> void:
	for error in errors:
		push_error(str(error))


func _has_arg(flag: String) -> bool:
	return OS.get_cmdline_args().has(flag) or OS.get_cmdline_user_args().has(flag)


func _stable_json(value: Variant) -> String:
	return JSON.stringify(value, "\t", true, false)


func _coord_less(a: Vector3i, b: Vector3i) -> bool:
	if a.x != b.x:
		return a.x < b.x
	if a.y != b.y:
		return a.y < b.y
	return a.z < b.z


func _coord_key(coord: Vector3i) -> String:
	return "%d,%d,%d" % [coord.x, coord.y, coord.z]


func _hash_packed_byte_array(values: PackedByteArray) -> int:
	var hash := HASH_OFFSET
	hash = _hash_int(hash, values.size())
	for value in values:
		hash = _hash_byte(hash, int(value))
	return hash


func _hash_vector3i(hash: int, coord: Vector3i) -> int:
	hash = _hash_int(hash, coord.x)
	hash = _hash_int(hash, coord.y)
	hash = _hash_int(hash, coord.z)
	return hash


func _hash_int(hash: int, value: int) -> int:
	var unsigned_value := value & HASH_MASK
	hash = _hash_byte(hash, unsigned_value)
	hash = _hash_byte(hash, unsigned_value >> 8)
	hash = _hash_byte(hash, unsigned_value >> 16)
	hash = _hash_byte(hash, unsigned_value >> 24)
	return hash


func _hash_byte(hash: int, value: int) -> int:
	hash = hash ^ (value & 0xff)
	return int((hash * HASH_PRIME) & HASH_MASK)


func _float_to_int(value: float) -> int:
	return int(round(value * FLOAT_SCALE))
