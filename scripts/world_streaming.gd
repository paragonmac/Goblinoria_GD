extends RefCounted
class_name WorldStreaming
## Handles chunk streaming, queue management, and spiral patterns.

#region Constants
const CHUNKS_PER_FRAME_DEFAULT := 6
const STREAM_QUEUE_BUDGET_DEFAULT := 100
const STREAM_RADIUS_DEFAULT := 12
const RENDER_RADIUS_DEFAULT := 0
const RENDER_VIEW_SCALE_DEFAULT := 0.5
const STREAM_HEIGHT_DEFAULT := 4
const STREAM_FULL_WORLD_DEFAULT := false
const STREAM_LEAD_TIME_DEFAULT := 0.4
const STREAM_BASE_BUFFER_CHUNKS_DEFAULT := 32
const STREAM_MAX_BUFFER_CHUNKS_DEFAULT := 128
const STREAM_BUFFER_VIEW_SCALE_DEFAULT := 0.5
const UNLOAD_RADIUS_DEFAULT := 16
const UNLOAD_BUDGET_DEFAULT := 8
const UNLOAD_INTERVAL_DEFAULT := 0.25
const UNLOAD_HYSTERESIS_DEFAULT := 4
const RENDER_ZONE_INTERVAL_DEFAULT := 0.1
const DUMMY_INT := 666
#endregion

#region State
var world: World

var chunks_per_frame: int = CHUNKS_PER_FRAME_DEFAULT
var stream_queue_budget: int = STREAM_QUEUE_BUDGET_DEFAULT
var stream_radius_base: int = STREAM_RADIUS_DEFAULT
var stream_radius_chunks: int = STREAM_RADIUS_DEFAULT
var render_radius_chunks: int = RENDER_RADIUS_DEFAULT
var render_view_scale: float = RENDER_VIEW_SCALE_DEFAULT
var stream_full_world_xz: bool = STREAM_FULL_WORLD_DEFAULT
var stream_height_chunks: int = STREAM_HEIGHT_DEFAULT
var stream_lead_time: float = STREAM_LEAD_TIME_DEFAULT
var stream_base_buffer_chunks: int = STREAM_BASE_BUFFER_CHUNKS_DEFAULT
var stream_max_buffer_chunks: int = STREAM_MAX_BUFFER_CHUNKS_DEFAULT
var stream_buffer_view_scale: float = STREAM_BUFFER_VIEW_SCALE_DEFAULT
var unload_radius_chunks: int = UNLOAD_RADIUS_DEFAULT
var unload_budget: int = UNLOAD_BUDGET_DEFAULT
var unload_interval: float = UNLOAD_INTERVAL_DEFAULT
var unload_timer: float = 0.0
var unload_hysteresis: int = UNLOAD_HYSTERESIS_DEFAULT
var render_zone_interval: float = RENDER_ZONE_INTERVAL_DEFAULT
var render_zone_timer: float = 0.0
var last_speed_buffer_chunks: int = 0
var last_buffer_chunks: int = 0

var last_stream_chunk := Vector2i(-DUMMY_INT, -DUMMY_INT)
var last_stream_max_cy := -DUMMY_INT
var last_stream_target := Vector3.ZERO
var last_stream_target_valid: bool = false

var stream_min_x: int = DUMMY_INT
var stream_max_x: int = - DUMMY_INT
var stream_min_z: int = DUMMY_INT
var stream_max_z: int = - DUMMY_INT
var stream_min_y: int = DUMMY_INT
var stream_max_y: int = - DUMMY_INT

var stream_pending: bool = false
var stream_plane_index: int = 0
var stream_plane_size: int = 0
var stream_layer_y: int = 0
var stream_layer_remaining: int = 0
var stream_spiral_offsets: Array = []
var last_spiral_x_range: int = -1
var last_spiral_z_range: int = -1
var last_render_zone_min_cx: int = DUMMY_INT
var last_render_zone_max_cx: int = -DUMMY_INT
var last_render_zone_min_cz: int = DUMMY_INT
var last_render_zone_max_cz: int = -DUMMY_INT
var last_render_zone_min_cy: int = DUMMY_INT
var last_render_zone_max_cy: int = -DUMMY_INT

var chunk_build_queue: Array = []
var chunk_build_set: Dictionary = {}
var spiral_cache: Dictionary = {}  # Key: Vector2i(x_range, z_range) -> Array of offsets
#endregion


#region Initialization
func _init(world_ref: World) -> void:
	world = world_ref
#endregion


