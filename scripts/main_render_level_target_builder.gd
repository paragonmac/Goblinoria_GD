extends RefCounted
class_name MainRenderLevelTargetBuilder

const STARTUP_REVEAL_BAND_RADIUS := 1
const STARTUP_GENERATION_NEIGHBOR_BAND_RADIUS := 1
const Y_REVEAL_READY_MARGIN_CHUNKS := 1

var owner_node: Node
var world: World


func initialize(owner_ref: Node, world_ref: World) -> void:
	owner_node = owner_ref
	world = world_ref


func update_world(world_ref: World) -> void:
	world = world_ref


func build_reveal_chunk_targets(render_y: int) -> Array[Vector3i]:
	return _build_chunk_targets_for_bands_in_bounds(
		_build_reveal_mesh_bands(render_y),
		_build_reveal_chunk_xz_bounds(render_y, false)
	)


func build_reveal_generation_targets(render_y: int) -> Array[Vector3i]:
	return _build_chunk_targets_for_bands_in_bounds(
		build_generation_bands_for_mesh_bands(_build_reveal_mesh_bands(render_y)),
		_build_reveal_chunk_xz_bounds(render_y, false)
	)


func build_directional_y_prewarm_mesh_targets(render_y: int) -> Array[Vector3i]:
	return _build_chunk_targets_for_bands_in_bounds(
		_build_reveal_mesh_bands(render_y),
		_build_reveal_chunk_xz_bounds(render_y, true)
	)


func build_directional_y_prewarm_generation_targets(render_y: int) -> Array[Vector3i]:
	return _build_chunk_targets_for_bands_in_bounds(
		build_generation_bands_for_mesh_bands(_build_reveal_mesh_bands(render_y)),
		_build_reveal_chunk_xz_bounds(render_y, true)
	)


func build_generation_bands_for_mesh_bands(mesh_bands: Array[int]) -> Array[int]:
	var band_set: Dictionary = {}
	var bands: Array[int] = []
	for cy_value in mesh_bands:
		var cy: int = int(cy_value)
		var min_cy: int = maxi(0, cy - STARTUP_GENERATION_NEIGHBOR_BAND_RADIUS)
		var max_cy: int = mini(World.WORLD_CHUNKS_Y - 1, cy + STARTUP_GENERATION_NEIGHBOR_BAND_RADIUS)
		for generation_cy: int in range(min_cy, max_cy + 1):
			if band_set.has(generation_cy):
				continue
			band_set[generation_cy] = true
			bands.append(generation_cy)
	return bands


func build_chunk_targets_for_bands(bands: Array[int]) -> Array[Vector3i]:
	var targets: Array[Vector3i] = []
	if world == null:
		return targets
	for cy_value in bands:
		var cy: int = int(cy_value)
		for cx: int in range(World.WORLD_MIN_CHUNK_X, World.WORLD_MAX_CHUNK_X + 1):
			for cz: int in range(World.WORLD_MIN_CHUNK_Z, World.WORLD_MAX_CHUNK_Z + 1):
				var coord := Vector3i(cx, cy, cz)
				if world.is_chunk_coord_valid(coord):
					targets.append(coord)
	return targets


func build_all_world_chunk_targets() -> Array[Vector3i]:
	var bands: Array[int] = []
	for cy: int in range(World.WORLD_CHUNKS_Y):
		bands.append(cy)
	return build_chunk_targets_for_bands(bands)


func chunk_y_for_render_y(render_y: int) -> int:
	if world == null:
		return 0
	var clamped_y: int = clampi(render_y, 0, world.world_size_y - 1)
	return clampi(int(floor(float(clamped_y) / float(World.CHUNK_SIZE))), 0, World.WORLD_CHUNKS_Y - 1)


func chunk_full_top_y(coord: Vector3i) -> int:
	return coord.y * World.CHUNK_SIZE + World.CHUNK_SIZE - 1


