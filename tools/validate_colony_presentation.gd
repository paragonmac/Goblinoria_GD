extends SceneTree
## Headless real-World contract; never opens the editor or renders worker assets.

const Model = preload("res://scripts/ui/colony_presentation_model.gd")
const Roles = preload("res://scripts/worker_roles.gd")
var failures: Array[String] = []


func _init() -> void:
	_run.call_deferred()


func _run() -> void:
	_test_roles_and_read_only()
	_test_materials_and_filters()
	_test_rebuild_and_replacement()
	_test_task_and_stockpile_restarts()
	_test_large_filters_and_sparse_ids()
	_test_reference_bounds()
	_test_sustained_dirty_signals()
	_test_single_step_fairness()
	if failures.is_empty():
		print("Colony presentation contract OK")
		quit(0)
	else:
		for message in failures:
			push_error(message)
		quit(1)


func _fixture() -> World:
	var world := World.new()
	world._init_ramp_lookup()
	world.block_registry.load_from_csv(World.BLOCK_DATA_PATH)
	world.task_manager = TaskManager.new(world, world.task_queue)
	for index in range(4):
		var worker := Worker.new()
		worker.worker_id = index + 1
		worker.role_id = Roles.DEFAULT_SPAWN_ROLES[index]
		worker.position = Vector3(index, 1, 0)
		# Outside the tree: real Worker fields and APIs, without _ready visuals.
		world.add_child(worker)
		world.workers.append(worker)
	return world


func _dispose(world: World, model) -> void:
	model.clear()
	world.task_manager.shutdown()
	world.free()


