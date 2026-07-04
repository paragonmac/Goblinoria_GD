extends RefCounted
class_name WorldArenaCooker

const WorldGeneratorScript = preload("res://scripts/world_generator.gd")
const ChunkMesherScript = preload("res://scripts/rendering/chunk_mesher.gd")
const WorldRendererMeshCacheScript = preload("res://scripts/rendering/world_renderer_mesh_cache.gd")
const DiagnosticsCsvWriterScript = preload("res://scripts/diagnostics/csv_writer.gd")
const WorldChunkSpaceScript = preload("res://scripts/world/world_chunk_space.gd")

const PROGRESS_UPDATE_INTERVAL := 16
const DIAGNOSTIC_DIR := "user://diagnostics"
const DIAGNOSTIC_PREFIX := "arena_world_cook_"

enum Stage {
	IDLE,
	GENERATING,
	MERGING_BLOCKS,
	MESHING,
	MERGING_MESHES,
	DONE,
	FAILED,
}

var world: World
var mesh_cache_helper = WorldRendererMeshCacheScript.new()
var stage: int = Stage.IDLE
var worker_count: int = 1
var coords: Array[Vector3i] = []
var arena_blocks: Dictionary = {}
var generation_task_ids: Array[int] = []
var mesh_task_ids: Array[int] = []
var generation_results: Array = []
var mesh_results: Array = []
var worker_progress: Array[int] = []
var worker_totals: Array[int] = []
var worker_generation_ms: Array[float] = []
var worker_mesh_ms: Array[float] = []
var progress_mutex := Mutex.new()
var result_mutex := Mutex.new()
var generation_tasks_waited: bool = false
var mesh_tasks_waited: bool = false
var merge_worker_index: int = 0
var merge_keys: Array = []
var merge_key_index: int = 0
var cook_start_usec: int = 0
var generation_start_usec: int = 0
var mesh_start_usec: int = 0
var merge_blocks_start_usec: int = 0
var merge_meshes_start_usec: int = 0
var generation_wall_ms: float = 0.0
var mesh_wall_ms: float = 0.0
var merge_blocks_ms: float = 0.0
var merge_meshes_ms: float = 0.0
var save_ms: float = 0.0
var chunks_generated: int = 0
var meshes_built: int = 0
var empty_meshes: int = 0
var meshes_merged: int = 0
var diagnostic_path: String = ""
var cook_world_seed: int = 0
var cook_sea_level: int = 0
var cook_world_size_y: int = 0
var generation_mode: String = ""
var pipeline_metrics: Dictionary = {}
var pipeline_progress: Dictionary = {}


func _init(world_ref: World) -> void:
	world = world_ref


func start_generation() -> void:
	_reset_state()
	coords = _build_all_world_chunk_targets()
	worker_count = 1
	cook_world_seed = world.world_seed
	cook_sea_level = world.sea_level
	cook_world_size_y = world.world_size_y
	cook_start_usec = Time.get_ticks_usec()
	generation_start_usec = cook_start_usec
	stage = Stage.GENERATING
	generation_mode = "layered_pipeline"
	_start_worker_arrays(worker_count)
	var task_id: int = WorkerThreadPool.add_task(
		Callable(self, "_run_layered_generation_worker").bind(0),
		false,
		"Arena layered world generation"
	)
	generation_task_ids.append(task_id)


func is_generation_done() -> bool:
	if stage != Stage.GENERATING:
		return stage > Stage.GENERATING
	if not _all_tasks_completed(generation_task_ids):
		return false
	if not generation_tasks_waited:
		_wait_for_tasks(generation_task_ids)
		generation_tasks_waited = true
		generation_wall_ms = _elapsed_ms(generation_start_usec)
		stage = Stage.MERGING_BLOCKS
		merge_blocks_start_usec = Time.get_ticks_usec()
		_reset_merge_cursor()
	return true


