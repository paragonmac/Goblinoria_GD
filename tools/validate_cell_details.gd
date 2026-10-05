extends SceneTree

const Model = preload("res://scripts/ui/colony_presentation_model.gd")
const Roles = preload("res://scripts/worker_roles.gd")

class TestWorld extends World:
	func ensure_chunk_generated(coord: Vector3i) -> ChunkData:
		var chunk := ensure_chunk(coord)
		chunk.generated = true
		return chunk

var checks := 0
var failures := 0


func _init() -> void:
	_test_cell_details()
	print("Cell details: %d checks, %d failures" % [checks, failures])
	quit(1 if failures else 0)


func _check(value: bool, message: String) -> void:
	checks += 1
	if not value:
		failures += 1
		push_error(message)


func _world() -> World:
	var world := TestWorld.new()
	world.world_size_y = 16
	world._init_ramp_lookup()
	world.block_registry.load_from_csv(World.BLOCK_DATA_PATH)
	world.task_manager = TaskManager.new(world, world.task_queue)
	return world


func _put(world: World, cell: Vector3i, block_id: int) -> void:
	world.set_block_raw(cell.x, cell.y, cell.z, block_id, true)


func _test_cell_details() -> void:
	var world := _world()
	var floor_cell := Vector3i(0, 3, 0)
	var occupant_cell := floor_cell + Vector3i.UP
	_put(world, floor_cell, World.BLOCK_ID_GRANITE)
	_put(world, occupant_cell, World.BLOCK_ID_AIR)
	for entry in [[7, Roles.Role.MINER, Worker.WorkerState.IDLE],
		[8, Roles.Role.HAULER, Worker.WorkerState.MOVING]]:
		var worker := Worker.new()
		worker.worker_id = entry[0]
		worker.role_id = entry[1]
		worker.state = entry[2]
		worker.position = Vector3(occupant_cell)
		world.add_child(worker)
		world.workers.append(worker)
	var stockpile_id: int = world.stockpile_store.create_stockpile([occupant_cell])
	world.item_store.add_stack(2, 3, occupant_cell)
	world.item_store.add_stack(3, 4, occupant_cell, stockpile_id)
	var carried_item: int = world.item_store.add_stack(3, 9, occupant_cell, stockpile_id)
	world.item_store.reserve_item(carried_item, 99)
	world.item_store.mark_carried(carried_item)
	var dig_id: int = world.task_queue.add_dig_task(floor_cell)
	var unrelated_id: int = world.task_queue.add_dig_task(Vector3i(2, 3, 0))
	var floor_details: Dictionary = Model.cell_details(world, floor_cell, 1)
	_check(floor_details.workers.size() == 2, "Floor details missed workers in the occupant cell")
	_check(floor_details.workers[0].label.begins_with("Worker 7 - Miner - Idle") \
		and floor_details.workers[1].label.begins_with("Worker 8 - Hauler - Moving"), "Worker labels lost role or state")
	var has_loose := false
	var has_stored := false
	for item: Dictionary in floor_details.items:
		has_loose = has_loose or item.label.ends_with("x3 - loose")
		has_stored = has_stored or item.label.ends_with("x4 - stored")
	_check(floor_details.items.size() == 2 and has_loose and has_stored, "Cell details missed loose/stored stacks")
	_check(floor_details.stockpile.id == stockpile_id, "Cell details missed occupant-cell stockpile")
	_check(floor_details.jobs.size() == 1 and floor_details.jobs[0].id == dig_id \
		and floor_details.jobs[0].label == "Dig - pending - unknown", "Cell details included an unrelated task or lost the DIG job")
	_check(floor_details.jobs.all(func(job: Dictionary) -> bool: return int(job.id) != unrelated_id), "Unrelated task was listed")
	_check(floor_details.solid and floor_details.diggable and floor_details.block_name == "Granite" \
		and floor_details.block_id == World.BLOCK_ID_GRANITE, "Granite header flags or live block identity are wrong")
	var air_cell := Vector3i(4, 3, 0)
	_put(world, air_cell, World.BLOCK_ID_AIR)
	world.item_store.add_stack(2, 1, air_cell)
	var air_details: Dictionary = Model.cell_details(world, air_cell, 1)
	_check(air_details.occupant_cell == air_cell and air_details.items.size() == 1 \
		and air_details.items[0].label.ends_with("x1 - loose"), "Air selection did not use its selected cell")
	var stair_cell := Vector3i(6, 3, 0)
	_put(world, stair_cell, World.RAMP_NORTH_ID)
	var stair_details: Dictionary = Model.cell_details(world, stair_cell, 1)
	_check(stair_details.shape == "Player stairs" \
		and stair_details.protection_reason == "stairs_require_removal", "Player stair header missed shape or protection reason")
	var slope_cell := Vector3i(8, 3, 0)
	_put(world, slope_cell, World.TERRAIN_SLOPE_NORTH_ID)
	var slope_details: Dictionary = Model.cell_details(world, slope_cell, 1)
	_check(slope_details.shape == "Terrain slope", "Terrain slope header was mislabeled")
	var empty_cell := Vector3i(10, 3, 0)
	_put(world, empty_cell, World.BLOCK_ID_AIR)
	var empty_details: Dictionary = Model.cell_details(world, empty_cell, 1)
	_check(empty_details.empty and empty_details.workers.is_empty() and empty_details.items.is_empty() \
		and empty_details.stockpile.is_empty() and empty_details.jobs.is_empty(), "Empty cell marker or empty groups are incorrect")
	_dispose(world)


func _dispose(world: World) -> void:
	world.task_manager.shutdown()
	world.free()
