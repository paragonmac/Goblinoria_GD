extends Node3D
class_name WorldRenderer
## Main renderer for voxel world chunks, overlays, and stats tracking.

#region Preloads
const ChunkMesherScript = preload("res://scripts/rendering/chunk_mesher.gd")
const ChunkCacheScript = preload("res://scripts/rendering/chunk_cache.gd")
const WorldRendererMeshSchedulerScript = preload("res://scripts/rendering/world_renderer_mesh_scheduler.gd")
const WorldRendererRenderLevelScript = preload("res://scripts/rendering/world_renderer_render_level.gd")
const WorldRendererMaterialsScript = preload("res://scripts/rendering/world_renderer_materials.gd")
const WorldRendererStatsScript = preload("res://scripts/rendering/world_renderer_stats.gd")
const OverlayRendererScript = preload("res://scripts/rendering/overlay_renderer.gd")
const FrustumCullerScript = preload("res://scripts/rendering/frustum_culler.gd")
const ChunkMeshJobBuilderScript = preload("res://scripts/rendering/chunk_mesh_job_builder.gd")
const WorldRendererMeshCacheStoreScript = preload("res://scripts/rendering/world_renderer_mesh_cache_store.gd")
#endregion

#region Constants
const NEAR_SAMPLE_OFFSET := 0.1
const NEAR_SAMPLE_MIN := 0.1
const MESH_BUILD_LOG_THRESHOLD_MS := 5.0
const MESH_APPLY_BUDGET := 8
const MESH_WORK_BUDGET_MS := 40.0
const MESH_RESULT_BACKLOG_MAX := 32
const MESH_RESULT_BACKLOG_SLEEP_USEC := 500
const MESH_CACHE_RADIUS := 0
const MESH_PREFETCH_BELOW_ONLY := true
const MESHER_CACHE_VERSION := 3
#endregion

#region State
var world: World
var mesher = ChunkMesherScript.new()
var mesher_thread = ChunkMesherScript.new()
var chunk_cache = ChunkCacheScript.new()
var mesh_scheduler = WorldRendererMeshSchedulerScript.new()
var render_level_helper = WorldRendererRenderLevelScript.new()
var material_helper = WorldRendererMaterialsScript.new()
var render_stats = WorldRendererStatsScript.new()
var overlay_renderer = OverlayRendererScript.new()
var frustum_culler = FrustumCullerScript.new()
var mesh_job_builder = ChunkMeshJobBuilderScript.new()
var mesh_cache_store = WorldRendererMeshCacheStoreScript.new()
var use_async_meshing: bool = true
var render_zone_visible: Dictionary = {}
var block_solid_table := PackedByteArray()
var block_color_table := PackedColorArray()
var block_ramp_table := PackedByteArray()
var pending_neighbor_remesh: Dictionary = {}
var chunk_missing_neighbors: Dictionary = {}
var neighbor_remesh_queued_total: int = 0
#endregion


#region Initialization
func initialize(world_ref: World) -> void:
	world = world_ref
	if chunk_cache.get_parent() == null:
		add_child(chunk_cache)
	if overlay_renderer.get_parent() == null:
		add_child(overlay_renderer)
	overlay_renderer.initialize(world_ref)
	material_helper.initialize(world_ref)
	_ensure_block_tables()
	mesh_job_builder.configure(world_ref, mesher)
	mesh_scheduler.configure(Callable(self, "_build_mesh_result_on_worker"), MESH_RESULT_BACKLOG_MAX, MESH_RESULT_BACKLOG_SLEEP_USEC)
	render_level_helper.configure(self, chunk_cache, mesh_scheduler)
	_start_mesh_worker()
#endregion


func _exit_tree() -> void:
	_stop_mesh_worker()


#region Reset and Clear
func reset_stats() -> void:
	_clear_all_chunk_render_stats()
	neighbor_remesh_queued_total = 0
	reset_mesh_cache_metrics()
	clear_drag_preview()
	overlay_renderer.clear_task_overlays()

func clear_chunks() -> void:
	chunk_cache.clear()
	_clear_all_chunk_render_stats()
	pending_neighbor_remesh.clear()
	chunk_missing_neighbors.clear()
	render_level_helper.clear()
	mesh_cache_store.clear()
	render_zone_visible.clear()
	_clear_mesh_jobs()
	if world == null:
		return
	for chunk in world.chunks.values():
		var entry: ChunkData = chunk
		entry.mesh_state = ChunkData.MESH_STATE_NONE
#endregion


func clear_chunk(coord: Vector3i) -> void:
	_cancel_chunk_jobs(coord)
	render_level_helper.remove_coord(coord)
	_clear_chunk_render_stats(coord)
	_clear_neighbor_remesh_dependencies(coord)
	mesh_cache_store.erase(coord)
	if chunk_cache != null:
		chunk_cache.remove_chunk(coord)