func _drain(model) -> void:
	for _iteration in range(10000):
		if not model.updating:
			return
		model.pump(128, 1.0)
		_expect(model.last_pump_steps <= 128, "Default pump exceeded its record budget")
	_expect(false, "Presentation rebuild did not finish")


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func _test_roles_and_read_only() -> void:
	var world := _fixture()
	# Real role classification on a small supported plane, with no Hauler.
	for x in range(-2, 4):
		for z in range(-2, 3):
			world.set_block_raw(x, 0, z, World.BLOCK_ID_GRANITE, true)
	world.workers[2].role_id = Roles.Role.FIGHTER
	var haul_id := world.task_queue.add_haul_task(1, Vector3i(0, 1, 0), 2, 1, Vector3i(1, 1, 0))
	var haul = world.task_queue.get_task(haul_id)
	world.task_manager._classify_task_accessibility(haul)
	_expect(haul.block_reason == TaskQueue.TaskBlockReason.NO_ELIGIBLE_WORKER, "Role fixture did not produce an unstaffable haul")
	world.workers[0].state = Worker.WorkerState.WORKING
	world.workers[0].current_task_id = haul_id
	world.workers[1].state = Worker.WorkerState.MOVING
	world.workers[2].state = Worker.WorkerState.WAITING_FOR_PATH
	world.workers[2].carried_count = 3
	world.workers[2].carried_material_id = World.BLOCK_ID_DIRT
	world.workers[2].carried_source_item_id = 42
	var unknown_id := world.task_queue.add_dig_task(Vector3i(3, 1, 0))
	var stale_id := world.task_queue.add_dig_task(Vector3i(4, 1, 0))
	var stale = world.task_queue.get_task(stale_id)
	stale.set_accessibility(TaskQueue.TaskAccessibility.UNREACHABLE, 1, TaskQueue.TaskBlockReason.NO_WORKER_PATH)
	stale.retry_due_msec = 1
	stale.unreachable_workers[1] = -10000
	world.task_manager.path_retry_due_by_task[stale_id] = 1
	var structural_id := world.task_queue.add_stairs_task(Vector3i(5, 1, 0), 2)
	world.task_queue.get_task(structural_id).set_accessibility(TaskQueue.TaskAccessibility.UNREACHABLE, 1, TaskQueue.TaskBlockReason.NO_WORK_POSITION)
	var assigned_id := world.task_queue.add_place_task(Vector3i(6, 1, 0), 2)
	var assigned = world.task_queue.get_task(assigned_id)
	assigned.status = TaskQueue.TaskStatus.IN_PROGRESS
	assigned.assigned_worker = world.workers[0]
	assigned.set_accessibility(TaskQueue.TaskAccessibility.REACHABLE, 1)
	var before := _domain_state(world)
	var model := Model.new()
	model.bind_world(world)
	_drain(model)
	var snapshot: Dictionary = model.snapshot()
	_expect(world.live_diagnostics == null, "Fixture unexpectedly enabled diagnostics")
	_expect(snapshot.counts.workers == 4 and snapshot.counts.working == 1 \
		and snapshot.counts.travelling == 1 and snapshot.counts.waiting == 1 \
		and snapshot.counts.reserve == 1, "Worker activity counts do not reflect real states")
	_expect(model.get_row("worker", 1).task_id == haul_id, "Assigned task ID missing from worker")
	_expect(model.get_row("worker", 3).carried_count == 3 \
		and model.get_row("worker", 3).pos == world.workers[2].get_block_coord(), "Carried amount or worker position missing")
	_expect(model.get_row("worker", 4).description == "Reserve; combat not implemented yet", "Fighter reserve description is incorrect")
	_expect(model.get_row("worker", 1).description.contains("Task %d: Haul" % haul_id) \
		and model.get_row("worker", 3).description.contains("Waiting for path") \
		and model.get_row("worker", 3).description.contains("Carrying 3 dirt"), "Worker task, waiting reason, or carried material is missing")
	_expect(model.get_row("job", haul_id).block_reason == TaskQueue.TaskBlockReason.NO_ELIGIBLE_WORKER, "Missing actual role block reason")
	var unknown: Dictionary = model.get_row("job", unknown_id)
	_expect(unknown.accessibility_age_msec == -1 and not unknown.accessibility_stale \
		and not unknown.blocked and unknown.description.contains("Not evaluated"), "Unknown accessibility was presented as stale or blocked")
	var stale_row: Dictionary = model.get_row("job", stale_id)
	_expect(stale_row.accessibility_stale and stale_row.blocked \
		and stale_row.accessibility == TaskQueue.TaskAccessibility.UNREACHABLE, "Expired retry lost its last known blocked state")
	_expect(model.get_row("job", assigned_id).assigned_worker_id == 1 \
		and not model.get_row("job", assigned_id).pending, "Assigned job state is incorrect")
	_expect(snapshot.counts.pending == 4 and snapshot.counts.blocked == 3, "Pending/blocked job totals are incorrect")
	_expect(snapshot.counts.pending_haul == 1 \
		and snapshot.suggestion == "1 hauling jobs waiting; 1 reserve available." \
		and snapshot.suggestion_category == "workers", "Hauling/reserve suggestion did not take priority or route to staffing")
	var idle_revision: int = model.revision
	for _frame in range(200):
		model.pump()
		model.snapshot()
		model.list_rows("job")
		model.get_row("job", stale_id)
	_expect(model.revision == idle_revision and model.last_pump_steps == 0, "Idle reads rebuilt the model")
	_expect(before == _domain_state(world), "Presentation read mutated gameplay, caches, retry state, or terrain")
	_expect(snapshot.is_read_only() and snapshot.counts.is_read_only() \
		and snapshot.jobs.is_read_only() and stale_row.is_read_only(), "Published values are mutable")
	_expect(_plain_values(snapshot), "Snapshot contains a domain object")
	var old_jobs: Array = model.list_rows("job")
	world.workers[1].state = Worker.WorkerState.WAITING
	model.refresh_workers()
	_expect(model.updating, "Worker refresh did not report pending work")
	_drain(model)
	_expect(model.snapshot().counts.waiting == 2 and is_same(old_jobs, model.list_rows("job")), "Worker refresh rescanned economy or missed worker state")
	world.workers[1].current_task_id = stale_id
	world.workers[0].state = Worker.WorkerState.IDLE
	world.workers[0].current_task_id = -1
	world.workers[2].state = Worker.WorkerState.IDLE
	world.workers[2].role_id = Roles.Role.HAULER
	model.refresh_workers()
	_drain(model)
	_expect(model.get_row("worker", 2).description.contains("Work position invalid; route retry pending") \
		and model.get_row("worker", 1).description.contains("Miner awaiting excavation") \
		and model.get_row("worker", 3).description.contains("Hauler awaiting haul"), "Worker waiting descriptions do not reflect state and role")
	world.task_queue.complete_task(assigned)
	_expect(model.updating, "Task completion did not dirty presentation")
	_drain(model)
	_expect(model.get_row("job", assigned_id).is_empty(), "Completed task remained in rows")
	_dispose(world, model)


