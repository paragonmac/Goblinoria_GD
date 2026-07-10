extends RefCounted
class_name TaskManager
## Manages task queuing, accessibility checking, and blocked task handling.

const PathSearchSchedulerScript = preload("res://scripts/pathfinding/path_search_scheduler.gd")

#region State
var world: World
var task_queue: TaskQueue
var path_search_scheduler = PathSearchSchedulerScript.new()
var reassign_timer := 1.0
const REASSIGN_INTERVAL := 1.0
const ACCESSIBILITY_CHECK_BUDGET := 8
const ACCESSIBILITY_INVALIDATION_RADIUS_XZ := 1
const ACCESSIBILITY_INVALIDATION_RADIUS_Y := 1
const ASSIGNMENT_TASK_TYPES := [
	TaskQueue.TaskType.DIG,
	TaskQueue.TaskType.STAIRS,
	TaskQueue.TaskType.PLACE,
	TaskQueue.TaskType.HAUL,
]

var assignment_task_id := -1
var assignment_workers: Array = []
var assignment_worker_index := 0
var assignment_best_worker: Worker
var assignment_best_path: Array = []
var assignment_best_search_ms := 0.0
var assignment_bids: Array = []
var assignment_pending_jobs: Dictionary = {}
var assignment_auction_id := 0
var next_assignment_auction_id := 1
var assist_requests_by_worker: Dictionary = {}
var assist_requests_by_id: Dictionary = {}
var next_assist_request_id := 1
var haul_rebuild_requested := true
var haul_rebuild_in_progress := false
var haul_rebuild_reasons: Dictionary = {"initial": true}
var haul_rebuild_count := 0
var pending_accessibility_ids: Array[int] = []
var pending_accessibility_set: Dictionary = {}
var path_retry_due_by_task: Dictionary = {}
var path_retry_timer: Timer
var accessibility_check_count := 0
#endregion


#region Initialization
func _init(world_ref: World, queue_ref: TaskQueue) -> void:
	world = world_ref
	task_queue = queue_ref
	if world != null:
		world.item_store.haul_state_changed.connect(request_haul_rebuild)
		world.stockpile_store.haul_state_changed.connect(request_haul_rebuild)
	task_queue.task_added.connect(_on_task_added)
	task_queue.task_removed.connect(_on_task_removed)
	task_queue.task_visual_state_changed.connect(_on_task_visual_state_changed)
	for task in task_queue.tasks:
		request_accessibility_check(task.id, "manager_initialized")
	_setup_path_retry_timer()
	path_search_scheduler.start()


func shutdown() -> void:
	path_search_scheduler.stop()
	if path_retry_timer != null and is_instance_valid(path_retry_timer):
		path_retry_timer.stop()
		path_retry_timer.queue_free()
	path_retry_timer = null


func _setup_path_retry_timer() -> void:
	if world == null:
		return
	path_retry_timer = Timer.new()
	path_retry_timer.name = "TaskPathRetryTimer"
	path_retry_timer.one_shot = true
	path_retry_timer.timeout.connect(_on_path_retry_timeout)
	world.add_child(path_retry_timer)


func _on_task_added(task) -> void:
	if task != null:
		request_accessibility_check(task.id, "task_added")


func _on_task_removed(task_id: int) -> void:
	pending_accessibility_set.erase(task_id)
	if path_retry_due_by_task.has(task_id):
		path_retry_due_by_task.erase(task_id)
		_schedule_path_retry_timer()


func _on_task_visual_state_changed(task_id: int) -> void:
	var task = task_queue.get_task(task_id)
	if task != null \
			and task.status == TaskQueue.TaskStatus.PENDING \
			and task.accessibility == TaskQueue.TaskAccessibility.UNKNOWN:
		request_accessibility_check(task_id, "task_state_unknown")
#endregion


