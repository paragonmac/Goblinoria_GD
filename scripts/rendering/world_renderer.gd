extends Node3D
class_name WorldRenderer
## Main renderer for voxel world chunks, overlays, and stats tracking.

#region Preloads
const ChunkMesherScript = preload("res://scripts/rendering/chunk_mesher.gd")
const ChunkCacheScript = preload("res://scripts/rendering/chunk_cache.gd")
const OverlayRendererScript = preload("res://scripts/rendering/overlay_renderer.gd")
const BlockTerrainShader = preload("res://scripts/rendering/block_terrain.gdshader")
const BlockTerrainDebugShader = preload("res://scripts/rendering/block_terrain_debug.gdshader")
const BLOCK_ATLAS_PATH := "res://assets/textures/atlas.png"
#endregion

#region Constants
const TRIS_PER_FACE := 2
const PERCENT_FACTOR := 100.0
const NEAR_SAMPLE_OFFSET := 0.1
const NEAR_SAMPLE_MIN := 0.1
const MESH_BUILD_LOG_THRESHOLD_MS := 5.0
const MESH_APPLY_BUDGET := 8
const MESH_CACHE_RADIUS := 0
const MESH_PREFETCH_BELOW_ONLY := true
#endregion

#region State
var world: World
var mesher = ChunkMesherScript.new()
var mesher_thread = ChunkMesherScript.new()
var chunk_cache = ChunkCacheScript.new()
var overlay_renderer = OverlayRendererScript.new()
var block_material: Material
var block_atlas_texture: Texture2D
var debug_normals_enabled: bool = false
var chunk_face_stats: Dictionary = {}
var total_visible_faces: int = 0
var total_occluded_faces: int = 0
var render_height_queue: Array = []
var render_height_queue_set: Dictionary = {}
var render_height_anchor := Vector3.ZERO
var render_height_target_y: int = 0
var chunk_mesh_cache: Dictionary = {}
var use_async_meshing: bool = true
var mesh_thread: Thread
var mesh_thread_running: bool = false
var mesh_job_queue: Array = []
var mesh_job_set: Dictionary = {}
var mesh_job_mutex := Mutex.new()
var mesh_job_semaphore := Semaphore.new()
var mesh_result_queue: Array = []
var mesh_result_mutex := Mutex.new()
var mesh_prefetch_set: Dictionary = {}
var render_zone_visible: Dictionary = {}
var block_solid_table := PackedByteArray()
var block_color_table := PackedColorArray()
var block_ramp_table := PackedByteArray()
#endregion


#region Initialization
func initialize(world_ref: World) -> void:
	world = world_ref
	if chunk_cache.get_parent() == null:
		add_child(chunk_cache)
	if overlay_renderer.get_parent() == null:
		add_child(overlay_renderer)
	overlay_renderer.initialize(world_ref)
	_ensure_block_tables()
	_start_mesh_worker()
#endregion


func _exit_tree() -> void:
	_stop_mesh_worker()


#region Reset and Clear
func reset_stats() -> void:
	chunk_face_stats.clear()
	total_visible_faces = 0
	total_occluded_faces = 0
	clear_drag_preview()
	overlay_renderer.clear_task_overlays()

func clear_chunks() -> void:
	chunk_cache.clear()
	chunk_face_stats.clear()
	total_visible_faces = 0
	total_occluded_faces = 0
	render_height_queue.clear()
	render_height_queue_set.clear()
	chunk_mesh_cache.clear()
	mesh_prefetch_set.clear()
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
	render_height_queue_set.erase(coord)
	if render_height_queue.has(coord):
		render_height_queue.erase(coord)
	if chunk_face_stats.has(coord):
		var prev_counts: Vector2i = chunk_face_stats[coord]
		total_visible_faces -= prev_counts.x
		total_occluded_faces -= prev_counts.y
		chunk_face_stats.erase(coord)
	if chunk_mesh_cache.has(coord):
		chunk_mesh_cache.erase(coord)
	if chunk_cache != null:
		chunk_cache.remove_chunk(coord)