func merge_generation_results_step(max_chunks: int) -> int:
	if stage != Stage.MERGING_BLOCKS:
		return 0
	var merged: int = 0
	while merged < max_chunks and merge_worker_index < generation_results.size():
		var result: Dictionary = _current_merge_result(generation_results)
		if result.is_empty():
			merge_worker_index += 1
			_reset_merge_cursor_for_next_worker()
			continue
		var blocks_by_coord: Dictionary = result.get("blocks", {})
		if merge_keys.is_empty():
			merge_keys = blocks_by_coord.keys()
			merge_key_index = 0
		while merged < max_chunks and merge_key_index < merge_keys.size():
			var coord: Vector3i = merge_keys[merge_key_index]
			merge_key_index += 1
			var blocks_value = blocks_by_coord.get(coord, PackedByteArray())
			if typeof(blocks_value) != TYPE_PACKED_BYTE_ARRAY:
				continue
			var blocks: PackedByteArray = PackedByteArray(blocks_value)
			if blocks.size() != World.CHUNK_VOLUME:
				continue
			arena_blocks[coord] = blocks
			var chunk: ChunkData = world.ensure_chunk(coord)
			if chunk == null:
				continue
			chunk.blocks = blocks.duplicate()
			chunk.generated = true
			chunk.dirty = false
			chunk.mesh_state = ChunkData.MESH_STATE_NONE
			world.touch_chunk(chunk)
			merged += 1
			chunks_generated += 1
		if merge_key_index >= merge_keys.size():
			merge_worker_index += 1
			_reset_merge_cursor_for_next_worker()
	if merge_worker_index >= generation_results.size():
		merge_blocks_ms = _elapsed_ms(merge_blocks_start_usec)
	return merged


func is_generation_merge_done() -> bool:
	return stage == Stage.MERGING_BLOCKS and merge_worker_index >= generation_results.size()


func start_mesh() -> void:
	if stage != Stage.MERGING_BLOCKS:
		return
	stage = Stage.MESHING
	worker_count = _resolve_worker_count(coords.size())
	mesh_start_usec = Time.get_ticks_usec()
	mesh_task_ids.clear()
	mesh_results.clear()
	mesh_results.resize(worker_count)
	mesh_tasks_waited = false
	_reset_progress_arrays(worker_count, false, true)
	var table_snapshot: Dictionary = world.renderer.get_mesher_table_snapshot()
	var slices: Array = _split_coords(coords, worker_count)
	for worker_index in range(worker_count):
		var task_id: int = WorkerThreadPool.add_task(
			Callable(self, "_run_mesh_worker").bind(worker_index, slices[worker_index], table_snapshot),
			false,
			"Arena mesh cache cook %d" % worker_index
		)
		mesh_task_ids.append(task_id)


func is_mesh_done() -> bool:
	if stage != Stage.MESHING:
		return stage > Stage.MESHING
	if not _all_tasks_completed(mesh_task_ids):
		return false
	if not mesh_tasks_waited:
		_wait_for_tasks(mesh_task_ids)
		mesh_tasks_waited = true
		mesh_wall_ms = _elapsed_ms(mesh_start_usec)
		stage = Stage.MERGING_MESHES
		merge_meshes_start_usec = Time.get_ticks_usec()
		_reset_merge_cursor()
	return true