#region Task Queue Updates
func update_task_queue() -> void:
	# SEE-ADR-009: Haul reconstruction is mutation-driven and coalesced.
	if not haul_rebuild_requested:
		return
	haul_rebuild_requested = false
	haul_rebuild_reasons.clear()
	haul_rebuild_in_progress = true
	rebuild_haul_tasks()
	haul_rebuild_in_progress = false
	haul_rebuild_count += 1


func request_haul_rebuild(reason: String = "unspecified") -> void:
	if haul_rebuild_in_progress:
		return
	haul_rebuild_requested = true
	haul_rebuild_reasons[reason] = true


func request_accessibility_check(task_id: int, _reason: String = "unspecified") -> void:
	# SEE-ADR-010: Accessibility work is deduplicated and budgeted.
	if task_id < 0 or pending_accessibility_set.has(task_id):
		return
	if task_queue.get_task(task_id) == null:
		return
	pending_accessibility_set[task_id] = true
	pending_accessibility_ids.append(task_id)


func update_task_accessibility() -> void:
	var checked := 0
	while not pending_accessibility_ids.is_empty() and checked < ACCESSIBILITY_CHECK_BUDGET:
		var task_id: int = pending_accessibility_ids.pop_front()
		if not pending_accessibility_set.erase(task_id):
			continue
		var task = task_queue.get_task(task_id)
		if task == null or task.status != TaskQueue.TaskStatus.PENDING:
			continue
		_classify_task_accessibility(task)
		checked += 1
		accessibility_check_count += 1


func _classify_task_accessibility(task) -> void:
	var now_msec := Time.get_ticks_msec()
	if task.type != TaskQueue.TaskType.STAIRS \
			and task.type != TaskQueue.TaskType.HAUL \
			and not world.pathfinder.has_walkable_adjacent_on_level(world, task.pos, task.pos.y):
		_clear_path_retry(task.id)
		task.set_accessibility(
			TaskQueue.TaskAccessibility.UNREACHABLE,
			now_msec,
			TaskQueue.TaskBlockReason.NO_WORK_POSITION
		)
		return
	if world.workers.is_empty():
		_mark_task_path_blocked(task, now_msec)
		return
	_clear_path_retry(task.id)
	task.unreachable_workers.clear()
	task.set_accessibility(TaskQueue.TaskAccessibility.REACHABLE, now_msec)


func _mark_task_path_blocked(task, now_msec: int) -> void:
	var retry_due := now_msec + TaskQueue.TASK_UNREACHABLE_TTL_MSEC
	task.retry_due_msec = retry_due
	task.set_accessibility(
		TaskQueue.TaskAccessibility.UNREACHABLE,
		now_msec,
		TaskQueue.TaskBlockReason.NO_WORKER_PATH
	)
	path_retry_due_by_task[task.id] = retry_due
	_schedule_path_retry_timer()


func _clear_path_retry(task_id: int) -> void:
	if not path_retry_due_by_task.has(task_id):
		return
	path_retry_due_by_task.erase(task_id)
	_schedule_path_retry_timer()


func _schedule_path_retry_timer(now_msec: int = -1) -> void:
	if path_retry_timer == null:
		return
	if now_msec < 0:
		now_msec = Time.get_ticks_msec()
	if path_retry_due_by_task.is_empty():
		path_retry_timer.stop()
		return
	var earliest_due := -1
	for due in path_retry_due_by_task.values():
		if earliest_due < 0 or int(due) < earliest_due:
			earliest_due = int(due)
	path_retry_timer.wait_time = maxf(float(earliest_due - now_msec) / 1000.0, 0.001)
	if path_retry_timer.is_inside_tree():
		path_retry_timer.start()


func _on_path_retry_timeout() -> void:
	process_due_path_retries(Time.get_ticks_msec())


func process_due_path_retries(now_msec: int) -> void:
	for task_id in path_retry_due_by_task.keys().duplicate():
		if int(path_retry_due_by_task[task_id]) > now_msec:
			continue
		path_retry_due_by_task.erase(task_id)
		var task = task_queue.get_task(int(task_id))
		if task == null \
				or task.status != TaskQueue.TaskStatus.PENDING \
				or task.block_reason != TaskQueue.TaskBlockReason.NO_WORKER_PATH:
			continue
		task.unreachable_workers.clear()
		task.set_accessibility(TaskQueue.TaskAccessibility.UNKNOWN, now_msec)
		request_accessibility_check(task.id, "path_retry_due")
	_schedule_path_retry_timer(now_msec)