#region Chunk Building
func regenerate_chunk(cx: int, cy: int, cz: int) -> void:
	if world == null:
		return
	var chunk_size: int = World.CHUNK_SIZE
	var key := Vector3i(cx, cy, cz)
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
	var visible_faces: int = result["visible_faces"]
	var occluded_faces: int = result["occluded_faces"]
	var has_geometry: bool = result["has_geometry"]

	var prev_counts: Vector2i = chunk_face_stats.get(key, Vector2i(0, 0))
	total_visible_faces += visible_faces - prev_counts.x
	total_occluded_faces += occluded_faces - prev_counts.y
	chunk_face_stats[key] = Vector2i(visible_faces, occluded_faces)
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
			_store_mesh_cache(key, local_top, mesh, visible_faces, occluded_faces, has_geometry, chunk.mesh_revision)
#endregion


#region Async Meshing
func queue_chunk_mesh_build(coord: Vector3i, top_render_y: int = -1, respect_top: bool = false, high_priority: bool = false, force_sync: bool = false) -> void:
	if world == null:
		return
	_ensure_block_tables()
	if not use_async_meshing or force_sync:
		regenerate_chunk(coord.x, coord.y, coord.z)
		return
	if not mesh_thread_running:
		_start_mesh_worker()
	var chunk: ChunkData = world.get_chunk(coord)
	if chunk == null or not chunk.generated:
		return
	var revision: int = chunk.mesh_revision
	var queued_rev: int = int(mesh_job_set.get(coord, -1))
	if queued_rev >= revision and chunk.mesh_state == ChunkData.MESH_STATE_PENDING and not respect_top:
		return
	chunk.mesh_state = ChunkData.MESH_STATE_PENDING
	var job := _build_mesh_job(coord, revision, top_render_y, false, respect_top)
	if job.is_empty():
		_apply_empty_mesh(coord)
		return
	mesh_job_set[coord] = revision
	mesh_job_mutex.lock()
	if high_priority:
		mesh_job_queue.insert(0, job)
	else:
		var insert_index := mesh_job_queue.size()
		for i in range(mesh_job_queue.size()):
			if bool(mesh_job_queue[i].get("prefetch", false)):
				insert_index = i
				break
		mesh_job_queue.insert(insert_index, job)
	mesh_job_mutex.unlock()
	mesh_job_semaphore.post()


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
	if not mesh_thread_running:
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
	var queued_rev: int = int(mesh_prefetch_set.get(key, -1))
	if queued_rev >= revision:
		return
	var chunk_base_y: int = coord.y * chunk_size
	var top_render_y := chunk_base_y + local_top
	var job := _build_mesh_job(coord, revision, top_render_y, true, false)
	if job.is_empty():
		return
	mesh_prefetch_set[key] = revision
	mesh_job_mutex.lock()
	mesh_job_queue.append(job)
	mesh_job_mutex.unlock()
	mesh_job_semaphore.post()


func process_mesh_results(budget: int) -> int:
	if budget <= 0:
		return 0
	var applied := 0
	while applied < budget:
		mesh_result_mutex.lock()
		if mesh_result_queue.is_empty():
			mesh_result_mutex.unlock()
			break
		var result: Dictionary = mesh_result_queue.pop_front()
		mesh_result_mutex.unlock()
		if _apply_mesh_result(result):
			applied += 1
	return applied


func flush_mesh_jobs(include_prefetch: bool = true) -> void:
	var safety := 0
	while has_pending_mesh_work(include_prefetch):
		process_mesh_results(MESH_APPLY_BUDGET * 8)
		safety += 1
		if safety > 100000:
			break