#region Reset
func reset_state() -> void:
	chunk_build_queue.clear()
	chunk_build_set.clear()
	spiral_cache.clear()
	stream_radius_chunks = stream_radius_base
	last_stream_chunk = Vector2i(-DUMMY_INT, -DUMMY_INT)
	last_stream_max_cy = - DUMMY_INT
	last_stream_target = Vector3.ZERO
	last_stream_target_valid = false
	stream_min_x = DUMMY_INT
	stream_max_x = - DUMMY_INT
	stream_min_z = DUMMY_INT
	stream_max_z = - DUMMY_INT
	stream_min_y = DUMMY_INT
	stream_max_y = - DUMMY_INT
	stream_pending = false
	stream_plane_index = 0
	stream_plane_size = 0
	stream_layer_y = 0
	stream_layer_remaining = 0
	stream_spiral_offsets.clear()
	last_spiral_x_range = -1
	last_spiral_z_range = -1
	unload_timer = 0.0
	render_zone_timer = render_zone_interval
	last_render_zone_min_cx = DUMMY_INT
	last_render_zone_max_cx = -DUMMY_INT
	last_render_zone_min_cz = DUMMY_INT
	last_render_zone_max_cz = -DUMMY_INT
	last_render_zone_min_cy = DUMMY_INT
	last_render_zone_max_cy = -DUMMY_INT
	last_speed_buffer_chunks = 0
	last_buffer_chunks = 0
#endregion