func merge_mesh_results_step(max_chunks: int) -> int:
	if stage != Stage.MERGING_MESHES:
		return 0
	var merged: int = 0
	while merged < max_chunks and merge_worker_index < mesh_results.size():
		var result: Dictionary = _current_merge_result(mesh_results)
		if result.is_empty():
			merge_worker_index += 1
			_reset_merge_cursor_for_next_worker()
			continue
		var entries_by_coord: Dictionary = result.get("mesh_entries", {})
		if merge_keys.is_empty():
			merge_keys = entries_by_coord.keys()
			merge_key_index = 0
		while merged < max_chunks and merge_key_index < merge_keys.size():
			var coord: Vector3i = merge_keys[merge_key_index]
			merge_key_index += 1
			var entry_value = entries_by_coord.get(coord, {})
			if typeof(entry_value) != TYPE_DICTIONARY:
				continue
			var entry: Dictionary = entry_value
			if world.renderer.import_persistent_mesh_cache_entry(coord, entry):
				meshes_merged += 1
			merged += 1
		if merge_key_index >= merge_keys.size():
			merge_worker_index += 1
			_reset_merge_cursor_for_next_worker()
	if merge_worker_index >= mesh_results.size():
		merge_meshes_ms = _elapsed_ms(merge_meshes_start_usec)
		stage = Stage.DONE
	return merged


func is_done() -> bool:
	return stage == Stage.DONE


func set_save_ms(value: float) -> void:
	save_ms = value


func get_progress() -> Dictionary:
	progress_mutex.lock()
	var done: int = 0
	var total: int = 0
	for value in worker_progress:
		done += int(value)
	for value in worker_totals:
		total += int(value)
	var pass_name: String = str(pipeline_progress.get("pass_name", ""))
	var pass_completed: int = int(pipeline_progress.get("pass_completed", 0))
	var pass_total: int = int(pipeline_progress.get("pass_total", 0))
	var pass_state: String = str(pipeline_progress.get("state", ""))
	var generation_stats: Dictionary = {}
	var stats_value = pipeline_progress.get("generation_stats", {})
	if typeof(stats_value) != TYPE_DICTIONARY:
		stats_value = pipeline_metrics.get("generation_stats", {})
	if typeof(stats_value) == TYPE_DICTIONARY:
		generation_stats = stats_value.duplicate(true)
	progress_mutex.unlock()
	return {
		"stage": stage,
		"done": done,
		"total": total,
		"workers": worker_count,
		"chunks_generated": chunks_generated,
		"meshes_built": meshes_built,
		"meshes_merged": meshes_merged,
		"pipeline_pass_name": pass_name,
		"pipeline_pass_completed": pass_completed,
		"pipeline_pass_total": pass_total,
		"pipeline_pass_state": pass_state,
		"generation_stats": generation_stats,
	}


func get_diagnostics() -> Dictionary:
	var total_ms: float = _elapsed_ms(cook_start_usec) if cook_start_usec > 0 else 0.0
	var generation_worker_total: float = 0.0
	for value in worker_generation_ms:
		generation_worker_total += float(value)
	var mesh_worker_total: float = 0.0
	for value in worker_mesh_ms:
		mesh_worker_total += float(value)
	return {
		"worker_count": worker_count,
		"chunks_total": coords.size(),
		"chunks_generated": chunks_generated,
		"meshes_built": meshes_built,
		"empty_meshes": empty_meshes,
		"meshes_merged": meshes_merged,
		"total_ms": total_ms,
		"generation_wall_ms": generation_wall_ms,
		"generation_worker_ms": generation_worker_total,
		"mesh_wall_ms": mesh_wall_ms,
		"mesh_worker_ms": mesh_worker_total,
		"merge_blocks_ms": merge_blocks_ms,
		"merge_meshes_ms": merge_meshes_ms,
		"save_ms": save_ms,
		"generation_mode": generation_mode,
		"pipeline_total_ms": float(pipeline_metrics.get("total_ms", 0.0)),
		"pipeline_pass_count": int(pipeline_metrics.get("pass_count", 0)),
		"generation_stat_count": _generation_stat_count(),
		"diagnostic_path": diagnostic_path,
	}