func _apply_mesh_result(result: Dictionary) -> bool:
	if world == null:
		return false
	var coord: Vector3i = result["coord"]
	var chunk: ChunkData = world.get_chunk(coord)
	var local_top: int = int(result.get("local_top", -1))
	var revision: int = int(result.get("mesh_revision", -1))
	var prefetch: bool = bool(result.get("prefetch", false))
	var respect_top: bool = bool(result.get("respect_top", false))
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

	var chunk_size: int = World.CHUNK_SIZE
	var current_local_top := world.top_render_y - coord.y * chunk_size
	if current_local_top >= 0:
		current_local_top = min(current_local_top, chunk_size - 1)
	else:
		current_local_top = -1
	var should_apply := not prefetch
	if prefetch or respect_top:
		should_apply = current_local_top == local_top
	if should_apply:
		var mesh_instance: MeshInstance3D = chunk_cache.ensure_chunk(coord, chunk_size)
		var prev_counts: Vector2i = chunk_face_stats.get(coord, Vector2i(0, 0))
		total_visible_faces += visible_faces - prev_counts.x
		total_occluded_faces += occluded_faces - prev_counts.y
		chunk_face_stats[coord] = Vector2i(visible_faces, occluded_faces)
		mesh_instance.mesh = mesh
		mesh_instance.visible = has_geometry and _is_chunk_in_current_render_zone(coord)
		if has_geometry:
			mesh_instance.material_override = get_block_material()
		chunk.mesh_state = ChunkData.MESH_STATE_READY
		chunk.dirty = false
	_store_mesh_cache(coord, local_top, mesh, visible_faces, occluded_faces, has_geometry, revision)
	if should_apply:
		_queue_prefetch_layers(coord, local_top)

	var build_ms := float(result.get("build_ms", 0.0))
	if build_ms > 0.0 and world.debug_profiler != null:
		world.debug_profiler.add_sample("Renderer.build_chunk_mesh", build_ms)
		if build_ms >= MESH_BUILD_LOG_THRESHOLD_MS:
			print("Chunk mesh build %d,%d,%d: %.2f ms" % [coord.x, coord.y, coord.z, build_ms])
	if prefetch:
		_clear_prefetch_job_record(coord, local_top, revision)
	else:
		_clear_mesh_job_record(coord, revision)
	return true


func _clear_mesh_job_record(coord: Vector3i, revision: int) -> void:
	if not mesh_job_set.has(coord):
		return
	var queued_rev: int = int(mesh_job_set.get(coord, -1))
	if queued_rev <= revision:
		mesh_job_set.erase(coord)


func _clear_prefetch_job_record(coord: Vector3i, local_top: int, revision: int) -> void:
	var key := _prefetch_key(coord, local_top)
	if not mesh_prefetch_set.has(key):
		return
	var queued_rev: int = int(mesh_prefetch_set.get(key, -1))
	if queued_rev <= revision:
		mesh_prefetch_set.erase(key)


func _cancel_chunk_jobs(coord: Vector3i) -> void:
	mesh_job_mutex.lock()
	for i in range(mesh_job_queue.size() - 1, -1, -1):
		var job: Dictionary = mesh_job_queue[i]
		if job.get("coord", null) == coord:
			mesh_job_queue.remove_at(i)
	mesh_job_mutex.unlock()
	mesh_result_mutex.lock()
	for i in range(mesh_result_queue.size() - 1, -1, -1):
		var result: Dictionary = mesh_result_queue[i]
		if result.get("coord", null) == coord:
			mesh_result_queue.remove_at(i)
	mesh_result_mutex.unlock()
	mesh_job_set.erase(coord)
	_purge_prefetch_for_coord(coord)


func _purge_prefetch_for_coord(coord: Vector3i) -> void:
	for key in mesh_prefetch_set.keys():
		var key_str: String = key
		if key_str.begins_with("%d,%d,%d," % [coord.x, coord.y, coord.z]):
			mesh_prefetch_set.erase(key_str)


func _prefetch_key(coord: Vector3i, local_top: int) -> String:
	return "%d,%d,%d,%d" % [coord.x, coord.y, coord.z, local_top]