func notify_worker_availability_changed() -> void:
	var now_msec := Time.get_ticks_msec()
	for task_id in path_retry_due_by_task.keys().duplicate():
		path_retry_due_by_task.erase(task_id)
		var task = task_queue.get_task(int(task_id))
		if task == null or task.status != TaskQueue.TaskStatus.PENDING:
			continue
		task.unreachable_workers.clear()
		task.set_accessibility(TaskQueue.TaskAccessibility.UNKNOWN, now_msec)
		request_accessibility_check(task.id, "worker_availability_changed")
	_schedule_path_retry_timer(now_msec)


func reset_accessibility_state() -> void:
	pending_accessibility_ids.clear()
	pending_accessibility_set.clear()
	path_retry_due_by_task.clear()
	if path_retry_timer != null:
		path_retry_timer.stop()


func update_task_assignments() -> void:
	# SEE-ADR-005: Assignment waits for worker path bids so shortest valid paths win.
	_process_path_results()
	var task = task_queue.get_task(assignment_task_id) if assignment_task_id >= 0 else null
	if task == null \
		or task.status != TaskQueue.TaskStatus.PENDING \
		or task.accessibility != TaskQueue.TaskAccessibility.REACHABLE:
		_reset_assignment_auction()
		task = _next_assignable_task()
		if task == null:
			return
		_start_assignment_auction(task)

	if assignment_worker_index < assignment_workers.size():
		var worker: Worker = assignment_workers[assignment_worker_index]
		assignment_worker_index += 1
		_queue_worker_bid(task, worker)
		return
	if not assignment_pending_jobs.is_empty():
		return

	var best_bid := _best_available_assignment_bid()
	if not best_bid.is_empty():
		var best_worker: Worker = best_bid["worker"]
		best_worker.assign_task_with_path(
			world,
			task_queue,
			task,
			best_bid["path"],
			float(best_bid["search_ms"])
		)
	elif not assignment_workers.is_empty():
		if task.block_reason != TaskQueue.TaskBlockReason.NO_WORKER_PATH:
			_mark_task_path_blocked(task, Time.get_ticks_msec())
	_reset_assignment_auction()


func transfer_task_to_arrived_worker(task, worker: Worker) -> bool:
	if task == null or worker == null:
		return false
	if task.status != TaskQueue.TaskStatus.IN_PROGRESS or task.assigned_worker == null:
		return false
	if task.assigned_worker == worker or worker.current_task_id >= 0:
		return false
	if not worker.can_work_task(task, world, world.pathfinder):
		return false
	var owner: Worker = task.assigned_worker
	if owner.state == Worker.WorkerState.WORKING:
		return false
	var remaining_nodes := maxi(0, owner.path.size() - owner.path_index)
	if not owner.release_task_for_transfer(task, world):
		return false
	worker.assign_task_with_path(
		world,
		task_queue,
		task,
		[worker.get_block_coord()],
		0.0,
		"task_transferred",
		"previous_worker=%d previous_remaining_nodes=%d" % [owner.worker_id, remaining_nodes]
	)
	return true


func reset_assignment_auction() -> void:
	_reset_assignment_auction()
	assist_requests_by_worker.clear()
	assist_requests_by_id.clear()
	path_search_scheduler.clear()


