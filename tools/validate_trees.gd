extends SceneTree
## Tree generation, attachment, pathing, chopping and persistence contract.

const VegetationScript = preload("res://scripts/world/world_vegetation_generator.gd")
const PipelineScript = preload("res://scripts/world_generation_pipeline.gd")
const SnapshotScript = preload("res://scripts/pathfinding/path_world_snapshot.gd")
const NavGridScript = preload("res://scripts/pathfinding/nav_grid.gd")
const SelectionScript = preload("res://scripts/main_selection_controller.gd")
const SaveLoadScript = preload("res://scripts/world_save_load.gd")
const TreeKinds = preload("res://scripts/world/tree_store.gd")
const Roles = preload("res://scripts/worker_roles.gd")

class TestWorld extends World:
	func _ready() -> void:
		_init_ramp_lookup()
		block_registry.load_from_csv(BLOCK_DATA_PATH)
		sea_level = 40
		top_render_y = 40
		deepest_structure_y = 0
		task_manager = TaskManager.new(self, task_queue)
		save_load = SaveLoadScript.new(self)
		generator = WorldGenerator.new(self)

	func ensure_chunk_generated(coord: Vector3i) -> ChunkData:
		var chunk := ensure_chunk(coord)
		chunk.generated = true
		return chunk

	func load_saved_chunk(coord: Vector3i) -> ChunkData:
		var chunk := ensure_chunk(coord)
		if save_load.load_chunk_into(coord, chunk):
			return chunk
		chunk.generated = true
		return chunk

	func _start_worker_trace_for_spawned_workers() -> void:
		pass

var checks := 0
var failures := 0
var forest_counts := {"oak": 0, "pine": 0, "bush": 0}
var pipeline_tree_counts := {"oak": 0, "pine": 0, "bush": 0}


func _init() -> void:
	_run.call_deferred()


func _check(value: bool, message: String) -> void:
	checks += 1
	if not value:
		failures += 1
		push_error(message)


func _run() -> void:
	_test_generation()
	_test_pipeline_tree_match()
	var world := TestWorld.new()
	root.add_child(world)
	_build_fixture(world)
	_test_pathing(world)
	await _test_chop_and_support(world)
	await _test_nav_grid_tree_blocking()
	await _test_tree_crossing_task_routes()
	await _test_in_progress_chop_cancel()
	_test_legacy_rejections()
	await _test_persistence(world)
	await _test_legacy_migration()
	print("Trees: %d checks, %d failures" % [checks, failures])
	world.task_manager.shutdown()
	world.queue_free()
	quit(1 if failures else 0)


func _test_generation() -> void:
	const SX := 48
	const SY := 4
	const SZ := 48
	var elevation := PackedInt32Array()
	elevation.resize(SX * SZ)
	elevation.fill(1)
	var biome := PackedByteArray()
	biome.resize(SX * SZ)
	biome.fill(1)
	for z in SZ:
		for x in range(SX / 2, SX):
			biome[z * SX + x] = 0
	var reserved := PackedByteArray()
	reserved.resize(SX * SZ)
	var volume := PackedByteArray()
	volume.resize(SX * SY * SZ)
	volume.fill(World.BLOCK_ID_AIR)
	for z in SZ:
		for x in SX:
			volume[(z * SY + 1) * SX + x] = World.BLOCK_ID_GRASS
	for z in range(10, 14):
		for x in range(4, 8):
			volume[(z * SY + 1) * SX + x] = World.BLOCK_ID_GRANITE
	var first := _generate_fixture_trees(71421, SX, SY, SZ, elevation, biome, reserved, volume)
	var second := _generate_fixture_trees(71421, SX, SY, SZ, elevation, biome, reserved, volume)
	_check(first == second, "same seed and fixture produce identical tree records")
	var bases: Array[Vector3i] = []
	for base: Vector3i in first:
		var tree: Dictionary = first[base]
		bases.append(base)
		var local_x: int = base.x + SX / 2
		var local_z: int = base.z + SZ / 2
		var ground_id := int(volume[(local_z * SY + base.y - 1) * SX + local_x])
		_check(ground_id == World.BLOCK_ID_GRASS or ground_id == World.BLOCK_ID_MOSS, "tree stands only on grass or moss")
		_check(Vector2(base.x, base.z).length_squared() > 225.0, "spawn clearance excludes worker offsets within fifteen cells")
		match int(tree.kind):
			TreeKinds.KIND_OAK:
				forest_counts.oak += 1
				_check(int(tree.height) >= 5 and int(tree.height) <= 7, "oak height is in range")
			TreeKinds.KIND_PINE:
				forest_counts.pine += 1
				_check(int(tree.height) >= 6 and int(tree.height) <= 9, "pine height is in range")
			TreeKinds.KIND_BUSH:
				forest_counts.bush += 1
				_check(int(tree.height) == 1, "bush height is one")
	for i in bases.size():
		for j in range(i + 1, bases.size()):
			var dx: int = bases[i].x - bases[j].x
			var dz: int = bases[i].z - bases[j].z
			_check(dx * dx + dz * dz >= 4, "tree trunks have at least two cells of spacing")
	_check(first.size() > 0, "generated fixture contains trees")