func write_diagnostics() -> String:
	if not DiagnosticsCsvWriterScript.ensure_dir(DIAGNOSTIC_DIR):
		push_warning("Arena cook diagnostics skipped: cannot create diagnostics dir")
		return ""
	var timestamp: String = Time.get_datetime_string_from_system(false, true).replace(":", "-")
	var path: String = DIAGNOSTIC_DIR.path_join("%s%s.csv" % [DIAGNOSTIC_PREFIX, timestamp])
	var file: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		push_warning("Arena cook diagnostics skipped: cannot open %s" % path)
		return ""
	file.store_line(DiagnosticsCsvWriterScript.row_from_values(["metric", "value"]))
	var metrics: Dictionary = get_diagnostics()
	for key in metrics.keys():
		if key == "diagnostic_path":
			continue
		file.store_line(DiagnosticsCsvWriterScript.row_from_values([key, metrics[key]]))
	var generation_stats: Dictionary = _generation_stats_snapshot()
	for stat_key in generation_stats.keys():
		var stat_metric := "generation_stat_%s" % [str(stat_key)]
		file.store_line(DiagnosticsCsvWriterScript.row_from_values([stat_metric, generation_stats[stat_key]]))
	var pass_entries: Array = pipeline_metrics.get("passes", [])
	for pass_index in range(pass_entries.size()):
		var pass_value = pass_entries[pass_index]
		if typeof(pass_value) == TYPE_DICTIONARY:
			var pass_entry: Dictionary = pass_value
			var pass_metric := "pipeline_pass_%d_%s_ms" % [pass_index, str(pass_entry.get("name", "unknown"))]
			file.store_line(DiagnosticsCsvWriterScript.row_from_values([pass_metric, pass_entry.get("ms", 0.0)]))
	for i in range(worker_count):
		var generation_metric := "worker_%d_generation_ms" % [i]
		var mesh_metric := "worker_%d_mesh_ms" % [i]
		var chunks_metric := "worker_%d_chunks" % [i]
		file.store_line(DiagnosticsCsvWriterScript.row_from_values([generation_metric, _worker_float(worker_generation_ms, i)]))
		file.store_line(DiagnosticsCsvWriterScript.row_from_values([mesh_metric, _worker_float(worker_mesh_ms, i)]))
		file.store_line(DiagnosticsCsvWriterScript.row_from_values([chunks_metric, _worker_int(worker_totals, i)]))
	file.flush()
	diagnostic_path = ProjectSettings.globalize_path(path)
	print("Arena world cook diagnostics: %s" % diagnostic_path)
	return diagnostic_path

func _generation_stats_snapshot() -> Dictionary:
	var stats_value = pipeline_metrics.get("generation_stats", {})
	if typeof(stats_value) == TYPE_DICTIONARY:
		return stats_value.duplicate()
	return {}


func _generation_stat_count() -> int:
	return _generation_stats_snapshot().size()


func _worker_float(values: Array, index: int) -> float:
	if index < 0 or index >= values.size():
		return 0.0
	return float(values[index])


func _worker_int(values: Array, index: int) -> int:
	if index < 0 or index >= values.size():
		return 0
	return int(values[index])

func _reset_state() -> void:
	stage = Stage.IDLE
	worker_count = 1
	coords.clear()
	arena_blocks.clear()
	generation_task_ids.clear()
	mesh_task_ids.clear()
	generation_results.clear()
	mesh_results.clear()
	worker_progress.clear()
	worker_totals.clear()
	worker_generation_ms.clear()
	worker_mesh_ms.clear()
	generation_tasks_waited = false
	mesh_tasks_waited = false
	_reset_merge_cursor()
	cook_start_usec = 0
	generation_start_usec = 0
	mesh_start_usec = 0
	merge_blocks_start_usec = 0
	merge_meshes_start_usec = 0
	generation_wall_ms = 0.0
	mesh_wall_ms = 0.0
	merge_blocks_ms = 0.0
	merge_meshes_ms = 0.0
	save_ms = 0.0
	chunks_generated = 0
	meshes_built = 0
	empty_meshes = 0
	meshes_merged = 0
	diagnostic_path = ""
	generation_mode = ""
	pipeline_metrics.clear()
	pipeline_progress.clear()


