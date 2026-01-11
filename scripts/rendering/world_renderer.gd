extends Node3D
class_name WorldRenderer

const ChunkMesherScript = preload("res://scripts/rendering/chunk_mesher.gd")
const ChunkCacheScript = preload("res://scripts/rendering/chunk_cache.gd")
const OverlayRendererScript = preload("res://scripts/rendering/overlay_renderer.gd")

const TRIS_PER_FACE := 2
const PERCENT_FACTOR := 100.0
const NEAR_SAMPLE_OFFSET := 0.1
const NEAR_SAMPLE_MIN := 0.1

var world: World
var mesher = ChunkMesherScript.new()
var chunk_cache = ChunkCacheScript.new()
var overlay_renderer = OverlayRendererScript.new()
var block_material: StandardMaterial3D
var chunk_face_stats: Dictionary = {}
var total_visible_faces: int = 0
var total_occluded_faces: int = 0


func initialize(world_ref: World) -> void:
	world = world_ref
	if chunk_cache.get_parent() == null:
		add_child(chunk_cache)
	if overlay_renderer.get_parent() == null:
		add_child(overlay_renderer)
	overlay_renderer.initialize(world_ref)


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

	var result: Dictionary = mesher.build_chunk_mesh(world, cx, cy, cz)
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


func get_block_material() -> StandardMaterial3D:
	if block_material == null:
		block_material = StandardMaterial3D.new()
		block_material.vertex_color_use_as_albedo = true
	return block_material


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


func update_render_height(old_y: int, new_y: int) -> void:
	if world == null:
		return
	var chunk_size: int = World.CHUNK_SIZE
	var min_y: int = min(old_y, new_y)
	var max_y: int = max(old_y, new_y)
	var max_cy: int = int(floor(float(world.world_size_y) / float(chunk_size))) - 1
	var min_cy: int = clampi(int(floor(float(min_y) / float(chunk_size))), 0, max_cy)
	var max_cy_clamped: int = clampi(int(floor(float(max_y) / float(chunk_size))), 0, max_cy)
	for key in chunk_cache.get_keys():
		var coord: Vector3i = key
		if coord.y < min_cy or coord.y > max_cy_clamped:
			continue
		regenerate_chunk(coord.x, coord.y, coord.z)

func update_render_height_in_range(old_y: int, new_y: int, min_x: int, max_x: int, min_z: int, max_z: int) -> void:
	if world == null:
		return
	if min_x > max_x or min_z > max_z:
		return
	var chunk_size: int = World.CHUNK_SIZE
	var min_y: int = min(old_y, new_y)
	var max_y: int = max(old_y, new_y)
	var max_cy: int = int(floor(float(world.world_size_y) / float(chunk_size))) - 1
	var min_cy: int = clampi(int(floor(float(min_y) / float(chunk_size))), 0, max_cy)
	var max_cy_clamped: int = clampi(int(floor(float(max_y) / float(chunk_size))), 0, max_cy)
	for key in chunk_cache.get_keys():
		var coord: Vector3i = key
		if coord.y < min_cy or coord.y > max_cy_clamped:
			continue
		if coord.x < min_x or coord.x > max_x:
			continue
		if coord.z < min_z or coord.z > max_z:
			continue
		regenerate_chunk(coord.x, coord.y, coord.z)

func is_chunk_built(coord: Vector3i) -> bool:
	return chunk_cache.is_chunk_built(coord)