func rebuild_haul_tasks() -> void:
	if world == null or task_queue == null:
		return
	_prune_invalid_haul_tasks()
	for item: Dictionary in world.item_store.loose_items():
		var item_id := int(item.get("id", -1))
		if item_id < 0:
			continue
		if int(item.get("reserved_by_task_id", -1)) >= 0:
			continue
		var destination: Dictionary = world.find_stockpile_destination_for_item(item)
		if destination.is_empty():
			world.trace_system_event(
				"haul_not_queued",
				"item_id=%d material=%d reason=no_accepting_stockpile" % [
					item_id,
					int(item.get("material_id", 0)),
				]
			)
			continue
		var task_id := task_queue.add_haul_task(
			item_id,
			item.get("pos", Vector3i.ZERO),
			int(item.get("material_id", 0)),
			int(destination.get("stockpile_id", -1)),
			destination.get("pos", Vector3i.ZERO)
		)
		if world.item_store.reserve_item(item_id, task_id):
			var task = task_queue.get_task(task_id)
			world.trace_task_event(task, "haul_queued", "item_id=%d stockpile=%d destination=%s" % [
				item_id,
				int(destination.get("stockpile_id", -1)),
				destination.get("pos", Vector3i.ZERO),
			])


func _prune_invalid_haul_tasks() -> void:
	for task in task_queue.tasks.duplicate():
		if task.type != TaskQueue.TaskType.HAUL or task.status == TaskQueue.TaskStatus.COMPLETED:
			continue
		if _is_haul_task_valid(task):
			continue
		var item_id := int(task.data.get("item_id", -1))
		world.item_store.release_reservation(item_id, task.id)
		task_queue.remove_task(task)
		if task.id == assignment_task_id:
			_reset_assignment_auction()
		world.trace_task_event(task, "haul_cancelled", "reason=invalid_reservation_or_destination")


func _is_haul_task_valid(task) -> bool:
	if world == null or task == null:
		return false
	var item_id := int(task.data.get("item_id", -1))
	var item: Dictionary = world.item_store.get_item(item_id)
	if item.is_empty():
		return false
	if int(item.get("stored_stockpile_id", -1)) >= 0:
		return false
	var reserved_by := int(item.get("reserved_by_task_id", -1))
	if reserved_by != task.id:
		return false
	var destination: Vector3i = task.data.get("destination", Vector3i.ZERO)
	var stockpile_id := int(task.data.get("stockpile_id", -1))
	if world.stockpile_store.stockpile_at(destination) != stockpile_id:
		return false
	return world.stockpile_store.accepts_material(stockpile_id, int(item.get("material_id", 0)))


func has_assignable_pending_task() -> bool:
	return _next_assignable_task() != null


func request_assist_path(worker: Worker, candidates: Array) -> bool:
	if worker == null or candidates.is_empty():
		return false
	if assist_requests_by_worker.has(worker.worker_id):
		return true
	var goals: Array = []
	var goal_task_ids: Dictionary = {}
	for entry: Dictionary in candidates:
		var goal: Vector3i = entry["pos"]
		var task = entry["task"]
		if goal_task_ids.has(goal):
			continue
		goals.append(goal)
		goal_task_ids[goal] = task.id
	if goals.is_empty():
		return false
	var request_id := next_assist_request_id
	next_assist_request_id += 1
	var job_id := path_search_scheduler.enqueue_goals(
		world,
		request_id,
		worker,
		goals,
		Worker.ASSIST_PATH_SEARCH_MAX_ITERATIONS
	)
	var request := {
		"request_id": request_id,
		"job_id": job_id,
		"worker": worker,
		"goal_task_ids": goal_task_ids,
	}
	assist_requests_by_worker[worker.worker_id] = request
	assist_requests_by_id[request_id] = request
	world.trace_worker_event(worker, "assist_path_queued", null, "job_id=%d goals=%d" % [job_id, goals.size()])
	return true


func _next_assignable_task():
	if world == null:
		return null
	var now_msec := Time.get_ticks_msec()
	for task_type in ASSIGNMENT_TASK_TYPES:
		for task in task_queue.tasks:
			if task.status != TaskQueue.TaskStatus.PENDING:
				continue
			if task.type != task_type:
				continue
			if task.accessibility != TaskQueue.TaskAccessibility.REACHABLE:
				continue
			if not world.is_block_coord_valid(task.pos.x, task.pos.y, task.pos.z):
				continue
			if task.type == TaskQueue.TaskType.DIG and world.is_block_protected_from_dig(task.pos):
				continue
			for worker: Worker in world.workers:
				if _is_worker_available(worker) and not task.is_worker_unreachable(worker.worker_id, now_msec):
					return task
	return null