func _test_materials_and_filters() -> void:
	var world := _fixture()
	var stockpile_id := world.stockpile_store.create_stockpile([Vector3i(1, 1, 0), Vector3i(2, 1, 0)])
	world.stockpile_store.set_category_allowed(stockpile_id, "soil", false)
	world.stockpile_store.set_material_override(stockpile_id, 2, true)
	world.item_store.add_stack(2, 10, Vector3i(1, 1, 0), stockpile_id)
	world.item_store.add_stack(2, 2, Vector3i(1, 1, 0), stockpile_id)
	var loose_id := world.item_store.add_stack(2, 7, Vector3i(0, 1, 0))
	var carried_id := world.item_store.add_stack(2, 3, Vector3i(0, 1, 1))
	world.item_store.reserve_item(carried_id, 81)
	world.item_store.mark_carried(carried_id)
	world.item_store.add_stack(1, 5, Vector3i(3, 1, 0))
	# Carry slots mirror store stacks; presentation must not count them twice.
	world.workers[2].carried_count = 3
	world.workers[2].carried_material_id = 2
	world.workers[2].carried_source_item_id = carried_id
	var model := Model.new()
	model.bind_world(world)
	_drain(model)
	var resource: Dictionary = model.get_row("resource", 2)
	_expect(resource.stored == 12 and resource.loose == 7 and resource.carried == 3 \
		and resource.reserved == 3 and resource.total == 22, "Stored/loose/carried partition or overlapping reservation count is wrong")
	_expect(not resource.has("pos"), "Aggregated resource has a misleading world position")
	_expect(resource.item_ids.size() == 4 and resource.stockpile_ids == [stockpile_id] \
		and resource.worker_ids == [3] and not resource.item_ids_truncated, "Resource relationship IDs are incorrect or duplicated")
	var stockpile: Dictionary = model.get_row("stockpile", stockpile_id)
	_expect(stockpile.cell_count == 2 and stockpile.occupied_cells == 1 \
		and stockpile.capacity == 32 and stockpile.stored_count == 12 \
		and stockpile.free_capacity == 20, "Stockpile occupancy double-counted stacks or has wrong capacity")
	_expect(not stockpile.has("cells") and not stockpile.allowed_categories.soil \
		and stockpile.material_overrides[2], "Stockpile filter values were lost")
	_expect(stockpile.allowed_categories.is_read_only() and stockpile.material_overrides.is_read_only(), "Nested filter values are mutable")
	var counts: Dictionary = model.snapshot().counts
	_expect(counts.stored == 12 and counts.loose == 12 and counts.carried == 3 \
		and counts.reserved == 3, "Global material totals are incorrect")
	world.stockpile_store.set_category_allowed(stockpile_id, "soil", true)
	_expect(model.updating, "Filter signal did not dirty model")
	_drain(model)
	_expect(model.get_row("stockpile", stockpile_id).allowed_categories.soil \
		and not stockpile.allowed_categories.soil, "Filter rebuild mutated completed row or missed new filter")
	world.item_store.reserve_item(loose_id, 82)
	_expect(model.updating, "DOMAIN HOOK: reserve_item must signal with diagnostics off")
	_drain(model)
	_expect(model.get_row("resource", 2).reserved == 10, "Reservation-only mutation was not reflected")
	world.item_store.release_reservation(loose_id, 82)
	_drain(model)
	_expect(model.get_row("resource", 2).reserved == 3, "Reservation release was not reflected")
	world.item_store.mark_loose(carried_id, Vector3i(8, 1, 0))
	_drain(model)
	_expect(model.get_row("resource", 2).loose == 10 and model.get_row("resource", 2).carried == 0, "Carry interruption was not reflected")
	_dispose(world, model)