func _generate_fixture_trees(seed_value: int, sx: int, sy: int, sz: int, elevation: PackedInt32Array, biome: PackedByteArray, reserved: PackedByteArray, volume: PackedByteArray) -> Dictionary:
	var generator = VegetationScript.new()
	generator.configure(seed_value, sx, sy, sz, elevation, biome, reserved, {"plains": 0, "forest": 1})
	return generator.place_trees(volume, -sx / 2, -sz / 2)


func _test_pipeline_tree_match() -> void:
	var config := {
		"world_seed": 12345,
		"sea_level": 40,
		"world_size_y": 64,
		"chunk_size": 8,
		"world_chunks_x": 4,
		"world_chunks_y": 8,
		"world_chunks_z": 4,
		"world_min_chunk_x": -2,
		"world_max_chunk_x": 1,
		"world_min_chunk_z": -2,
		"world_max_chunk_z": 1,
	}
	var full_trees: Dictionary = PipelineScript.new().generate(config).get("trees", {})
	var migrated_trees: Dictionary = PipelineScript.new().generate_tree_attachments(config)
	_check(full_trees == migrated_trees, "fast legacy tree generation matches the full-map generation pipeline")
	for tree: Dictionary in full_trees.values():
		match int(tree.kind):
			TreeKinds.KIND_OAK:
				pipeline_tree_counts.oak += 1
			TreeKinds.KIND_PINE:
				pipeline_tree_counts.pine += 1
			TreeKinds.KIND_BUSH:
				pipeline_tree_counts.bush += 1


func _build_fixture(world: TestWorld) -> void:
	world.world_seed = 7401
	world.spawn_coord = Vector3i.ZERO
	for x in range(-3, 12):
		for z in range(-3, 5):
			world.set_block_raw(x, 19, z, World.BLOCK_ID_GRASS, false)
			for y in range(20, 28):
				world.set_block_raw(x, y, z, World.BLOCK_ID_AIR, false)
	for chunk: ChunkData in world.chunks.values():
		chunk.generated = true
	world.light_field.explored.resize(world.light_field.VOLUME)
	world.light_field.explored.fill(0)
	world.light_field_built = true
	for x in range(-3, 12):
		for z in range(-3, 5):
			world.light_field.mark_explored(x, 19, z)
			world.light_field.mark_explored(x, 20, z)
	world.drop_rng.seed = 991


