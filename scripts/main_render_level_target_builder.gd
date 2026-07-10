extends RefCounted
class_name MainRenderLevelTargetBuilder

const WorldChunkSpaceScript = preload("res://scripts/world/world_chunk_space.gd")

const STARTUP_REVEAL_BAND_RADIUS := 1
const STARTUP_GENERATION_NEIGHBOR_BAND_RADIUS := 1
const Y_REVEAL_READY_MARGIN_CHUNKS := 1

var world: World
var stream_view_rect_provider: Callable


func initialize(world_ref: World, stream_view_rect_provider_ref: Callable) -> void:
	world = world_ref
	stream_view_rect_provider = stream_view_rect_provider_ref


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
	return WorldChunkSpaceScript.chunk_targets_for_bands(bands)


func build_all_world_chunk_targets() -> Array[Vector3i]:
	if world == null:
		var targets: Array[Vector3i] = []
		return targets
	return WorldChunkSpaceScript.all_world_chunk_targets()


func chunk_y_for_render_y(render_y: int) -> int:
	if world == null:
		return 0
	return WorldChunkSpaceScript.chunk_y_for_render_y(render_y, world.world_size_y)


func chunk_full_top_y(coord: Vector3i) -> int:
	return WorldChunkSpaceScript.full_top_y(coord)


func get_stream_view_rect_for_y(render_y: int) -> Rect2:
	if not stream_view_rect_provider.is_valid():
		return Rect2()
	var value: Variant = stream_view_rect_provider.call(render_y)
	if typeof(value) == TYPE_RECT2:
		return value
	return Rect2()


func _build_reveal_mesh_bands(render_y: int) -> Array[int]:
	return _build_band_range(chunk_y_for_render_y(render_y), STARTUP_REVEAL_BAND_RADIUS)


func _build_band_range(center_cy: int, radius: int) -> Array[int]:
	return WorldChunkSpaceScript.band_range(center_cy, radius)


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
	return WorldChunkSpaceScript.chunk_coord_from_world(value)


func _build_chunk_targets_for_bands_in_bounds(bands: Array[int], bounds: Dictionary) -> Array[Vector3i]:
	var targets: Array[Vector3i] = []
	if world == null:
		return targets
	return WorldChunkSpaceScript.chunk_targets_for_bands_in_bounds(bands, bounds)