func _clear_all_chunk_render_stats() -> void:
	render_stats.clear_all()


func _clear_chunk_render_stats(coord: Vector3i) -> void:
	render_stats.clear_chunk(coord)

func _clear_neighbor_remesh_dependencies(coord: Vector3i) -> void:
	if chunk_missing_neighbors.has(coord):
		var missing_map_value: Variant = chunk_missing_neighbors[coord]
		if typeof(missing_map_value) == TYPE_DICTIONARY:
			var missing_map: Dictionary = missing_map_value
			for neighbor_coord in missing_map.keys():
				if pending_neighbor_remesh.has(neighbor_coord):
					var dependents_value: Variant = pending_neighbor_remesh[neighbor_coord]
					if typeof(dependents_value) == TYPE_DICTIONARY:
						var dependents: Dictionary = dependents_value
						dependents.erase(coord)
						if dependents.is_empty():
							pending_neighbor_remesh.erase(neighbor_coord)
		chunk_missing_neighbors.erase(coord)
	for neighbor_coord in pending_neighbor_remesh.keys():
		var dependents_value: Variant = pending_neighbor_remesh[neighbor_coord]
		if typeof(dependents_value) != TYPE_DICTIONARY:
			continue
		var dependents: Dictionary = dependents_value
		if dependents.has(coord):
			dependents.erase(coord)
			if dependents.is_empty():
				pending_neighbor_remesh.erase(neighbor_coord)


func _update_neighbor_remesh_dependencies(coord: Vector3i, missing_neighbors: Array) -> void:
	_clear_neighbor_remesh_dependencies(coord)
	if missing_neighbors.is_empty():
		return
	var unique_missing: Dictionary = {}
	for neighbor_coord in missing_neighbors:
		if typeof(neighbor_coord) != TYPE_VECTOR3I:
			continue
		if world != null and not world.is_chunk_coord_valid(neighbor_coord):
			continue
		unique_missing[neighbor_coord] = true
	if unique_missing.is_empty():
		return
	chunk_missing_neighbors[coord] = unique_missing
	for neighbor_coord in unique_missing.keys():
		var dependents: Dictionary = {}
		if pending_neighbor_remesh.has(neighbor_coord):
			var dependents_value: Variant = pending_neighbor_remesh[neighbor_coord]
			if typeof(dependents_value) == TYPE_DICTIONARY:
				dependents = dependents_value
		dependents[coord] = true
		pending_neighbor_remesh[neighbor_coord] = dependents


func notify_chunk_loaded(coord: Vector3i) -> void:
	if not pending_neighbor_remesh.has(coord):
		return
	var dependents_value: Variant = pending_neighbor_remesh[coord]
	pending_neighbor_remesh.erase(coord)
	if typeof(dependents_value) != TYPE_DICTIONARY:
		return
	var dependents: Dictionary = dependents_value
	for dependent_coord in dependents.keys():
		if chunk_missing_neighbors.has(dependent_coord):
			var missing_map_value: Variant = chunk_missing_neighbors[dependent_coord]
			if typeof(missing_map_value) == TYPE_DICTIONARY:
				var missing_map: Dictionary = missing_map_value
				missing_map.erase(coord)
				if missing_map.is_empty():
					chunk_missing_neighbors.erase(dependent_coord)
		if world == null or not world.is_chunk_coord_valid(dependent_coord):
			continue
		var chunk: ChunkData = world.get_chunk(dependent_coord)
		if chunk == null or not chunk.generated:
			continue
		chunk.mesh_state = ChunkData.MESH_STATE_NONE
		chunk.mesh_revision += 1
		invalidate_chunk_mesh_cache(dependent_coord)
		queue_chunk_mesh_build(dependent_coord, -1, false, true)
		neighbor_remesh_queued_total += 1


func _count_pending_neighbor_remesh_dependents() -> int:
	var total := 0
	for dependents_value in pending_neighbor_remesh.values():
		if typeof(dependents_value) == TYPE_DICTIONARY:
			var dependents: Dictionary = dependents_value
			total += dependents.size()
	return total


func _missing_neighbors_from_value(value: Variant) -> Array:
	var missing: Array = []
	if typeof(value) != TYPE_ARRAY:
		return missing
	var values: Array = value
	for coord in values:
		if typeof(coord) == TYPE_VECTOR3I:
			missing.append(coord)
	return missing


func _record_chunk_render_stats(coord: Vector3i, visible_faces: int, occluded_faces: int, mesh_metrics: Dictionary) -> void:
	render_stats.record_chunk_render_stats(coord, visible_faces, occluded_faces, mesh_metrics)


func _mesh_metrics_from_result(result: Dictionary, mesh_value: Variant) -> Dictionary:
	return render_stats.mesh_metrics_from_result(result, mesh_value)