func _start_worker_arrays(count: int) -> void:
	generation_results.resize(count)
	mesh_results.resize(count)
	_reset_progress_arrays(count)


func _reset_progress_arrays(count: int, reset_generation_ms: bool = true, reset_mesh_ms: bool = true) -> void:
	progress_mutex.lock()
	worker_progress.clear()
	worker_totals.clear()
	if reset_generation_ms:
		worker_generation_ms.clear()
	if reset_mesh_ms:
		worker_mesh_ms.clear()
	for _i in range(count):
		worker_progress.append(0)
		worker_totals.append(0)
		if reset_generation_ms:
			worker_generation_ms.append(0.0)
		if reset_mesh_ms:
			worker_mesh_ms.append(0.0)
	while worker_generation_ms.size() < count:
		worker_generation_ms.append(0.0)
	while worker_mesh_ms.size() < count:
		worker_mesh_ms.append(0.0)
	progress_mutex.unlock()


func _reset_merge_cursor() -> void:
	merge_worker_index = 0
	merge_keys.clear()
	merge_key_index = 0


func _reset_merge_cursor_for_next_worker() -> void:
	merge_keys.clear()
	merge_key_index = 0


func _resolve_worker_count(total_chunks: int) -> int:
	if total_chunks <= 0:
		return 1
	var cores: int = OS.get_processor_count()
	return clampi(maxi(1, cores - 1), 1, total_chunks)


func _split_coords(source: Array[Vector3i], count: int) -> Array:
	var slices: Array = []
	for _i in range(count):
		slices.append([])
	for i in range(source.size()):
		slices[i % count].append(source[i])
	return slices


func _build_all_world_chunk_targets() -> Array[Vector3i]:
	return WorldChunkSpaceScript.all_world_chunk_targets()


func _run_layered_generation_worker(worker_index: int) -> void:
	var start_usec: int = Time.get_ticks_usec()
	_set_worker_total(worker_index, coords.size())
	var generator: WorldGenerator = WorldGeneratorScript.new(null)
	var config: Dictionary = generator.build_layered_world_config(cook_world_seed, cook_sea_level, cook_world_size_y)
	config["progress_callback"] = Callable(self, "_record_pipeline_progress")
	var result: Dictionary = generator.generate_layered_world(config)
	var blocks_by_coord: Dictionary = result.get("chunks", {})
	_set_worker_progress(worker_index, blocks_by_coord.size())
	var elapsed: float = _elapsed_ms(start_usec)
	_store_generation_result(worker_index, {
		"blocks": blocks_by_coord,
		"chunks": blocks_by_coord.size(),
		"generation_ms": elapsed,
		"pipeline_metrics": result.get("metrics", {}),
	})


func _record_pipeline_progress(row: Dictionary) -> void:
	var pass_completed: int = int(row.get("pass_completed", 0))
	var pass_total: int = maxi(int(row.get("pass_total", 1)), 1)
	var total_chunks: int = coords.size()
	var chunk_equivalent_progress: int = clampi(int(round(float(total_chunks) * float(pass_completed) / float(pass_total))), 0, total_chunks)
	progress_mutex.lock()
	pipeline_progress = row.duplicate(true)
	if worker_totals.size() > 0:
		worker_totals[0] = total_chunks
	if worker_progress.size() > 0:
		worker_progress[0] = chunk_equivalent_progress
	progress_mutex.unlock()


