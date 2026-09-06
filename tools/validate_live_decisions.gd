extends SceneTree
## Exercises production decision branches with a passive recorder and controlled
## path completions. Real threaded/path geometry contracts live in path_safety.

const Snapshots = preload("res://scripts/diagnostics/live_decision_snapshot.gd")
const Roles = preload("res://scripts/worker_roles.gd")

class Recorder:
	extends RefCounted
	var enabled := true
	var events: Array = []
	var invalidations: Array = []
	func observe(subject: String, subject_id: Variant, reason: String, data: Dictionary = {}) -> void:
		events.append({"subject": subject, "id": str(subject_id), "reason": reason, "data": data.duplicate(true)})
	func invalidate(subject: String, subject_id: Variant, reason: String) -> void:
		invalidations.append({"subject": subject, "id": str(subject_id), "reason": reason})
	func has_event(reason: String, subject_id: int = -1) -> bool:
		for event in events:
			if event.reason == reason and (subject_id < 0 or event.id == str(subject_id)):
				return true
		return false
	func has_invalidation(reason: String, subject_id: int) -> bool:
		for entry in invalidations:
			if entry.reason == reason and entry.id == str(subject_id):
				return true
		return false

class RevisionSnapshot:
	extends RefCounted
	var matches := true
	var checks := 0
	func revisions_match(_world) -> bool:
		checks += 1
		return matches

class ControlledScheduler:
	extends RefCounted
	var results: Array = []
	var next_job := 1
	var enqueued := 0
	func enqueue(_world, _auction_id, _task, _worker, _max_iterations) -> int:
		return _job()
	func enqueue_exact(_world, _request_id, _worker, _goal, _max_iterations, _kind) -> int:
		return _job()
	func enqueue_goals(_world, _request_id, _worker, _goals, _max_iterations) -> int:
		return _job()
	func _job() -> int:
		var id := next_job
		next_job += 1
		enqueued += 1
		return id
	func pop_result() -> Dictionary:
		return {} if results.is_empty() else results.pop_front()
	func clear() -> void:
		results.clear()
	func stop() -> void:
		clear()

class TestWorld:
	extends World
	var enclosed := false
	# Allows independent validation before main adds World's service property.
	# Once present, Godot uses that real property without these fallback accessors.
	var _test_diagnostics = null
	func _get(property: StringName):
		if property == &"live_diagnostics":
			return _test_diagnostics
		return null
	func _set(property: StringName, value) -> bool:
		if property == &"live_diagnostics":
			_test_diagnostics = value
			return true
		return false
	func get_block_no_generate(_x: int, y: int, _z: int) -> int:
		return BLOCK_ID_GRANITE if y == 0 or enclosed else BLOCK_ID_AIR
	func is_block_protected_from_dig(_pos: Vector3i) -> bool:
		return false

var failures: Array[String] = []
var checks := 0


func _init() -> void:
	_run.call_deferred()


func _run() -> void:
	_test_membership()
	_test_snapshots()
	_test_invalidation()
	var disabled_stores := _store_scenario(false)
	var enabled_stores := _store_scenario(true)
	_check(disabled_stores == enabled_stores, "Observing store branches changed store outcomes")
	var disabled_decisions := _decision_scenario(false)
	var enabled_decisions := _decision_scenario(true)
	_check(disabled_decisions == enabled_decisions, "Observing auctions/worker branches changed gameplay outcomes")
	if failures.is_empty():
		print("Live decisions contract OK (%d checks)" % checks)
		quit(0)
	else:
		for failure in failures:
			push_error(failure)
		quit(1)


func _test_membership() -> void:
	var queue := TaskQueue.new()
	_check(queue.diagnostics_membership_revision == 0, "Membership revision must start at zero")
	var id := queue.add_dig_task(Vector3i.ONE)
	var task = queue.get_task(id)
	var revision := queue.diagnostics_membership_revision
	queue.add_dig_task(Vector3i.ONE)
	task.accessibility = TaskQueue.TaskAccessibility.REACHABLE
	_check(queue.diagnostics_membership_revision == revision, "Duplicates/state edits changed membership revision")
	queue.complete_task(task)
	_check(queue.diagnostics_membership_revision == revision + 1, "Completion did not increment membership revision")
	queue.remove_task(task)
	_check(queue.diagnostics_membership_revision == revision + 1, "Failed removal incremented membership revision")
	queue.add_place_task(Vector3i.ONE, 1)
	queue.remove_pending_tasks_at(Vector3i.ONE)
	_check(queue.diagnostics_membership_revision == revision + 3, "Pending removal missed membership revision")
	revision = queue.diagnostics_membership_revision
	queue.clear()
	_check(queue.diagnostics_membership_revision == revision + 1, "Clear must invalidate old pagination even when empty")