func _mesh_metrics_from_entry(entry: Dictionary, mesh_value: Variant) -> Dictionary:
	return render_stats.mesh_metrics_from_entry(entry, mesh_value)

#region Chunk Building
func regenerate_chunk(cx: int, cy: int, cz: int) -> void:
	if world == null:
		return
	var key := Vector3i(cx, cy, cz)
	if not world.is_chunk_coord_valid(key):
		return
	var chunk_size: int = World.CHUNK_SIZE
	var mesh_instance: MeshInstance3D = chunk_cache.ensure_chunk(key, chunk_size)

	var profiler: DebugProfiler = world.debug_profiler
	var build_start := 0
	var log_build_time := profiler != null and profiler.enabled
	if log_build_time:
		profiler.begin("Renderer.build_chunk_mesh")
		build_start = Time.get_ticks_usec()
	var result: Dictionary = mesher.build_chunk_mesh(world, cx, cy, cz)
	if log_build_time:
		profiler.end("Renderer.build_chunk_mesh")
		var build_ms := float(Time.get_ticks_usec() - build_start) / 1000.0
		if build_ms >= MESH_BUILD_LOG_THRESHOLD_MS:
			print("Chunk mesh build %d,%d,%d: %.2f ms" % [cx, cy, cz, build_ms])
	var mesh: ArrayMesh = result["mesh"]
	var vertices: PackedVector3Array = result.get("vertices", PackedVector3Array())
	var normals: PackedVector3Array = result.get("normals", PackedVector3Array())
	var colors: PackedColorArray = result.get("colors", PackedColorArray())
	var uvs: PackedVector2Array = result.get("uv", PackedVector2Array())
	var uv2s: PackedVector2Array = result.get("uv2", PackedVector2Array())
	var visible_faces: int = result["visible_faces"]
	var occluded_faces: int = result["occluded_faces"]
	var has_geometry: bool = result["has_geometry"]
	var missing_neighbors: Array = _missing_neighbors_from_value(result.get("missing_neighbors", []))
	var mesh_metrics := _mesh_metrics_from_result(result, mesh)

	_record_chunk_render_stats(key, visible_faces, occluded_faces, mesh_metrics)
	mesh_instance.mesh = mesh
	mesh_instance.visible = has_geometry and _is_chunk_in_current_render_zone(key)
	if has_geometry:
		mesh_instance.material_override = get_block_material()
	var chunk: ChunkData = world.get_chunk(key)
	if chunk != null:
		chunk.mesh_state = ChunkData.MESH_STATE_READY
		chunk.dirty = false
		var local_top := world.top_render_y - key.y * chunk_size
		if local_top >= 0:
			local_top = min(local_top, chunk_size - 1)
			_store_mesh_cache_from_arrays(key, local_top, vertices, normals, colors, uvs, uv2s, visible_faces, occluded_faces, has_geometry, chunk.mesh_revision, mesh_metrics, missing_neighbors)
	_update_neighbor_remesh_dependencies(key, missing_neighbors)
#endregion


#region Async Meshing
func queue_chunk_mesh_build(coord: Vector3i, top_render_y: int = -1, respect_top: bool = false, high_priority: bool = false, force_sync: bool = false) -> void:
	if world == null:
		return
	if not world.is_chunk_coord_valid(coord):
		return
	_ensure_block_tables()
	var chunk: ChunkData = world.get_chunk(coord)
	if chunk == null or not chunk.generated:
		return
	var requested_local_top: int = _mesh_request_local_top(coord, top_render_y)
	if requested_local_top < 0:
		_apply_empty_mesh(coord)
		return
	if _apply_cached_mesh(coord, requested_local_top):
		_cancel_chunk_jobs(coord)
		return
	if not use_async_meshing or force_sync:
		regenerate_chunk(coord.x, coord.y, coord.z)
		return
	if not mesh_scheduler.is_running():
		_start_mesh_worker()
	var revision: int = chunk.mesh_revision
	var queued_rev: int = mesh_scheduler.get_job_revision(coord)
	if queued_rev >= revision and chunk.mesh_state == ChunkData.MESH_STATE_PENDING and not respect_top:
		if high_priority:
			_reprioritize_mesh_job(coord)
		return
	if queued_rev >= 0 and queued_rev < revision:
		_cancel_chunk_jobs(coord)
	chunk.mesh_state = ChunkData.MESH_STATE_PENDING
	var job := _build_mesh_job(coord, revision, top_render_y, false, respect_top)
	if job.is_empty():
		_apply_empty_mesh(coord)
		return
	mesh_scheduler.enqueue_visible_job(job, revision, high_priority)


func _reprioritize_mesh_job(coord: Vector3i) -> void:
	mesh_scheduler.reprioritize_job(coord)


