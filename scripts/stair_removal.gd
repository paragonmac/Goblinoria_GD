extends RefCounted
## Explicit dismantling of player stairs. Terrain slopes remain ordinary terrain.

const Flight = preload("res://scripts/stair_flight.gd")


static func get_spec(world, pos: Vector3i) -> Dictionary:
	if not world.is_block_coord_valid(pos.x, pos.y, pos.z):
		return {}
	if not world._is_loaded_generated_cell(pos):
		return {}
	var block_id: int = world.get_block_no_generate(pos.x, pos.y, pos.z)
	if not World.PLAYER_STAIR_BLOCK_IDS.has(block_id):
		return {}
	var anchor := pos
	var rotation := -1
	var footprint: Array[Vector3i] = [pos]
	var materials: Array[int] = [block_id]
	if Flight.is_flight(block_id):
		var direction := Flight.direction(Flight.rotation_for(block_id))
		var other := pos + direction if Flight.is_lower(block_id) else pos - direction
		if world.is_block_coord_valid(other.x, other.y, other.z) and not world._is_loaded_generated_cell(other):
			return {}
		var expected := Flight.upper_id(Flight.rotation_for(block_id)) if Flight.is_lower(block_id) else Flight.lower_id(Flight.rotation_for(block_id))
		if world.get_block_no_generate(other.x, other.y, other.z) == expected:
			rotation = Flight.rotation_for(block_id)
			anchor = pos if Flight.is_lower(block_id) else other
			footprint = Flight.cells(anchor, rotation)
			materials = [Flight.lower_id(rotation), Flight.upper_id(rotation)]
	# An orphaned half from older destructive edits can also be removed explicitly.
	return {"anchor": anchor, "rotation": rotation, "footprint": footprint, "materials": materials}


static func queue(world, pos: Vector3i) -> bool:
	var spec := get_spec(world, pos)
	if spec.is_empty() or world.task_queue == null:
		return false
	for cell: Vector3i in spec.footprint:
		if not world.task_queue.get_active_tasks_at(cell).is_empty():
			return false
	var data := {
		"remove_stairs": true,
		"flight": true,
		"rotation": spec.rotation,
		"up": true,
		"footprint": spec.footprint,
		"materials": spec.materials,
	}
	return world.task_queue.add_task(spec.anchor, TaskQueue.TaskType.STAIRS,
		int(spec.materials[0]), data, spec.materials) >= 0


static func complete(world, task) -> bool:
	if task == null or task.type != TaskQueue.TaskType.STAIRS \
			or world.task_queue.get_task(task.id) != task \
			or not bool(task.data.get("remove_stairs", false)):
		return false
	var spec := get_spec(world, task.pos)
	if spec.is_empty() or spec.footprint != task.data.get("footprint", []) \
			or spec.materials != task.expected_blocks:
		return false
	for cell: Vector3i in spec.footprint:
		if is_cell_occupied(world, cell):
			return false
	# SEE-ADR-018: Validate the complete footprint before mutating either half.
	# set_block retains ordinary terrain, navigation and renderer invalidation.
	for cell: Vector3i in spec.footprint:
		world.set_block(cell.x, cell.y, cell.z, World.BLOCK_ID_AIR)
	return true


static func is_cell_occupied(world, cell: Vector3i) -> bool:
	if not world.get_workers_blocking_dig(cell).is_empty():
		return true
	for worker: Worker in world.workers:
		if worker.get_block_coord() == cell:
			return true
		# A worker between nodes still owns both ends of its current segment.
		if worker.state == Worker.WorkerState.MOVING and worker.path_segment_validated \
				and worker.path_index > 0 and worker.path_index < worker.path.size():
			if worker.path[worker.path_index - 1] == cell or worker.path[worker.path_index] == cell:
				return true
	return false
