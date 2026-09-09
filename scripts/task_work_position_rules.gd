extends RefCounted
class_name TaskWorkPositionRules
## Shared work-position rules used by path searches and live worker validation.

const CARDINAL_DIRS := [
	Vector3i(-1, 0, 0),
	Vector3i(1, 0, 0),
	Vector3i(0, 0, -1),
	Vector3i(0, 0, 1),
]
const StairFlightScript = preload("res://scripts/stair_flight.gd")


static func stair_work_positions(
	world,
	pathfinder: Pathfinder,
	target: Vector3i,
	flight_rotation: int = -1
) -> Array[Vector3i]:
	var positions: Array[Vector3i] = []
	if world == null or pathfinder == null:
		return positions
	if flight_rotation >= 0 and flight_rotation < StairFlightScript.ROTATION_COUNT:
		var footprint := StairFlightScript.cells(target, flight_rotation)
		for cell: Vector3i in footprint:
			for dir in CARDINAL_DIRS:
				# Do not select a work position above either cell being replaced.
				if footprint.has(cell + dir):
					continue
				_append_walkable(positions, world, pathfinder, cell + dir)
				_append_walkable(positions, world, pathfinder, cell + dir + Vector3i.UP)
		return positions
	_append_walkable(positions, world, pathfinder, target)
	_append_walkable(positions, world, pathfinder, target + Vector3i.UP)
	for dir in CARDINAL_DIRS:
		_append_walkable(positions, world, pathfinder, target + dir)
		_append_walkable(positions, world, pathfinder, target + dir + Vector3i.UP)
	return positions


static func can_work_stairs_from(
	world,
	pathfinder: Pathfinder,
	worker_pos: Vector3i,
	target: Vector3i,
	flight_rotation: int = -1
) -> bool:
	return stair_work_positions(world, pathfinder, target, flight_rotation).has(worker_pos)


static func _append_walkable(
	positions: Array[Vector3i],
	world,
	pathfinder: Pathfinder,
	pos: Vector3i
) -> void:
	if positions.has(pos):
		return
	if pathfinder.is_walkable(world, pos.x, pos.y, pos.z):
		positions.append(pos)