func _queue_prefetch_layers(coord: Vector3i, local_top: int) -> void:
	if MESH_CACHE_RADIUS <= 0:
		return
	if local_top < 0:
		return
	if not _is_chunk_in_current_render_zone(coord):
		return
	for offset in range(1, MESH_CACHE_RADIUS + 1):
		if not MESH_PREFETCH_BELOW_ONLY:
			_queue_prefetch_job(coord, local_top + offset)
		_queue_prefetch_job(coord, local_top - offset)


func _queue_prefetch_job(coord: Vector3i, local_top: int) -> void:
	if world == null:
		return
	if not use_async_meshing:
		return
	if not mesh_scheduler.is_running():
		_start_mesh_worker()
	_ensure_block_tables()
	var chunk_size: int = World.CHUNK_SIZE
	if local_top < 0 or local_top >= chunk_size:
		return
	if _has_cached_mesh(coord, local_top):
		return
	var chunk: ChunkData = world.get_chunk(coord)
	if chunk == null:
		return
	var revision: int = chunk.mesh_revision
	var key := _prefetch_key(coord, local_top)
	var queued_rev: int = mesh_scheduler.get_prefetch_revision(key)
	if queued_rev >= revision:
		return
	var chunk_base_y: int = coord.y * chunk_size
	var top_render_y := chunk_base_y + local_top
	var job := _build_mesh_job(coord, revision, top_render_y, true, false)
	if job.is_empty():
		return
	mesh_scheduler.enqueue_prefetch_job(key, job, revision)


func queue_chunk_mesh_cache_build(coord: Vector3i, local_top: int, high_priority: bool = false) -> bool:
	if world == null:
		return false
	if not use_async_meshing:
		return false
	if not world.is_chunk_coord_valid(coord):
		return false
	if local_top < 0 or local_top >= World.CHUNK_SIZE:
		return false
	if _has_cached_mesh(coord, local_top):
		return false
	if not mesh_scheduler.is_running():
		_start_mesh_worker()
	_ensure_block_tables()
	var chunk: ChunkData = world.get_chunk(coord)
	if chunk == null or not chunk.generated:
		return false
	var revision: int = chunk.mesh_revision
	var key := _prefetch_key(coord, local_top)
	var queued_rev: int = mesh_scheduler.get_prefetch_revision(key)
	if queued_rev >= revision:
		return false
	var top_render_y: int = coord.y * World.CHUNK_SIZE + local_top
	var job := _build_mesh_job(coord, revision, top_render_y, true, false)
	if job.is_empty():
		return false
	job["cache_only"] = true
	mesh_scheduler.enqueue_prefetch_job(key, job, revision, high_priority)
	return true


func process_mesh_results(budget: int) -> int:
	if budget <= 0:
		return 0
	var applied := 0
	while applied < budget:
		var result: Dictionary = mesh_scheduler.pop_result()
		if result.is_empty():
			break
		if _apply_mesh_result(result):
			applied += 1
	return applied


func process_mesh_results_time_budget(max_ms: float, max_count: int = -1) -> int:
	if max_ms <= 0.0:
		return 0
	var start_usec := Time.get_ticks_usec()
	var applied := 0
	var build_ms_sum := 0.0
	while true:
		if max_count >= 0 and applied >= max_count:
			break
		var elapsed_ms := float(Time.get_ticks_usec() - start_usec) / 1000.0
		if elapsed_ms >= max_ms:
			break
		if build_ms_sum >= max_ms:
			break
		var next_build_ms := mesh_scheduler.peek_next_result_build_ms()
		if next_build_ms < 0.0:
			break
		if build_ms_sum > 0.0 and build_ms_sum + next_build_ms > max_ms:
			break
		var result: Dictionary = mesh_scheduler.pop_result()
		if result.is_empty():
			break
		build_ms_sum += next_build_ms
		if _apply_mesh_result(result):
			applied += 1
	return applied


func flush_mesh_jobs(include_prefetch: bool = true, max_ms: float = -1.0) -> void:
	var start_usec := Time.get_ticks_usec()
	var safety := 0
	while has_pending_mesh_work(include_prefetch):
		var applied := 0
		if max_ms > 0.0:
			var elapsed_ms := float(Time.get_ticks_usec() - start_usec) / 1000.0
			var remaining_ms := max_ms - elapsed_ms
			if remaining_ms <= 0.0:
				break
			applied = process_mesh_results_time_budget(remaining_ms)
		else:
			applied = process_mesh_results(MESH_APPLY_BUDGET * 8)
		if applied <= 0:
			OS.delay_usec(500)
		safety += 1
		if safety > 100000:
			break