func _test_pathing(world: TestWorld) -> void:
	var obstacle := Vector3i(2, 20, 1)
	_check(world.add_tree(obstacle, TreeKinds.KIND_OAK, 4, 6), "tree attachment adds")
	var start := Vector3i(1, 20, 1)
	var goal := Vector3i(3, 20, 1)
	_check(not world.pathfinder.is_walkable(world, obstacle.x, obstacle.y, obstacle.z), "trunk base is not walkable")
	var path: Array = world.pathfinder.find_path(world, start, goal, false)
	_check(not path.is_empty() and not path.has(obstacle), "path routes around the trunk")
	var snapshot = SnapshotScript.new()
	snapshot.capture_from_world(world, start, [goal], 8, 2)
	var tokens: Dictionary = snapshot.path_revision_tokens(path)
	var second := Vector3i(4, 20, 1)
	_check(world.add_tree(second, TreeKinds.KIND_BUSH, 0, 1), "second tree attachment adds")
	_check(not SnapshotScript.path_tokens_match(world, tokens), "adding a tree invalidates dependent path snapshot tokens")
	snapshot.capture_from_world(world, start, [goal], 8, 2)
	tokens = snapshot.path_revision_tokens(path)
	_check(world.remove_tree(second), "second tree attachment removes")
	_check(not SnapshotScript.path_tokens_match(world, tokens), "removing a tree invalidates dependent path snapshot tokens")
	world.remove_tree(obstacle)


func _test_chop_and_support(world: TestWorld) -> void:
	var selector = SelectionScript.new()
	selector.world = world
	world.player_mode = World.PlayerMode.CHOP
	var oak := Vector3i(5, 20, 1)
	_check(world.add_tree(oak, TreeKinds.KIND_OAK, 9, 7), "oak attachment adds for chop")
	world.light_field.mark_explored(oak.x, oak.y - 1, oak.z)
	world.light_field.explored[world.light_field._world_index(oak.x, oak.y, oak.z)] = 0
	var hidden: Dictionary = selector._enqueue_task_at(oak.x, oak.y - 1, oak.z)
	_check(hidden.reason == "unexplored", "fog gating rejects a tree with an unexplored base cell")
	world.light_field.mark_explored(oak.x, oak.y, oak.z)
	var designation: Dictionary = selector._enqueue_task_at(oak.x, oak.y - 1, oak.z)
	_check(bool(designation.queued), "explored ground click queues its tree above (%s)" % designation.get("reason", "unknown"))
	var task_id := _task_id_at(world, oak, TaskQueue.TaskType.CHOP)
	var worker := _add_worker(world, 88, Vector3i(4, 20, 1))
	var completed := await _advance_until(world, func(): return not world.tree_store.has_tree(oak))
	_check(completed, "worker completes chop through real assignment and world updates")
	_check(world.task_queue.get_task(task_id) == null, "chop task leaves the queue on completion")
	var oak_logs := _last_log_count(world)
	_check(oak_logs >= 3 and oak_logs <= 4, "oak chop spawns three or four logs")
	_check(worker.role_id == Roles.Role.MINER, "miner is eligible for chopping")

	var bush := Vector3i(6, 20, 1)
	_check(world.add_tree(bush, TreeKinds.KIND_BUSH, 0, 1), "bush attachment adds")
	var item_count_before: int = world.item_store.items.size()
	_check(world.remove_tree(bush, true), "bush is removable")
	_check(world.item_store.items.size() == item_count_before, "bush removal spawns no logs")

	var erase_tree := Vector3i(7, 20, 1)
	world.add_tree(erase_tree, TreeKinds.KIND_PINE, 0, 8)
	world.light_field.mark_explored(erase_tree.x, erase_tree.y, erase_tree.z)
	world.light_field.mark_explored(erase_tree.x, erase_tree.y - 1, erase_tree.z)
	_check(world.queue_task_request(TaskQueue.TaskType.CHOP, erase_tree, 0), "pending chop designation queues")
	world.player_mode = World.PlayerMode.ERASE
	var erase_pos := selector._erase_target_from_hit(erase_tree + Vector3i.DOWN)
	var erased: Dictionary = selector._enqueue_task_at(erase_pos.x, erase_pos.y, erase_pos.z)
	_check(bool(erased.queued) and not world.task_queue.has_active_task_at(erase_tree, TaskQueue.TaskType.CHOP), "Erase cancels pending chop from the ground cell")

	var supported := Vector3i(9, 20, 1)
	world.add_tree(supported, TreeKinds.KIND_PINE, 0, 9)
	var count_before: int = world.item_store.items.size()
	world.set_block_raw(supported.x, supported.y - 1, supported.z, World.BLOCK_ID_AIR, true)
	_check(not world.tree_store.has_tree(supported), "removing floor support removes tree")
	_check(world.item_store.items.size() == count_before + 1 and _last_log_count(world) >= 4 and _last_log_count(world) <= 5, "support loss drops four or five pine logs")
	var solid_base := Vector3i(10, 20, 1)
	world.add_tree(solid_base, TreeKinds.KIND_OAK, 0, 5)
	count_before = world.item_store.items.size()
	world.set_block_raw(solid_base.x, solid_base.y, solid_base.z, World.BLOCK_ID_GRANITE, true)
	_check(not world.tree_store.has_tree(solid_base) and world.item_store.items.size() == count_before, "solidifying the base removes tree without drops")