func _build_mesh_job(coord: Vector3i, revision: int, top_render_y: int, prefetch: bool, respect_top: bool) -> Dictionary:
	if world == null:
		return {}
	var chunk: ChunkData = world.get_chunk(coord)
	if chunk == null:
		return {}
	if top_render_y < 0:
		top_render_y = world.top_render_y
	var chunk_base_y: int = coord.y * World.CHUNK_SIZE
	if top_render_y < chunk_base_y:
		return {}
	var local_top: int = World.CHUNK_SIZE - 1
	var neighbors: Dictionary = {
		"x_neg": _copy_neighbor_blocks(Vector3i(coord.x - 1, coord.y, coord.z)),
		"x_pos": _copy_neighbor_blocks(Vector3i(coord.x + 1, coord.y, coord.z)),
		"y_neg": _copy_neighbor_blocks(Vector3i(coord.x, coord.y - 1, coord.z)),
		"y_pos": _copy_neighbor_blocks(Vector3i(coord.x, coord.y + 1, coord.z)),
		"z_neg": _copy_neighbor_blocks(Vector3i(coord.x, coord.y, coord.z - 1)),
		"z_pos": _copy_neighbor_blocks(Vector3i(coord.x, coord.y, coord.z + 1)),
	}
	return {
		"coord": coord,
		"cx": coord.x,
		"cy": coord.y,
		"cz": coord.z,
		"chunk_size": World.CHUNK_SIZE,
		"top_render_y": top_render_y,
		"air_id": World.BLOCK_ID_AIR,
		"blocks": chunk.blocks.duplicate(),
		"neighbors": neighbors,
		"solid_table": block_solid_table,
		"ramp_table": block_ramp_table,
		"color_table": block_color_table,
		"mesh_revision": revision,
		"local_top": local_top,
		"prefetch": prefetch,
		"respect_top": respect_top,
	}


func _copy_neighbor_blocks(coord: Vector3i) -> Variant:
	if world == null:
		return null
	var chunk: ChunkData = world.get_chunk(coord)
	if chunk == null or not chunk.generated:
		return null
	return chunk.blocks.duplicate()


func _mesh_worker_loop() -> void:
	while mesh_thread_running:
		mesh_job_semaphore.wait()
		if not mesh_thread_running:
			break
		var job: Dictionary = {}
		mesh_job_mutex.lock()
		if mesh_job_queue.size() > 0:
			job = mesh_job_queue.pop_front()
		mesh_job_mutex.unlock()
		if job.is_empty():
			continue
		var build_start := Time.get_ticks_usec()
		var result: Dictionary = mesher_thread.build_chunk_arrays_from_data(job)
		result["coord"] = job["coord"]
		result["mesh_revision"] = job.get("mesh_revision", -1)
		result["local_top"] = job.get("local_top", -1)
		result["prefetch"] = job.get("prefetch", false)
		result["respect_top"] = job.get("respect_top", false)
		result["build_ms"] = float(Time.get_ticks_usec() - build_start) / 1000.0
		mesh_result_mutex.lock()
		mesh_result_queue.append(result)
		mesh_result_mutex.unlock()


func _start_mesh_worker() -> void:
	if not use_async_meshing or mesh_thread_running:
		return
	mesh_thread_running = true
	mesh_thread = Thread.new()
	mesh_thread.start(Callable(self, "_mesh_worker_loop"))


func _stop_mesh_worker() -> void:
	if not mesh_thread_running:
		return
	mesh_thread_running = false
	mesh_job_semaphore.post()
	if mesh_thread != null:
		mesh_thread.wait_to_finish()
	mesh_thread = null


func _ensure_block_tables() -> void:
	if world == null:
		return
	if block_solid_table.size() == BlockRegistry.TABLE_SIZE \
		and block_color_table.size() == BlockRegistry.TABLE_SIZE \
		and block_ramp_table.size() == BlockRegistry.TABLE_SIZE:
		return
	block_solid_table.resize(BlockRegistry.TABLE_SIZE)
	block_color_table.resize(BlockRegistry.TABLE_SIZE)
	block_ramp_table.resize(BlockRegistry.TABLE_SIZE)
	for i in range(BlockRegistry.TABLE_SIZE):
		block_solid_table[i] = 1 if world.is_block_solid_id(i) else 0
		block_color_table[i] = world.get_block_color(i)
		block_ramp_table[i] = 1 if world.is_ramp_block_id(i) else 0