func _apply_mesh_result(result: Dictionary) -> bool:
	if world == null:
		return false
	var apply_start_usec: int = Time.get_ticks_usec()
	var coord: Vector3i = result["coord"]
	var chunk: ChunkData = world.get_chunk(coord)
	var local_top: int = int(result.get("local_top", -1))
	var revision: int = int(result.get("mesh_revision", -1))
	var prefetch: bool = bool(result.get("prefetch", false))
	var respect_top: bool = bool(result.get("respect_top", false))
	var cache_only: bool = bool(result.get("cache_only", false))
	if chunk == null:
		if prefetch:
			_clear_prefetch_job_record(coord, local_top, revision)
		else:
			_clear_mesh_job_record(coord, revision)
		return false
	if revision != chunk.mesh_revision:
		if chunk.mesh_state == ChunkData.MESH_STATE_PENDING:
			chunk.mesh_state = ChunkData.MESH_STATE_NONE
		if prefetch:
			_clear_prefetch_job_record(coord, local_top, revision)
		else:
			_clear_mesh_job_record(coord, revision)
		return false
	var vertices: PackedVector3Array = result["vertices"]
	var normals: PackedVector3Array = result["normals"]
	var colors: PackedColorArray = result["colors"]
	var uvs: PackedVector2Array = result["uv"]
	var uv2s: PackedVector2Array = result["uv2"]
	var visible_faces: int = int(result["visible_faces"])
	var occluded_faces: int = int(result["occluded_faces"])
	var has_geometry: bool = bool(result["has_geometry"])
	var missing_neighbors: Array = _missing_neighbors_from_value(result.get("missing_neighbors", []))
	var mesh_metrics := _mesh_metrics_from_result(result, null)


	var chunk_size: int = World.CHUNK_SIZE
	var current_local_top := world.top_render_y - coord.y * chunk_size
	if current_local_top >= 0:
		current_local_top = min(current_local_top, chunk_size - 1)
	else:
		current_local_top = -1
	var should_apply := not prefetch and not cache_only
	if not cache_only and (prefetch or respect_top):
		should_apply = current_local_top == local_top
	if should_apply:
		var mesh := ArrayMesh.new()
		if has_geometry:
			var arrays := []
			arrays.resize(Mesh.ARRAY_MAX)
			arrays[Mesh.ARRAY_VERTEX] = vertices
			arrays[Mesh.ARRAY_NORMAL] = normals
			arrays[Mesh.ARRAY_COLOR] = colors
			arrays[Mesh.ARRAY_TEX_UV] = uvs
			arrays[Mesh.ARRAY_TEX_UV2] = uv2s
			mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		var mesh_instance: MeshInstance3D = chunk_cache.ensure_chunk(coord, chunk_size)
		_record_chunk_render_stats(coord, visible_faces, occluded_faces, mesh_metrics)
		mesh_instance.mesh = mesh
		mesh_instance.visible = has_geometry and _is_chunk_in_current_render_zone(coord)
		if has_geometry:
			mesh_instance.material_override = get_block_material()
		chunk.mesh_state = ChunkData.MESH_STATE_READY
		chunk.dirty = false
	_store_mesh_cache_from_arrays(coord, local_top, vertices, normals, colors, uvs, uv2s, visible_faces, occluded_faces, has_geometry, revision, mesh_metrics, missing_neighbors)
	_update_neighbor_remesh_dependencies(coord, missing_neighbors)
	if should_apply:
		_queue_prefetch_layers(coord, local_top)

	var build_ms := float(result.get("build_ms", 0.0))
	mesh_cache_store.record_build_ms(build_ms)
	if build_ms > 0.0 and world.debug_profiler != null:
		world.debug_profiler.add_sample("Renderer.build_chunk_mesh", build_ms)
		if build_ms >= MESH_BUILD_LOG_THRESHOLD_MS:
			print("Chunk mesh build %d,%d,%d: %.2f ms" % [coord.x, coord.y, coord.z, build_ms])
	mesh_cache_store.record_upload_ms(float(Time.get_ticks_usec() - apply_start_usec) / 1000.0)
	if prefetch:
		_clear_prefetch_job_record(coord, local_top, revision)
	else:
		_clear_mesh_job_record(coord, revision)
	return true


func _clear_mesh_job_record(coord: Vector3i, revision: int) -> void:
	mesh_scheduler.clear_job_record(coord, revision)


func _clear_prefetch_job_record(coord: Vector3i, local_top: int, revision: int) -> void:
	mesh_scheduler.clear_prefetch_job_record(coord, local_top, revision)


func _cancel_chunk_jobs(coord: Vector3i) -> void:
	mesh_scheduler.cancel_coord(coord)


func _purge_prefetch_for_coord(coord: Vector3i) -> void:
	mesh_scheduler.purge_prefetch_for_coord(coord)


func _prefetch_key(coord: Vector3i, local_top: int) -> String:
	return mesh_scheduler.prefetch_key(coord, local_top)