func _test_nav_grid_tree_blocking() -> void:
	var world := TestWorld.new()
	root.add_child(world)
	world.world_seed = 7401
	for x in range(-3, 12):
		for z in range(-3, 5):
			world.set_block_raw(x, 19, z, World.BLOCK_ID_GRASS if z == 1 else World.BLOCK_ID_AIR, false)
			for y in range(20, 28):
				world.set_block_raw(x, y, z, World.BLOCK_ID_AIR, false)
	for chunk: ChunkData in world.chunks.values():
		chunk.generated = true
	var trunk := Vector3i(3, 20, 1)
	world.add_tree(trunk, TreeKinds.KIND_OAK, 0, 6)
	var start := Vector3i(0, 20, 1)
	var goal := Vector3i(6, 20, 1)
	var astar: Array = world.pathfinder.find_path(world, start, goal, false)
	var snapshot = SnapshotScript.new()
	snapshot.capture_from_world(world, goal, [start], 16, 4)
	var grid = NavGridScript.new()
	grid.build(snapshot, snapshot.min_block, snapshot.max_block, world.pathfinder)
	var flood: Dictionary = grid.reverse_distances([goal], [start])
	_check(astar.is_empty(), "A* reports the one-cell corridor blocked by a trunk as unreachable")
	_check(bool(flood.complete) and int(flood.distances.get(start, -2)) == -1 and grid.path_from(start).is_empty(), "NavGrid also proves the trunk-blocked corridor unreachable")
	world.task_manager.shutdown()
	world.queue_free()


func _test_tree_crossing_task_routes() -> void:
	var chop_world := TestWorld.new()
	root.add_child(chop_world)
	_build_fixture(chop_world)
	var blocker := Vector3i(3, 20, 2)
	var target := Vector3i(8, 20, 2)
	chop_world.add_tree(blocker, TreeKinds.KIND_OAK, 0, 5)
	chop_world.add_tree(target, TreeKinds.KIND_PINE, 0, 7)
	var chop_worker := _add_worker(chop_world, 901, Vector3i(0, 20, 2))
	_check(chop_world.queue_task_request(TaskQueue.TaskType.CHOP, target, 0), "open-field CHOP task queues behind a trunk")
	var chop_id := _task_id_at(chop_world, target, TaskQueue.TaskType.CHOP)
	var chop_flips := 0
	var prior_status := TaskQueue.TaskStatus.PENDING
	var chopped := false
	for _step in 1800:
		chop_world.update_world(1.0 / 60.0)
		var task = chop_world.task_queue.get_task(chop_id)
		if task == null:
			chopped = not chop_world.tree_store.has_tree(target)
			break
		if prior_status == TaskQueue.TaskStatus.IN_PROGRESS and task.status == TaskQueue.TaskStatus.PENDING:
			chop_flips += 1
		prior_status = task.status
		await process_frame
	_check(chopped, "open-field CHOP completes with a trunk on the straight route")
	_check(chop_flips <= 2, "CHOP does not repeatedly return from IN_PROGRESS to PENDING (%d flips)" % chop_flips)
	_check(chop_worker.current_task_id < 0 or not chop_world.tree_store.has_tree(target), "worker releases completed chop target")
	chop_world.task_manager.shutdown()
	chop_world.queue_free()

	var dig_world := TestWorld.new()
	root.add_child(dig_world)
	_build_fixture(dig_world)
	dig_world.add_tree(Vector3i(3, 20, 2), TreeKinds.KIND_OAK, 0, 5)
	var dig_target := Vector3i(8, 20, 2)
	dig_world.set_block_raw(dig_target.x, dig_target.y, dig_target.z, World.BLOCK_ID_GRANITE, false)
	var dig_worker := _add_worker(dig_world, 902, Vector3i(0, 20, 2))
	_check(dig_world.queue_task_request(TaskQueue.TaskType.DIG, dig_target, 0), "DIG task queues with a tree on its straight route")
	var dug := await _advance_until(dig_world, func(): return dig_world.get_block_no_generate(dig_target.x, dig_target.y, dig_target.z) == World.BLOCK_ID_AIR)
	_check(dug, "DIG completes after NavGrid routes around a trunk")
	_check(dig_worker.current_task_id < 0 or dig_world.get_block_no_generate(dig_target.x, dig_target.y, dig_target.z) == World.BLOCK_ID_AIR, "worker releases completed dig target")
	dig_world.task_manager.shutdown()
	dig_world.queue_free()