func _test_snapshots() -> void:
	var world := _world(false)
	var worker: Worker = world.workers[0]
	worker.rng.seed = 123
	worker.path = [Vector3i.ONE, Vector3i(2, 1, 1)]
	var task = world.task_queue.get_task(world.task_queue.add_haul_task(7, Vector3i.ONE, 2, 1, Vector3i(2, 1, 1)))
	task.assigned_worker = worker
	for id in range(70):
		task.unreachable_workers[id] = -100000
	task.data["ignored_object"] = world
	var stockpile_id := world.stockpile_store.create_stockpile([Vector3i.ONE])
	for id in range(70):
		world.stockpile_store.set_material_override(stockpile_id, id + 1, true)
	var item_id := world.item_store.add_stack(2, 4, Vector3i.ONE)
	var before_exclusions: Dictionary = task.unreachable_workers.duplicate(true)
	var before_rng: int = worker.rng.state
	var before_pending: Array = world.task_manager.pending_accessibility_ids.duplicate()
	var before_checks: int = world.task_manager.accessibility_check_count
	var before_haul: int = world.task_manager.haul_rebuild_count
	var before_path: Array = worker.path.duplicate()
	var before_items: Array = world.item_store.as_save_array()
	var before_stockpiles: Array = world.stockpile_store.as_save_array()
	world.task_manager._start_assignment_auction(task)
	for id in range(70):
		world.task_manager.assignment_bids.append({"worker_id": id, "path_length": 3})
		world.task_manager.assignment_pending_jobs[id] = worker
	world.task_manager.haul_path_requests_by_worker[worker.worker_id] = {"request_id": 4, "job_id": 5, "task_id": task.id, "destination": Vector3i.ONE}
	var worker_data := Snapshots.worker_snapshot(worker)
	_check(worker_data.auction.pending_jobs.size() == Snapshots.MAX_ENTRIES and worker_data.auction.pending_jobs_truncated, "Worker pending auction jobs must be bounded")
	_check(worker_data.pending_haul_path.request_id == 4 and worker_data.pending_haul_path.task_id == task.id, "Worker pending path request summary missing")
	var task_data := Snapshots.task_snapshot(task)
	_check(task_data.auction.bids.size() == Snapshots.MAX_ENTRIES and task_data.auction.bids_truncated, "Task auction bids must be bounded")
	var item_data := Snapshots.item_snapshot(world.item_store.get_item(item_id))
	var stockpile_data := Snapshots.stockpile_snapshot(world.stockpile_store, Vector3i.ONE)
	_check(task_data.unreachable_workers.size() == Snapshots.MAX_ENTRIES and task_data.unreachable_workers_truncated, "Task exclusions must be bounded and explicitly truncated")
	_check(stockpile_data.material_overrides.size() == Snapshots.MAX_ENTRIES and stockpile_data.material_overrides_truncated, "Stockpile overrides must be bounded and explicitly truncated")
	for _i in range(10):
		_check(_plain(Snapshots.worker_snapshot(worker)) and _plain(Snapshots.task_snapshot(task)), "Worker/task snapshots contain objects")
		_check(_plain(Snapshots.item_snapshot(world.item_store.get_item(item_id))) and _plain(stockpile_data), "Store snapshots contain objects")
	task_data.unreachable_workers.clear()
	task_data.data["stage"] = "tampered"
	item_data["count"] = 999
	stockpile_data.material_overrides.clear()
	_check(task.unreachable_workers == before_exclusions and task.data.stage == "pickup", "Task snapshot expired exclusions or aliased task data")
	_check(worker.rng.state == before_rng and worker.path == before_path, "Snapshot changed worker RNG/path")
	_check(world.task_manager.pending_accessibility_ids == before_pending and world.task_manager.accessibility_check_count == before_checks and world.task_manager.haul_rebuild_count == before_haul, "Snapshot reevaluated accessibility/hauling")
	_check(world.item_store.as_save_array() == before_items and world.stockpile_store.as_save_array() == before_stockpiles, "Snapshot mutated store data")
	_check(Snapshots.worker_snapshot(null).is_empty() and Snapshots.task_snapshot(null).is_empty() and Snapshots.item_snapshot({}).is_empty(), "Missing subject snapshots must be empty")
	_check(not Snapshots.stockpile_snapshot(world.stockpile_store, Vector3i(90, 1, 0)).exists, "Absent stockpile cell reported present")
	_dispose(world)