func _build_mesh_job(coord: Vector3i, revision: int, top_render_y: int, prefetch: bool, respect_top: bool) -> Dictionary:
	return mesh_job_builder.build_mesh_job(
		coord,
		revision,
		top_render_y,
		prefetch,
		respect_top,
		block_solid_table,
		block_ramp_table,
		block_color_table
	)


func _build_mesh_result_on_worker(job: Dictionary) -> Dictionary:
	var build_start := Time.get_ticks_usec()
	var result: Dictionary = mesher_thread.build_chunk_arrays_from_data(job)
	result["coord"] = job["coord"]
	result["mesh_revision"] = job.get("mesh_revision", -1)
	result["local_top"] = job.get("local_top", -1)
	result["prefetch"] = job.get("prefetch", false)
	result["respect_top"] = job.get("respect_top", false)
	result["cache_only"] = job.get("cache_only", false)
	result["missing_neighbors"] = job.get("missing_neighbors", [])
	result["build_ms"] = float(Time.get_ticks_usec() - build_start) / 1000.0
	return result


func _start_mesh_worker() -> void:
	mesh_scheduler.start(use_async_meshing)


func _stop_mesh_worker() -> void:
	mesh_scheduler.stop()


func _ensure_block_tables() -> void:
	if world == null:
		return
	mesher._ensure_block_tables(world)
	block_solid_table = mesher.block_solid_table
	block_color_table = mesher.block_color_table
	block_ramp_table = mesher.block_ramp_table


func _clear_mesh_jobs() -> void:
	mesh_scheduler.clear()
#endregion


#region Render Height Queue
func queue_render_height_update(old_y: int, new_y: int, anchor: Vector3, min_x: int, max_x: int, min_z: int, max_z: int) -> int:
	if world == null:
		return 0
	return render_level_helper.queue_update(world, old_y, new_y, anchor, min_x, max_x, min_z, max_z)


func process_render_height_queue(budget: int) -> int:
	return render_level_helper.process_queue(budget)


func clear_render_height_queue() -> void:
	render_level_helper.clear()


func has_pending_render_height_work() -> bool:
	return render_level_helper.has_pending_work()


func has_pending_mesh_work(include_prefetch: bool) -> bool:
	if mesh_scheduler.has_visible_records():
		return true
	if include_prefetch and mesh_scheduler.has_prefetch_records():
		return true
	if include_prefetch:
		if _has_any_jobs():
			return true
		if _has_any_results():
			return true
		return false
	if _has_non_prefetch_jobs():
		return true
	if _has_non_prefetch_results():
		return true
	return false


func _has_non_prefetch_jobs() -> bool:
	return mesh_scheduler.has_non_prefetch_jobs()


func _has_non_prefetch_results() -> bool:
	return mesh_scheduler.has_non_prefetch_results()


func _has_any_jobs() -> bool:
	return mesh_scheduler.has_any_jobs()


func _has_any_results() -> bool:
	return mesh_scheduler.has_any_results()


func update_render_height_anchor(anchor: Vector3) -> void:
	render_level_helper.update_anchor(anchor)
#endregion


#region Mesh Cache
func invalidate_chunk_mesh_cache(coord: Vector3i) -> void:
	mesh_cache_store.erase(coord)


func reset_mesh_cache_metrics() -> void:
	mesh_cache_store.reset_metrics()


func get_mesh_cache_metrics() -> Dictionary:
	return mesh_cache_store.get_metrics()

func get_mesher_table_snapshot() -> Dictionary:
	_ensure_block_tables()
	return {
		"solid_table": block_solid_table.duplicate(),
		"color_table": block_color_table.duplicate(),
		"ramp_table": block_ramp_table.duplicate(),
	}

func _store_mesh_cache_from_arrays(
	coord: Vector3i,
	local_top: int,
	vertices: PackedVector3Array,
	normals: PackedVector3Array,
	colors: PackedColorArray,
	uvs: PackedVector2Array,
	uv2s: PackedVector2Array,
	visible_faces: int,
	occluded_faces: int,
	has_geometry: bool,
	revision: int,
	mesh_metrics: Dictionary = {},
	missing_neighbors: Array = []
) -> void:
	mesh_cache_store.store_from_arrays(
		coord,
		local_top,
		vertices,
		normals,
		colors,
		uvs,
		uv2s,
		visible_faces,
		occluded_faces,
		has_geometry,
		revision,
		mesh_metrics,
		missing_neighbors
	)


func export_persistent_mesh_cache_entry(coord: Vector3i, local_top: int) -> Dictionary:
	return mesh_cache_store.export_persistent_entry(coord, local_top)

func import_persistent_mesh_cache_entry(coord: Vector3i, entry: Dictionary) -> bool:
	return mesh_cache_store.import_persistent_entry(world, coord, entry)

func _validate_mesh_cache_arrays(entry: Dictionary) -> bool:
	return mesh_cache_store.validate_arrays(entry)