func get_stream_view_rect_for_y(render_y: int) -> Rect2:
	if owner_node == null:
		return Rect2()
	var value: Variant = owner_node.call("get_stream_view_rect_for_y", render_y)
	if typeof(value) == TYPE_RECT2:
		return value
	return Rect2()


func _build_reveal_mesh_bands(render_y: int) -> Array[int]:
	return _build_band_range(chunk_y_for_render_y(render_y), STARTUP_REVEAL_BAND_RADIUS)


func _build_band_range(center_cy: int, radius: int) -> Array[int]:
	var bands: Array[int] = []
	var min_cy: int = maxi(0, center_cy - radius)
	var max_cy: int = mini(World.WORLD_CHUNKS_Y - 1, center_cy + radius)
	for cy: int in range(min_cy, max_cy + 1):
		bands.append(cy)
	return bands


func _build_reveal_chunk_xz_bounds(render_y: int, include_render_buffer: bool) -> Dictionary:
	var rect: Rect2 = get_stream_view_rect_for_y(render_y)
	var chunk_size: int = World.CHUNK_SIZE
	var render_radius_chunks := 0
	var render_view_scale := 0.0
	if include_render_buffer and world != null and world.streaming != null:
		render_radius_chunks = world.streaming.render_radius_chunks
		render_view_scale = maxf(world.streaming.render_view_scale, 0.0)
	var render_pad: float = float(render_radius_chunks * chunk_size)
	var render_buffer_x: float = render_pad
	var render_buffer_z: float = render_pad
	if render_view_scale > 0.0:
		render_buffer_x = maxf(render_buffer_x, rect.size.x * render_view_scale)
		render_buffer_z = maxf(render_buffer_z, rect.size.y * render_view_scale)
	var min_cx: int = _chunk_coord_from_world_value(rect.position.x - render_buffer_x) - Y_REVEAL_READY_MARGIN_CHUNKS
	var max_cx: int = _chunk_coord_from_world_value(rect.position.x + rect.size.x + render_buffer_x) + Y_REVEAL_READY_MARGIN_CHUNKS
	var min_cz: int = _chunk_coord_from_world_value(rect.position.y - render_buffer_z) - Y_REVEAL_READY_MARGIN_CHUNKS
	var max_cz: int = _chunk_coord_from_world_value(rect.position.y + rect.size.y + render_buffer_z) + Y_REVEAL_READY_MARGIN_CHUNKS
	return {
		"min_x": clampi(min_cx, World.WORLD_MIN_CHUNK_X, World.WORLD_MAX_CHUNK_X),
		"max_x": clampi(max_cx, World.WORLD_MIN_CHUNK_X, World.WORLD_MAX_CHUNK_X),
		"min_z": clampi(min_cz, World.WORLD_MIN_CHUNK_Z, World.WORLD_MAX_CHUNK_Z),
		"max_z": clampi(max_cz, World.WORLD_MIN_CHUNK_Z, World.WORLD_MAX_CHUNK_Z),
	}


func _chunk_coord_from_world_value(value: float) -> int:
	return int(floor(value / float(World.CHUNK_SIZE)))


func _build_chunk_targets_for_bands_in_bounds(bands: Array[int], bounds: Dictionary) -> Array[Vector3i]:
	var targets: Array[Vector3i] = []
	if world == null:
		return targets
	var min_cx: int = int(bounds.get("min_x", World.WORLD_MIN_CHUNK_X))
	var max_cx: int = int(bounds.get("max_x", World.WORLD_MAX_CHUNK_X))
	var min_cz: int = int(bounds.get("min_z", World.WORLD_MIN_CHUNK_Z))
	var max_cz: int = int(bounds.get("max_z", World.WORLD_MAX_CHUNK_Z))
	if min_cx > max_cx or min_cz > max_cz:
		return targets
	for cy_value in bands:
		var cy: int = int(cy_value)
		for cx: int in range(min_cx, max_cx + 1):
			for cz: int in range(min_cz, max_cz + 1):
				var coord := Vector3i(cx, cy, cz)
				if world.is_chunk_coord_valid(coord):
					targets.append(coord)
	return targets