func _test_invalidation() -> void:
	var world := _world(true)
	var recorder: Recorder = world.get("live_diagnostics")
	var queue: TaskQueue = world.task_queue
	var task = queue.get_task(queue.add_dig_task(Vector3i(2, 1, 0)))
	world.task_manager.invalidate_task_accessibility(task.pos)
	_check(recorder.has_invalidation("nearby_terrain_changed", task.id), "Deduplicated accessibility queue suppressed terrain invalidation")
	world.task_manager.notify_worker_availability_changed()
	_check(recorder.has_invalidation("worker_availability_changed", task.id), "Worker availability failed to invalidate unchanged UNKNOWN task")
	var worker: Worker = world.workers[0]
	world.task_manager.mark_worker_unreachable_for_task(task, worker)
	world.task_manager._queue_worker_bid(task, worker)
	_check(recorder.has_event("bid_excluded_until_retry", worker.worker_id), "Actual unreachable-worker exclusion did not emit retry reason")
	_check(world.task_manager.path_search_scheduler.enqueued == 0, "Excluded worker queued a new path search")
	worker.set_role(Roles.Role.FIGHTER, world)
	worker.update_idle(0.0, world, queue, world.pathfinder)
	_check(recorder.has_event("role_reserve_idle", worker.worker_id), "Fighter reserve branch missing observation")
	world.task_manager._start_assignment_auction(task)
	_check(recorder.has_event("auction_candidate_excluded", worker.worker_id), "Role-filtered auction candidate missing observation")
	var second: Worker = world.workers[1]
	world.task_manager._collect_worker_bid_result(task, second, {"worker_id": second.worker_id, "task_id": task.id, "path": [], "search_stats": {"reason": "iteration_cap", "hit_iteration_cap": true, "iterations_used": 42, "max_iterations": 42}})
	_check(recorder.has_event("assignment_bid_failed", second.worker_id), "Failed bid did not preserve search outcome")
	_check(task.block_reason == TaskQueue.TaskBlockReason.NO_WORKER_PATH, "All failed worker paths did not block task")
	queue.remove_task(task)
	_check(recorder.has_invalidation("task_removed", task.id), "Removal failed to invalidate task explanation")
	var cleared_id := queue.add_dig_task(Vector3i.ONE)
	queue.clear()
	_check(recorder.has_invalidation("queue_cleared", cleared_id), "Clear failed to invalidate old task ID")
	world.item_store.add_stack(2, 1, Vector3i.ONE)
	world.item_store.clear()
	_check(recorder.has_invalidation("items_cleared", 1), "Item clear left prior identity decisions valid")
	_dispose(world)