func _array_mesh_from_entry(entry: Dictionary) -> ArrayMesh:
	return mesh_cache_store.array_mesh_from_entry(entry)

func has_cached_chunk_mesh(coord: Vector3i, local_top: int) -> bool:
	return _has_cached_mesh(coord, local_top)


func _has_cached_mesh(coord: Vector3i, local_top: int) -> bool:
	return mesh_cache_store.has_cached_mesh(world, coord, local_top)


func _apply_cached_mesh(coord: Vector3i, local_top: int) -> bool:
	var cached := mesh_cache_store.get_valid_entry_for_apply(world, coord, local_top)
	if cached.is_empty():
		return false
	var entry: Dictionary = cached["entry"]
	var cache_local_top: int = int(cached["local_top"])
	var chunk: ChunkData = world.get_chunk(coord)
	if chunk == null:
		return false
	_apply_mesh_entry(coord, entry, chunk)
	_queue_prefetch_layers(coord, cache_local_top)
	return true


func _mesh_request_local_top(coord: Vector3i, top_render_y: int) -> int:
	if top_render_y < 0:
		top_render_y = world.top_render_y
	var local_top: int = top_render_y - coord.y * World.CHUNK_SIZE
	if local_top < 0:
		return -1
	return mini(local_top, World.CHUNK_SIZE - 1)


func _apply_mesh_entry(coord: Vector3i, entry: Dictionary, chunk: ChunkData) -> void:
	var visible_faces: int = int(entry["visible_faces"])
	var occluded_faces: int = int(entry["occluded_faces"])
	var has_geometry: bool = bool(entry["has_geometry"])
	var missing_neighbors: Array = _missing_neighbors_from_value(entry.get("missing_neighbors", []))
	var mesh: ArrayMesh = _array_mesh_from_entry(entry)
	var mesh_instance: MeshInstance3D = chunk_cache.ensure_chunk(coord, World.CHUNK_SIZE)
	_record_chunk_render_stats(coord, visible_faces, occluded_faces, _mesh_metrics_from_entry(entry, null))
	mesh_instance.mesh = mesh if has_geometry else null
	mesh_instance.visible = has_geometry and _is_chunk_in_current_render_zone(coord)
	if has_geometry:
		mesh_instance.material_override = get_block_material()
	chunk.mesh_state = ChunkData.MESH_STATE_READY
	chunk.dirty = false
	_update_neighbor_remesh_dependencies(coord, missing_neighbors)

func _apply_empty_mesh(coord: Vector3i) -> void:
	var mesh_instance: MeshInstance3D = chunk_cache.get_chunk(coord)
	_clear_chunk_render_stats(coord)
	_clear_neighbor_remesh_dependencies(coord)
	if mesh_instance != null:
		mesh_instance.mesh = null
		mesh_instance.visible = false
	var chunk: ChunkData = world.get_chunk(coord)
	if chunk != null:
		chunk.mesh_state = ChunkData.MESH_STATE_READY
		chunk.dirty = false


func _hide_chunk_mesh(coord: Vector3i) -> void:
	var mesh_instance: MeshInstance3D = chunk_cache.get_chunk(coord)
	if mesh_instance != null:
		mesh_instance.visible = false
	var chunk: ChunkData = world.get_chunk(coord)
	if chunk != null:
		chunk.mesh_state = ChunkData.MESH_STATE_NONE
#endregion


#region Render Zone
func update_render_zone(min_cx: int, max_cx: int, min_cz: int, max_cz: int, min_cy: int, max_cy: int) -> void:
	var new_visible: Dictionary = {}
	if min_cx <= max_cx and min_cz <= max_cz and min_cy <= max_cy:
		for cy: int in range(min_cy, max_cy + 1):
			for cx: int in range(min_cx, max_cx + 1):
				for cz: int in range(min_cz, max_cz + 1):
					var coord := Vector3i(cx, cy, cz)
					new_visible[coord] = true
					_set_chunk_visibility(coord, true)
	for key in render_zone_visible.keys():
		if not new_visible.has(key):
			_set_chunk_visibility(key, false)
	render_zone_visible = new_visible


func _is_chunk_in_current_render_zone(coord: Vector3i) -> bool:
	if render_zone_visible.is_empty():
		return true
	return render_zone_visible.has(coord)


func _set_chunk_visibility(coord: Vector3i, is_visible: bool) -> void:
	var mesh_instance: MeshInstance3D = chunk_cache.get_chunk(coord)
	if mesh_instance == null:
		return
	if not is_visible:
		mesh_instance.visible = false
		return
	if mesh_instance.mesh == null:
		mesh_instance.visible = false
		return
	mesh_instance.visible = true
#endregion


#region Materials
func get_block_material() -> Material:
	return material_helper.get_block_material()


