extends Node3D
class_name WorldRenderer
## Main renderer for voxel world chunks, overlays, and stats tracking.

#region Preloads
const ChunkMesherScript = preload("res://scripts/rendering/chunk_mesher.gd")
const ChunkCacheScript = preload("res://scripts/rendering/chunk_cache.gd")
const OverlayRendererScript = preload("res://scripts/rendering/overlay_renderer.gd")
#endregion

#region Constants
const TRIS_PER_FACE := 2
const PERCENT_FACTOR := 100.0
const NEAR_SAMPLE_OFFSET := 0.1
const NEAR_SAMPLE_MIN := 0.1
const MESH_BUILD_LOG_THRESHOLD_MS := 5.0
const MESH_APPLY_BUDGET := 8
#endregion

#region State
var world: World
var mesher = ChunkMesherScript.new()
var mesher_thread = ChunkMesherScript.new()
var chunk_cache = ChunkCacheScript.new()
var overlay_renderer = OverlayRendererScript.new()
var block_material: StandardMaterial3D
var chunk_face_stats: Dictionary = {}
var total_visible_faces: int = 0
var total_occluded_faces: int = 0
var render_height_queue: Array = []
var render_height_queue_set: Dictionary = {}
var render_height_anchor := Vector3.ZERO
var use_async_meshing: bool = true
var mesh_thread: Thread
var mesh_thread_running: bool = false
var mesh_job_queue: Array = []
var mesh_job_set: Dictionary = {}
var mesh_job_mutex := Mutex.new()
var mesh_job_semaphore := Semaphore.new()
var mesh_result_queue: Array = []
var mesh_result_mutex := Mutex.new()
var block_solid_table := PackedByteArray()
var block_color_table := PackedColorArray()
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
	_clear_mesh_jobs()
	if world == null:
		return
	for chunk in world.chunks.values():
		var entry: ChunkData = chunk
		entry.mesh_state = ChunkData.MESH_STATE_NONE
#endregion


#region Chunk Building
func build_all_chunks() -> void:
	if world == null:
		return
	var chunk_size: int = World.CHUNK_SIZE
	var chunks_x: int = int(floor(float(world.world_size_x) / float(chunk_size)))
	var chunks_y: int = int(floor(float(world.world_size_y) / float(chunk_size)))
	var chunks_z: int = int(floor(float(world.world_size_z) / float(chunk_size)))
	for cx in range(chunks_x):
		for cy in range(chunks_y):
			for cz in range(chunks_z):
				regenerate_chunk(cx, cy, cz)


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
	mesh_instance.visible = true
	if has_geometry:
		mesh_instance.material_override = get_block_material()
	var chunk: ChunkData = world.get_chunk(key)
	if chunk != null:
		chunk.mesh_state = ChunkData.MESH_STATE_READY
		chunk.dirty = false
#endregion


#region Async Meshing
func queue_chunk_mesh_build(coord: Vector3i, top_render_y: int = -1) -> void:
	if world == null:
		return
	_ensure_block_tables()
	if not use_async_meshing:
		regenerate_chunk(coord.x, coord.y, coord.z)
		return
	if not mesh_thread_running:
		_start_mesh_worker()
	var chunk: ChunkData = world.ensure_chunk_generated(coord)
	if chunk == null:
		return
	var revision: int = chunk.mesh_revision
	var queued_rev: int = int(mesh_job_set.get(coord, -1))
	if queued_rev >= revision and chunk.mesh_state == ChunkData.MESH_STATE_PENDING:
		return
	chunk.mesh_state = ChunkData.MESH_STATE_PENDING
	var job := _build_mesh_job(coord, revision, top_render_y)
	if job.is_empty():
		return
	mesh_job_set[coord] = revision
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


func _apply_mesh_result(result: Dictionary) -> bool:
	if world == null:
		return false
	var coord: Vector3i = result["coord"]
	var chunk: ChunkData = world.get_chunk(coord)
	if chunk == null:
		_clear_mesh_job_record(coord, int(result.get("mesh_revision", -1)))
		return false
	var revision: int = int(result.get("mesh_revision", -1))
	if revision != chunk.mesh_revision:
		if chunk.mesh_state == ChunkData.MESH_STATE_PENDING:
			chunk.mesh_state = ChunkData.MESH_STATE_NONE
		_clear_mesh_job_record(coord, revision)
		return false
	var vertices: PackedVector3Array = result["vertices"]
	var normals: PackedVector3Array = result["normals"]
	var colors: PackedColorArray = result["colors"]
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
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)

	var mesh_instance: MeshInstance3D = chunk_cache.ensure_chunk(coord, World.CHUNK_SIZE)
	var prev_counts: Vector2i = chunk_face_stats.get(coord, Vector2i(0, 0))
	total_visible_faces += visible_faces - prev_counts.x
	total_occluded_faces += occluded_faces - prev_counts.y
	chunk_face_stats[coord] = Vector2i(visible_faces, occluded_faces)
	mesh_instance.mesh = mesh
	mesh_instance.visible = true
	if has_geometry:
		mesh_instance.material_override = get_block_material()
	chunk.mesh_state = ChunkData.MESH_STATE_READY
	chunk.dirty = false

	var build_ms := float(result.get("build_ms", 0.0))
	if build_ms > 0.0 and world.debug_profiler != null:
		world.debug_profiler.add_sample("Renderer.build_chunk_mesh", build_ms)
		if build_ms >= MESH_BUILD_LOG_THRESHOLD_MS:
			print("Chunk mesh build %d,%d,%d: %.2f ms" % [coord.x, coord.y, coord.z, build_ms])
	_clear_mesh_job_record(coord, revision)
	return true


