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
#endregion

#region State
var world: World
var mesher = ChunkMesherScript.new()
var chunk_cache = ChunkCacheScript.new()
var overlay_renderer = OverlayRendererScript.new()
var block_material: StandardMaterial3D
var chunk_face_stats: Dictionary = {}
var total_visible_faces: int = 0
var total_occluded_faces: int = 0
var render_height_queue: Array = []
var render_height_queue_set: Dictionary = {}
#endregion


#region Initialization
func initialize(world_ref: World) -> void:
	world = world_ref
	if chunk_cache.get_parent() == null:
		add_child(chunk_cache)
	if overlay_renderer.get_parent() == null:
		add_child(overlay_renderer)
	overlay_renderer.initialize(world_ref)
#endregion


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
	if has_geometry:
		mesh_instance.material_override = get_block_material()
	var chunk: ChunkData = world.get_chunk(key)
	if chunk != null:
		chunk.mesh_state = ChunkData.MESH_STATE_READY
		chunk.dirty = false
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
		regenerate_chunk(coord.x, coord.y, coord.z)
	return build_count


func _queue_render_height_rebuild(min_cy: int, max_cy: int, min_x: int, max_x: int, min_z: int, max_z: int, anchor: Vector3) -> int:
	render_height_queue.clear()
	render_height_queue_set.clear()
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