func _start_assignment_auction(task) -> void:
	assignment_task_id = task.id
	assignment_auction_id = next_assignment_auction_id
	next_assignment_auction_id += 1
	assignment_workers.clear()
	for worker: Worker in world.workers:
		if _is_worker_available(worker):
			assignment_workers.append(worker)
	assignment_workers.sort_custom(func(a: Worker, b: Worker):
		return a.worker_id < b.worker_id
	)
	assignment_worker_index = 0
	assignment_best_worker = null
	assignment_best_path = []
	assignment_best_search_ms = 0.0
	assignment_bids.clear()
	assignment_pending_jobs.clear()
	world.trace_task_event(task, "assignment_auction_started", "candidate_workers=%s" % _worker_ids(assignment_workers))


func _queue_worker_bid(task, worker: Worker) -> void:
	if not _is_worker_available(worker):
		return
	var now_msec := Time.get_ticks_msec()
	if task.is_worker_unreachable(worker.worker_id, now_msec):
		return
	var job_id: int = path_search_scheduler.enqueue(
		world,
		assignment_auction_id,
		task,
		worker,
		Worker.WORKER_PATH_SEARCH_MAX_ITERATIONS
	)
	assignment_pending_jobs[job_id] = worker
	world.trace_worker_event(worker, "assignment_bid_queued", task, "job_id=%d" % job_id)


func _process_path_results() -> void:
	var restart_auction := false
	while true:
		var result: Dictionary = path_search_scheduler.pop_result()
		if result.is_empty():
			break
		if String(result.get("kind", "assignment")) == "goals":
			_process_assist_result(result)
			continue
		if int(result.get("auction_id", -1)) != assignment_auction_id:
			continue
		var job_id: int = int(result.get("job_id", -1))
		var worker: Worker = assignment_pending_jobs.get(job_id, null)
		assignment_pending_jobs.erase(job_id)
		var task = task_queue.get_task(int(result.get("task_id", -1)))
		if worker == null or task == null:
			continue
		var snapshot = result.get("snapshot", null)
		if snapshot == null or not snapshot.revisions_match(world):
			world.trace_worker_event(worker, "assignment_bid_stale", task, "job_id=%d" % job_id)
			restart_auction = true
			continue
		_collect_worker_bid_result(task, worker, result)
	if restart_auction:
		_reset_assignment_auction()


func _process_assist_result(result: Dictionary) -> void:
	var request_id: int = int(result.get("request_id", -1))
	var request: Dictionary = assist_requests_by_id.get(request_id, {})
	if request.is_empty():
		return
	assist_requests_by_id.erase(request_id)
	var worker: Worker = request["worker"]
	if not is_instance_valid(worker):
		return
	assist_requests_by_worker.erase(worker.worker_id)
	var snapshot = result.get("snapshot", null)
	if snapshot == null or not snapshot.revisions_match(world):
		world.trace_worker_event(worker, "assist_path_stale", null, "request_id=%d" % request_id)
		worker.task_search_timer = 0.0
		return
	if worker.current_task_id >= 0 or worker.state != Worker.WorkerState.IDLE:
		return
	var path: Array = result.get("path", [])
	if path.is_empty():
		var stats: Dictionary = result.get("search_stats", {})
		world.trace_worker_event(worker, "assist_path_failed", null, "snapshot_ms=%.3f queue_wait_ms=%.3f search_ms=%.3f reason=%s iterations=%d/%d" % [
			float(result.get("snapshot_ms", 0.0)),
			float(result.get("queue_wait_ms", 0.0)),
			float(result.get("search_ms", 0.0)),
			str(stats.get("reason", "unknown")),
			int(stats.get("iterations_used", 0)),
			int(stats.get("max_iterations", 0)),
		])
		worker.task_search_timer = Worker.FAILED_TASK_SEARCH_INTERVAL
		return
	var goal: Vector3i = path[path.size() - 1]
	var task_id: int = int(request["goal_task_ids"].get(goal, -1))
	var task = task_queue.get_task(task_id)
	if task == null \
		or task.status != TaskQueue.TaskStatus.IN_PROGRESS \
		or task.assigned_worker == null \
		or task.assigned_worker == worker:
		worker.task_search_timer = 0.0
		return
	worker.start_assist_path(
		world,
		task,
		path,
		goal,
		float(result.get("search_ms", 0.0)),
		float(result.get("snapshot_ms", 0.0)),
		float(result.get("queue_wait_ms", 0.0))
	)