func _clear_mesh_jobs() -> void:
	mesh_job_mutex.lock()
	mesh_job_queue.clear()
	mesh_job_mutex.unlock()
	mesh_result_mutex.lock()
	mesh_result_queue.clear()
	mesh_result_mutex.unlock()
	mesh_job_set.clear()
	mesh_prefetch_set.clear()
#endregion


#region Render Height Queue
func queue_render_height_update(old_y: int, new_y: int, anchor: Vector3, min_x: int, max_x: int, min_z: int, max_z: int) -> int:
	if world == null:
		return 0
	var chunk_size: int = World.CHUNK_SIZE
	var min_y: int = min(old_y, new_y)
	var max_y: int = max(old_y, new_y)
	var max_cy: int = int(floor(float(world.world_size_y) / float(chunk_size))) - 1
	var min_cy: int = clampi(int(floor(float(min_y) / float(chunk_size))), 0, max_cy)
	var max_cy_clamped: int = clampi(int(floor(float(max_y) / float(chunk_size))), 0, max_cy)
	_hide_chunks_outside_bounds(min_cy, max_cy_clamped, min_x, max_x, min_z, max_z)
	return _queue_render_height_rebuild(min_cy, max_cy_clamped, min_x, max_x, min_z, max_z, anchor, new_y)


func process_render_height_queue(budget: int) -> int:
	if budget <= 0:
		return 0
	var build_count: int = min(budget, render_height_queue.size())
	for _i in range(build_count):
		var coord: Vector3i = render_height_queue.pop_front()
		render_height_queue_set.erase(coord)
		queue_chunk_mesh_build(coord, render_height_target_y, true)
	return build_count


func clear_render_height_queue() -> void:
	render_height_queue.clear()
	render_height_queue_set.clear()


func has_pending_render_height_work() -> bool:
	if render_height_queue.size() > 0:
		return true
	if mesh_job_set.size() > 0:
		return true
	if _has_non_prefetch_jobs():
		return true
	if _has_non_prefetch_results():
		return true
	return false


func has_pending_mesh_work(include_prefetch: bool) -> bool:
	if mesh_job_set.size() > 0:
		return true
	if include_prefetch and mesh_prefetch_set.size() > 0:
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
	mesh_job_mutex.lock()
	for job in mesh_job_queue:
		if not bool(job.get("prefetch", false)):
			mesh_job_mutex.unlock()
			return true
	mesh_job_mutex.unlock()
	return false


func _has_non_prefetch_results() -> bool:
	mesh_result_mutex.lock()
	for result in mesh_result_queue:
		if not bool(result.get("prefetch", false)):
			mesh_result_mutex.unlock()
			return true
	mesh_result_mutex.unlock()
	return false


func _has_any_jobs() -> bool:
	var pending := false
	mesh_job_mutex.lock()
	pending = mesh_job_queue.size() > 0
	mesh_job_mutex.unlock()
	return pending


func _has_any_results() -> bool:
	var pending := false
	mesh_result_mutex.lock()
	pending = mesh_result_queue.size() > 0
	mesh_result_mutex.unlock()
	return pending


func _queue_render_height_rebuild(min_cy: int, max_cy: int, min_x: int, max_x: int, min_z: int, max_z: int, anchor: Vector3, target_top_y: int) -> int:
	render_height_queue.clear()
	render_height_queue_set.clear()
	render_height_anchor = anchor
	render_height_target_y = target_top_y
	var chunk_size: int = World.CHUNK_SIZE
	var anchor_x: float = anchor.x
	var anchor_z: float = anchor.z
	var candidates: Array = []
	for key in chunk_cache.get_keys():
		var coord: Vector3i = key
		if coord.y < min_cy or coord.y > max_cy:
			continue
		if coord.x < min_x or coord.x > max_x:
			continue
		if coord.z < min_z or coord.z > max_z:
			continue
		var local_top := target_top_y - coord.y * chunk_size
		if local_top < 0:
			_apply_empty_mesh(coord)
			continue
		local_top = min(local_top, chunk_size - 1)
		if _apply_cached_mesh(coord, local_top):
			continue
		_hide_chunk_mesh(coord)
		var center_x := (float(coord.x) + 0.5) * chunk_size
		var center_z := (float(coord.z) + 0.5) * chunk_size
		var dx := center_x - anchor_x
		var dz := center_z - anchor_z
		var dist := dx * dx + dz * dz
		candidates.append({"key": coord, "dist": dist})
	candidates.sort_custom(Callable(self, "_sort_render_height_candidate"))
	for entry in candidates:
		var coord: Vector3i = entry["key"]
		render_height_queue.append(coord)
		render_height_queue_set[coord] = true
	return render_height_queue.size()