func _test_in_progress_chop_cancel() -> void:
	var world := TestWorld.new()
	root.add_child(world)
	_build_fixture(world)
	var target := Vector3i(8, 20, 2)
	world.add_tree(target, TreeKinds.KIND_OAK, 0, 6)
	var worker := _add_worker(world, 903, Vector3i(0, 20, 2))
	world.queue_task_request(TaskQueue.TaskType.CHOP, target, 0)
	var task_id := _task_id_at(world, target, TaskQueue.TaskType.CHOP)
	var assigned := false
	for _step in 360:
		world.update_world(1.0 / 60.0)
		var task = world.task_queue.get_task(task_id)
		if task != null and task.status == TaskQueue.TaskStatus.IN_PROGRESS:
			assigned = true
			break
		await process_frame
	_check(assigned, "CHOP becomes in progress before external tree removal")
	_check(world.remove_tree(target), "external removal removes tree during an active chop")
	_check(world.task_queue.get_task(task_id) == null, "external tree removal cancels active CHOP immediately")
	_check(worker.current_task_id < 0 and worker.state == Worker.WorkerState.IDLE, "worker returns cleanly to idle after active CHOP cancellation")
	world.task_manager.shutdown()
	world.queue_free()


func _test_legacy_rejections() -> void:
	var world := TestWorld.new()
	root.add_child(world)
	_build_fixture(world)
	var base := Vector3i(4, 20, 3)
	world.set_block_raw(base.x, base.y - 1, base.z, World.BLOCK_ID_DIRT, false)
	world.set_block_raw(base.x, base.y, base.z, World.BLOCK_ID_AIR, false)
	_check(world.save_load._tree_site_is_valid(base), "legacy migration accepts dirt support")
	world.task_queue.add_dig_task(base + Vector3i.DOWN)
	_check(world.save_load._tree_site_occupied(base), "legacy migration rejects an active task below a candidate tree")
	world.task_queue.clear()
	var footprint: Array[Vector3i] = [base, base + Vector3i.DOWN]
	world.task_queue.add_task(Vector3i(7, 20, 3), TaskQueue.TaskType.STAIRS, 0, {"flight": true, "footprint": footprint})
	_check(world.save_load._tree_site_occupied(base), "legacy migration rejects a stair footprint covering the tree base and support")
	world.task_queue.clear()
	world.task_queue.add_chop_task(Vector3i(10, 20, 3))
	world.save_load.has_pending_light_snapshots = true
	world.save_load.pending_tree_snapshot = {"present": true, "trees": []}
	world.save_load.pending_torch_snapshot = {"present": true, "positions": []}
	world.save_load.pending_explored_snapshot = {"present": true, "explored": PackedByteArray()}
	world.save_load.apply_final_light_snapshots()
	_check(world.task_queue.get_active_tasks_at(Vector3i(10, 20, 3)).is_empty(), "post-load snapshot application drops restored CHOPs whose trees are absent")
	world.task_manager.shutdown()
	world.queue_free()