func set_top_render_y(value: int) -> void:
	material_helper.set_top_render_y(value)
	if overlay_renderer != null:
		overlay_renderer.set_top_render_y(value)


func set_min_render_y(value: int) -> void:
	material_helper.set_min_render_y(value)


func toggle_debug_normals() -> void:
	material_helper.toggle_debug_normals()
#endregion


#region Stats
func get_draw_burden_stats() -> Dictionary:
	return render_stats.get_draw_burden_stats()


func get_chunk_draw_stats() -> Dictionary:
	var loaded := 0
	if world != null:
		loaded = world.chunks.size()
	var keys: Array = chunk_cache.get_keys()
	var meshed: int = keys.size()
	var visible_count: int = 0
	for key in keys:
		var mesh_instance: MeshInstance3D = chunk_cache.get_chunk(key)
		if mesh_instance == null:
			continue
		if mesh_instance.mesh == null:
			continue
		if mesh_instance.visible:
			visible_count += 1
	var zone: int = render_zone_visible.size()
	var pool_stats := chunk_cache.get_pool_stats()
	return {
		"loaded": loaded,
		"meshed": meshed,
		"visible": visible_count,
		"zone": zone,
		"chunk_node_active": int(pool_stats.get("active", 0)),
		"chunk_node_pooled": int(pool_stats.get("pooled", 0)),
		"chunk_node_pool_max": int(pool_stats.get("pool_max", 0)),
		"chunk_node_created": int(pool_stats.get("created", 0)),
		"chunk_node_reused": int(pool_stats.get("reused", 0)),
		"chunk_node_freed": int(pool_stats.get("freed", 0)),
	}


func get_mesh_work_stats() -> Dictionary:
	var scheduler_stats := mesh_scheduler.get_stats()
	var cache_metrics := mesh_cache_store.get_metrics()
	var stats: Dictionary = render_stats.get_mesh_work_stats()
	stats["job_queue"] = int(scheduler_stats.get("job_queue", 0))
	stats["result_queue"] = int(scheduler_stats.get("result_queue", 0))
	stats["job_set"] = int(scheduler_stats.get("job_set", 0))
	stats["prefetch_set"] = int(scheduler_stats.get("prefetch_set", 0))
	stats["cache_hits"] = int(cache_metrics.get("hits", 0))
	stats["cache_misses"] = int(cache_metrics.get("misses", 0))
	stats["cache_imports"] = int(cache_metrics.get("imports", 0))
	stats["mesh_build_ms"] = float(cache_metrics.get("mesh_build_ms", 0.0))
	stats["mesh_upload_ms"] = float(cache_metrics.get("mesh_upload_ms", 0.0))
	stats["pending_neighbor_remesh_chunks"] = pending_neighbor_remesh.size()
	stats["pending_neighbor_remesh_dependents"] = _count_pending_neighbor_remesh_dependents()
	stats["neighbor_remesh_queued"] = neighbor_remesh_queued_total
	return stats


func get_camera_tris_rendered(camera: Camera3D) -> Dictionary:
	return render_stats.get_camera_tris_rendered(camera, frustum_culler, World.CHUNK_SIZE, NEAR_SAMPLE_OFFSET, NEAR_SAMPLE_MIN)
#endregion


#region Overlay Management
func update_task_overlays(tasks: Array, blocked_tasks: Array) -> void:
	if overlay_renderer == null:
		return
	overlay_renderer.update_task_overlays(tasks, blocked_tasks)


func set_drag_preview(rect: Dictionary, mode: int) -> void:
	if overlay_renderer == null:
		return
	overlay_renderer.set_drag_preview(rect, mode)


func clear_drag_preview() -> void:
	if overlay_renderer == null:
		return
	overlay_renderer.clear_drag_preview()
#endregion


#region Render Height
func update_render_height(old_y: int, new_y: int) -> int:
	if world == null:
		return 0
	var bounds := world.get_render_height_bounds()
	var anchor := world.get_render_height_anchor()
	return queue_render_height_update(old_y, new_y, anchor, bounds["min_x"], bounds["max_x"], bounds["min_z"], bounds["max_z"])

func update_render_height_in_range(old_y: int, new_y: int, min_x: int, max_x: int, min_z: int, max_z: int) -> int:
	if world == null:
		return 0
	if min_x > max_x or min_z > max_z:
		return 0
	var anchor := world.get_render_height_anchor()
	return queue_render_height_update(old_y, new_y, anchor, min_x, max_x, min_z, max_z)
#endregion


#region Chunk Queries
func is_chunk_built(coord: Vector3i) -> bool:
	return chunk_cache.is_chunk_built(coord)
#endregion


#region Debug Stats
func get_overlay_debug_stats() -> Dictionary:
	if overlay_renderer == null:
		return {}
	return overlay_renderer.get_overlay_debug_stats()
#endregion
