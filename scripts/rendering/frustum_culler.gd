extends RefCounted
class_name FrustumCuller
## Frustum plane extraction and chunk AABB culling.


func build_planes(camera: Camera3D, near_sample_offset: float, near_sample_min: float) -> Array:
	if camera == null:
		return []
	var frustum: Array = camera.get_frustum()
	var near_sample: float = max(camera.near + near_sample_offset, near_sample_min)
	var inside_point: Vector3 = camera.global_transform.origin + (-camera.global_transform.basis.z) * near_sample
	var planes: Array = []
	for plane in frustum:
		var p: Plane = plane
		var inside_positive: bool = p.distance_to(inside_point) >= 0.0
		planes.append({"plane": p, "inside_positive": inside_positive})
	return planes


func is_chunk_in_view(planes: Array, coord: Vector3i, chunk_size: int) -> bool:
	var min_corner := Vector3(
		coord.x * chunk_size,
		coord.y * chunk_size,
		coord.z * chunk_size
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

