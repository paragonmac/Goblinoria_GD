extends SceneTree

const TaskWorkPositionRulesScript = preload("res://scripts/task_work_position_rules.gd")

var failed := false


class ReachWorld:

	var world_size_y := 6
	var blocks: Dictionary = {}
	var workers: Array = []
	var task_queue := TaskQueue.new()

	func reset() -> void:
		blocks.clear()
		for x in range(-8, 9):
			for z in range(-8, 9):
				blocks[Vector3i(x, 0, z)] = World.BLOCK_ID_GRANITE

	func is_block_coord_valid(x: int, y: int, z: int) -> bool:
		return x >= -8 and x <= 8 and z >= -8 and z <= 8 and y >= 0 and y < world_size_y

	func get_block_no_generate(x: int, y: int, z: int) -> int:
		if not is_block_coord_valid(x, y, z):
			return World.BLOCK_ID_AIR
		return int(blocks.get(Vector3i(x, y, z), World.BLOCK_ID_AIR))

	func get_block(x: int, y: int, z: int) -> int:
		return get_block_no_generate(x, y, z)

	func set_block(x: int, y: int, z: int, block_id: int) -> void:
		blocks[Vector3i(x, y, z)] = block_id

	func is_block_solid_id(block_id: int) -> bool:
		return block_id == World.BLOCK_ID_GRANITE \
			or block_id == World.BLOCK_ID_GRASS \
			or block_id == World.BLOCK_ID_DIRT

	func is_ramp_block_id(block_id: int) -> bool:
		return World.RAMP_BLOCK_IDS.has(block_id)

	func is_diggable_at(x: int, y: int, z: int) -> bool:
		return is_block_solid_id(get_block_no_generate(x, y, z))

	func stair_dig_reject_reason(_pos: Vector3i) -> String:
		return ""

	func get_workers_blocking_dig(_pos: Vector3i) -> Array:
		return []

	func spawn_mining_drops(_block_id: int, _pos: Vector3i) -> void:
		pass

	func reassess_waiting_tasks() -> void:
		pass

	func get_block_name(_block_id: int) -> String:
		return "test"

	func trace_worker_event(_worker, _event: String, _task = null, _details: String = "") -> void:
		pass


func _check(condition: bool, message: String) -> void:
	if not condition:
		push_error(message)
		failed = true


func _flight_setup(world: ReachWorld, rotation: int) -> Dictionary:
	world.reset()
	var lower := Vector3i(0, 1, 0)
	var direction := StairFlight.direction(rotation)
	var upper := lower + direction
	world.set_block(lower.x, lower.y, lower.z, StairFlight.lower_id(rotation))
	world.set_block(upper.x, upper.y, upper.z, StairFlight.upper_id(rotation))
	var low_target := lower - direction
	var high_target := upper + direction
	var side_direction := Vector3i(-direction.z, 0, direction.x)
	var side_target := lower + side_direction
	for target: Vector3i in [low_target, high_target, side_target]:
		world.set_block(target.x, target.y, target.z, World.BLOCK_ID_GRASS)
	return {
		"lower": lower,
		"upper": upper,
		"low_target": low_target,
		"high_target": high_target,
		"side_target": side_target,
	}


func _flight_reach_contract(world: ReachWorld, pathfinder: Pathfinder) -> void:
	for rotation in range(StairFlight.ROTATION_COUNT):
		var cells := _flight_setup(world, rotation)
		var lower: Vector3i = cells["lower"]
		var upper: Vector3i = cells["upper"]
		var low_target: Vector3i = cells["low_target"]
		var high_target: Vector3i = cells["high_target"]
		var side_target: Vector3i = cells["side_target"]
		_check(pathfinder.is_walkable(world, lower.x, lower.y, lower.z), "supported lower half is not walkable rot=%d" % rotation)
		_check(pathfinder.is_walkable(world, upper.x, upper.y, upper.z), "supported upper half is not walkable rot=%d" % rotation)
		_check(TaskWorkPositionRulesScript.can_work_task_from(world, pathfinder, lower, low_target, TaskQueue.TaskType.DIG), "low edge is not a mining face rot=%d" % rotation)
		_check(not TaskWorkPositionRulesScript.can_work_task_from(world, pathfinder, lower, high_target, TaskQueue.TaskType.DIG), "high edge is a mining face rot=%d" % rotation)
		_check(not TaskWorkPositionRulesScript.can_work_task_from(world, pathfinder, lower, side_target, TaskQueue.TaskType.DIG), "side edge is a mining face rot=%d" % rotation)
		_check(not TaskWorkPositionRulesScript.can_work_task_from(world, pathfinder, upper, high_target, TaskQueue.TaskType.DIG), "upper half exposes a mining face rot=%d" % rotation)
		var positions := TaskWorkPositionRulesScript.task_work_positions(world, pathfinder, low_target, TaskQueue.TaskType.DIG)
		_check(positions.has(lower), "dig candidate omitted lower stair endpoint rot=%d" % rotation)
		var start := upper + StairFlight.direction(rotation) + Vector3i.UP
		var start_support := start + Vector3i.DOWN
		world.set_block(start_support.x, start_support.y, start_support.z, World.BLOCK_ID_GRANITE)
		var scheduler := PathSearchScheduler.new()
		var scheduler_path := scheduler._find_work_path(
			world,
			pathfinder,
			start,
			low_target,
			TaskQueue.TaskType.DIG,
			Pathfinder.TASK_SEARCH_MAX_ITERATIONS
		)
		_check(not scheduler_path.is_empty() and scheduler_path[scheduler_path.size() - 1] == lower, "threaded work rule omitted stair endpoint rot=%d" % rotation)

		world.set_block(lower.x, lower.y + 1, lower.z, World.BLOCK_ID_GRANITE)
		_check(not TaskWorkPositionRulesScript.can_work_task_from(world, pathfinder, lower, low_target, TaskQueue.TaskType.DIG), "covered lower stair still reachable rot=%d" % rotation)
		world.set_block(lower.x, lower.y + 1, lower.z, World.BLOCK_ID_AIR)
		world.set_block(lower.x, lower.y - 1, lower.z, World.BLOCK_ID_AIR)
		_check(not TaskWorkPositionRulesScript.can_work_task_from(world, pathfinder, lower, low_target, TaskQueue.TaskType.DIG), "unsupported lower stair still reachable rot=%d" % rotation)