func _collect_worker_bid_result(task, worker: Worker, result: Dictionary) -> void:
	var maybe_path: Array = result.get("path", [])
	var search_ms: float = float(result.get("search_ms", 0.0))
	var stats: Dictionary = result.get("search_stats", {})
	if maybe_path.is_empty():
		world.trace_worker_event(worker, "assignment_bid_failed", task, "snapshot_ms=%.3f queue_wait_ms=%.3f search_ms=%.3f reason=%s iterations=%d/%d hit_iteration_cap=%s" % [
			float(result.get("snapshot_ms", 0.0)),
			float(result.get("queue_wait_ms", 0.0)),
			search_ms,
			str(stats.get("reason", "unknown")),
			int(stats.get("iterations_used", 0)),
			int(stats.get("max_iterations", 0)),
			str(stats.get("hit_iteration_cap", false)),
		])
		mark_worker_unreachable_for_task(task, worker)
		return
	world.trace_worker_event(worker, "assignment_bid", task, "path_length=%d snapshot_ms=%.3f queue_wait_ms=%.3f search_ms=%.3f" % [
		maybe_path.size(),
		float(result.get("snapshot_ms", 0.0)),
		float(result.get("queue_wait_ms", 0.0)),
		search_ms,
	])
	assignment_bids.append({
		"worker": worker,
		"path": maybe_path,
		"path_length": maybe_path.size(),
		"worker_id": worker.worker_id,
		"search_ms": search_ms,
	})
	if _is_better_assignment_bid(maybe_path.size(), worker.worker_id):
		assignment_best_worker = worker
		assignment_best_path = maybe_path.duplicate()
		assignment_best_search_ms = search_ms


func _best_available_assignment_bid() -> Dictionary:
	var best: Dictionary = {}
	for bid: Dictionary in assignment_bids:
		var worker: Worker = bid["worker"]
		if not _is_worker_available(worker):
			continue
		if best.is_empty() \
			or int(bid["path_length"]) < int(best["path_length"]) \
			or (
				int(bid["path_length"]) == int(best["path_length"])
				and int(bid["worker_id"]) < int(best["worker_id"])
			):
			best = bid
	return best


func _is_better_assignment_bid(path_length: int, worker_id: int) -> bool:
	if assignment_best_worker == null:
		return true
	if path_length != assignment_best_path.size():
		return path_length < assignment_best_path.size()
	return worker_id < assignment_best_worker.worker_id


func _is_worker_available(worker: Worker) -> bool:
	return worker != null \
		and worker.current_task_id < 0 \
		and worker.state == Worker.WorkerState.IDLE \
		and not assist_requests_by_worker.has(worker.worker_id)


func _reset_assignment_auction() -> void:
	assignment_task_id = -1
	assignment_auction_id = 0
	assignment_workers.clear()
	assignment_worker_index = 0
	assignment_best_worker = null
	assignment_best_path = []
	assignment_best_search_ms = 0.0
	assignment_bids.clear()
	assignment_pending_jobs.clear()


func _worker_ids(worker_list: Array) -> String:
	var ids: Array[String] = []
	for worker: Worker in worker_list:
		ids.append(str(worker.worker_id))
	return "|".join(ids)