func _test_persistence(world: TestWorld) -> void:
	var root_path := ProjectSettings.globalize_path("res://.playtest/luna-trees/v12-%d-%d" % [OS.get_process_id(), Time.get_ticks_usec()])
	_check(DirAccess.make_dir_recursive_absolute(root_path) == OK, "create isolated tree save root")
	var slot_path := root_path.path_join("world.save")
	var tree_base := Vector3i(3, 20, 2)
	world.set_block_raw(tree_base.x, tree_base.y - 1, tree_base.z, World.BLOCK_ID_GRASS, false)
	world.set_block_raw(tree_base.x, tree_base.y, tree_base.z, World.BLOCK_ID_AIR, false)
	world.add_tree(tree_base, TreeKinds.KIND_PINE, 123, 8)
	world.queue_task_request(TaskQueue.TaskType.CHOP, tree_base, 0)
	_check(world.save_world(slot_path), "V13 save stores trees and pending chop")
	_check(SaveLoadScript.SAVE_VERSION == 13 and FileAccess.file_exists(slot_path.get_basename().path_join("trees.dat")), "V13 includes trees.dat")
	var reader := TestWorld.new()
	root.add_child(reader)
	_check(reader.load_world(slot_path), "V13 save reload succeeds")
	reader.load_saved_chunk(reader.world_to_chunk_coords(tree_base.x, tree_base.y, tree_base.z))
	reader.rebuild_light_field()
	_check(reader.tree_store.tree_at(tree_base) == {"kind": TreeKinds.KIND_PINE, "variant": 123, "height": 8}, "V13 round trip restores tree attachment")
	_check(reader.task_queue.has_active_task_at(tree_base, TaskQueue.TaskType.CHOP), "V13 round trip restores pending CHOP")
	var meta := slot_path.get_basename().path_join("world_meta.dat")
	var file := FileAccess.open(meta, FileAccess.READ_WRITE)
	file.seek(4)
	file.store_16(14)
	file.close()
	var epoch := reader.runtime_epoch
	_check(not reader.load_world(slot_path) and reader.runtime_epoch == epoch, "version 14 is rejected without replacing the live world")
	reader.task_manager.shutdown()
	reader.queue_free()
	world.task_queue.remove_pending_tasks_at(tree_base, [TaskQueue.TaskType.CHOP])
	world.remove_tree(tree_base)