func _store_scenario(enabled: bool) -> Array:
	var recorder := Recorder.new()
	recorder.enabled = enabled
	var items := ItemStackStore.new()
	items.live_diagnostics = recorder
	var stockpiles := StockpileStore.new()
	stockpiles.live_diagnostics = recorder
	var cell := Vector3i(2, 1, 0)
	var stockpile_id := stockpiles.create_stockpile([cell])
	var source := items.add_stack(2, 20, Vector3i(0, 1, 0))
	_check(items.reserve_item(source, 10), "Initial reservation failed")
	_check(not items.reserve_item(source, 11), "Conflicting reservation unexpectedly succeeded")
	items.release_reservation(source, 11)
	_check(items.get_item(source).reserved_by_task_id == 10, "Mismatched reservation release changed owner")
	_check(items.mark_carried(source), "Reserved item pickup failed")
	var deposit := items.deposit_into_cell(source, stockpile_id, cell, 16)
	_check(deposit.get("deposited") == 16 and deposit.get("remaining") == 4, "Partial deposit outcome changed")
	_check(items.deposit_into_cell(source, stockpile_id, cell, 16).is_empty(), "Full cell accepted excess items")
	var other := items.add_stack(1, 1, Vector3i.ONE)
	_check(items.deposit_into_cell(other, stockpile_id, cell, 16).is_empty(), "Mixed material deposit unexpectedly succeeded")
	_check(not items.mark_carried(other), "Unreserved item was carried")
	stockpiles.set_category_allowed(stockpile_id, "soil", false)
	stockpiles.set_material_override(stockpile_id, 2, true)
	_check(stockpiles.accepts_material(stockpile_id, 2), "Exact material override lost priority")
	if enabled:
		for reason in ["item_reserved", "reservation_conflict", "reservation_release_rejected", "stack_carried", "cell_deposit", "deposit_capacity_conflict", "deposit_material_conflict", "pickup_unreserved", "stockpile_category_changed", "stockpile_material_changed"]:
			_check(recorder.has_event(reason), "Missing actual store hook: " + reason)
		_check(not recorder.invalidations.is_empty(), "Store mutations did not invalidate prior decisions")
	else:
		_check(recorder.events.is_empty() and recorder.invalidations.is_empty(), "Disabled store diagnostics received calls")
	for event in recorder.events:
		_check(_plain(event), "Store hook leaked engine object")
	return [items.as_save_array(), stockpiles.as_save_array(), items.next_id, stockpiles.next_id]