#region Update
func update_streaming(view_rect: Rect2, plane_y: float, dt: float) -> void:
	if world.renderer == null:
		return
	var rect: Rect2 = view_rect.abs()
	var center_x: float = rect.position.x + rect.size.x * 0.5
	var center_z: float = rect.position.y + rect.size.y * 0.5
	var view_center := Vector3(center_x, plane_y, center_z)
	var velocity := Vector3.ZERO
	if last_stream_target_valid and dt > 0.0:
		velocity = (view_center - last_stream_target) / dt
	last_stream_target = view_center
	last_stream_target_valid = true
	var speed: float = Vector2(velocity.x, velocity.z).length()
	var speed_buffer_chunks: int = 0
	if stream_lead_time > 0.0 and speed > 0.0:
		speed_buffer_chunks = int(ceil((speed * stream_lead_time) / float(World.CHUNK_SIZE)))
	speed_buffer_chunks = clampi(speed_buffer_chunks, 0, stream_max_buffer_chunks)
	var base_buffer: int = maxi(stream_base_buffer_chunks, 0)
	var buffer_chunks: int = maxi(base_buffer, speed_buffer_chunks)
	last_speed_buffer_chunks = speed_buffer_chunks
	var chunk_size: int = World.CHUNK_SIZE
	var view_scale: float = float(max(stream_buffer_view_scale, 0.0))
	var buffer_world_x: float = float(buffer_chunks * chunk_size)
	var buffer_world_z: float = buffer_world_x
	if view_scale > 0.0:
		buffer_world_x = max(buffer_world_x, rect.size.x * view_scale)
		buffer_world_z = max(buffer_world_z, rect.size.y * view_scale)
	last_buffer_chunks = int(ceil(max(buffer_world_x, buffer_world_z) / float(chunk_size)))
	var max_cy: int = int(floor(float(world.top_render_y) / float(chunk_size)))
	if max_cy < 0:
		return
	var min_cy: int = 0
	if stream_height_chunks > 0:
		min_cy = maxi(0, max_cy - stream_height_chunks + 1)

	var render_pad: float = float(render_radius_chunks * chunk_size)
	var render_scale: float = float(max(render_view_scale, 0.0))
	var render_buffer_x: float = render_pad
	var render_buffer_z: float = render_pad
	if render_scale > 0.0:
		render_buffer_x = max(render_buffer_x, rect.size.x * render_scale)
		render_buffer_z = max(render_buffer_z, rect.size.y * render_scale)
	var render_min_x: float = rect.position.x - render_buffer_x
	var render_max_x: float = rect.position.x + rect.size.x + render_buffer_x
	var render_min_z: float = rect.position.y - render_buffer_z
	var render_max_z: float = rect.position.y + rect.size.y + render_buffer_z
	var render_min_cx: int = _chunk_coord_from_world(render_min_x, chunk_size)
	var render_max_cx: int = _chunk_coord_from_world(render_max_x, chunk_size)
	var render_min_cz: int = _chunk_coord_from_world(render_min_z, chunk_size)
	var render_max_cz: int = _chunk_coord_from_world(render_max_z, chunk_size)

	var lead_offset: Vector2 = Vector2(velocity.x, velocity.z) * stream_lead_time
	var stream_pos_2d: Vector2 = rect.position + lead_offset
	var stream_size_2d: Vector2 = rect.size
	if buffer_world_x > 0.0 or buffer_world_z > 0.0:
		stream_pos_2d -= Vector2(buffer_world_x, buffer_world_z)
		stream_size_2d += Vector2(buffer_world_x * 2.0, buffer_world_z * 2.0)
	var stream_min_x_f: float = stream_pos_2d.x
	var stream_max_x_f: float = stream_pos_2d.x + stream_size_2d.x
	var stream_min_z_f: float = stream_pos_2d.y
	var stream_max_z_f: float = stream_pos_2d.y + stream_size_2d.y

	var min_cx: int = _chunk_coord_from_world(stream_min_x_f, chunk_size)
	var max_cx: int = _chunk_coord_from_world(stream_max_x_f, chunk_size)
	var min_cz: int = _chunk_coord_from_world(stream_min_z_f, chunk_size)
	var max_cz: int = _chunk_coord_from_world(stream_max_z_f, chunk_size)
	var stream_center_x: float = stream_pos_2d.x + stream_size_2d.x * 0.5
	var stream_center_z: float = stream_pos_2d.y + stream_size_2d.y * 0.5
	var anchor_cx: int = _chunk_coord_from_world(stream_center_x, chunk_size)
	var anchor_cz: int = _chunk_coord_from_world(stream_center_z, chunk_size)
	stream_radius_chunks = maxi(
		maxi(absi(max_cx - anchor_cx), absi(anchor_cx - min_cx)),
		maxi(absi(max_cz - anchor_cz), absi(anchor_cz - min_cz))
	)
	var anchor_changed: bool = anchor_cx != last_stream_chunk.x \
		or anchor_cz != last_stream_chunk.y \
		or max_cy != last_stream_max_cy \
		or min_cx != stream_min_x \
		or max_cx != stream_max_x \
		or min_cz != stream_min_z \
		or max_cz != stream_max_z
	if anchor_changed:
		last_stream_chunk = Vector2i(anchor_cx, anchor_cz)
		last_stream_max_cy = max_cy

		stream_min_x = min_cx
		stream_max_x = max_cx
		stream_min_z = min_cz
		stream_max_z = max_cz
		stream_min_y = min_cy
		stream_max_y = max_cy
		chunk_build_queue.clear()
		chunk_build_set.clear()
		var x_range: int = stream_max_x - stream_min_x + 1
		var z_range: int = stream_max_z - stream_min_z + 1
		var y_range: int = stream_max_y - stream_min_y + 1
		stream_plane_index = 0
		if x_range <= 0 or z_range <= 0 or y_range <= 0:
			stream_plane_size = 0
			stream_pending = false
		else:
			if x_range != last_spiral_x_range or z_range != last_spiral_z_range or stream_spiral_offsets.is_empty():
				stream_spiral_offsets = build_spiral_offsets_2d(x_range, z_range)
				last_spiral_x_range = x_range
				last_spiral_z_range = z_range
			stream_plane_size = stream_spiral_offsets.size()
			stream_pending = stream_plane_size > 0
		stream_layer_y = stream_max_y
		stream_layer_remaining = stream_plane_size
	enqueue_stream_chunks()
	process_chunk_queue()
	unload_timer += dt
	if unload_timer >= unload_interval:
		_unload_distant_chunks(anchor_cx, anchor_cz)
		unload_timer = 0.0
	render_zone_timer += dt
	var render_zone_changed: bool = render_min_cx != last_render_zone_min_cx \
		or render_max_cx != last_render_zone_max_cx \
		or render_min_cz != last_render_zone_min_cz \
		or render_max_cz != last_render_zone_max_cz \
		or min_cy != last_render_zone_min_cy \
		or max_cy != last_render_zone_max_cy
	if render_zone_changed and (render_zone_timer >= render_zone_interval or last_render_zone_min_cx == DUMMY_INT):
		world.renderer.update_render_zone(render_min_cx, render_max_cx, render_min_cz, render_max_cz, min_cy, max_cy)
		last_render_zone_min_cx = render_min_cx
		last_render_zone_max_cx = render_max_cx
		last_render_zone_min_cz = render_min_cz
		last_render_zone_max_cz = render_max_cz
		last_render_zone_min_cy = min_cy
		last_render_zone_max_cy = max_cy
		render_zone_timer = 0.0
#endregion


#region Queue Processing
func process_chunk_queue() -> void:
	if world.renderer == null:
		return
	var build_count: int = min(chunks_per_frame, chunk_build_queue.size())
	for _i in range(build_count):
		var key: Vector3i = chunk_build_queue.pop_front()
		chunk_build_set.erase(key)
		world.ensure_chunk_generated(key)
		world.renderer.queue_chunk_mesh_build(key)
		if stream_pending and key.y == stream_layer_y and stream_layer_remaining > 0:
			stream_layer_remaining -= 1


func process_chunk_queue_full() -> void:
	if world.renderer == null:
		return
	var original := chunks_per_frame
	chunks_per_frame = chunk_build_queue.size()
	process_chunk_queue()
	chunks_per_frame = original