func _run_generation_worker(worker_index: int, worker_coords: Array) -> void:
	var start_usec: int = Time.get_ticks_usec()
	var generator: WorldGenerator = WorldGeneratorScript.new(null)
	var flat_noise: FastNoiseLite = FastNoiseLite.new()
	var small_noise: FastNoiseLite = FastNoiseLite.new()
	var large_noise: FastNoiseLite = FastNoiseLite.new()
	var macro_noise: FastNoiseLite = FastNoiseLite.new()
	generator._configure_height_noises(cook_world_seed, flat_noise, small_noise, large_noise, macro_noise)
	var blocks_by_coord: Dictionary = {}
	_set_worker_total(worker_index, worker_coords.size())
	var processed: int = 0
	for coord_value in worker_coords:
		var coord: Vector3i = coord_value
		var job: Dictionary = _build_generation_job(coord)
		var blocks: PackedByteArray = generator._generate_chunk_blocks(job, flat_noise, small_noise, large_noise, macro_noise)
		if blocks.size() != World.CHUNK_VOLUME:
			blocks = _make_air_blocks()
		blocks_by_coord[coord] = blocks
		processed += 1
		if processed % PROGRESS_UPDATE_INTERVAL == 0:
			_set_worker_progress(worker_index, processed)
	_set_worker_progress(worker_index, processed)
	var elapsed: float = _elapsed_ms(start_usec)
	_store_generation_result(worker_index, {
		"blocks": blocks_by_coord,
		"chunks": processed,
		"generation_ms": elapsed,
	})


func _run_mesh_worker(worker_index: int, worker_coords: Array, table_snapshot: Dictionary) -> void:
	var start_usec: int = Time.get_ticks_usec()
	var mesher: ChunkMesher = ChunkMesherScript.new()
	var mesh_entries: Dictionary = {}
	var built: int = 0
	var empty: int = 0
	_set_worker_total(worker_index, worker_coords.size())
	var processed: int = 0
	for coord_value in worker_coords:
		var coord: Vector3i = coord_value
		var blocks: PackedByteArray = _arena_blocks_for_coord(coord)
		if blocks.size() != World.CHUNK_VOLUME:
			processed += 1
			continue
		var neighbors: Dictionary = _build_neighbor_blocks(coord)
		var padded_blocks: PackedByteArray = mesher.build_padded_block_buffer(World.CHUNK_SIZE, blocks, neighbors, World.BLOCK_ID_AIR)
		var job: Dictionary = {
			"chunk_size": World.CHUNK_SIZE,
			"cx": coord.x,
			"cy": coord.y,
			"cz": coord.z,
			"top_render_y": coord.y * World.CHUNK_SIZE + World.CHUNK_SIZE - 1,
			"air_id": World.BLOCK_ID_AIR,
			"blocks": blocks,
			"padded_blocks": padded_blocks,
			"solid_table": table_snapshot.get("solid_table", PackedByteArray()),
			"ramp_table": table_snapshot.get("ramp_table", PackedByteArray()),
			"color_table": table_snapshot.get("color_table", PackedColorArray()),
		}
		var result: Dictionary = mesher.build_chunk_arrays_from_data(job)
		var entry: Dictionary = _mesh_cache_entry_from_result(result)
		mesh_entries[coord] = entry
		built += 1
		if not bool(entry.get("has_geometry", false)):
			empty += 1
		processed += 1
		if processed % PROGRESS_UPDATE_INTERVAL == 0:
			_set_worker_progress(worker_index, processed)
	_set_worker_progress(worker_index, processed)
	var elapsed: float = _elapsed_ms(start_usec)
	_store_mesh_result(worker_index, {
		"mesh_entries": mesh_entries,
		"meshes": built,
		"empty_meshes": empty,
		"mesh_ms": elapsed,
	})


func _build_generation_job(coord: Vector3i) -> Dictionary:
	return {
		"coord": coord,
		"world_seed": cook_world_seed,
		"sea_level": cook_sea_level,
		"world_size_y": cook_world_size_y,
		"chunk_size": World.CHUNK_SIZE,
		"block_id_air": World.BLOCK_ID_AIR,
		"block_id_default": World.DEFAULT_MATERIAL,
		"block_id_grass": World.BLOCK_ID_GRASS,
		"block_id_dirt": World.BLOCK_ID_DIRT,
	}


func _mesh_cache_entry_from_result(result: Dictionary) -> Dictionary:
	return mesh_cache_helper.entry_from_mesher_result(result, World.CHUNK_SIZE - 1, 0, [])

