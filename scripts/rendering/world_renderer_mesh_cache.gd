extends RefCounted
class_name WorldRendererMeshCache


func entry_from_arrays(
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
) -> Dictionary:
	var metrics := _normalize_metrics(mesh_metrics, vertices.size())
	return {
		"vertices": PackedVector3Array(vertices),
		"normals": PackedVector3Array(normals),
		"colors": PackedColorArray(colors),
		"uv": PackedVector2Array(uvs),
		"uv2": PackedVector2Array(uv2s),
		"visible_faces": visible_faces,
		"occluded_faces": occluded_faces,
		"has_geometry": has_geometry,
		"revision": revision,
		"metrics": metrics,
		"missing_neighbors": missing_neighbors.duplicate(),
		"local_top": local_top,
	}


func entry_from_mesher_result(result: Dictionary, local_top: int, revision: int = 0, missing_neighbors: Array = []) -> Dictionary:
	var vertices: PackedVector3Array = result.get("vertices", PackedVector3Array())
	var metrics: Dictionary = {
		"vertices": int(result.get("vertex_count", vertices.size())),
		"triangles": int(result.get("triangle_count", int(vertices.size() / 3))),
		"greedy_visible_faces": int(result.get("greedy_visible_faces", 0)),
		"greedy_occluded_faces": int(result.get("greedy_occluded_faces", 0)),
		"greedy_source_visible_faces": int(result.get("greedy_source_visible_faces", result.get("greedy_visible_faces", 0))),
		"ramp_visible_faces": int(result.get("ramp_visible_faces", 0)),
		"ramp_occluded_faces": int(result.get("ramp_occluded_faces", 0)),
	}
	return entry_from_arrays(
		local_top,
		vertices,
		PackedVector3Array(result.get("normals", PackedVector3Array())),
		PackedColorArray(result.get("colors", PackedColorArray())),
		PackedVector2Array(result.get("uv", PackedVector2Array())),
		PackedVector2Array(result.get("uv2", PackedVector2Array())),
		int(result.get("visible_faces", 0)),
		int(result.get("occluded_faces", 0)),
		bool(result.get("has_geometry", false)),
		revision,
		metrics,
		missing_neighbors
	)

func entry_from_persistent(entry: Dictionary, revision: int) -> Dictionary:
	var local_top: int = int(entry.get("local_top", -1))
	return entry_from_arrays(
		local_top,
		PackedVector3Array(entry.get("vertices", PackedVector3Array())),
		PackedVector3Array(entry.get("normals", PackedVector3Array())),
		PackedColorArray(entry.get("colors", PackedColorArray())),
		PackedVector2Array(entry.get("uv", PackedVector2Array())),
		PackedVector2Array(entry.get("uv2", PackedVector2Array())),
		int(entry.get("visible_faces", 0)),
		int(entry.get("occluded_faces", 0)),
		bool(entry.get("has_geometry", false)),
		revision,
		metrics_from_entry(entry),
		[]
	)


func export_persistent_entry(entry: Dictionary, local_top: int) -> Dictionary:
	if local_top < 0:
		return {}
	if not validate_arrays(entry):
		return {}
	return {
		"local_top": local_top,
		"visible_faces": int(entry.get("visible_faces", 0)),
		"occluded_faces": int(entry.get("occluded_faces", 0)),
		"has_geometry": bool(entry.get("has_geometry", false)),
		"metrics": metrics_from_entry(entry),
		"vertices": PackedVector3Array(entry.get("vertices", PackedVector3Array())),
		"normals": PackedVector3Array(entry.get("normals", PackedVector3Array())),
		"colors": PackedColorArray(entry.get("colors", PackedColorArray())),
		"uv": PackedVector2Array(entry.get("uv", PackedVector2Array())),
		"uv2": PackedVector2Array(entry.get("uv2", PackedVector2Array())),
	}