func _sort_render_height_candidate(a: Dictionary, b: Dictionary) -> bool:
	return float(a["dist"]) < float(b["dist"])


func update_render_height_anchor(anchor: Vector3) -> void:
	if render_height_queue.is_empty():
		return
	var dx := anchor.x - render_height_anchor.x
	var dz := anchor.z - render_height_anchor.z
	var threshold := float(World.CHUNK_SIZE * World.CHUNK_SIZE)
	if dx * dx + dz * dz < threshold:
		return
	render_height_anchor = anchor
	render_height_queue.sort_custom(Callable(self, "_sort_render_height_coord"))


func _sort_render_height_coord(a: Vector3i, b: Vector3i) -> bool:
	return _render_height_coord_dist_sq(a) < _render_height_coord_dist_sq(b)


func _render_height_coord_dist_sq(coord: Vector3i) -> float:
	var chunk_size := World.CHUNK_SIZE
	var center_x := (float(coord.x) + 0.5) * chunk_size
	var center_z := (float(coord.z) + 0.5) * chunk_size
	var dx := center_x - render_height_anchor.x
	var dz := center_z - render_height_anchor.z
	return dx * dx + dz * dz


func _hide_chunks_outside_bounds(min_cy: int, max_cy: int, min_x: int, max_x: int, min_z: int, max_z: int) -> void:
	for key in chunk_cache.get_keys():
		var coord: Vector3i = key
		if coord.y < min_cy or coord.y > max_cy:
			continue
		if coord.x >= min_x and coord.x <= max_x and coord.z >= min_z and coord.z <= max_z:
			continue
		_hide_chunk_mesh(coord)
#endregion


#region Mesh Cache
func invalidate_chunk_mesh_cache(coord: Vector3i) -> void:
	if chunk_mesh_cache.has(coord):
		chunk_mesh_cache.erase(coord)


func _get_chunk_mesh_cache(coord: Vector3i) -> Dictionary:
	if chunk_mesh_cache.has(coord):
		return chunk_mesh_cache[coord]
	var entry: Dictionary = {}
	chunk_mesh_cache[coord] = entry
	return entry


func _store_mesh_cache(coord: Vector3i, local_top: int, mesh: ArrayMesh, visible_faces: int, occluded_faces: int, has_geometry: bool, revision: int) -> void:
	if local_top < 0:
		return
	var entry := {
		"mesh": mesh,
		"visible_faces": visible_faces,
		"occluded_faces": occluded_faces,
		"has_geometry": has_geometry,
		"revision": revision,
	}
	var cache := _get_chunk_mesh_cache(coord)
	cache[local_top] = entry


func _has_cached_mesh(coord: Vector3i, local_top: int) -> bool:
	if world == null:
		return false
	if local_top < 0:
		return false
	if not chunk_mesh_cache.has(coord):
		return false
	var cache: Dictionary = chunk_mesh_cache[coord]
	if not cache.has(local_top):
		return false
	var entry: Dictionary = cache[local_top]
	var chunk: ChunkData = world.get_chunk(coord)
	if chunk == null:
		return false
	if int(entry.get("revision", -1)) != chunk.mesh_revision:
		cache.erase(local_top)
		return false
	return true