func _build_neighbor_blocks(coord: Vector3i) -> Dictionary:
	return {
		"x_neg": _arena_blocks_for_coord_or_null(Vector3i(coord.x - 1, coord.y, coord.z)),
		"x_pos": _arena_blocks_for_coord_or_null(Vector3i(coord.x + 1, coord.y, coord.z)),
		"y_neg": _arena_blocks_for_coord_or_null(Vector3i(coord.x, coord.y - 1, coord.z)),
		"y_pos": _arena_blocks_for_coord_or_null(Vector3i(coord.x, coord.y + 1, coord.z)),
		"z_neg": _arena_blocks_for_coord_or_null(Vector3i(coord.x, coord.y, coord.z - 1)),
		"z_pos": _arena_blocks_for_coord_or_null(Vector3i(coord.x, coord.y, coord.z + 1)),
	}


func _arena_blocks_for_coord_or_null(coord: Vector3i) -> Variant:
	if not _is_chunk_coord_valid(coord):
		return null
	return _arena_blocks_for_coord(coord)


func _arena_blocks_for_coord(coord: Vector3i) -> PackedByteArray:
	var blocks_value = arena_blocks.get(coord, PackedByteArray())
	if typeof(blocks_value) == TYPE_PACKED_BYTE_ARRAY:
		return PackedByteArray(blocks_value)
	return PackedByteArray()


func _is_chunk_coord_valid(coord: Vector3i) -> bool:
	return WorldChunkSpaceScript.is_chunk_coord_valid(coord)


func _make_air_blocks() -> PackedByteArray:
	var blocks: PackedByteArray = PackedByteArray()
	blocks.resize(World.CHUNK_VOLUME)
	blocks.fill(World.BLOCK_ID_AIR)
	return blocks


func _all_tasks_completed(task_ids: Array[int]) -> bool:
	for task_id in task_ids:
		if not WorkerThreadPool.is_task_completed(task_id):
			return false
	return true


func _wait_for_tasks(task_ids: Array[int]) -> void:
	for task_id in task_ids:
		WorkerThreadPool.wait_for_task_completion(task_id)


func _current_merge_result(results: Array) -> Dictionary:
	if merge_worker_index < 0 or merge_worker_index >= results.size():
		return {}
	var result_value = results[merge_worker_index]
	if typeof(result_value) == TYPE_DICTIONARY:
		return result_value
	return {}


func _set_worker_total(worker_index: int, total: int) -> void:
	progress_mutex.lock()
	worker_totals[worker_index] = total
	progress_mutex.unlock()


func _set_worker_progress(worker_index: int, value: int) -> void:
	progress_mutex.lock()
	worker_progress[worker_index] = value
	progress_mutex.unlock()


func _store_generation_result(worker_index: int, result: Dictionary) -> void:
	result_mutex.lock()
	generation_results[worker_index] = result
	progress_mutex.lock()
	worker_generation_ms[worker_index] = float(result.get("generation_ms", 0.0))
	if result.has("pipeline_metrics"):
		var metrics_value = result.get("pipeline_metrics", {})
		if typeof(metrics_value) == TYPE_DICTIONARY:
			pipeline_metrics = metrics_value.duplicate(true)
		else:
			pipeline_metrics = {}
	progress_mutex.unlock()
	result_mutex.unlock()


func _store_mesh_result(worker_index: int, result: Dictionary) -> void:
	result_mutex.lock()
	mesh_results[worker_index] = result
	progress_mutex.lock()
	worker_mesh_ms[worker_index] = float(result.get("mesh_ms", 0.0))
	progress_mutex.unlock()
	meshes_built += int(result.get("meshes", 0))
	empty_meshes += int(result.get("empty_meshes", 0))
	result_mutex.unlock()


func _elapsed_ms(start_usec: int) -> float:
	return float(Time.get_ticks_usec() - start_usec) / 1000.0
