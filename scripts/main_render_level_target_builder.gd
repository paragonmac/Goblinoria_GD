extends RefCounted
class_name MainRenderLevelTargetBuilder

const WorldChunkSpaceScript = preload("res://scripts/world/world_chunk_space.gd")

const STARTUP_GENERATION_NEIGHBOR_BAND_RADIUS := 1
const Y_REVEAL_READY_MARGIN_CHUNKS := 1

var world: World
var stream_view_rect_provider: Callable
var cached_band_rects: Dictionary = {}
var cached_band_limits := Vector2i(-1, -1)
var cached_lower_rect := Rect2()
var cached_upper_rect := Rect2()


func initialize(world_ref: World, stream_view_rect_provider_ref: Callable) -> void:
	world = world_ref
	stream_view_rect_provider = stream_view_rect_provider_ref
	cached_band_rects.clear()


func update_world(world_ref: World) -> void:
	world = world_ref
	cached_band_rects.clear()


func build_reveal_chunk_targets(render_y: int) -> Array[Vector3i]:
	return _build_visible_chunk_targets(render_y, false)


func build_reveal_generation_targets(render_y: int) -> Array[Vector3i]:
	return _build_mesh_generation_targets(build_reveal_chunk_targets(render_y))


func build_directional_y_prewarm_mesh_targets(render_y: int) -> Array[Vector3i]:
	return _build_visible_chunk_targets(render_y, true)


func build_directional_y_prewarm_generation_targets(render_y: int) -> Array[Vector3i]:
	return _build_mesh_generation_targets(build_directional_y_prewarm_mesh_targets(render_y))


func _build_mesh_generation_targets(mesh_targets: Array[Vector3i]) -> Array[Vector3i]:
	# Every mesh snapshot needs its six boundary neighbors, including neighbors
	# outside the projected viewport. Do not build meshes for this halo.
	var targets: Array[Vector3i] = []
	var seen := {}
	for coord in mesh_targets:
		for offset in [Vector3i.ZERO, Vector3i.LEFT, Vector3i.RIGHT, Vector3i.UP,
			Vector3i.DOWN, Vector3i.FORWARD, Vector3i.BACK]:
			var neighbor: Vector3i = coord + offset
			if not seen.has(neighbor) and world.is_chunk_coord_valid(neighbor):
				seen[neighbor] = true
				targets.append(neighbor)
	return targets


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
	var bands: Array[int] = []
	if world == null:
		return bands
	var streaming := world.streaming if world.streaming != null else WorldStreaming.new(world)
	var bounds := streaming.get_render_chunk_y_bounds(render_y)
	for cy in range(bounds.y, bounds.x - 1, -1):
		bands.append(cy)
	return bands


func get_stream_volume_view_rect(render_y: int) -> Rect2:
	if world == null:
		return get_stream_view_rect_for_y(render_y)
	# The lower viewport footprint shifts with an oblique camera. A rectangle
	# projected only at the cut plane misses cave faces near the screen edges.
	var bounds := _visible_block_y_bounds(render_y)
	return get_stream_view_rect_for_y(bounds.x).merge(get_stream_view_rect_for_y(bounds.y))


func get_render_band_view_rects(render_y: int) -> Dictionary:
	var rects := {}
	if world == null:
		return rects
	var visible_y := _visible_block_y_bounds(render_y)
	var lower_rect := get_stream_view_rect_for_y(visible_y.x)
	var upper_rect := get_stream_view_rect_for_y(visible_y.y)
	# Parallel-plane footprints are determined by the endpoint projections.
	# A stationary camera should not reproject every band on every frame.
	# Returned rectangles are read-only to callers.
	if not cached_band_rects.is_empty() and visible_y == cached_band_limits \
		and lower_rect == cached_lower_rect and upper_rect == cached_upper_rect:
		return cached_band_rects
	for cy in _build_reveal_mesh_bands(render_y):
		var lower_y := maxi(cy * World.CHUNK_SIZE, visible_y.x)
		var upper_y := mini((cy + 1) * World.CHUNK_SIZE, visible_y.y)
		rects[cy] = get_stream_view_rect_for_y(lower_y).merge(get_stream_view_rect_for_y(upper_y))
	cached_band_limits = visible_y
	cached_lower_rect = lower_rect
	cached_upper_rect = upper_rect
	cached_band_rects = rects
	return rects


func _visible_block_y_bounds(render_y: int) -> Vector2i:
	var upper_margin := WorldStreaming.RENDER_UPPER_CONNECTION_MARGIN_BLOCKS_DEFAULT
	if world.streaming != null:
		upper_margin = maxi(world.streaming.render_vertical_margin_blocks, 0) \
			+ maxi(world.streaming.render_upper_connection_margin_blocks, 0)
	return Vector2i(world.get_min_render_y(), mini(render_y + upper_margin + 1, world.world_size_y))


func _build_visible_chunk_targets(render_y: int, include_render_buffer: bool) -> Array[Vector3i]:
	var targets: Array[Vector3i] = []
	if world == null:
		return targets
	var rects := get_render_band_view_rects(render_y)
	for cy: int in rects:
		var rect: Rect2 = rects[cy]
		var bands: Array[int] = [cy]
		targets.append_array(_build_chunk_targets_for_bands_in_bounds(
			bands, _build_reveal_chunk_xz_bounds(rect, include_render_buffer)))
	return targets


func _build_reveal_chunk_xz_bounds(rect: Rect2, include_render_buffer: bool) -> Dictionary:
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