func _apply_cached_mesh(coord: Vector3i, local_top: int) -> bool:
	if local_top < 0:
		return false
	if not chunk_mesh_cache.has(coord):
		return false
	var cache: Dictionary = chunk_mesh_cache[coord]
	if not cache.has(local_top):
		return false
	var entry: Dictionary = cache[local_top]
	var chunk: ChunkData = world.get_chunk(coord)
	if chunk == null:
		return false
	if int(entry.get("revision", -1)) != chunk.mesh_revision:
		cache.erase(local_top)
		return false
	_apply_mesh_entry(coord, entry, chunk)
	_queue_prefetch_layers(coord, local_top)
	return true


func _apply_mesh_entry(coord: Vector3i, entry: Dictionary, chunk: ChunkData) -> void:
	var mesh: ArrayMesh = entry["mesh"]
	var visible_faces: int = int(entry["visible_faces"])
	var occluded_faces: int = int(entry["occluded_faces"])
	var has_geometry: bool = bool(entry["has_geometry"])
	var mesh_instance: MeshInstance3D = chunk_cache.ensure_chunk(coord, World.CHUNK_SIZE)
	var prev_counts: Vector2i = chunk_face_stats.get(coord, Vector2i(0, 0))
	total_visible_faces += visible_faces - prev_counts.x
	total_occluded_faces += occluded_faces - prev_counts.y
	chunk_face_stats[coord] = Vector2i(visible_faces, occluded_faces)
	mesh_instance.mesh = mesh
	mesh_instance.visible = has_geometry and _is_chunk_in_current_render_zone(coord)
	if has_geometry:
		mesh_instance.material_override = get_block_material()
	chunk.mesh_state = ChunkData.MESH_STATE_READY
	chunk.dirty = false


func _apply_empty_mesh(coord: Vector3i) -> void:
	var mesh_instance: MeshInstance3D = chunk_cache.get_chunk(coord)
	if mesh_instance == null:
		return
	var prev_counts: Vector2i = chunk_face_stats.get(coord, Vector2i(0, 0))
	total_visible_faces -= prev_counts.x
	total_occluded_faces -= prev_counts.y
	chunk_face_stats[coord] = Vector2i(0, 0)
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


func _set_chunk_visibility(coord: Vector3i, visible: bool) -> void:
	var mesh_instance: MeshInstance3D = chunk_cache.get_chunk(coord)
	if mesh_instance == null:
		return
	if not visible:
		mesh_instance.visible = false
		return
	if mesh_instance.mesh == null:
		mesh_instance.visible = false
		return
	mesh_instance.visible = true
#endregion


#region Materials
func get_block_material() -> Material:
	if block_material == null:
		var shader_material := ShaderMaterial.new()
		shader_material.shader = BlockTerrainDebugShader if debug_normals_enabled else BlockTerrainShader
		shader_material.set_shader_parameter("atlas_texture", _get_block_atlas_texture())
		if world != null:
			shader_material.set_shader_parameter("top_render_y", float(world.top_render_y))
		block_material = shader_material
	return block_material


func _get_block_atlas_texture() -> Texture2D:
	if block_atlas_texture != null:
		return block_atlas_texture
	var image := Image.new()
	var err := image.load(BLOCK_ATLAS_PATH)
	if err != OK:
		push_warning("Block atlas load failed: %s (%d)" % [BLOCK_ATLAS_PATH, err])
		return null
	block_atlas_texture = ImageTexture.create_from_image(image)
	return block_atlas_texture


func set_top_render_y(value: int) -> void:
	var mat := get_block_material()
	if mat is ShaderMaterial:
		var shader_material := mat as ShaderMaterial
		shader_material.set_shader_parameter("top_render_y", float(value))
	if overlay_renderer != null:
		overlay_renderer.set_top_render_y(value)


func toggle_debug_normals() -> void:
	debug_normals_enabled = not debug_normals_enabled
	var mat := get_block_material()
	if mat is ShaderMaterial:
		var shader_material := mat as ShaderMaterial
		shader_material.shader = BlockTerrainDebugShader if debug_normals_enabled else BlockTerrainShader
		if world != null:
			shader_material.set_shader_parameter("top_render_y", float(world.top_render_y))
#endregion