func _legacy_ramp_contract(world: ReachWorld, pathfinder: Pathfinder) -> void:
	world.reset()
	var ramp := Vector3i(0, 1, 0)
	var low_target := Vector3i(0, 1, 1)
	var high_target := Vector3i(0, 1, -1)
	world.set_block(ramp.x, ramp.y, ramp.z, World.RAMP_NORTH_ID)
	world.set_block(low_target.x, low_target.y, low_target.z, World.BLOCK_ID_GRASS)
	world.set_block(high_target.x, high_target.y, high_target.z, World.BLOCK_ID_GRASS)
	_check(TaskWorkPositionRulesScript.can_work_task_from(world, pathfinder, ramp, low_target, TaskQueue.TaskType.DIG), "legacy ramp low edge is not a mining face")
	_check(not TaskWorkPositionRulesScript.can_work_task_from(world, pathfinder, ramp, high_target, TaskQueue.TaskType.DIG), "legacy ramp high edge is a mining face")
	world.set_block(ramp.x, ramp.y + 1, ramp.z, World.BLOCK_ID_GRANITE)
	_check(not TaskWorkPositionRulesScript.can_work_task_from(world, pathfinder, ramp, low_target, TaskQueue.TaskType.DIG), "covered legacy ramp is still a mining face")


func _flat_and_worker_execution(world: ReachWorld, pathfinder: Pathfinder) -> void:
	world.reset()
	var flat_worker := Vector3i(2, 1, 0)
	var flat_target := Vector3i(3, 1, 0)
	world.set_block(flat_target.x, flat_target.y, flat_target.z, World.BLOCK_ID_GRASS)
	_check(TaskWorkPositionRulesScript.can_work_task_from(world, pathfinder, flat_worker, flat_target, TaskQueue.TaskType.DIG), "ordinary flat dig face was rejected")

	var cells := _flight_setup(world, 0)
	var lower: Vector3i = cells["lower"]
	var first_target: Vector3i = cells["low_target"]
	var second_target := first_target + Vector3i(0, 0, 1)
	world.set_block(second_target.x, second_target.y, second_target.z, World.BLOCK_ID_GRASS)
	var worker := Worker.new()
	worker.worker_id = 7
	worker.position = Vector3(lower.x, lower.y + 0.25, lower.z)
	_check(worker.get_block_coord() == lower, "lower stair interpolation changed logical worker cell")
	worker.position.y = float(lower.y) + 0.75
	_check(worker.get_block_coord() == lower, "upper stair interpolation changed logical worker cell")
	worker.position = Vector3(lower)
	var first_id := world.task_queue.add_dig_task(first_target)
	var first_task = world.task_queue.get_task(first_id)
	worker.current_task_id = first_id
	worker.state = Worker.WorkerState.WORKING
	_check(worker.can_work_task(first_task, world, pathfinder), "worker cannot execute first stair-front dig")
	worker.update_working(0.0, world, world.task_queue, pathfinder)
	_check(world.get_block(first_target.x, first_target.y, first_target.z) == World.BLOCK_ID_AIR, "first stair-front block was not mined")

	worker.position = Vector3(second_target.x - 1, second_target.y, second_target.z)
	var second_id := world.task_queue.add_dig_task(second_target)
	var second_task = world.task_queue.get_task(second_id)
	worker.current_task_id = second_id
	worker.state = Worker.WorkerState.WORKING
	_check(worker.can_work_task(second_task, world, pathfinder), "worker cannot execute second stair-front dig")
	worker.update_working(0.0, world, world.task_queue, pathfinder)
	_check(world.get_block(second_target.x, second_target.y, second_target.z) == World.BLOCK_ID_AIR, "second stair-front block was not mined")
	worker.free()


func _init() -> void:
	var world := ReachWorld.new()
	var pathfinder := Pathfinder.new()
	_flight_reach_contract(world, pathfinder)
	_legacy_ramp_contract(world, pathfinder)
	_flat_and_worker_execution(world, pathfinder)
	if failed:
		quit(1)
	else:
		print("validate_stair_mining_reach: PASS")
		quit(0)
