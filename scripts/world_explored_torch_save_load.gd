extends RefCounted
class_name WorldExploredTorchSaveLoad
## Versioned persistence for explored fog and torch attachments.

const WorldSaveTransactionScript = preload("res://scripts/world_save_transaction.gd")
const EXPLORED_FILE_NAME := "explored.dat"
const TORCH_FILE_NAME := "torches.dat"
const TREE_FILE_NAME := "trees.dat"
const EXPLORED_MAGIC := 0x4558504C
const TORCH_MAGIC := 0x544F5243
const TREE_MAGIC := 0x54524545
const FORMAT_VERSION := 1
const TORCH_FORMAT_VERSION := 2
const COMPRESSION_MODE := FileAccess.COMPRESSION_DEFLATE
const MAX_TORCHES := 65536
const MAX_TREES := 1048576


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
	var ok := file.store_32(TORCH_MAGIC) and file.store_16(TORCH_FORMAT_VERSION) and file.store_32(positions.size())
	for pos in positions:
		var facing: Vector3i = world.torch_store.facing(pos)
		var facing_code := _facing_to_code(facing)
		if facing_code < 0:
			push_warning("Torch save failed: invalid facing at %s" % pos)
			file.close()
			return false
		ok = ok and file.store_32(pos.x) and file.store_32(pos.y) and file.store_32(pos.z) and file.store_8(facing_code)
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
	if (version != FORMAT_VERSION and version != TORCH_FORMAT_VERSION) or count < 0 or count > MAX_TORCHES \
			or file.get_length() - file.get_position() != count * (13 if version == TORCH_FORMAT_VERSION else 12):
		push_warning("Torch load failed: invalid format or length")
		return {"ok": false}
	var positions: Array[Vector3i] = []
	var facings := {}
	var seen := {}
	for _i in count:
		var pos := Vector3i(file.get_32(), file.get_32(), file.get_32())
		if not world.is_block_coord_valid(pos.x, pos.y, pos.z) or seen.has(pos):
			push_warning("Torch load failed: invalid position")
			return {"ok": false}
		if version == TORCH_FORMAT_VERSION:
			var facing_code := file.get_8()
			var facing := _code_to_facing(facing_code)
			if facing_code < 0 or facing == Vector3i(999, 999, 999):
				push_warning("Torch load failed: invalid facing")
				return {"ok": false}
			facings[pos] = facing
		seen[pos] = true
		positions.append(pos)
	return {"ok": true, "present": true, "format_version": version, "positions": positions, "facings": facings}


func save_trees(world, world_dir: String) -> bool:
	if world == null or world.tree_store == null:
		return false
	var positions: Array[Vector3i] = []
	for base: Vector3i in world.tree_store.trees:
		positions.append(base)
	positions.sort_custom(func(a: Vector3i, b: Vector3i) -> bool:
		if a.y != b.y: return a.y < b.y
		if a.z != b.z: return a.z < b.z
		return a.x < b.x)
	var file := FileAccess.open(world_dir.path_join(TREE_FILE_NAME), FileAccess.WRITE)
	if file == null:
		push_warning("Tree save failed")
		return false
	var ok := file.store_32(TREE_MAGIC) and file.store_16(1) and file.store_32(positions.size())
	for base: Vector3i in positions:
		var tree: Dictionary = world.tree_store.tree_at(base)
		var kind := int(tree.get("kind", -1))
		var variant := int(tree.get("variant", -1))
		var height := int(tree.get("height", -1))
		if kind < 0 or kind > 2 or variant < 0 or variant > 255 or height < 1 or height > 255:
			file.close()
			return false
		ok = ok and file.store_32(base.x) and file.store_32(base.y) and file.store_32(base.z) \
			and file.store_8(kind) and file.store_8(variant) and file.store_8(height)
	return WorldSaveTransactionScript.finish_write(file) and ok


func read_tree_snapshot(world, world_dir: String, required: bool) -> Dictionary:
	var path := world_dir.path_join(TREE_FILE_NAME)
	if not FileAccess.file_exists(path):
		return {"ok": not required, "present": false, "trees": []}
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null or file.get_length() < 10 or file.get_32() != TREE_MAGIC:
		push_warning("Tree load failed: bad header")
		return {"ok": false}
	var version := file.get_16()
	var count := file.get_32()
	if version != 1 or count < 0 or count > MAX_TREES \
			or file.get_length() - file.get_position() != count * 15:
		push_warning("Tree load failed: invalid format or length")
		return {"ok": false}
	var records: Array[Dictionary] = []
	var seen := {}
	for _i in count:
		var base := Vector3i(file.get_32(), file.get_32(), file.get_32())
		var kind := file.get_8()
		var variant := file.get_8()
		var height := file.get_8()
		if not world.is_block_coord_valid(base.x, base.y, base.z) or seen.has(base) \
				or kind > 2 or height < 1:
			push_warning("Tree load failed: invalid tree record")
			return {"ok": false}
		seen[base] = true
		records.append({"base": base, "kind": kind, "variant": variant, "height": height})
	return {"ok": true, "present": true, "trees": records}


func _facing_to_code(facing: Vector3i) -> int:
	match facing:
		Vector3i.ZERO: return 0
		Vector3i.LEFT: return 1
		Vector3i.RIGHT: return 2
		Vector3i.FORWARD: return 3
		Vector3i.BACK: return 4
		_: return -1


func _code_to_facing(code: int) -> Vector3i:
	match code:
		0: return Vector3i.ZERO
		1: return Vector3i.LEFT
		2: return Vector3i.RIGHT
		3: return Vector3i.FORWARD
		4: return Vector3i.BACK
		_: return Vector3i(999, 999, 999)


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
