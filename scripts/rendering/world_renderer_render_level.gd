extends RefCounted
class_name WorldRendererRenderLevel
## Owns render-height rebuild queue ordering for the renderer facade.

#region State
var renderer = null
var chunk_cache = null
var mesh_scheduler = null
var render_height_queue: Array = []
var render_height_queue_set: Dictionary = {}
var render_height_anchor := Vector3.ZERO
var render_height_target_y: int = 0
#endregion


#region Setup
func configure(renderer_ref, chunk_cache_ref, mesh_scheduler_ref) -> void:
	renderer = renderer_ref
	chunk_cache = chunk_cache_ref
	mesh_scheduler = mesh_scheduler_ref
#endregion


#region Queue State
func clear() -> void:
	render_height_queue.clear()
	render_height_queue_set.clear()


func remove_coord(coord: Vector3i) -> void:
	render_height_queue_set.erase(coord)
	if render_height_queue.has(coord):
		render_height_queue.erase(coord)
#endregion


#region Processing
func queue_update(world: World, old_y: int, new_y: int, anchor: Vector3, min_x: int, max_x: int, min_z: int, max_z: int) -> int:
	if world == null:
		return 0
	var chunk_size: int = World.CHUNK_SIZE
	var min_y: int = min(old_y, new_y)
	var max_y: int = max(old_y, new_y)
	var max_cy: int = int(floor(float(world.world_size_y) / float(chunk_size))) - 1
	var min_cy: int = clampi(int(floor(float(min_y) / float(chunk_size))), 0, max_cy)
	var max_cy_clamped: int = clampi(int(floor(float(max_y) / float(chunk_size))), 0, max_cy)
	_hide_chunks_outside_bounds(min_cy, max_cy_clamped, min_x, max_x, min_z, max_z)
	return _queue_rebuild(min_cy, max_cy_clamped, min_x, max_x, min_z, max_z, anchor, new_y)


func process_queue(budget: int) -> int:
	if budget <= 0:
		return 0
	if renderer == null:
		return 0
	var build_count: int = min(budget, render_height_queue.size())
	for _i in range(build_count):
		var coord: Vector3i = render_height_queue.pop_front()
		render_height_queue_set.erase(coord)
		renderer.queue_chunk_mesh_build(coord, render_height_target_y, true)
	return build_count


func has_pending_work() -> bool:
	if render_height_queue.size() > 0:
		return true
	if mesh_scheduler != null and mesh_scheduler.has_visible_records():
		return true
	if mesh_scheduler != null and mesh_scheduler.has_non_prefetch_jobs():
		return true
	if mesh_scheduler != null and mesh_scheduler.has_non_prefetch_results():
		return true
	return false


func update_anchor(anchor: Vector3) -> void:
	if render_height_queue.is_empty():
		return
	var dx := anchor.x - render_height_anchor.x
	var dz := anchor.z - render_height_anchor.z
	var threshold := float(World.CHUNK_SIZE * World.CHUNK_SIZE)
	if dx * dx + dz * dz < threshold:
		return
	render_height_anchor = anchor
	render_height_queue.sort_custom(Callable(self, "_sort_coord"))
#endregion


#region Internals
func _queue_rebuild(min_cy: int, max_cy: int, min_x: int, max_x: int, min_z: int, max_z: int, anchor: Vector3, target_top_y: int) -> int:
	clear()
	render_height_anchor = anchor
	render_height_target_y = target_top_y
	if chunk_cache == null or renderer == null:
		return 0
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
			renderer._apply_empty_mesh(coord)
			continue
		local_top = min(local_top, chunk_size - 1)
		if renderer._apply_cached_mesh(coord, local_top):
			continue
		renderer._hide_chunk_mesh(coord)
		var center_x := (float(coord.x) + 0.5) * chunk_size
		var center_z := (float(coord.z) + 0.5) * chunk_size
		var dx := center_x - anchor_x
		var dz := center_z - anchor_z
		var dist := dx * dx + dz * dz
		candidates.append({"key": coord, "dist": dist})
	candidates.sort_custom(Callable(self, "_sort_candidate"))
	for entry in candidates:
		var coord: Vector3i = entry["key"]
		render_height_queue.append(coord)
		render_height_queue_set[coord] = true
	return render_height_queue.size()


func _sort_candidate(a: Dictionary, b: Dictionary) -> bool:
	return float(a["dist"]) < float(b["dist"])


func _sort_coord(a: Vector3i, b: Vector3i) -> bool:
	return _coord_dist_sq(a) < _coord_dist_sq(b)


func _coord_dist_sq(coord: Vector3i) -> float:
	var chunk_size := World.CHUNK_SIZE
	var center_x := (float(coord.x) + 0.5) * chunk_size
	var center_z := (float(coord.z) + 0.5) * chunk_size
	var dx := center_x - render_height_anchor.x
	var dz := center_z - render_height_anchor.z
	return dx * dx + dz * dz


func _hide_chunks_outside_bounds(min_cy: int, max_cy: int, min_x: int, max_x: int, min_z: int, max_z: int) -> void:
	if chunk_cache == null or renderer == null:
		return
	for key in chunk_cache.get_keys():
		var coord: Vector3i = key
		if coord.y < min_cy or coord.y > max_cy:
			continue
		if coord.x >= min_x and coord.x <= max_x and coord.z >= min_z and coord.z <= max_z:
			continue
		renderer._hide_chunk_mesh(coord)
#endregion
