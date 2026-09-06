extends RefCounted
## Main-thread coordinate set with stable, bounded cursor iteration.
## Removals leave reusable holes rather than moving an unvisited coordinate.
var members: Dictionary = {}
var slots: Array = []
var _indices: Dictionary = {}
var _free: Array[int] = []

func add(coord: Vector3i) -> void:
	if members.has(coord):
		return
	var index: int = slots.size() if _free.is_empty() else _free.pop_back()
	if index == slots.size():
		slots.append(coord)
	else:
		slots[index] = coord
	members[coord] = true
	_indices[coord] = index

func erase(coord: Vector3i) -> void:
	if not members.has(coord):
		return
	var index: int = _indices[coord]
	slots[index] = null
	_free.append(index)
	_indices.erase(coord)
	members.erase(coord)

func clear() -> void:
	members.clear()
	_indices.clear()
	_free.clear()
	slots.clear()
