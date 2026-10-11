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
	flight_rotation: int = -1,
	excluded_cells: Array = []
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
				_append_walkable(positions, world, pathfinder, cell + dir, excluded_cells)
				_append_walkable(positions, world, pathfinder, cell + dir + Vector3i.UP, excluded_cells)
		return positions
	_append_walkable(positions, world, pathfinder, target, excluded_cells)
	_append_walkable(positions, world, pathfinder, target + Vector3i.UP, excluded_cells)
	for dir in CARDINAL_DIRS:
		_append_walkable(positions, world, pathfinder, target + dir, excluded_cells)
		_append_walkable(positions, world, pathfinder, target + dir + Vector3i.UP, excluded_cells)
	return positions


static func can_work_stairs_from(
	world,
	pathfinder: Pathfinder,
	worker_pos: Vector3i,
	target: Vector3i,
	flight_rotation: int = -1,
	excluded_cells: Array = []
) -> bool:
	return stair_work_positions(world, pathfinder, target, flight_rotation, excluded_cells).has(worker_pos)


static func task_work_positions(
	world,
	pathfinder: Pathfinder,
	target: Vector3i,
	task_type: int
) -> Array[Vector3i]:
	match task_type:
		TaskQueue.TaskType.DIG, TaskQueue.TaskType.PLACE, TaskQueue.TaskType.TORCH, TaskQueue.TaskType.CHOP:
			return _cardinal_work_positions(world, pathfinder, target)
	var empty: Array[Vector3i] = []
	return empty


static func can_work_task_from(
	world,
	pathfinder: Pathfinder,
	worker_pos: Vector3i,
	task_pos: Vector3i,
	task_type: int
) -> bool:
	if task_type != TaskQueue.TaskType.DIG and task_type != TaskQueue.TaskType.PLACE and task_type != TaskQueue.TaskType.TORCH and task_type != TaskQueue.TaskType.CHOP:
		return false
	return can_work_face_from(world, pathfinder, worker_pos, task_pos)


static func stair_excluded_cells_for_task(task) -> Array[Vector3i]:
	var cells: Array[Vector3i] = []
	if task == null or task.type != TaskQueue.TaskType.STAIRS \
			or not (task.data is Dictionary) \
			or not bool(task.data.get("remove_stairs", false)):
		return cells
	var raw_cells = task.data.get("footprint", [])
	if raw_cells is Array:
		for value in raw_cells:
			if value is Vector3i:
				cells.append(value)
	if cells.is_empty():
		cells.append(task.pos)
	var above_cells: Array[Vector3i] = cells.duplicate()
	for cell: Vector3i in above_cells:
		var above := cell + Vector3i.UP
		if not cells.has(above):
			cells.append(above)
	return cells


static func can_work_face_from(
	world,
	pathfinder: Pathfinder,
	worker_pos: Vector3i,
	task_pos: Vector3i
) -> bool:
	if world == null or pathfinder == null:
		return false
	# The interaction is horizontal and cardinal. A half-height stair still
	# belongs to its physical cell's logical level (both halves floor to y).
	if worker_pos.y != task_pos.y:
		return false
	var dx: int = abs(worker_pos.x - task_pos.x)
	var dz: int = abs(worker_pos.z - task_pos.z)
	if dx + dz != 1:
		return false
	if not world.is_block_coord_valid(worker_pos.x, worker_pos.y, worker_pos.z) \
			or not world.is_block_coord_valid(task_pos.x, task_pos.y, task_pos.z):
		return false
	if not pathfinder.is_walkable(world, worker_pos.x, worker_pos.y, worker_pos.z):
		return false
	var worker_block: int = world.get_block_no_generate(worker_pos.x, worker_pos.y, worker_pos.z)
	var task_block: int = world.get_block_no_generate(task_pos.x, task_pos.y, task_pos.z)
	# Player stair flights are infrastructure, never a dig/place work face.
	# This also keeps a worker from reaching through a high or side stair face.
	if StairFlightScript.is_flight(task_block):
		return false
	if StairFlightScript.is_flight(worker_block):
		if not StairFlightScript.is_lower(worker_block):
			return false
		var direction := StairFlightScript.direction(StairFlightScript.rotation_for(worker_block))
		var work_dir := Vector2i(task_pos.x - worker_pos.x, task_pos.z - worker_pos.z)
		# The lower half's outside face is opposite the flight direction.
		if work_dir != Vector2i(-direction.x, -direction.z):
			return false
		return pathfinder.is_valid_flight_cell(world, worker_pos)
	# Legacy player stairs and generated terrain slopes retain Pathfinder's
	# directional low-edge rules. Its same-level check accepts a solid work
	# face, while rejecting high/side faces. A covered legacy ramp is not a
	# physically valid worker position even though it predates two-cell stairs.
	if world.is_ramp_block_id(worker_block):
		if not _has_ramp_headroom(world, pathfinder, worker_pos):
			return false
	return pathfinder.can_move_same_level(world, worker_pos, task_pos)


static func _cardinal_work_positions(
	world,
	pathfinder: Pathfinder,
	target: Vector3i
) -> Array[Vector3i]:
	var positions: Array[Vector3i] = []
	for dir in CARDINAL_DIRS:
		var candidate: Vector3i = target + dir
		if can_work_face_from(world, pathfinder, candidate, target):
			positions.append(candidate)
	return positions


static func _has_ramp_headroom(world, pathfinder: Pathfinder, pos: Vector3i) -> bool:
	var above := pos + Vector3i.UP
	if not world.is_block_coord_valid(above.x, above.y, above.z):
		return false
	var above_id: int = world.get_block_no_generate(above.x, above.y, above.z)
	return not pathfinder.is_blocking(world, above_id)


static func _append_walkable(
	positions: Array[Vector3i],
	world,
	pathfinder: Pathfinder,
	pos: Vector3i,
	excluded_cells: Array = []
) -> void:
	if positions.has(pos):
		return
	if excluded_cells.has(pos):
		return
	if pathfinder.is_walkable(world, pos.x, pos.y, pos.z):
		positions.append(pos)