func _clear_mesh_job_record(coord: Vector3i, revision: int) -> void:
	if not mesh_job_set.has(coord):
		return
	var queued_rev: int = int(mesh_job_set.get(coord, -1))
	if queued_rev <= revision:
		mesh_job_set.erase(coord)


func _build_mesh_job(coord: Vector3i, revision: int, top_render_y: int) -> Dictionary:
	if world == null:
		return {}
	var chunk: ChunkData = world.get_chunk(coord)
	if chunk == null:
		return {}
	if top_render_y < 0:
		top_render_y = world.top_render_y
	var neighbors := {
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
		"color_table": block_color_table,
		"mesh_revision": revision,
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
	if block_solid_table.size() == BlockRegistry.TABLE_SIZE and block_color_table.size() == BlockRegistry.TABLE_SIZE:
		return
	block_solid_table.resize(BlockRegistry.TABLE_SIZE)
	block_color_table.resize(BlockRegistry.TABLE_SIZE)
	for i in range(BlockRegistry.TABLE_SIZE):
		block_solid_table[i] = 1 if world.is_block_solid_id(i) else 0
		block_color_table[i] = world.get_block_color(i)


func _clear_mesh_jobs() -> void:
	mesh_job_mutex.lock()
	mesh_job_queue.clear()
	mesh_job_mutex.unlock()
	mesh_result_mutex.lock()
	mesh_result_queue.clear()
	mesh_result_mutex.unlock()
	mesh_job_set.clear()
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
	_invalidate_render_height_layers(min_cy, max_cy_clamped)
	return _queue_render_height_rebuild(min_cy, max_cy_clamped, min_x, max_x, min_z, max_z, anchor)


func process_render_height_queue(budget: int) -> int:
	if budget <= 0:
		return 0
	var build_count: int = min(budget, render_height_queue.size())
	for _i in range(build_count):
		var coord: Vector3i = render_height_queue.pop_front()
		render_height_queue_set.erase(coord)
		queue_chunk_mesh_build(coord)
	return build_count


func has_pending_render_height_work() -> bool:
	if render_height_queue.size() > 0:
		return true
	var pending_jobs := false
	mesh_job_mutex.lock()
	pending_jobs = mesh_job_queue.size() > 0
	mesh_job_mutex.unlock()
	if pending_jobs:
		return true
	var pending_results := false
	mesh_result_mutex.lock()
	pending_results = mesh_result_queue.size() > 0
	mesh_result_mutex.unlock()
	if pending_results:
		return true
	return mesh_job_set.size() > 0


func _queue_render_height_rebuild(min_cy: int, max_cy: int, min_x: int, max_x: int, min_z: int, max_z: int, anchor: Vector3) -> int:
	render_height_queue.clear()
	render_height_queue_set.clear()
	render_height_anchor = anchor
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


func _invalidate_render_height_layers(min_cy: int, max_cy: int) -> void:
	if world == null:
		return
	for coord in world.chunks.keys():
		var key: Vector3i = coord
		if key.y < min_cy or key.y > max_cy:
			continue
		var chunk: ChunkData = world.chunks[key]
		chunk.mesh_state = ChunkData.MESH_STATE_NONE
		chunk.mesh_revision += 1
		var mesh_instance := chunk_cache.get_chunk(key)
		if mesh_instance != null:
			mesh_instance.visible = false


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
#endregion


#region Materials
func get_block_material() -> StandardMaterial3D:
	if block_material == null:
		block_material = StandardMaterial3D.new()
		block_material.vertex_color_use_as_albedo = true
	return block_material
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
	var chunk_size: int = World.CHUNK_SIZE
	var max_cx: int = int(floor(float(world.world_size_x) / float(chunk_size))) - 1
	var max_cz: int = int(floor(float(world.world_size_z) / float(chunk_size))) - 1
	var anchor := Vector3(world.world_size_x * 0.5, float(world.top_render_y), world.world_size_z * 0.5)
	return queue_render_height_update(old_y, new_y, anchor, 0, max_cx, 0, max_cz)

func update_render_height_in_range(old_y: int, new_y: int, min_x: int, max_x: int, min_z: int, max_z: int) -> int:
	if world == null:
		return 0
	if min_x > max_x or min_z > max_z:
		return 0
	var anchor := Vector3(world.world_size_x * 0.5, float(world.top_render_y), world.world_size_z * 0.5)
	return queue_render_height_update(old_y, new_y, anchor, min_x, max_x, min_z, max_z)
#endregion


#region Chunk Queries
func is_chunk_built(coord: Vector3i) -> bool:
	return chunk_cache.is_chunk_built(coord)
#endregion
