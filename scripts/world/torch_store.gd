extends RefCounted
class_name TorchStore
## Torches are world attachments; they never alter the block or pathing grids.

signal visual_state_changed

var torches: Dictionary = {} # Vector3i -> Vector3i facing
var revision := 0
var _world


func bind_world(world) -> void:
	_world = world


func clear() -> void:
	if _world != null and _world.light_field != null:
		for pos: Vector3i in torches.keys():
			_world.light_field.remove_light_source(pos)
	torches.clear()
	revision += 1
	visual_state_changed.emit()


func add_torch(pos: Vector3i, facing: Vector3i = Vector3i.ZERO) -> bool:
	if torches.has(pos):
		return false
	torches[pos] = facing
	if _world != null and _world.light_field_built:
		_world.light_field.add_light_source(pos, 15)
	revision += 1
	visual_state_changed.emit()
	return true


func remove_torch(pos: Vector3i) -> bool:
	if not torches.erase(pos):
		return false
	if _world != null and _world.light_field != null:
		_world.light_field.remove_light_source(pos)
	revision += 1
	visual_state_changed.emit()
	return true


func has_torch(pos: Vector3i) -> bool:
	return torches.has(pos)


func facing(pos: Vector3i) -> Vector3i:
	return torches.get(pos, Vector3i.ZERO)


func set_facing(pos: Vector3i, facing: Vector3i) -> void:
	if not torches.has(pos) or torches[pos] == facing:
		return
	torches[pos] = facing
	revision += 1
	visual_state_changed.emit()


func torch_positions() -> Array[Vector3i]:
	var positions: Array[Vector3i] = []
	for pos: Vector3i in torches.keys():
		positions.append(pos)
	return positions


func count() -> int:
	return torches.size()


func register_light_sources() -> void:
	if _world == null or not _world.light_field_built:
		return
	for pos: Vector3i in torches.keys():
		if not _world.light_field.has_light_source(pos):
			_world.light_field.add_light_source(pos, 15)
