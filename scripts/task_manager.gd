extends RefCounted
class_name TaskManager
## Manages task queuing, accessibility checking, and blocked task handling.

const PathSearchSchedulerScript = preload("res://scripts/pathfinding/path_search_scheduler.gd")

#region State
var world: World
var task_queue: TaskQueue
var path_search_scheduler = PathSearchSchedulerScript.new()
var blocked_tasks: Array = []
var blocked_recheck_timer := 1.0
var reassign_timer := 1.0
var accessibility_recheck_index: int = 0
var accessibility_worker_index: int = 0
const REASSIGN_INTERVAL := 1.0
const BLOCKED_RECHECK_INTERVAL := 0.1
const BLOCKED_RECHECK_BUDGET := 8
const ACCESSIBILITY_INVALIDATION_RADIUS_XZ := 1
const ACCESSIBILITY_INVALIDATION_RADIUS_Y := 1
const ASSIGNMENT_TASK_TYPES := [
	TaskQueue.TaskType.DIG,
	TaskQueue.TaskType.STAIRS,
	TaskQueue.TaskType.PLACE,
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
#endregion


#region Initialization
func _init(world_ref: World, queue_ref: TaskQueue) -> void:
	world = world_ref
	task_queue = queue_ref
	path_search_scheduler.start()


func shutdown() -> void:
	path_search_scheduler.stop()
#endregion


#region Task Queue Updates
func update_task_queue() -> void:
	task_queue.cleanup_completed()


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
		task.set_accessibility(TaskQueue.TaskAccessibility.UNREACHABLE, Time.get_ticks_msec())
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


func update_blocked_tasks(dt: float) -> void:
	blocked_recheck_timer -= dt
	if blocked_recheck_timer <= 0.0:
		recheck_blocked_tasks()
		recheck_task_accessibility()
		blocked_recheck_timer = BLOCKED_RECHECK_INTERVAL


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
	blocked_recheck_timer = 0.0
	return true


func add_task_to_queue(task_type: int, pos: Vector3i, material: int) -> void:
	match task_type:
		TaskQueue.TaskType.DIG:
			task_queue.add_dig_task(pos)
		TaskQueue.TaskType.PLACE:
			task_queue.add_place_task(pos, material)
		TaskQueue.TaskType.STAIRS:
			task_queue.add_stairs_task(pos, material)
#endregion


#region Blocked Task Handling
func recheck_blocked_tasks() -> void:
	var checked := 0
	var i := 0
	while i < blocked_tasks.size() and checked < BLOCKED_RECHECK_BUDGET:
		var task = blocked_tasks[i]
		var task_type: int = task["type"]
		var pos: Vector3i = task["pos"]
		checked += 1
		if is_task_accessible(task_type, pos):
			add_task_to_queue(task_type, pos, task["material"])
			blocked_tasks.remove_at(i)
		else:
			i += 1


func recheck_task_accessibility() -> void:
	_refresh_stale_unreachable_tasks()
	_classify_tasks_without_work_positions()
	var unchecked_tasks: Array = []
	for task in task_queue.tasks:
		if task.status == TaskQueue.TaskStatus.PENDING \
			and task.accessibility == TaskQueue.TaskAccessibility.UNKNOWN:
			unchecked_tasks.append(task)
	if unchecked_tasks.is_empty():
		accessibility_recheck_index = 0
		accessibility_worker_index = 0
		return
	var task_index: int = accessibility_recheck_index % unchecked_tasks.size()
	var task = unchecked_tasks[task_index]
	var now_msec := Time.get_ticks_msec()
	if world == null or world.workers.is_empty():
		task.set_accessibility(TaskQueue.TaskAccessibility.UNREACHABLE, now_msec)
		_advance_accessibility_task(unchecked_tasks.size())
		return
	task.set_accessibility(TaskQueue.TaskAccessibility.REACHABLE, now_msec)
	_advance_accessibility_task(unchecked_tasks.size())


func _refresh_stale_unreachable_tasks() -> void:
	var now_msec := Time.get_ticks_msec()
	var refreshed := false
	for task in task_queue.tasks:
		if task.status != TaskQueue.TaskStatus.PENDING:
			continue
		if task.clear_expired_worker_unreachable(now_msec):
			refreshed = true
		if task.accessibility != TaskQueue.TaskAccessibility.UNREACHABLE:
			continue
		if task.accessibility_updated_msec > 0 \
			and now_msec - task.accessibility_updated_msec <= TaskQueue.TASK_UNREACHABLE_TTL_MSEC:
			continue
		task.set_accessibility(TaskQueue.TaskAccessibility.UNKNOWN, now_msec)
		task.unreachable_workers.clear()
		refreshed = true
	if not refreshed:
		return
	accessibility_recheck_index = 0
	accessibility_worker_index = 0


func _classify_tasks_without_work_positions() -> void:
	if world == null or world.pathfinder == null:
		return
	var now_msec := Time.get_ticks_msec()
	for task in task_queue.tasks:
		if task.status != TaskQueue.TaskStatus.PENDING:
			continue
		if task.accessibility != TaskQueue.TaskAccessibility.UNKNOWN:
			continue
		if task.type == TaskQueue.TaskType.STAIRS:
			continue
		if not world.pathfinder.has_walkable_adjacent_on_level(world, task.pos, task.pos.y):
			task.set_accessibility(TaskQueue.TaskAccessibility.UNREACHABLE, now_msec)


func _advance_accessibility_task(task_count: int) -> void:
	accessibility_worker_index = 0
	if task_count <= 1:
		accessibility_recheck_index = 0
	else:
		accessibility_recheck_index %= task_count - 1


func invalidate_task_accessibility(changed_pos: Vector3i) -> void:
	var invalidated := false
	for task in task_queue.tasks:
		if task.status != TaskQueue.TaskStatus.PENDING:
			continue
		if abs(task.pos.x - changed_pos.x) > ACCESSIBILITY_INVALIDATION_RADIUS_XZ:
			continue
		if abs(task.pos.z - changed_pos.z) > ACCESSIBILITY_INVALIDATION_RADIUS_XZ:
			continue
		if abs(task.pos.y - changed_pos.y) > ACCESSIBILITY_INVALIDATION_RADIUS_Y:
			continue
		task.unreachable_workers.clear()
		if task.accessibility != TaskQueue.TaskAccessibility.UNREACHABLE:
			continue
		task.accessibility = TaskQueue.TaskAccessibility.UNKNOWN
		invalidated = true
	if not invalidated:
		return
	accessibility_recheck_index = 0
	accessibility_worker_index = 0
	blocked_recheck_timer = 0.0


func mark_worker_unreachable_for_task(task, worker: Worker) -> void:
	if task == null or worker == null or task.status != TaskQueue.TaskStatus.PENDING:
		return
	var now_msec := Time.get_ticks_msec()
	task.mark_worker_unreachable(worker.worker_id, now_msec)
	world.trace_worker_event(worker, "task_worker_unreachable", task, "worker excluded from task assignment")
	for candidate: Worker in world.workers:
		if not task.is_worker_unreachable(candidate.worker_id, now_msec):
			return
	task.set_accessibility(TaskQueue.TaskAccessibility.UNREACHABLE, now_msec)
#endregion


#region Accessibility Checking
func is_task_accessible(task_type: int, pos: Vector3i) -> bool:
	if world == null or world.workers.is_empty():
		return false
	if not world.is_block_coord_valid(pos.x, pos.y, pos.z):
		return false
	if task_type == TaskQueue.TaskType.STAIRS:
		return true
	return world.pathfinder.has_walkable_adjacent_on_level(world, pos, pos.y)


func is_task_already_queued(task_type: int, pos: Vector3i) -> bool:
	if task_queue.has_active_task_at(pos, task_type):
		return true
	for task in blocked_tasks:
		if task["type"] == task_type and task["pos"] == pos:
			return true
	return false
#endregion
