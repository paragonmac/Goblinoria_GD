extends RefCounted
## Trees are world attachments; trunk bases obstruct movement without changing blocks.

const KIND_OAK := 0
const KIND_PINE := 1
const KIND_BUSH := 2

signal visual_state_changed

var trees: Dictionary = {} # Vector3i -> {"kind": int, "variant": int, "height": int}
var trees_by_chunk: Dictionary = {} # Vector3i chunk coord -> Dictionary[Vector3i, true]
var chunk_size := 8
var revision := 0


func add_tree(base: Vector3i, kind: int, variant: int, height: int) -> bool:
	if trees.has(base) or kind < KIND_OAK or kind > KIND_BUSH or variant < 0 or variant > 255 or height < 1:
		return false
	trees[base] = {"kind": kind, "variant": variant, "height": height}
	var chunk := _chunk_coord(base)
	if not trees_by_chunk.has(chunk):
		trees_by_chunk[chunk] = {}
	trees_by_chunk[chunk][base] = true
	revision += 1
	visual_state_changed.emit()
	return true


func remove_tree(base: Vector3i) -> bool:
	if not trees.erase(base):
		return false
	var chunk := _chunk_coord(base)
	if trees_by_chunk.has(chunk):
		trees_by_chunk[chunk].erase(base)
		if trees_by_chunk[chunk].is_empty():
			trees_by_chunk.erase(chunk)
	revision += 1
	visual_state_changed.emit()
	return true


func tree_at(base: Vector3i) -> Dictionary:
	return trees.get(base, {}).duplicate()


func has_tree(base: Vector3i) -> bool:
	return trees.has(base)


func count() -> int:
	return trees.size()


func set_chunk_size(value: int) -> void:
	if value <= 0 or value == chunk_size:
		return
	chunk_size = value
	trees_by_chunk.clear()
	for base: Vector3i in trees:
		var chunk := _chunk_coord(base)
		if not trees_by_chunk.has(chunk):
			trees_by_chunk[chunk] = {}
		trees_by_chunk[chunk][base] = true


func trees_in_chunk(chunk_coord: Vector3i) -> Array[Vector3i]:
	var result: Array[Vector3i] = []
	var indexed: Dictionary = trees_by_chunk.get(chunk_coord, {})
	for base: Vector3i in indexed:
		result.append(base)
	return result


func _chunk_coord(pos: Vector3i) -> Vector3i:
	return Vector3i(_floor_div(pos.x, chunk_size), _floor_div(pos.y, chunk_size), _floor_div(pos.z, chunk_size))


func _floor_div(value: int, divisor: int) -> int:
	var quotient := value / divisor
	if value < 0 and value % divisor != 0:
		quotient -= 1
	return quotient


func clear() -> void:
	if trees.is_empty():
		return
	trees.clear()
	trees_by_chunk.clear()
	revision += 1
	visual_state_changed.emit()
