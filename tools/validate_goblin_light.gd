extends SceneTree

const GoblinLightScript = preload("res://scripts/world/goblin_light.gd")
const WorkerScript = preload("res://scripts/worker.gd")
const CENTER := Vector3i(0, 120, 0)

var checks := 0
var failures := 0


class TestWorld extends World:
	func ensure_chunk_generated(coord: Vector3i) -> ChunkData:
		var chunk := ensure_chunk(coord)
		if chunk != null:
			chunk.generated = true
		return chunk


func _init() -> void:
	_run.call_deferred()


func _check(value: bool, message: String) -> void:
	checks += 1
	if not value:
		failures += 1
		push_error(message)


func _make_world() -> TestWorld:
	var world := TestWorld.new()
	world.block_registry.load_from_csv(World.BLOCK_DATA_PATH)
	world._init_ramp_lookup()
	for cx in range(-2, 3):
		for cz in range(-2, 3):
			for cy in range(32):
				world.ensure_chunk_generated(Vector3i(cx, cy, cz))
	for x in range(-20, 21):
		for z in range(-20, 21):
			for y in range(100, 141):
				var boundary := x == -20 or x == 20 or z == -20 or z == 20 or y == 100 or y == 140
				world.set_block_raw(x, y, z, World.BLOCK_ID_GRANITE if boundary else World.BLOCK_ID_AIR, false)
	for chunk in world.chunks.values():
		chunk.generated = true
	world.light_field.build(world)
	world.light_field_built = true
	world.goblin_light = GoblinLightScript.new()
	return world


func _add_worker(world: TestWorld, worker_id: int, cell: Vector3i) -> Worker:
	var worker: Worker = WorkerScript.new()
	worker.worker_id = worker_id
	worker.position = Vector3(cell)
	world.workers.append(worker)
	return worker


func _run() -> void:
	var world := _make_world()
	var goblin: Worker = _add_worker(world, 10, CENTER)
	_check(world.goblin_light.update(world), "new worker creates its light grid")
	_check(world.goblin_light.get_level(CENTER.x, CENTER.y, CENTER.z) == 6, "goblin cell receives level 6")
	for distance in range(1, 6):
		_check(world.goblin_light.get_level(distance, CENTER.y, CENTER.z) == 6 - distance, "open cave falloff at distance %d" % distance)
	_check(world.goblin_light.get_level(6, CENTER.y, CENTER.z) == 0, "goblin light ends at distance 6")
	_check(world.light_field.is_explored(5, CENTER.y, CENTER.z) \
		and world.light_field.is_explored(6, CENTER.y, CENTER.z), "lit cells and their neighbours are explored")

	for wall_y in range(CENTER.y - 3, CENTER.y + 4):
		for wall_z in range(-3, 4):
			world.set_block_raw(1, wall_y, wall_z, World.BLOCK_ID_GRANITE, false)
	_check(world.goblin_light.update(world), "nearby block change recomputes the goblin")
	_check(world.goblin_light.get_level(1, CENTER.y, CENTER.z) == 0 \
		and world.goblin_light.get_level(2, CENTER.y, CENTER.z) == 0, "one-block wall blocks light behind it")
	_check(world.goblin_light.get_level(1, CENTER.y, 4) == 1, "light reaches the wall edge at its path distance")
	var gpu: Dictionary = world.goblin_light.build_gpu_data(CENTER)
	var gpu_cells: PackedVector4Array = gpu.cells
	var atlas: PackedByteArray = gpu.atlas
	_check(int(gpu.count) == 1 and gpu_cells.size() == GoblinLightScript.MAX_GPU_GOBLINS \
		and Vector3i(int(gpu_cells[0].x), int(gpu_cells[0].y), int(gpu_cells[0].z)) == CENTER, "GPU data includes the nearest goblin cell")
	_check(atlas.size() == 121 * 11 * GoblinLightScript.MAX_GPU_GOBLINS \
		and atlas[5 * 121 + 60] == 6 * 17 and atlas[5 * 121 + 61] == 0, "GPU atlas maps the goblin and wall-blocked cells")
	_check(not world.goblin_light.gpu_dirty, "GPU data build clears gpu_dirty")
	for wall_y in range(CENTER.y - 3, CENTER.y + 4):
		for wall_z in range(-3, 4):
			if wall_y == CENTER.y and wall_z == CENTER.z:
				continue
			world.set_block_raw(1, wall_y, wall_z, World.BLOCK_ID_AIR, false)
	world.goblin_light.update(world)
	_check(world.goblin_light.get_level(1, CENTER.y, 1) == 4, "light travels around a one-cell corner at path distance 2")

	var prior_bfs := world.goblin_light.bfs_count
	goblin.position = Vector3(CENTER + Vector3i(0, 0, 1))
	world.goblin_light.update(world)
	_check(world.goblin_light.bfs_count - prior_bfs == 1, "moving a goblin recomputes only that goblin")
	world.set_block_raw(1, CENTER.y, CENTER.z, World.BLOCK_ID_AIR, false)
	world.goblin_light.notify_block_changed(1, CENTER.y, CENTER.z)
	world.goblin_light.update(world)
	_check(world.goblin_light.get_level(2, CENTER.y, CENTER.z) > 0, "digging a wall relights the nearby goblin")
	world.workers.clear()
	_check(world.goblin_light.update(world) and world.goblin_light.get_level(0, CENTER.y, 1) == 0, "removed worker drops its light grid")
	_check(world.light_field.is_explored(CENTER.x, CENTER.y, CENTER.z), "exploration persists after the goblin leaves")
	goblin.free()

	var nearby := _add_worker(world, 22, CENTER)
	var far := _add_worker(world, 3, CENTER + Vector3i(4, 0, 0))
	var tied_far := _add_worker(world, 2, CENTER + Vector3i(-4, 0, 0))
	world.goblin_light.update(world)
	var nearest: Dictionary = world.goblin_light.build_gpu_data(CENTER, 1)
	var nearest_cells: PackedVector4Array = nearest.cells
	_check(int(nearest.count) == 1 and int(nearest_cells[0].x) == CENTER.x \
		and int(nearest_cells[0].y) == CENTER.y and int(nearest_cells[0].z) == CENTER.z, "GPU selection is nearest focus first")
	var ordered: Dictionary = world.goblin_light.build_gpu_data(CENTER)
	var ordered_cells: PackedVector4Array = ordered.cells
	_check(int(ordered_cells[1].x) == CENTER.x - 4 and int(ordered_cells[2].x) == CENTER.x + 4, "equidistant GPU cells are ordered by worker ID")

	world.workers.clear()
	world.goblin_light.update(world)
	nearby.free()
	far.free()
	tied_far.free()
	var crowd: Array[Worker] = []
	for index in 36:
		var cell := Vector3i(-15 + index % 9 * 3, 120, -15 + index / 9 * 3)
		crowd.append(_add_worker(world, 100 + index, cell))
	world.goblin_light.update(world)
	for worker in crowd:
		worker.position.x += 1.0
	var started := Time.get_ticks_usec()
	world.goblin_light.update(world)
	var cost_usec := Time.get_ticks_usec() - started
	print("Goblin light 36-worker move update us: %d (target <= 5000)" % cost_usec)
	if cost_usec > 5000:
		print("WARN: 36-worker goblin light update exceeded 5 ms")
	for worker in world.workers:
		worker.free()
	world.workers.clear()
	world.free()
	print("Goblin light: %d checks, %d failures" % [checks, failures])
	quit(1 if failures else 0)