func validate_arrays(entry: Dictionary) -> bool:
	var has_geometry: bool = bool(entry.get("has_geometry", false))
	var vertices_value = entry.get("vertices", PackedVector3Array())
	var normals_value = entry.get("normals", PackedVector3Array())
	var colors_value = entry.get("colors", PackedColorArray())
	var uvs_value = entry.get("uv", PackedVector2Array())
	var uv2s_value = entry.get("uv2", PackedVector2Array())
	if typeof(vertices_value) != TYPE_PACKED_VECTOR3_ARRAY:
		return false
	if typeof(normals_value) != TYPE_PACKED_VECTOR3_ARRAY:
		return false
	if typeof(colors_value) != TYPE_PACKED_COLOR_ARRAY:
		return false
	if typeof(uvs_value) != TYPE_PACKED_VECTOR2_ARRAY:
		return false
	if typeof(uv2s_value) != TYPE_PACKED_VECTOR2_ARRAY:
		return false
	if not has_geometry:
		return true
	var vertices: PackedVector3Array = vertices_value
	return not vertices.is_empty()


func array_mesh_from_entry(entry: Dictionary) -> ArrayMesh:
	var mesh := ArrayMesh.new()
	if not bool(entry.get("has_geometry", false)):
		return mesh
	if not validate_arrays(entry):
		return mesh
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array(entry.get("vertices", PackedVector3Array()))
	arrays[Mesh.ARRAY_NORMAL] = PackedVector3Array(entry.get("normals", PackedVector3Array()))
	arrays[Mesh.ARRAY_COLOR] = PackedColorArray(entry.get("colors", PackedColorArray()))
	arrays[Mesh.ARRAY_TEX_UV] = PackedVector2Array(entry.get("uv", PackedVector2Array()))
	arrays[Mesh.ARRAY_TEX_UV2] = PackedVector2Array(entry.get("uv2", PackedVector2Array()))
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


func metrics_from_entry(entry: Dictionary) -> Dictionary:
	var metrics_value: Variant = entry.get("metrics", {})
	if typeof(metrics_value) == TYPE_DICTIONARY:
		return _normalize_metrics(metrics_value, PackedVector3Array(entry.get("vertices", PackedVector3Array())).size())
	return _normalize_metrics({}, PackedVector3Array(entry.get("vertices", PackedVector3Array())).size())


func _normalize_metrics(metrics: Dictionary, fallback_vertex_count: int) -> Dictionary:
	var vertex_count := int(metrics.get("vertices", metrics.get("vertex_count", -1)))
	if vertex_count < 0:
		vertex_count = fallback_vertex_count
	var triangle_count := int(metrics.get("triangles", metrics.get("triangle_count", -1)))
	if triangle_count < 0 and vertex_count > 0:
		triangle_count = int(vertex_count / 3)
	var greedy_visible_faces := int(metrics.get("greedy_visible_faces", metrics.get("greedy_visible", 0)))
	var greedy_occluded_faces := int(metrics.get("greedy_occluded_faces", metrics.get("greedy_occluded", 0)))
	var greedy_source_visible_faces := int(metrics.get("greedy_source_visible_faces", metrics.get("greedy_source_visible", greedy_visible_faces)))
	var ramp_visible_faces := int(metrics.get("ramp_visible_faces", metrics.get("ramp_visible", 0)))
	var ramp_occluded_faces := int(metrics.get("ramp_occluded_faces", metrics.get("ramp_occluded", 0)))
	return {
		"vertices": maxi(0, vertex_count),
		"triangles": maxi(0, triangle_count),
		"greedy_visible_faces": maxi(0, greedy_visible_faces),
		"greedy_occluded_faces": maxi(0, greedy_occluded_faces),
		"greedy_source_visible_faces": maxi(0, greedy_source_visible_faces),
		"ramp_visible_faces": maxi(0, ramp_visible_faces),
		"ramp_occluded_faces": maxi(0, ramp_occluded_faces),
	}