func _decision_scenario(enabled: bool) -> Array:
	var world := _world(enabled)
	var recorder: Recorder = world.get("live_diagnostics")
	var manager: TaskManager = world.task_manager
	var scheduler: ControlledScheduler = manager.path_search_scheduler
	var queue: TaskQueue = world.task_queue
	var worker: Worker = world.workers[0]
	var second: Worker = world.workers[1]
	var task = queue.get_task(queue.add_dig_task(Vector3i(2, 1, 0)))
	world.enclosed = true
	manager._classify_task_accessibility(task)
	_check(task.block_reason == TaskQueue.TaskBlockReason.NO_WORK_POSITION, "Enclosed task should lack a work position")
	world.enclosed = false
	manager._classify_task_accessibility(task)
	_check(task.accessibility == TaskQueue.TaskAccessibility.UNKNOWN, "Structural accessibility must await path proof")
	var haul = queue.get_task(queue.add_haul_task(1, Vector3i.ONE, 2, 1, Vector3i.ONE))
	manager._classify_task_accessibility(haul)
	_check(haul.block_reason == TaskQueue.TaskBlockReason.NO_ELIGIBLE_WORKER, "Haul task should report missing eligible role")
	queue.remove_task(haul)
	manager._start_assignment_auction(task)
	manager._queue_worker_bid(task, worker)
	manager.assignment_worker_index = manager.assignment_workers.size()
	manager.update_task_assignments()
	_check(task.assigned_worker == null and task.status == TaskQueue.TaskStatus.PENDING, "Auction assigned before all bids finished")
	var stale := RevisionSnapshot.new()
	stale.matches = false
	scheduler.results.append(_result(task.id, worker.worker_id, manager.assignment_auction_id, 1, [Vector3i(1, 1, 0)], stale))
	manager._process_path_results()
	_check(stale.checks == 1 and manager.assignment_task_id == -1 and worker.current_task_id == -1, "Stale path was accepted or revision check was repeated")
	manager._start_assignment_auction(task)
	manager._queue_worker_bid(task, worker)
	manager._queue_worker_bid(task, second)
	manager.assignment_worker_index = manager.assignment_workers.size()
	var first_revision := RevisionSnapshot.new()
	var second_revision := RevisionSnapshot.new()
	scheduler.results.append(_result(task.id, second.worker_id, manager.assignment_auction_id, 3, [Vector3i(1, 1, 0)], second_revision))
	scheduler.results.append(_result(task.id, worker.worker_id, manager.assignment_auction_id, 2, [Vector3i(1, 1, 0)], first_revision))
	manager.update_task_assignments()
	_check(task.assigned_worker == worker and worker.state == Worker.WorkerState.MOVING, "Equal length bids must assign lowest worker ID")
	_check(first_revision.checks == 1 and second_revision.checks == 1, "Diagnostics revalidated path results")
	worker.set_state(Worker.WorkerState.WAITING, world)
	worker.waiting_repath_timer = 0.0
	worker.update_waiting(0.0, world, queue, world.pathfinder)
	_check(task.status == TaskQueue.TaskStatus.PENDING and task.assigned_worker == null, "Waiting worker failed to release task")
	manager._mark_task_path_blocked(task, 100)
	var due: int = task.retry_due_msec
	manager.process_due_path_retries(due - 1)
	_check(task.block_reason == TaskQueue.TaskBlockReason.NO_WORKER_PATH, "Path retry fired early")
	manager.process_due_path_retries(due)
	_check(task.accessibility == TaskQueue.TaskAccessibility.UNKNOWN, "Due path retry did not reopen task")
	worker.set_role(Roles.Role.FIGHTER, world)
	worker.assign_task_with_path(world, queue, task, [Vector3i.ONE], 0.0)
	_check(worker.current_task_id == -1 and task.assigned_worker == null, "Role-ineligible assignment changed worker/task")
	worker.set_role(Roles.Role.HAULER, world)
	var item_id := world.item_store.add_stack(2, 3, Vector3i.ONE)
	haul = queue.get_task(queue.add_haul_task(item_id, Vector3i.ONE, 2, 1, Vector3i(2, 1, 0)))
	world.item_store.reserve_item(item_id, haul.id)
	worker.assign_task_with_path(world, queue, haul, [Vector3i.ONE], 0.0)
	_check(not worker._advance_haul_task(world, queue, haul) and worker.state == Worker.WorkerState.WAITING_FOR_PATH, "Haul pickup did not await delivery path")
	var request_id: int = manager.haul_path_requests_by_worker[worker.worker_id].request_id
	var stale_haul := RevisionSnapshot.new()
	stale_haul.matches = false
	var requests_before := scheduler.enqueued
	manager._process_haul_delivery_result({"request_id": request_id, "worker_id": worker.worker_id, "path": [Vector3i.ONE], "snapshot": stale_haul})
	_check(stale_haul.checks == 1 and scheduler.enqueued == requests_before + 1 and worker.state == Worker.WorkerState.WAITING_FOR_PATH, "Stale haul path must resubmit exactly once and keep waiting")
	request_id = manager.haul_path_requests_by_worker[worker.worker_id].request_id
	var haul_revision := RevisionSnapshot.new()
	manager._process_haul_delivery_result({"request_id": request_id, "worker_id": worker.worker_id, "path": [], "snapshot": haul_revision, "search_stats": {"reason": "iteration_cap", "hit_iteration_cap": true}})
	_check(queue.get_task(haul.id) == null and worker.carried_source_item_id == -1, "Failed haul path did not release task/carry")
	_check(not world.item_store.get_item(item_id).is_carried and world.item_store.get_item(item_id).reserved_by_task_id == -1, "Failed haul path did not drop item")
	# A successful handoff followed by terrain invalidation must execute the
	# existing interrupted-carry cleanup, with diagnostics both off and on.
	haul = queue.get_task(queue.add_haul_task(item_id, worker.get_block_coord(), 2, 1, Vector3i(2, 1, 0)))
	world.item_store.reserve_item(item_id, haul.id)
	worker.assign_task_with_path(world, queue, haul, [worker.get_block_coord()], 0.0)
	worker._advance_haul_task(world, queue, haul)
	request_id = manager.haul_path_requests_by_worker[worker.worker_id].request_id
	manager._process_haul_delivery_result({"request_id": request_id, "worker_id": worker.worker_id, "path": [worker.get_block_coord(), Vector3i(2, 1, 0)], "snapshot": RevisionSnapshot.new()})
	_check(worker.state == Worker.WorkerState.MOVING and haul.data.stage == "deposit", "Accepted haul delivery path did not start movement")
	worker.path_index = 1
	world.enclosed = true
	_check(not worker._validate_next_path_node(world, queue, world.pathfinder), "Newly blocked path segment was accepted")
	world.enclosed = false
	_check(worker.state == Worker.WorkerState.IDLE and queue.get_task(haul.id) == null and worker.carried_count == 0, "Path invalidation changed interrupted haul cleanup")
	_check(world.item_store.get_item(item_id).pos == worker.get_block_coord(), "Invalidated haul failed to drop at worker's actual location")
	# Assist completions also consume exactly one existing revision decision.
	manager.request_assist_path(worker, [{"task": task, "pos": Vector3i(2, 1, 0)}])
	var assist_id: int = manager.assist_requests_by_worker[worker.worker_id].request_id
	var stale_assist := RevisionSnapshot.new()
	stale_assist.matches = false
	manager._process_assist_result({"request_id": assist_id, "worker_id": worker.worker_id, "snapshot": stale_assist, "path": []})
	_check(stale_assist.checks == 1 and worker.task_search_timer == 0.0 and manager.assist_requests_by_worker.is_empty(), "Stale assist result was rechecked or retained")
	if enabled:
		for reason in ["no_work_position", "awaiting_worker_path", "no_eligible_worker", "auction_waiting_for_bids", "assignment_bid_stale", "auction_winner", "task_assigned", "worker_state_changed", "task_released_for_repath", "no_worker_path", "path_retry_due", "assignment_role_rejected", "worker_role_changed", "item_picked_up", "haul_delivery_path_queued", "haul_delivery_path_stale", "haul_delivery_path_failed", "haul_delivery_path_started", "path_invalidated", "assist_path_queued", "assist_path_stale", "item_dropped"]:
			_check(recorder.has_event(reason), "Missing actual decision hook: " + reason)
		_check(not recorder.invalidations.is_empty(), "Task/worker mutations did not invalidate decisions")
	else:
		_check(recorder.events.is_empty() and recorder.invalidations.is_empty(), "Disabled decision diagnostics received calls")
	for event in recorder.events:
		_check(_plain(event), "Decision hook leaked engine object")
	var state: Array = [worker.state, worker.current_task_id, worker.carried_source_item_id, task.status, task.accessibility, world.item_store.as_save_array(), queue.active_count(), queue.diagnostics_membership_revision, scheduler.enqueued]
	_dispose(world)
	return state