func update_reassign_tasks(dt: float) -> void:
	reassign_timer -= dt
	if reassign_timer <= 0.0:
		reassess_waiting_tasks()
		reassign_timer = REASSIGN_INTERVAL


func reassess_waiting_tasks() -> void:
	for task in task_queue.tasks:
		if task.status != TaskQueue.TaskStatus.IN_PROGRESS:
			continue
		var worker = task.assigned_worker
		if worker == null:
			task.status = TaskQueue.TaskStatus.PENDING
			task.accessibility = TaskQueue.TaskAccessibility.UNKNOWN
			continue
		if worker.state == Worker.WorkerState.IDLE:
			world.trace_worker_event(worker, "task_released", task, "assigned worker idle")
			task.status = TaskQueue.TaskStatus.PENDING
			task.accessibility = TaskQueue.TaskAccessibility.UNKNOWN
			task.assigned_worker = null
			if worker.current_task_id == task.id:
				worker.current_task_id = -1
				worker.set_state(Worker.WorkerState.IDLE)
#endregion


#region Task Queueing
func queue_task_request(task_type: int, pos: Vector3i, material: int) -> bool:
	if world == null or not world.is_block_coord_valid(pos.x, pos.y, pos.z):
		return false
	if is_task_already_queued(task_type, pos):
		return false
	if task_type == TaskQueue.TaskType.STAIRS \
			and task_queue.has_active_task_at(pos, TaskQueue.TaskType.DIG) \
			and not task_queue.remove_pending_task_at(pos, TaskQueue.TaskType.DIG):
		return false
	add_task_to_queue(task_type, pos, material)
	return true


func cancel_pending_task_requests_at(pos: Vector3i) -> Array:
	if world == null or not world.is_block_coord_valid(pos.x, pos.y, pos.z):
		return []
	var removed: Array = task_queue.remove_pending_tasks_at(pos, ASSIGNMENT_TASK_TYPES)
	if removed.is_empty():
		return removed
	for task in removed:
		world.trace_task_event(task, "task_cancelled", "reason=player_erase")
		if task.id == assignment_task_id:
			_reset_assignment_auction()
	return removed


func add_task_to_queue(task_type: int, pos: Vector3i, material: int) -> void:
	match task_type:
		TaskQueue.TaskType.DIG:
			task_queue.add_dig_task(pos)
		TaskQueue.TaskType.PLACE:
			task_queue.add_place_task(pos, material)
		TaskQueue.TaskType.STAIRS:
			task_queue.add_stairs_task(pos, material)
		TaskQueue.TaskType.HAUL:
			pass
#endregion


func invalidate_task_accessibility(changed_pos: Vector3i) -> void:
	# SEE-ADR-010: Terrain changes only inspect tasks in the indexed local neighborhood.
	for task in task_queue.tasks_near(
		changed_pos,
		ACCESSIBILITY_INVALIDATION_RADIUS_XZ,
		ACCESSIBILITY_INVALIDATION_RADIUS_Y
	):
		if task.status != TaskQueue.TaskStatus.PENDING:
			continue
		task.unreachable_workers.clear()
		_clear_path_retry(task.id)
		task.set_accessibility(TaskQueue.TaskAccessibility.UNKNOWN, Time.get_ticks_msec())
		request_accessibility_check(task.id, "nearby_terrain_changed")


func mark_worker_unreachable_for_task(task, worker: Worker) -> void:
	if task == null or worker == null or task.status != TaskQueue.TaskStatus.PENDING:
		return
	var now_msec := Time.get_ticks_msec()
	task.mark_worker_unreachable(worker.worker_id, now_msec)
	world.trace_worker_event(worker, "task_worker_unreachable", task, "worker excluded from task assignment")
	for candidate: Worker in world.workers:
		if not task.is_worker_unreachable(candidate.worker_id, now_msec):
			return
	_mark_task_path_blocked(task, now_msec)
#endregion


func is_task_already_queued(task_type: int, pos: Vector3i) -> bool:
	return task_queue.has_active_task_at(pos, task_type)
#endregion
