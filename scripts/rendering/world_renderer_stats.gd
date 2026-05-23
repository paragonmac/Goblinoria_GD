extends RefCounted
class_name WorldRendererStats

const TRIS_PER_FACE := 2
const PERCENT_FACTOR := 100.0

var chunk_face_stats: Dictionary = {}
var chunk_mesh_stats: Dictionary = {}
var total_visible_faces: int = 0
var total_occluded_faces: int = 0
var total_mesh_vertices: int = 0
var total_mesh_triangles: int = 0
var total_greedy_visible_faces: int = 0
var total_greedy_occluded_faces: int = 0
var total_greedy_source_visible_faces: int = 0
var total_ramp_visible_faces: int = 0
var total_ramp_occluded_faces: int = 0


func clear_all() -> void:
	chunk_face_stats.clear()
	chunk_mesh_stats.clear()
	total_visible_faces = 0
	total_occluded_faces = 0
	total_mesh_vertices = 0
	total_mesh_triangles = 0
	total_greedy_visible_faces = 0
	total_greedy_occluded_faces = 0
	total_greedy_source_visible_faces = 0
	total_ramp_visible_faces = 0
	total_ramp_occluded_faces = 0


func clear_chunk(coord: Vector3i) -> void:
	if chunk_face_stats.has(coord):
		var prev_counts: Vector2i = chunk_face_stats[coord]
		total_visible_faces -= prev_counts.x
		total_occluded_faces -= prev_counts.y
		chunk_face_stats.erase(coord)
	if chunk_mesh_stats.has(coord):
		var prev_value: Variant = chunk_mesh_stats[coord]
		if typeof(prev_value) == TYPE_DICTIONARY:
			var prev_stats: Dictionary = prev_value
			total_mesh_vertices -= int(prev_stats.get("vertices", 0))
			total_mesh_triangles -= int(prev_stats.get("triangles", 0))
			total_greedy_visible_faces -= int(prev_stats.get("greedy_visible_faces", 0))
			total_greedy_occluded_faces -= int(prev_stats.get("greedy_occluded_faces", 0))
			total_greedy_source_visible_faces -= int(prev_stats.get("greedy_source_visible_faces", 0))
			total_ramp_visible_faces -= int(prev_stats.get("ramp_visible_faces", 0))
			total_ramp_occluded_faces -= int(prev_stats.get("ramp_occluded_faces", 0))
		chunk_mesh_stats.erase(coord)


func record_chunk_render_stats(coord: Vector3i, visible_faces: int, occluded_faces: int, mesh_metrics: Dictionary) -> void:
	var prev_counts: Vector2i = chunk_face_stats.get(coord, Vector2i(0, 0))
	total_visible_faces += visible_faces - prev_counts.x
	total_occluded_faces += occluded_faces - prev_counts.y
	chunk_face_stats[coord] = Vector2i(visible_faces, occluded_faces)

	var metrics: Dictionary = normalize_mesh_metrics(mesh_metrics, null)
	var prev_stats: Dictionary = {}
	var prev_value: Variant = chunk_mesh_stats.get(coord, {})
	if typeof(prev_value) == TYPE_DICTIONARY:
		prev_stats = prev_value
	total_mesh_vertices += int(metrics.get("vertices", 0)) - int(prev_stats.get("vertices", 0))
	total_mesh_triangles += int(metrics.get("triangles", 0)) - int(prev_stats.get("triangles", 0))
	total_greedy_visible_faces += int(metrics.get("greedy_visible_faces", 0)) - int(prev_stats.get("greedy_visible_faces", 0))
	total_greedy_occluded_faces += int(metrics.get("greedy_occluded_faces", 0)) - int(prev_stats.get("greedy_occluded_faces", 0))
	total_greedy_source_visible_faces += int(metrics.get("greedy_source_visible_faces", 0)) - int(prev_stats.get("greedy_source_visible_faces", 0))
	total_ramp_visible_faces += int(metrics.get("ramp_visible_faces", 0)) - int(prev_stats.get("ramp_visible_faces", 0))
	total_ramp_occluded_faces += int(metrics.get("ramp_occluded_faces", 0)) - int(prev_stats.get("ramp_occluded_faces", 0))
	chunk_mesh_stats[coord] = metrics


func mesh_metrics_from_result(result: Dictionary, mesh_value: Variant) -> Dictionary:
	return normalize_mesh_metrics({
		"vertices": int(result.get("vertex_count", -1)),
		"triangles": int(result.get("triangle_count", -1)),
		"greedy_visible_faces": int(result.get("greedy_visible_faces", 0)),
		"greedy_occluded_faces": int(result.get("greedy_occluded_faces", 0)),
		"greedy_source_visible_faces": int(result.get("greedy_source_visible_faces", result.get("greedy_visible_faces", 0))),
		"ramp_visible_faces": int(result.get("ramp_visible_faces", 0)),
		"ramp_occluded_faces": int(result.get("ramp_occluded_faces", 0)),
	}, mesh_value)