func enqueue_stream_chunks() -> void:
	if not stream_pending:
		return
	var x_range: int = stream_max_x - stream_min_x + 1
	var z_range: int = stream_max_z - stream_min_z + 1
	var y_range: int = stream_max_y - stream_min_y + 1
	if x_range <= 0 or z_range <= 0 or y_range <= 0:
		stream_pending = false
		return
	while stream_pending and stream_layer_remaining <= 0:
		if stream_layer_y <= stream_min_y:
			stream_pending = false
			return
		stream_layer_y -= 1
		stream_plane_index = 0
		stream_layer_remaining = stream_plane_size
	var plane_size: int = stream_plane_size
	if plane_size <= 0:
		stream_pending = false
		return
	var remaining_in_plane: int = plane_size - stream_plane_index
	if remaining_in_plane <= 0:
		return
	var budget: int = min(stream_queue_budget, remaining_in_plane)
	for _i in range(budget):
		var plane_index: int = stream_plane_index
		var offset: Vector2i = stream_spiral_offsets[plane_index]
		var key := Vector3i(stream_min_x + offset.x, stream_layer_y, stream_min_z + offset.y)
		if is_chunk_mesh_ready(key):
			if stream_layer_remaining > 0:
				stream_layer_remaining -= 1
		elif not chunk_build_set.has(key):
			chunk_build_set[key] = true
			chunk_build_queue.append(key)
			var chunk := world.ensure_chunk(key)
			chunk.mesh_state = ChunkData.MESH_STATE_PENDING
		stream_plane_index += 1
#endregion


#region Helpers
func is_chunk_mesh_ready(coord: Vector3i) -> bool:
	var chunk: ChunkData = world.get_chunk(coord)
	return chunk != null and chunk.mesh_state == ChunkData.MESH_STATE_READY


func warmup_streaming(view_rect: Rect2, plane_y: float) -> void:
	update_streaming(view_rect, plane_y, 0.0)
	process_chunk_queue_full()
	while stream_pending:
		enqueue_stream_chunks()
		process_chunk_queue_full()


func _chunk_coord_from_world(value: float, chunk_size: int) -> int:
	return int(floor(value / float(chunk_size)))


func build_spiral_offsets_2d(x_range: int, z_range: int) -> Array:
	var cache_key := Vector2i(x_range, z_range)
	if spiral_cache.has(cache_key):
		return spiral_cache[cache_key]
	var offsets: Array = []
	if x_range <= 0 or z_range <= 0:
		return offsets
	var center_x: int = int(floor(float(x_range - 1) / 2.0))
	var center_z: int = int(floor(float(z_range - 1) / 2.0))
	var max_x_radius := maxi(center_x, x_range - 1 - center_x)
	var max_z_radius := maxi(center_z, z_range - 1 - center_z)
	var max_radius := maxi(max_x_radius, max_z_radius)
	offsets.append(Vector2i(center_x, center_z))
	for radius: int in range(1, max_radius + 1):
		var min_x: int = center_x - radius
		var max_x: int = center_x + radius
		var min_z: int = center_z - radius
		var max_z: int = center_z + radius
		for x: int in range(min_x, max_x + 1):
			var z: int = min_z
			if x >= 0 and x < x_range and z >= 0 and z < z_range:
				offsets.append(Vector2i(x, z))
		for z: int in range(min_z + 1, max_z + 1):
			var x: int = max_x
			if x >= 0 and x < x_range and z >= 0 and z < z_range:
				offsets.append(Vector2i(x, z))
		for x: int in range(max_x - 1, min_x - 1, -1):
			var z: int = max_z
			if x >= 0 and x < x_range and z >= 0 and z < z_range:
				offsets.append(Vector2i(x, z))
		for z: int in range(max_z - 1, min_z, -1):
			var x: int = min_x
			if x >= 0 and x < x_range and z >= 0 and z < z_range:
				offsets.append(Vector2i(x, z))
	spiral_cache[cache_key] = offsets
	return offsets
#endregion


func _unload_distant_chunks(center_cx: int, center_cz: int) -> void:
	if unload_budget <= 0:
		return
	if unload_radius_chunks <= 0:
		return
	var effective_unload: int = maxi(unload_radius_chunks, stream_radius_chunks + unload_hysteresis)
	var candidates: Array = []
	for key in world.chunks:
		var coord: Vector3i = key
		var dist: int = maxi(absi(coord.x - center_cx), absi(coord.z - center_cz))
		if dist > effective_unload:
			candidates.append(coord)
			if candidates.size() >= unload_budget:
				break
	if candidates.is_empty():
		return
	for coord in candidates:
		if chunk_build_set.erase(coord):
			# Only search queue if it was in the set (avoids O(N) scan)
			chunk_build_queue.erase(coord)
		world.unload_chunk(coord)