func _test_rebuild_and_replacement() -> void:
	var world := _fixture()
	var model := Model.new()
	world.item_store.add_stack(2, 4, Vector3i.ZERO)
	model.bind_world(world)
	_drain(model)
	var old_snapshot: Dictionary = model.snapshot()
	for index in range(600):
		world.item_store.add_stack(2, 1, Vector3i(index, 1, 0))
	model.pump(0, 1.0)
	_expect(model.last_pump_steps == 0 and model.updating, "Zero step budget did work or lost dirty state")
	model.pump(128, 0.0)
	_expect(model.last_pump_steps == 0 and model.updating, "Zero time budget did work")
	model.pump(1, 100.0)
	_expect(model.last_pump_steps == 1 and model.updating, "One-step budget was exceeded")
	model.pump(128, 0.001)
	_expect(model.last_pump_steps <= 128 and model.updating, "Time-limited build completed an oversized store")
	model.pump(128, 100.0)
	_expect(model.last_pump_steps == 128 and model.updating, "Large store did not retain a bounded pending cursor")
	_expect(model.snapshot().counts == old_snapshot.counts \
		and is_same(model.list_rows("resource"), old_snapshot.resources), "Partial economy build leaked into published data")
	# Mutate the dictionary while its iterator is suspended, including erase/clear.
	world.item_store.remove_item(1)
	world.item_store.clear()
	world.item_store.add_stack(1, 9, Vector3i.ZERO)
	_drain(model)
	_expect(model.get_row("resource", 2).is_empty() \
		and model.get_row("resource", 1).total == 9, "Mutation during rebuild mixed generations or retained deleted items")
	_expect(old_snapshot.resources[0].total == 4, "Completed snapshot changed after publication")
	var old_epoch: int = model.epoch
	model.bind_world(world)
	_expect(model.epoch == old_epoch + 1 and model.list_rows("resource").is_empty() \
		and model.updating, "Same-World bind did not clear and advance epoch")
	_drain(model)
	var replacement := _fixture()
	model.bind_world(replacement)
	_drain(model)
	var replacement_revision: int = model.revision
	world.item_store.add_stack(2, 99, Vector3i.ZERO)
	model.pump()
	_expect(not model.updating and model.revision == replacement_revision, "Old-world store signal dirtied replacement model")
	_expect(model.get_row("invalid", 1).is_empty() and model.list_rows("invalid").is_empty() \
		and model.get_row("worker", -99).is_empty(), "Unknown row lookup is not empty")
	model.clear()
	_expect(not model.updating and model.snapshot().counts.workers == 0, "clear left work or stale rows")
	model.bind_world(null)
	_expect(not model.updating, "Null bind scheduled work")
	_dispose(replacement, model)
	world.task_manager.shutdown()
	world.free()


func _test_large_filters_and_sparse_ids() -> void:
	var world := _fixture()
	world.item_store.next_id = 1000000000
	world.item_store.add_stack(2, 1, Vector3i.ZERO)
	world.stockpile_store.next_id = 1000000000
	var stockpile_id := world.stockpile_store.create_stockpile([Vector3i(1, 1, 0)])
	for material in range(1, 201):
		world.stockpile_store.set_material_override(stockpile_id, material, material % 2 == 0)
	var model := Model.new()
	model.bind_world(world)
	_drain(model)
	var row: Dictionary = model.get_row("stockpile", stockpile_id)
	_expect(row.material_overrides.size() == Model.MAX_OVERRIDES \
		and row.material_overrides_truncated, "Oversized stockpile filter record is unbounded or silently truncated")
	_expect(model.get_row("resource", 2).total == 1, "Sparse IDs were not iterated correctly")
	# Close a suspended cursor on a freed world; weak ownership must not dereference it.
	world.item_store.add_stack(1, 1, Vector3i.ZERO)
	model.pump(4, 100.0)
	world.task_manager.shutdown()
	world.free()
	model.pump()
	_expect(not model.updating and model.list_rows("worker").is_empty(), "Freed-world pending build was not cleared")