func _world(enabled: bool) -> TestWorld:
	var world := TestWorld.new()
	world._init_ramp_lookup()
	world.block_registry.load_from_csv(World.BLOCK_DATA_PATH)
	var recorder := Recorder.new()
	recorder.enabled = enabled
	world.set("live_diagnostics", recorder)
	world.item_store.live_diagnostics = recorder
	world.stockpile_store.live_diagnostics = recorder
	world.task_manager = TaskManager.new(world, world.task_queue)
	world.task_manager.path_search_scheduler.stop()
	world.task_manager.path_search_scheduler = ControlledScheduler.new()
	for id in [1, 2]:
		var worker := Worker.new()
		worker.worker_id = id
		worker.position = Vector3(1, 1, 0)
		world.add_child(worker)
		world.workers.append(worker)
	return world


func _dispose(world: TestWorld) -> void:
	world.task_manager.shutdown()
	world.free()


func _result(task_id: int, worker_id: int, auction_id: int, job_id: int, path: Array, snapshot) -> Dictionary:
	return {"task_id": task_id, "worker_id": worker_id, "auction_id": auction_id, "job_id": job_id, "path": path, "snapshot": snapshot}


func _plain(value) -> bool:
	match typeof(value):
		TYPE_NIL, TYPE_BOOL, TYPE_INT, TYPE_FLOAT, TYPE_STRING, TYPE_VECTOR3, TYPE_VECTOR3I:
			return true
		TYPE_ARRAY:
			for entry in value:
				if not _plain(entry):
					return false
			return true
		TYPE_DICTIONARY:
			for key in value:
				if typeof(key) not in [TYPE_STRING, TYPE_INT] or not _plain(value[key]):
					return false
			return true
	return false


func _check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)
