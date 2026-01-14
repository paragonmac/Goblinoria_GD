extends RefCounted
class_name WorldStreaming
## Handles chunk streaming, queue management, and spiral patterns.

#region Constants
const CHUNKS_PER_FRAME_DEFAULT := 6
const STREAM_QUEUE_BUDGET_DEFAULT := 6000
const STREAM_RADIUS_DEFAULT := 8
const STREAM_HEIGHT_DEFAULT := 1
const STREAM_FULL_WORLD_DEFAULT := false
const STREAM_LEAD_TIME_DEFAULT := 0.4
const STREAM_MAX_BUFFER_CHUNKS_DEFAULT := 12
const DUMMY_INT := 666
#endregion

#region State
var world: World

var chunks_per_frame: int = CHUNKS_PER_FRAME_DEFAULT
var stream_queue_budget: int = STREAM_QUEUE_BUDGET_DEFAULT
var stream_radius_base: int = STREAM_RADIUS_DEFAULT
var stream_radius_chunks: int = STREAM_RADIUS_DEFAULT
var stream_full_world_xz: bool = STREAM_FULL_WORLD_DEFAULT
var stream_height_chunks: int = STREAM_HEIGHT_DEFAULT
var stream_lead_time: float = STREAM_LEAD_TIME_DEFAULT
var stream_max_buffer_chunks: int = STREAM_MAX_BUFFER_CHUNKS_DEFAULT

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
var stream_x_offsets: Array = []
var stream_z_offsets: Array = []

var chunk_build_queue: Array = []
var chunk_build_set: Dictionary = {}
#endregion


#region Initialization
func _init(world_ref: World) -> void:
	world = world_ref
#endregion


#region Reset
func reset_state() -> void:
	chunk_build_queue.clear()
	chunk_build_set.clear()
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
	stream_x_offsets.clear()
	stream_z_offsets.clear()
#endregion


#region Update
func update_streaming(camera_pos: Vector3, dt: float) -> void:
	if world.renderer == null:
		return
	var velocity := Vector3.ZERO
	if last_stream_target_valid and dt > 0.0:
		velocity = (camera_pos - last_stream_target) / dt
	last_stream_target = camera_pos
	last_stream_target_valid = true
	var speed: float = velocity.length()
	var buffer_chunks: int = 0
	if stream_lead_time > 0.0 and speed > 0.0:
		buffer_chunks = int(ceil((speed * stream_lead_time) / float(World.CHUNK_SIZE)))
	buffer_chunks = clampi(buffer_chunks, 0, stream_max_buffer_chunks)
	stream_radius_chunks = stream_radius_base + buffer_chunks
	var stream_pos: Vector3 = camera_pos + velocity * stream_lead_time
	var chunk_size: int = World.CHUNK_SIZE
	var max_cx: int = int(floor(float(world.world_size_x) / float(chunk_size))) - 1
	var max_cy: int = int(floor(float(world.top_render_y) / float(chunk_size)))
	var max_cz: int = int(floor(float(world.world_size_z) / float(chunk_size))) - 1
	if max_cx < 0 or max_cy < 0 or max_cz < 0:
		return
	var min_cy: int = 0
	if stream_height_chunks > 0:
		min_cy = max(0, max_cy - stream_height_chunks + 1)

	var cx: int = clampi(int(floor(stream_pos.x / float(chunk_size))), 0, max_cx)
	var cz: int = clampi(int(floor(stream_pos.z / float(chunk_size))), 0, max_cz)
	var anchor_cx: int = 0 if stream_full_world_xz else cx
	var anchor_cz: int = 0 if stream_full_world_xz else cz
	if anchor_cx != last_stream_chunk.x or anchor_cz != last_stream_chunk.y or max_cy != last_stream_max_cy:
		last_stream_chunk = Vector2i(anchor_cx, anchor_cz)
		last_stream_max_cy = max_cy

		if stream_full_world_xz:
			stream_min_x = 0
			stream_max_x = max_cx
			stream_min_z = 0
			stream_max_z = max_cz
		else:
			stream_min_x = clampi(cx - stream_radius_chunks, 0, max_cx)
			stream_max_x = clampi(cx + stream_radius_chunks, 0, max_cx)
			stream_min_z = clampi(cz - stream_radius_chunks, 0, max_cz)
			stream_max_z = clampi(cz + stream_radius_chunks, 0, max_cz)
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
			stream_plane_size = x_range * z_range
			stream_pending = true
		stream_x_offsets = build_center_spiral_offsets(x_range)
		stream_z_offsets = build_center_spiral_offsets(z_range)
		stream_layer_y = stream_max_y
		stream_layer_remaining = count_unbuilt_in_layer(stream_layer_y)
	enqueue_stream_chunks()
	process_chunk_queue()
#endregion


#region Queue Processing
func process_chunk_queue() -> void:
	if world.renderer == null:
		return
	var build_count: int = min(chunks_per_frame, chunk_build_queue.size())
	for _i in range(build_count):
		var key: Vector3i = chunk_build_queue.pop_front()
		chunk_build_set.erase(key)
		var chunk := world.ensure_chunk(key)
		chunk.mesh_state = ChunkData.MESH_STATE_PENDING
		world.ensure_chunk_generated(key)
		world.renderer.regenerate_chunk(key.x, key.y, key.z)
		if stream_pending and key.y == stream_layer_y and stream_layer_remaining > 0:
			stream_layer_remaining -= 1


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
		stream_layer_remaining = count_unbuilt_in_layer(stream_layer_y)
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
		var x_spiral_index: int = int(floor(float(plane_index) / float(z_range)))
		var z_spiral_index: int = plane_index % z_range
		var x_offset: int = stream_x_offsets[x_spiral_index]
		var z_offset: int = stream_z_offsets[z_spiral_index]
		var key := Vector3i(stream_min_x + x_offset, stream_layer_y, stream_min_z + z_offset)
		if not is_chunk_mesh_ready(key) and not chunk_build_set.has(key):
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

func count_unbuilt_in_layer(layer_y: int) -> int:
	if world.renderer == null:
		return 0
	var x_range: int = stream_max_x - stream_min_x + 1
	var z_range: int = stream_max_z - stream_min_z + 1
	if x_range <= 0 or z_range <= 0:
		return 0
	var remaining := 0
	for x_offset in stream_x_offsets:
		var x: int = stream_min_x + int(x_offset)
		for z_offset in stream_z_offsets:
			var z: int = stream_min_z + int(z_offset)
			var key := Vector3i(x, layer_y, z)
			if not is_chunk_mesh_ready(key):
				remaining += 1
	return remaining


func build_center_spiral_offsets(size: int) -> Array:
	var offsets: Array = []
	if size <= 0:
		return offsets
	var center: int = int(floor(float(size - 1) / 2.0))
	offsets.append(center)
	for radius in range(1, size):
		var left: int = center - radius
		var right: int = center + radius
		var added := false
		if left >= 0:
			offsets.append(left)
			added = true
		if right < size:
			offsets.append(right)
			added = true
		if not added:
			break
	return offsets
#endregion