func _test_task_and_stockpile_restarts() -> void:
	var world := _fixture()
	var model := Model.new()
	model.bind_world(world)
	_drain(model)
	for index in range(180):
		world.task_queue.add_dig_task(Vector3i(index, 1, 0))
	model.pump(80, 100.0)
	_expect(model.updating and model.list_rows("job").is_empty(), "Partial task build was published")
	world.task_queue.remove_task(world.task_queue.get_task(1))
	world.task_queue.get_task(2).set_accessibility(TaskQueue.TaskAccessibility.UNREACHABLE, 1, TaskQueue.TaskBlockReason.NO_WORK_POSITION)
	_drain(model)
	_expect(model.list_rows("job").size() == 179 and model.get_row("job", 1).is_empty() \
		and model.get_row("job", 2).blocked, "Task removal/state change during rebuild mixed completed rows")
	world.task_queue.clear()
	for index in range(180):
		world.stockpile_store.create_stockpile([Vector3i(index, 1, 0)])
	model.pump(80, 100.0)
	_expect(model.updating and model.list_rows("stockpile").is_empty(), "Partial stockpile build was published")
	world.stockpile_store.remove_cells([Vector3i(0, 1, 0)])
	world.stockpile_store.set_material_override(2, 2, false)
	_drain(model)
	_expect(model.list_rows("stockpile").size() == 179 \
		and model.get_row("stockpile", 1).is_empty() \
		and not model.get_row("stockpile", 2).material_overrides[2], "Stockpile erase/filter mutation invalidated its iterator unsafely")
	# Invalidate while a dictionary cursor is suspended, then explicitly rebind.
	world.item_store.add_stack(2, 1, Vector3i.ZERO)
	model.pump(30, 100.0)
	var old_epoch: int = model.epoch
	model.bind_world(world)
	_expect(model.epoch == old_epoch + 1 and model.list_rows("stockpile").is_empty(), "Pending bind retained previous epoch rows")
	_drain(model)
	var abandoned := _abandon_pending_model(world)
	_expect(abandoned.get_ref() == null, "Suspended dictionary cursor retained its model after release")
	_dispose(world, model)


func _abandon_pending_model(world: World) -> WeakRef:
	var temporary := Model.new()
	temporary.bind_world(world)
	temporary.pump(30, 100.0)
	return weakref(temporary)


func _test_reference_bounds() -> void:
	var world := _fixture()
	for index in range(40):
		var pos := Vector3i(index, 1, 0)
		var stockpile_id := world.stockpile_store.create_stockpile([pos])
		world.item_store.add_stack(2, 1, pos, stockpile_id)
		var item_id := world.item_store.add_stack(2, 1, pos)
		world.item_store.reserve_item(item_id, index + 100)
		world.item_store.mark_carried(item_id)
		var worker := Worker.new()
		worker.worker_id = index + 100
		worker.role_id = Roles.Role.HAULER
		worker.carried_count = 1
		worker.carried_material_id = 2
		worker.carried_source_item_id = item_id
		world.add_child(worker)
		world.workers.append(worker)
	var model := Model.new()
	model.bind_world(world)
	_drain(model)
	var row: Dictionary = model.get_row("resource", 2)
	for field in ["item_ids", "stockpile_ids", "worker_ids"]:
		_expect(row[field].size() == 32 and row[field].is_read_only() \
			and row[field + "_truncated"], "Resource %s is unbounded, mutable, or silently truncated" % field)
	_expect(row.total == 80 and row.carried == 40 and row.reserved == 40, "Reference truncation changed full material totals")
	_expect(_plain_values(model.snapshot()), "Relationship rows contain domain object references")
	_dispose(world, model)