func _test_legacy_migration() -> void:
	var seed_value := 551029
	var generated: Dictionary = PipelineScript.new().generate_tree_attachments({"world_seed": seed_value, "sea_level": 226, "world_size_y": 256})
	var candidate := Vector3i.ZERO
	var found := false
	for base: Vector3i in generated:
		if base.x == -10 or base.x == 10 or base.z == -10 or base.z == 10:
			continue
		candidate = base
		found = true
		break
	_check(found, "legacy generation has a candidate away from worker spawn cells")
	if not found:
		return
	var root_path := ProjectSettings.globalize_path("res://.playtest/luna-trees/v11-%d-%d" % [OS.get_process_id(), Time.get_ticks_usec()])
	_check(DirAccess.make_dir_recursive_absolute(root_path) == OK, "create isolated legacy save root")
	var slot_path := root_path.path_join("legacy.save")
	var source := TestWorld.new()
	root.add_child(source)
	source.world_seed = seed_value
	source.sea_level = 226
	source.set_block_raw(candidate.x, candidate.y - 1, candidate.z, World.BLOCK_ID_GRASS, false)
	source.set_block_raw(candidate.x, candidate.y, candidate.z, World.BLOCK_ID_AIR, false)
	for chunk: ChunkData in source.chunks.values():
		chunk.generated = true
		chunk.dirty = true
	_check(source.get_block_no_generate(candidate.x, candidate.y - 1, candidate.z) == World.BLOCK_ID_GRASS, "V11 source fixture has grass support before save")
	_check(source.save_world(slot_path), "write V11 terrain fixture")
	var slot_dir := slot_path.get_basename()
	var meta := slot_dir.path_join("world_meta.dat")
	var file := FileAccess.open(meta, FileAccess.READ_WRITE)
	file.seek(4)
	file.store_16(11)
	file.close()
	_check(DirAccess.remove_absolute(slot_dir.path_join("trees.dat")) == OK, "remove V13 tree snapshot to create V11 fixture")
	var first := TestWorld.new()
	root.add_child(first)
	_check(first.load_world(slot_path), "load V11 tree-less save")
	first.load_saved_chunk(first.world_to_chunk_coords(candidate.x, candidate.y, candidate.z))
	_check(first.world_seed == seed_value, "V11 reader restores the legacy tree seed")
	_check(first.sea_level == 226 and first.world_size_y == 256, "V11 reader restores generation dimensions")
	_check(first.get_block_no_generate(candidate.x, candidate.y - 1, candidate.z) == World.BLOCK_ID_GRASS, "V11 fixture reload keeps candidate support grass")
	_check(first.save_load._tree_site_is_valid(candidate), "V11 candidate remains an intact supported surface")
	_check(not first.save_load._tree_site_occupied(candidate), "V11 candidate is not occupied by a worker, item, stockpile or designation")
	_check(first.save_load.has_pending_light_snapshots, "V11 tree migration is queued with the light snapshot apply step")
	_check(not bool(first.save_load.pending_tree_snapshot.get("present", false)), "V11 save has no tree snapshot")
	first.rebuild_light_field()
	_check(first.save_load._tree_site_is_valid(candidate), "V11 surface remains valid after light build")
	_check(first.tree_store.has_tree(candidate), "V11 migration regenerates trees on intact loaded surface; candidates=%d added=%d invalid=%d occupied=%d rejected=%d candidate=%s" % [int(first.save_load.last_load_metrics.get("legacy_tree_candidates", -1)), int(first.save_load.last_load_metrics.get("legacy_trees_added", -1)), int(first.save_load.last_load_metrics.get("legacy_tree_invalid_sites", -1)), int(first.save_load.last_load_metrics.get("legacy_tree_occupied_sites", -1)), int(first.save_load.last_load_metrics.get("legacy_tree_rejected_stores", -1)), candidate])
	_check(first.tree_store.tree_at(candidate) == generated[candidate], "V11 migration matches deterministic seed-generated tree metadata")
	source.queue_free()
	first.task_manager.shutdown()
	first.queue_free()


func _add_worker(world: TestWorld, worker_id: int, cell: Vector3i) -> Worker:
	var worker := Worker.new()
	worker.worker_id = worker_id
	worker.role_id = Roles.Role.MINER
	worker.work_priorities = {"mining": 1, "hauling": 1, "building": 1}
	worker.use_animated_model = false
	worker.position = Vector3(cell)
	world.add_child(worker)
	world.workers.append(worker)
	return worker


func _task_id_at(world: World, pos: Vector3i, task_type: int) -> int:
	for task in world.task_queue.get_active_tasks_at(pos):
		if task.type == task_type:
			return task.id
	return -1


func _last_log_count(world: World) -> int:
	var item_ids: Array = world.item_store.items.keys()
	if item_ids.is_empty():
		return 0
	var item: Dictionary = world.item_store.get_item(int(item_ids.back()))
	return int(item.get("count", 0)) if int(item.get("material_id", -1)) == World.BLOCK_ID_LOG else 0


func _advance_until(world: TestWorld, condition: Callable, max_steps: int = 1800) -> bool:
	var deadline := Time.get_ticks_msec() + 30000
	for _step in max_steps:
		world.update_world(1.0 / 60.0)
		if condition.call():
			return true
		if Time.get_ticks_msec() >= deadline:
			return false
		await process_frame
	return condition.call()
