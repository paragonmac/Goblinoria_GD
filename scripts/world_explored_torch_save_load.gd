extends RefCounted
class_name WorldExploredTorchSaveLoad
## Versioned persistence for explored fog and torch attachments.

const WorldSaveTransactionScript = preload("res://scripts/world_save_transaction.gd")
const EXPLORED_FILE_NAME := "explored.dat"
const TORCH_FILE_NAME := "torches.dat"
const EXPLORED_MAGIC := 0x4558504C
const TORCH_MAGIC := 0x544F5243
const FORMAT_VERSION := 1
const COMPRESSION_MODE := FileAccess.COMPRESSION_DEFLATE
const MAX_TORCHES := 65536


func save_explored(light_field, world_dir: String) -> bool:
	if light_field == null:
		return false
	var raw: PackedByteArray
	if light_field.explored.size() == light_field.VOLUME:
		raw = light_field.explored
	else:
		raw.resize(256 * 256 * 256)
		raw.fill(0)
	var compressed := raw.compress(COMPRESSION_MODE)
	var file := FileAccess.open(world_dir.path_join(EXPLORED_FILE_NAME), FileAccess.WRITE)
	if file == null:
		push_warning("Explored save failed")
		return false
	var ok := file.store_32(EXPLORED_MAGIC) and file.store_16(FORMAT_VERSION) \
		and file.store_8(COMPRESSION_MODE) and file.store_32(raw.size()) \
		and file.store_32(compressed.size()) and file.store_buffer(compressed)
	return WorldSaveTransactionScript.finish_write(file) and ok


func read_explored_snapshot(world_dir: String, required: bool) -> Dictionary:
	var path := world_dir.path_join(EXPLORED_FILE_NAME)
	if not FileAccess.file_exists(path):
		return {"ok": not required, "present": false, "explored": PackedByteArray()}
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null or file.get_length() < 15 or file.get_32() != EXPLORED_MAGIC:
		push_warning("Explored load failed: bad header")
		return {"ok": false}
	var version := file.get_16()
	var mode := file.get_8()
	var raw_size := file.get_32()
	var compressed_size := file.get_32()
	if version != FORMAT_VERSION or mode != COMPRESSION_MODE or raw_size != 256 * 256 * 256 \
			or compressed_size < 0 or file.get_length() - file.get_position() != compressed_size:
		push_warning("Explored load failed: invalid format or length")
		return {"ok": false}
	var compressed := file.get_buffer(compressed_size)
	if compressed.size() != compressed_size:
		return {"ok": false}
	var raw := compressed.decompress(raw_size, mode)
	if raw.size() != raw_size:
		push_warning("Explored load failed: decompressed length mismatch")
		return {"ok": false}
	for value in raw:
		if value != 0 and value != 255:
			push_warning("Explored load failed: invalid cell value")
			return {"ok": false}
	return {"ok": true, "present": true, "explored": raw}


func save_torches(world, world_dir: String) -> bool:
	if world == null or world.torch_store == null:
		return false
	var positions: Array[Vector3i] = world.torch_store.torch_positions()
	positions.sort_custom(func(a: Vector3i, b: Vector3i) -> bool:
		if a.y != b.y: return a.y < b.y
		if a.z != b.z: return a.z < b.z
		return a.x < b.x)
	var file := FileAccess.open(world_dir.path_join(TORCH_FILE_NAME), FileAccess.WRITE)
	if file == null:
		push_warning("Torch save failed")
		return false
	var ok := file.store_32(TORCH_MAGIC) and file.store_16(FORMAT_VERSION) and file.store_32(positions.size())
	for pos in positions:
		ok = ok and file.store_32(pos.x) and file.store_32(pos.y) and file.store_32(pos.z)
	return WorldSaveTransactionScript.finish_write(file) and ok


func read_torch_snapshot(world, world_dir: String, required: bool) -> Dictionary:
	var path := world_dir.path_join(TORCH_FILE_NAME)
	if not FileAccess.file_exists(path):
		return {"ok": not required, "present": false, "positions": []}
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null or file.get_length() < 10 or file.get_32() != TORCH_MAGIC:
		push_warning("Torch load failed: bad header")
		return {"ok": false}
	var version := file.get_16()
	var count := file.get_32()
	if version != FORMAT_VERSION or count < 0 or count > MAX_TORCHES \
			or file.get_length() - file.get_position() != count * 12:
		push_warning("Torch load failed: invalid format or length")
		return {"ok": false}
	var positions: Array[Vector3i] = []
	var seen := {}
	for _i in count:
		var pos := Vector3i(file.get_32(), file.get_32(), file.get_32())
		if not world.is_block_coord_valid(pos.x, pos.y, pos.z) or seen.has(pos):
			push_warning("Torch load failed: invalid position")
			return {"ok": false}
		seen[pos] = true
		positions.append(pos)
	return {"ok": true, "present": true, "positions": positions}


## Legacy exploration reveals worker-connected air and pending designations.
func migrate_explored(world, light_field, task_snapshot: Dictionary, cell_cap: int = 2000000) -> float:
	var started := Time.get_ticks_usec()
	var visited := PackedByteArray()
	visited.resize(light_field.VOLUME)
	var queue := PackedInt32Array()
	var head := 0
	for worker: Worker in world.workers:
		var pos := Vector3i(int(round(worker.position.x)), int(floor(worker.position.y)), int(round(worker.position.z)))
		var idx: int = light_field._world_index(pos.x, pos.y, pos.z)
		if light_field._valid(pos.x, pos.y, pos.z) and light_field.opacity[light_field.block_mirror[idx]] == 0 and visited[idx] == 0:
			visited[idx] = 1
			queue.append(idx)
	var filled := 0
	var capped := false
	# Open sky (sky light 15) is explored by the build already; the flood stops
	# there instead of filling the air volume above the terrain.
	var opacity: PackedByteArray = light_field.opacity
	var block_mirror: PackedByteArray = light_field.block_mirror
	var light: PackedByteArray = light_field.light
	var layer: int = light_field.LAYER_SIZE
	var offsets := PackedInt32Array([1, -1, 256, -256, layer, -layer])
	while head < queue.size():
		if filled >= cell_cap:
			capped = true
			break
		var idx: int = queue[head]
		head += 1
		filled += 1
		light_field._mark_explored_neighborhood(idx)
		var x: int = idx & 255
		var z: int = (idx >> 8) & 255
		var y: int = idx >> 16
		for i in 6:
			if (i == 0 and x == 255) or (i == 1 and x == 0) or (i == 2 and z == 255) 					or (i == 3 and z == 0) or (i == 4 and y == 255) or (i == 5 and y == 0):
				continue
			var neighbor: int = idx + offsets[i]
			if visited[neighbor] != 0 or opacity[block_mirror[neighbor]] != 0 or (light[neighbor] & 15) == 15:
				continue
			visited[neighbor] = 1
			queue.append(neighbor)
	for record: Dictionary in task_snapshot.get("tasks", []):
		var pos: Vector3i = record.pos
		light_field.mark_explored(pos.x, pos.y, pos.z)
		light_field._mark_explored_neighborhood(light_field._world_index(pos.x, pos.y, pos.z))
	if capped:
		push_warning("Explored migration reached %d-cell flood cap; remaining worker-connected cells stay unexplored" % cell_cap)
	return float(Time.get_ticks_usec() - started) / 1000.0