func _test_sustained_dirty_signals() -> void:
	var world := _fixture()
	world.item_store.add_stack(2, 4, Vector3i.ZERO)
	var model := Model.new()
	model.bind_world(world)
	_drain(model)
	var completed: Dictionary = model.get_row("resource", 2)
	for index in range(2000):
		world.item_store.add_stack(2, 1, Vector3i(index, 1, 0))
	var maximum_usec := 0
	for frame in range(60):
		var id := world.item_store.add_stack(2, 1, Vector3i(frame, 2, 0))
		world.item_store.reserve_item(id, frame + 100)
		world.item_store.release_reservation(id, frame + 100)
		world.workers[0].position.x = frame
		model.refresh_workers()
		var started := Time.get_ticks_usec()
		model.pump(128, 1.0)
		maximum_usec = maxi(maximum_usec, Time.get_ticks_usec() - started)
		_expect(model.last_pump_steps <= 128 and model.updating, "Sustained signals exceeded the pump budget or hid unfinished work")
		_expect(is_same(model.get_row("resource", 2), completed) \
			and model.snapshot().counts.loose == 4, "Sustained invalidation published mixed economy generations")
	_expect(model.get_row("worker", 1).pos.x > 0, "Economy invalidation starved worker publication")
	_drain(model)
	_expect(model.get_row("resource", 2).total == 2064 \
		and model.snapshot().counts.reserved == 0, "Dirty storm did not converge to the final store state")
	_expect(completed.total == 4 and completed.item_ids == [1], "Dirty storm changed a retained read-only snapshot")
	var settled_revision: int = model.revision
	for _frame in range(200):
		model.pump()
		model.snapshot()
		_expect(model.last_pump_steps == 0 and model.revision == settled_revision, "Settled economy performed frame-driven work")
	print("Sustained-dirty maximum pump: %d usec; 128-step cap respected" % maximum_usec)
	_dispose(world, model)


func _test_single_step_fairness() -> void:
	var world := _fixture()
	for index in range(20):
		var worker := Worker.new()
		worker.worker_id = index + 100
		world.add_child(worker)
		world.workers.append(worker)
	var model := Model.new()
	model.bind_world(world)
	for _step in range(4):
		model.pump(1, 100.0)
		_expect(model.last_pump_steps == 1, "Single-step pump exceeded its budget")
	# Economy advances beyond its startup while the larger worker batch is pending.
	_expect(model._phase >= 1 and model.list_rows("worker").is_empty(), "Single-step pumps starved economy behind a worker batch")
	_drain(model)
	world.workers[0].state = Worker.WorkerState.WAITING
	world.workers[0].current_task_id = 99999
	model.refresh_workers()
	_drain(model)
	_expect(model.get_row("worker", 1).description.contains("Waiting for task") \
		and model.get_row("worker", 1).description.contains("no longer queued"), "Missing task was incorrectly diagnosed as a blocked route")
	_dispose(world, model)


func _domain_state(world: World) -> Dictionary:
	var tasks: Array = []
	for task in world.task_queue.tasks:
		tasks.append([task.id, task.status, task.accessibility, task.block_reason,
			task.accessibility_updated_msec, task.retry_due_msec, task.unreachable_workers.duplicate(true)])
	var workers: Array = []
	for worker in world.workers:
		workers.append([worker.state, worker.role_id, worker.position, worker.current_task_id,
			worker.path.duplicate(), worker.carried_count])
	return {"tasks": tasks, "workers": workers,
		"items": world.item_store.items.duplicate(true), "stockpiles": world.stockpile_store.stockpiles.duplicate(true),
		"inventory": world.inventory.duplicate(), "chunks": world.chunks.size(), "access_tick": world.chunk_access_tick,
		"accessibility_checks": world.task_manager.accessibility_check_count,
		"pending_checks": world.task_manager.pending_accessibility_ids.duplicate(),
		"retry_deadlines": world.task_manager.path_retry_due_by_task.duplicate(),
		"haul_rebuilds": world.task_manager.haul_rebuild_count,
		"pending_bids": world.task_manager.assignment_pending_jobs.duplicate(true)}


func _plain_values(value) -> bool:
	if typeof(value) == TYPE_OBJECT or typeof(value) == TYPE_CALLABLE or typeof(value) == TYPE_SIGNAL:
		return false
	if value is Dictionary:
		for key in value:
			if not _plain_values(key) or not _plain_values(value[key]):
				return false
	elif value is Array:
		for entry in value:
			if not _plain_values(entry):
				return false
	return true