func mesh_metrics_from_entry(entry: Dictionary, mesh_value: Variant) -> Dictionary:
	var metrics_value: Variant = entry.get("metrics", {})
	if typeof(metrics_value) == TYPE_DICTIONARY:
		var metrics: Dictionary = metrics_value
		return normalize_mesh_metrics(metrics, mesh_value)
	return normalize_mesh_metrics({}, mesh_value)


func normalize_mesh_metrics(metrics: Dictionary, mesh_value: Variant) -> Dictionary:
	var vertex_count := int(metrics.get("vertices", metrics.get("vertex_count", -1)))
	if vertex_count < 0:
		vertex_count = _get_mesh_vertex_count(mesh_value)
	var triangle_count := int(metrics.get("triangles", metrics.get("triangle_count", -1)))
	if triangle_count < 0:
		triangle_count = _get_mesh_triangle_count(mesh_value)
		if triangle_count <= 0 and vertex_count > 0:
			triangle_count = int(vertex_count / 3)
	var greedy_visible_faces := int(metrics.get("greedy_visible_faces", metrics.get("greedy_visible", 0)))
	var greedy_occluded_faces := int(metrics.get("greedy_occluded_faces", metrics.get("greedy_occluded", 0)))
	var greedy_source_visible_faces := int(metrics.get("greedy_source_visible_faces", metrics.get("greedy_source_visible", greedy_visible_faces)))
	var ramp_visible_faces := int(metrics.get("ramp_visible_faces", metrics.get("ramp_visible", 0)))
	var ramp_occluded_faces := int(metrics.get("ramp_occluded_faces", metrics.get("ramp_occluded", 0)))
	return {
		"vertices": max(0, vertex_count),
		"triangles": max(0, triangle_count),
		"greedy_visible_faces": max(0, greedy_visible_faces),
		"greedy_occluded_faces": max(0, greedy_occluded_faces),
		"greedy_source_visible_faces": max(0, greedy_source_visible_faces),
		"ramp_visible_faces": max(0, ramp_visible_faces),
		"ramp_occluded_faces": max(0, ramp_occluded_faces),
	}


func get_draw_burden_stats() -> Dictionary:
	var drawn_tris: int = total_visible_faces * TRIS_PER_FACE
	var culled_tris: int = total_occluded_faces * TRIS_PER_FACE
	var total_tris: int = drawn_tris + culled_tris
	var percent: float = 0.0
	if total_tris > 0:
		percent = float(drawn_tris) / float(total_tris) * PERCENT_FACTOR
	return {"drawn": drawn_tris, "culled": culled_tris, "percent": percent}


func get_mesh_work_stats() -> Dictionary:
	var greedy_saved_faces := int(max(0, total_greedy_source_visible_faces - total_greedy_visible_faces))
	var greedy_reduction_percent := 0.0
	if total_greedy_source_visible_faces > 0:
		greedy_reduction_percent = float(greedy_saved_faces) / float(total_greedy_source_visible_faces) * PERCENT_FACTOR
	return {
		"vertices": total_mesh_vertices,
		"triangles": total_mesh_triangles,
		"visible_faces": total_visible_faces,
		"occluded_faces": total_occluded_faces,
		"greedy_visible_faces": total_greedy_visible_faces,
		"greedy_occluded_faces": total_greedy_occluded_faces,
		"greedy_source_visible_faces": total_greedy_source_visible_faces,
		"greedy_saved_faces": greedy_saved_faces,
		"greedy_reduction_percent": greedy_reduction_percent,
		"ramp_visible_faces": total_ramp_visible_faces,
		"ramp_occluded_faces": total_ramp_occluded_faces,
	}


func get_camera_tris_rendered(camera: Camera3D, frustum_culler: FrustumCuller, chunk_size: int, near_sample_offset: float, near_sample_min: float) -> Dictionary:
	if camera == null:
		return {"rendered": 0, "total": 0, "percent": 0.0}
	var planes: Array = []
	if frustum_culler != null:
		planes = frustum_culler.build_planes(camera, near_sample_offset, near_sample_min)
	var rendered_faces := 0
	for key in chunk_face_stats.keys():
		var counts: Vector2i = chunk_face_stats[key]
		if counts.x == 0:
			continue
		if frustum_culler != null and frustum_culler.is_chunk_in_view(planes, key, chunk_size):
			rendered_faces += counts.x
	var rendered_tris: int = rendered_faces * TRIS_PER_FACE
	var total_tris: int = total_visible_faces * TRIS_PER_FACE
	var percent := 0.0
	if total_tris > 0:
		percent = float(rendered_tris) / float(total_tris) * PERCENT_FACTOR
	return {"rendered": rendered_tris, "total": total_tris, "percent": percent}


func _get_mesh_vertex_count(mesh_value: Variant) -> int:
	if not (mesh_value is ArrayMesh):
		return 0
	var mesh: ArrayMesh = mesh_value as ArrayMesh
	if mesh.get_surface_count() <= 0:
		return 0
	var arrays: Array = mesh.surface_get_arrays(0)
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	return vertices.size()


func _get_mesh_triangle_count(mesh_value: Variant) -> int:
	var vertex_count := _get_mesh_vertex_count(mesh_value)
	if vertex_count <= 0:
		return 0
	return int(vertex_count / 3)