#region Stats
func get_draw_burden_stats() -> Dictionary:
	var drawn_tris: int = total_visible_faces * TRIS_PER_FACE
	var culled_tris: int = total_occluded_faces * TRIS_PER_FACE
	var total_tris: int = drawn_tris + culled_tris
	var percent: float = 0.0
	if total_tris > 0:
		percent = float(drawn_tris) / float(total_tris) * PERCENT_FACTOR
	return {"drawn": drawn_tris, "culled": culled_tris, "percent": percent}


func get_chunk_draw_stats() -> Dictionary:
	var loaded := 0
	if world != null:
		loaded = world.chunks.size()
	var keys: Array = chunk_cache.get_keys()
	var meshed: int = keys.size()
	var visible: int = 0
	for key in keys:
		var mesh_instance: MeshInstance3D = chunk_cache.get_chunk(key)
		if mesh_instance == null:
			continue
		if mesh_instance.mesh == null:
			continue
		if mesh_instance.visible:
			visible += 1
	var zone: int = render_zone_visible.size()
	return {"loaded": loaded, "meshed": meshed, "visible": visible, "zone": zone}


func get_mesh_work_stats() -> Dictionary:
	var job_queue := 0
	var result_queue := 0
	mesh_job_mutex.lock()
	job_queue = mesh_job_queue.size()
	mesh_job_mutex.unlock()
	mesh_result_mutex.lock()
	result_queue = mesh_result_queue.size()
	mesh_result_mutex.unlock()
	return {
		"job_queue": job_queue,
		"result_queue": result_queue,
		"job_set": mesh_job_set.size(),
		"prefetch_set": mesh_prefetch_set.size(),
	}


func get_camera_tris_rendered(camera: Camera3D) -> Dictionary:
	if camera == null:
		return {"rendered": 0, "total": 0, "percent": 0.0}
	var frustum: Array = camera.get_frustum()
	var near_sample: float = max(camera.near + NEAR_SAMPLE_OFFSET, NEAR_SAMPLE_MIN)
	var inside_point: Vector3 = camera.global_transform.origin + (-camera.global_transform.basis.z) * near_sample
	var planes: Array = []
	for plane in frustum:
		var p: Plane = plane
		var inside_positive: bool = p.distance_to(inside_point) >= 0.0
		planes.append({"plane": p, "inside_positive": inside_positive})
	var rendered_faces := 0
	for key in chunk_face_stats.keys():
		var counts: Vector2i = chunk_face_stats[key]
		if counts.x == 0:
			continue
		if is_chunk_in_view(planes, key):
			rendered_faces += counts.x
	var rendered_tris: int = rendered_faces * TRIS_PER_FACE
	var total_tris: int = total_visible_faces * TRIS_PER_FACE
	var percent := 0.0
	if total_tris > 0:
		percent = float(rendered_tris) / float(total_tris) * PERCENT_FACTOR
	return {"rendered": rendered_tris, "total": total_tris, "percent": percent}


func is_chunk_in_view(planes: Array, key: Vector3i) -> bool:
	var chunk_size: int = World.CHUNK_SIZE
	var min_corner := Vector3(
		key.x * chunk_size,
		key.y * chunk_size,
		key.z * chunk_size
	)
	var max_corner := min_corner + Vector3(chunk_size, chunk_size, chunk_size)
	for entry in planes:
		var p: Plane = entry["plane"]
		var inside_positive: bool = entry["inside_positive"]
		var v: Vector3
		if inside_positive:
			v = Vector3(
				max_corner.x if p.normal.x >= 0.0 else min_corner.x,
				max_corner.y if p.normal.y >= 0.0 else min_corner.y,
				max_corner.z if p.normal.z >= 0.0 else min_corner.z
			)
			if p.distance_to(v) < 0.0:
				return false
		else:
			v = Vector3(
				min_corner.x if p.normal.x >= 0.0 else max_corner.x,
				min_corner.y if p.normal.y >= 0.0 else max_corner.y,
				min_corner.z if p.normal.z >= 0.0 else max_corner.z
			)
			if p.distance_to(v) > 0.0:
				return false
	return true
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
