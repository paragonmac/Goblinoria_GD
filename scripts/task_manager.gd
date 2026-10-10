extends RefCounted
class_name TaskManager
## Manages task queuing, accessibility checking, and blocked task handling.

const PathSearchSchedulerScript = preload("res://scripts/pathfinding/path_search_scheduler.gd")
const TaskWorkPositionRulesScript = preload("res://scripts/task_work_position_rules.gd")
const StairFlightScript = preload("res://scripts/stair_flight.gd")

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
# A round visits the live task array incrementally; no task/path matrix is copied.
# Retain only one best bid per worker, and one task's asynchronous bids at a time.
var priority_round_active := false
var priority_task_cursor := 0
var priority_task_limit := 0
var priority_worker_cursor := 0
var priority_choices: Dictionary = {}
var priority_winner: Dictionary = {}
# Every bid of the round per worker (not only the best), so the round can be
# committed as a greedy matching instead of one claim per round.
var priority_alternates: Dictionary = {}
var priority_choice_checks: Dictionary = {}
var assignment_job_context: Dictionary = {}
# Per auction: start cells whose search already failed (identical searches are
# skipped) and the number of candidates that failed to reach the task.
var assignment_failed_starts: Dictionary = {}
var assignment_failed_count := 0
# Grid auction (SEE-ADR-005 amendment 2026-10-10): candidates near the task
# share one reverse navigation-grid search; far ones keep per-worker searches.
const GRID_AUCTION_RADIUS_XZ := 64
const GRID_AUCTION_RADIUS_Y := 24
var assignment_auction_dispatched := false
var assignment_legacy_workers: Array[Worker] = []
const PRIORITY_SCAN_BUDGET := 128
## Auctions per priority round before committing the best choices found. Full
## rounds over every pending task needed ~1000 serial path searches with 70
## tasks and 14 workers, so nobody was assigned for minutes.
const PRIORITY_ROUND_AUCTION_CAP := 24
const PRIORITY_REDUCTION_BUDGET := 256
var priority_scan_offset := 0
var priority_round_auctions := 0
var priority_round_capped_at := -1
# Task ids already examined (auctioned or passed over) this round; rescans
# after membership changes skip them. Choices only improve within a round, so a
# task that was not worth bidding stays not worth bidding.
var priority_examined: Dictionary = {}
var assist_requests_by_worker: Dictionary = {}
var assist_requests_by_id: Dictionary = {}
var next_assist_request_id := 1
var haul_path_requests_by_worker: Dictionary = {}
var haul_path_requests_by_id: Dictionary = {}
var next_haul_path_request_id := 1
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
		task_queue.diagnostics_world = weakref(world)
		world.item_store.haul_state_changed.connect(request_haul_rebuild)
		world.stockpile_store.haul_state_changed.connect(request_haul_rebuild)
	task_queue.task_added.connect(_on_task_added)
	task_queue.task_removed.connect(_on_task_removed)
	task_queue.task_visual_state_changed.connect(_on_task_visual_state_changed)
	for task in task_queue.tasks:
		task.diagnostics_world = task_queue.diagnostics_world
		request_accessibility_check(task.id, "manager_initialized")
	_setup_path_retry_timer()
	path_search_scheduler.start()


func shutdown() -> void:
	path_search_scheduler.stop()
	reset_assignment_auction()
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
		if priority_round_active:
			priority_task_limit = task_queue.tasks.size()
			priority_worker_cursor = 0
			priority_winner = {}
		request_accessibility_check(task.id, "task_added")


func _on_task_removed(task_id: int) -> void:
	# Do not assume ordered erase versus swap-removal. Retain valid nominations
	# and rescan the array, but tasks already auctioned this round are skipped
	# (priority_examined), so frequent haul churn no longer repeats the scan.
	priority_task_cursor = 0
	priority_task_limit = mini(priority_task_limit, task_queue.tasks.size())
	priority_worker_cursor = 0
	priority_winner = {}
	pending_accessibility_set.erase(task_id)
	_clear_haul_path_request_for_task(task_id)
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
	if _diagnostics_enabled():
		world.live_diagnostics.invalidate("task", str(task_id), _reason)


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
	var has_work_position := true
	if task.type == TaskQueue.TaskType.STAIRS:
		has_work_position = not _stair_work_positions_for_task(task).is_empty()
	elif task.type != TaskQueue.TaskType.HAUL:
		has_work_position = not TaskWorkPositionRulesScript.task_work_positions(
			world, world.pathfinder, task.pos, task.type).is_empty()
	if not has_work_position:
		_clear_path_retry(task.id)
		task.set_accessibility(
			TaskQueue.TaskAccessibility.UNREACHABLE,
			now_msec,
			TaskQueue.TaskBlockReason.NO_WORK_POSITION
		)
		if _diagnostics_enabled():
			world.live_diagnostics.observe("task", str(task.id), "no_work_position", {"type": task.type, "pos": task.pos})
		return
	if not _has_eligible_worker(task):
		_clear_path_retry(task.id)
		task.set_accessibility(
			TaskQueue.TaskAccessibility.UNREACHABLE,
			now_msec,
			TaskQueue.TaskBlockReason.NO_ELIGIBLE_WORKER
		)
		if _diagnostics_enabled():
			world.live_diagnostics.observe("task", str(task.id), "no_eligible_worker", {"type": task.type, "worker_count": world.workers.size()})
		return
	_clear_path_retry(task.id)
	task.unreachable_workers.clear()
	# A work position is necessary but not sufficient. Keep the task green until
	# a revision-checked worker path bid proves it is currently reachable.
	task.set_accessibility(TaskQueue.TaskAccessibility.UNKNOWN, now_msec)
	if _diagnostics_enabled():
		world.live_diagnostics.observe("task", str(task.id), "awaiting_worker_path", {"has_work_position": has_work_position, "eligible_role_present": true})


func _mark_task_path_blocked(task, now_msec: int) -> void:
	# Back off repeated failures (2.5 s doubling to 60 s) so unreachable work
	# cannot monopolize serial auctions; terrain changes nearby reset it.
	task.path_block_streak += 1
	var backoff_msec: int = TaskQueue.TASK_UNREACHABLE_TTL_MSEC << mini(task.path_block_streak - 1, 5)
	var retry_due := now_msec + mini(backoff_msec, TaskQueue.TASK_UNREACHABLE_MAX_TTL_MSEC)
	task.retry_due_msec = retry_due
	task.set_accessibility(
		TaskQueue.TaskAccessibility.UNREACHABLE,
		now_msec,
		TaskQueue.TaskBlockReason.NO_WORKER_PATH
	)
	path_retry_due_by_task[task.id] = retry_due
	_schedule_path_retry_timer()
	if _diagnostics_enabled():
		world.live_diagnostics.observe("task", str(task.id), "no_worker_path", {"retry_due_msec": retry_due})


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
		if _diagnostics_enabled():
			world.live_diagnostics.observe("task", str(task.id), "path_retry_due", {"now_msec": now_msec})
	_schedule_path_retry_timer(now_msec)


func notify_worker_availability_changed() -> void:
	var now_msec := Time.get_ticks_msec()
	_reset_assignment_auction()
	_reset_priority_round()
	# Invalidate unclaimed assist results, not active haul delivery requests.
	assist_requests_by_worker.clear()
	assist_requests_by_id.clear()
	for task in task_queue.tasks:
		if task.status != TaskQueue.TaskStatus.PENDING:
			continue
		if task.block_reason == TaskQueue.TaskBlockReason.NO_WORK_POSITION:
			continue
		path_retry_due_by_task.erase(task.id)
		task.unreachable_workers.clear()
		task.set_accessibility(TaskQueue.TaskAccessibility.UNKNOWN, now_msec)
		request_accessibility_check(task.id, "worker_availability_changed")
		if _diagnostics_enabled():
			world.live_diagnostics.invalidate("task", str(task.id), "worker_availability_changed")
	_schedule_path_retry_timer(now_msec)


func reset_accessibility_state() -> void:
	pending_accessibility_ids.clear()
	pending_accessibility_set.clear()
	path_retry_due_by_task.clear()
	if path_retry_timer != null:
		path_retry_timer.stop()


func update_task_assignments() -> void:
	# SEE-ADR-005: Compare completed reachable paths, not straight-line distances.
	# Per-worker numeric priority precedes route cost across ALL implemented types.
	if world == null or task_queue == null:
		return
	priority_choice_checks.clear()
	_process_path_results()
	if task_queue.tasks.is_empty():
		if priority_round_active:
			_reset_assignment_auction()
			_reset_priority_round()
		return
	if not priority_round_active:
		priority_round_active = true
		priority_task_limit = task_queue.tasks.size()
	var task = task_queue.get_task(assignment_task_id) if assignment_task_id >= 0 else null
	if task == null \
			or task.status != TaskQueue.TaskStatus.PENDING \
			or task.accessibility == TaskQueue.TaskAccessibility.UNREACHABLE:
		_reset_assignment_auction()
		task = _next_priority_round_task()
		if task == null:
			if priority_task_cursor >= mini(priority_task_limit, task_queue.tasks.size()):
				_finish_priority_round_step()
			return
		_start_assignment_auction(task)

	# One in-flight assignment path bounds snapshot/result retention independent of
	# task count. Delivery/assist paths retain their own existing handoff contracts.
	if not assignment_auction_dispatched:
		assignment_auction_dispatched = true
		_dispatch_grid_auction(task)
	if not assignment_pending_jobs.is_empty():
		if _diagnostics_enabled():
			world.live_diagnostics.observe("task", str(task.id), "auction_waiting_for_bids", {"auction_id": assignment_auction_id, "pending_jobs": assignment_pending_jobs.size(), "received_bids": assignment_bids.size()})
		return
	if assignment_worker_index < assignment_legacy_workers.size():
		var worker: Worker = assignment_legacy_workers[assignment_worker_index]
		assignment_worker_index += 1
		_queue_worker_bid(task, worker)
		return
	# Only actual failed paths may mark a task blocked. A skipped lower-priority
	# bid, busy worker, or settings edit is not proof of unreachability.
	_reset_assignment_auction()


func _next_priority_round_task():
	var started := Time.get_ticks_usec()
	var steps := 0
	while priority_task_cursor < mini(priority_task_limit, task_queue.tasks.size()):
		if priority_round_auctions >= PRIORITY_ROUND_AUCTION_CAP:
			# Commit what this round found; the next round continues from here.
			priority_round_capped_at = priority_task_cursor
			priority_task_cursor = mini(priority_task_limit, task_queue.tasks.size())
			return null
		if steps >= PRIORITY_SCAN_BUDGET or Time.get_ticks_usec() - started >= 1000:
			return null
		var task = task_queue.tasks[(priority_scan_offset + priority_task_cursor) % task_queue.tasks.size()]
		priority_task_cursor += 1
		if priority_examined.has(task.id):
			continue
		priority_examined[task.id] = true
		steps += 1
		if task.status != TaskQueue.TaskStatus.PENDING \
				or task.accessibility == TaskQueue.TaskAccessibility.UNREACHABLE:
			continue
		if not world.is_block_coord_valid(task.pos.x, task.pos.y, task.pos.z):
			continue
		if task.type == TaskQueue.TaskType.DIG and world.is_block_protected_from_dig(task.pos):
			continue
		if not _task_material_available(task):
			continue
		var worth_bidding := false
		for worker: Worker in world.workers:
			if _is_worker_available(worker) and worker.can_accept_task(task) and _can_improve_priority_choice(task, worker):
				worth_bidding = true
				break
		if not worth_bidding:
			continue
		priority_round_auctions += 1
		return task
	return null


func _remember_priority_bid(task, worker: Worker, bid: Dictionary) -> void:
	if not priority_round_active:
		return
	var priority := worker.get_work_priority(Worker.WorkPrioritiesScript.task_work_id(task.type))
	var alternate := bid.duplicate()
	alternate["task"] = task
	alternate["priority"] = priority
	alternate["configuration"] = worker.get_work_configuration()
	alternate["start"] = worker.get_block_coord()
	if not priority_alternates.has(worker.worker_id):
		priority_alternates[worker.worker_id] = []
	priority_alternates[worker.worker_id].append(alternate)
	var previous: Dictionary = priority_choices.get(worker.worker_id, {})
	if not previous.is_empty():
		if priority > int(previous["priority"]):
			return
		if priority == int(previous["priority"]) and (
			int(bid["path_length"]) > int(previous["path_length"]) or (
			int(bid["path_length"]) == int(previous["path_length"]) and task.id >= previous["task"].id)):
			return
	var choice := bid.duplicate()
	choice["task"] = task
	choice["priority"] = priority
	choice["configuration"] = worker.get_work_configuration()
	choice["start"] = worker.get_block_coord()
	priority_choices[worker.worker_id] = choice
	priority_choice_checks.erase(worker.worker_id)


func _priority_choice_valid(choice: Dictionary) -> bool:
	if not _priority_choice_valid_except_snapshot(choice):
		return false
	var snapshot = choice.get("snapshot")
	return snapshot != null and snapshot.revisions_match(world)


func _priority_choice_valid_except_snapshot(choice: Dictionary) -> bool:
	if choice.is_empty():
		return false
	var worker: Worker = choice["worker"]
	var task = choice["task"]
	if not is_instance_valid(worker) or not _is_worker_available(worker):
		return false
	if task_queue.get_task(task.id) != task or task.status != TaskQueue.TaskStatus.PENDING:
		return false
	if not _task_material_available(task):
		return false
	if not worker.can_accept_task(task) or worker.get_work_configuration() != choice["configuration"]:
		return false
	if worker.get_block_coord() != choice["start"]:
		return false
	return true


func _finish_priority_round_step() -> void:
	# Reduce all workers in one frame (bounded), then commit on the next frame
	# so a task added in between still participates. Reducing one worker per
	# frame let routine job churn reset the reduction before it ever finished.
	var processed := 0
	while priority_worker_cursor < world.workers.size() and processed < PRIORITY_REDUCTION_BUDGET:
		var worker: Worker = world.workers[priority_worker_cursor]
		priority_worker_cursor += 1
		processed += 1
		var choice: Dictionary = priority_choices.get(worker.worker_id, {})
		if _priority_choice_valid(choice):
			if priority_winner.is_empty() or int(choice["path_length"]) < int(priority_winner["path_length"]) \
					or (choice["path_length"] == priority_winner["path_length"] and choice["worker_id"] < priority_winner["worker_id"]):
				priority_winner = choice
	if processed > 0:
		return
	_commit_priority_matching()
	# Recompute losers against unclaimed jobs, including their lower priorities.
	_reset_priority_round()


## SEE-ADR-005 (amendment 2026-10-10): commit the round as a greedy matching over
## every bid it collected, ordered by worker priority, path length, worker ID and
## task ID. Each worker and task is used once. One claim per round left most
## workers idle when they all nominated the same nearest task.
func _commit_priority_matching() -> void:
	var pairs: Array = []
	for worker_id in priority_alternates:
		pairs.append_array(priority_alternates[worker_id])
	if pairs.is_empty():
		return
	pairs.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if int(a["priority"]) != int(b["priority"]):
			return int(a["priority"]) < int(b["priority"])
		if int(a["path_length"]) != int(b["path_length"]):
			return int(a["path_length"]) < int(b["path_length"])
		if int(a["worker_id"]) != int(b["worker_id"]):
			return int(a["worker_id"]) < int(b["worker_id"])
		return a["task"].id < b["task"].id)
	var used_workers := {}
	var used_tasks := {}
	var snapshot_valid := {}
	for choice: Dictionary in pairs:
		var worker_id := int(choice["worker_id"])
		var task = choice["task"]
		if used_workers.has(worker_id) or used_tasks.has(task.id):
			continue
		# Bids of one grid auction share a snapshot: validate it once.
		var snapshot = choice.get("snapshot")
		if snapshot != null and not snapshot_valid.has(snapshot):
			snapshot_valid[snapshot] = snapshot.revisions_match(world)
		if snapshot == null or not snapshot_valid[snapshot] or not _priority_choice_valid_except_snapshot(choice):
			continue
		var worker: Worker = choice["worker"]
		if _diagnostics_enabled():
			world.live_diagnostics.observe("task", str(task.id), "auction_winner", {"worker_id": worker_id, "priority": choice["priority"], "path_length": choice["path_length"], "tie_break": "priority_then_path_then_worker_id_then_task_id"})
		worker.assign_task_with_path(world, task_queue, task, choice["path"], choice["search_ms"])
		used_workers[worker_id] = true
		used_tasks[task.id] = true


func _reset_priority_round() -> void:
	# Rotate the scan window so capped rounds cover every task over time.
	var task_count := task_queue.tasks.size() if task_queue != null else 0
	var examined := priority_round_capped_at if priority_round_capped_at >= 0 else priority_task_cursor
	priority_scan_offset = (priority_scan_offset + examined) % task_count if task_count > 0 else 0
	priority_round_capped_at = -1
	priority_round_auctions = 0
	priority_examined.clear()
	priority_round_active = false
	priority_task_cursor = 0
	priority_task_limit = 0
	priority_worker_cursor = 0
	priority_choices.clear()
	priority_alternates.clear()
	priority_choice_checks.clear()
	priority_winner = {}


func _task_material_available(task) -> bool:
	# World.inventory is the maintained stored/spendable compatibility view.
	# get_inventory_count() would rescan item stacks here; do not use it.
	return task.type != TaskQueue.TaskType.PLACE or int(world.inventory.get(task.material, 0)) > 0


func _can_improve_priority_choice(task, worker: Worker) -> bool:
	var previous: Dictionary = priority_choices.get(worker.worker_id, {})
	if previous.is_empty():
		return true
	# At most one snapshot validation per worker per update, not per candidate.
	# A stale winner must not suppress routes already skipped using its old bound.
	if not priority_choice_checks.has(worker.worker_id):
		priority_choice_checks[worker.worker_id] = _priority_choice_valid(previous)
	if not priority_choice_checks[worker.worker_id]:
		priority_choices.erase(worker.worker_id)
		priority_task_cursor = 0
		priority_worker_cursor = 0
		priority_winner = {}
		return true
	var priority := worker.get_work_priority(Worker.WorkPrioritiesScript.task_work_id(task.type))
	if priority != int(previous["priority"]):
		return priority < int(previous["priority"])
	var bound := Worker.WorkPrioritiesScript.route_length_lower_bound(worker.get_block_coord(), task.pos, task.type)
	return bound < int(previous["path_length"]) \
		or (bound == int(previous["path_length"]) and task.id < previous["task"].id)


func transfer_task_to_arrived_worker(task, worker: Worker) -> bool:
	if task == null or worker == null:
		return false
	if task.status != TaskQueue.TaskStatus.IN_PROGRESS or task.assigned_worker == null:
		return false
	if task.assigned_worker == worker or worker.current_task_id >= 0:
		return false
	# Higher-priority pending work must go through the cross-type comparison.
	# For equal priorities the arrived worker already has the minimum route cost.
	if has_assignable_pending_task_for_worker(worker, worker.get_work_priority(Worker.WorkPrioritiesScript.task_work_id(task.type))):
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
	_reset_priority_round()
	assist_requests_by_worker.clear()
	assist_requests_by_id.clear()
	haul_path_requests_by_worker.clear()
	haul_path_requests_by_id.clear()
	path_search_scheduler.clear()


func rebuild_haul_tasks() -> void:
	if world == null or task_queue == null:
		return
	_settle_loose_items()
	_prune_invalid_haul_tasks()
	for item: Dictionary in world.item_store.loose_items():
		var item_id := int(item.get("id", -1))
		if item_id < 0:
			continue
		if int(item.get("reserved_by_task_id", -1)) >= 0:
			if _diagnostics_enabled():
				world.live_diagnostics.observe("item", str(item_id), "haul_already_reserved", {"task_id": int(item["reserved_by_task_id"])})
			continue
		var destination: Dictionary = world.find_stockpile_destination_for_item(item)
		if destination.is_empty():
			if _diagnostics_enabled():
				world.live_diagnostics.observe("item", str(item_id), "haul_no_destination", {"material_id": int(item.get("material_id", 0))})
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
			if _diagnostics_enabled():
				world.live_diagnostics.observe("item", str(item_id), "haul_queued", {"task_id": task_id, "stockpile_id": int(destination.get("stockpile_id", -1)), "destination": destination.get("pos", Vector3i.ZERO)})
			var task = task_queue.get_task(task_id)
			world.trace_task_event(task, "haul_queued", "item_id=%d stockpile=%d destination=%s" % [
				item_id,
				int(destination.get("stockpile_id", -1)),
				destination.get("pos", Vector3i.ZERO),
			])


## Loose items left floating (support dug out, dropped above stairs) move to
## where they rest so hauling can reach them. A pending haul for the old cell is
## cancelled and rebuilt; items a worker is already handling stay put.
func _settle_loose_items() -> void:
	for item: Dictionary in world.item_store.loose_items():
		if bool(item.get("is_carried", false)):
			continue
		var pos: Vector3i = item.get("pos", Vector3i.ZERO)
		var rest: Vector3i = world.item_rest_cell(pos)
		if rest == pos:
			continue
		var item_id := int(item.get("id", -1))
		var reserved_by := int(item.get("reserved_by_task_id", -1))
		if reserved_by >= 0:
			var task = task_queue.get_task(reserved_by)
			if task != null and (task.type != TaskQueue.TaskType.HAUL or task.status != TaskQueue.TaskStatus.PENDING):
				continue
			world.item_store.release_reservation(item_id, reserved_by)
			if task != null:
				task_queue.remove_task(task)
				if task.id == assignment_task_id:
					_reset_assignment_auction()
				world.trace_task_event(task, "haul_cancelled", "reason=item_settled")
		world.item_store.mark_loose(item_id, rest)
		world.trace_system_event("item_settled", "item_id=%d from=%s to=%s" % [item_id, pos, rest])


func _prune_invalid_haul_tasks() -> void:
	for task in task_queue.tasks.duplicate():
		if task.type != TaskQueue.TaskType.HAUL or task.status == TaskQueue.TaskStatus.COMPLETED:
			continue
		if _is_haul_task_valid(task):
			continue
		var item_id := int(task.data.get("item_id", -1))
		var assigned_worker: Worker = task.assigned_worker
		if is_instance_valid(assigned_worker) \
				and assigned_worker.current_task_id == task.id \
				and assigned_worker.carried_source_item_id == item_id:
			assigned_worker.fail_haul_delivery_path(
				world,
				task_queue,
				task,
				"reason=destination_invalidated"
			)
		else:
			world.item_store.release_reservation(item_id, task.id)
			task_queue.remove_task(task)
		if task.id == assignment_task_id:
			_reset_assignment_auction()
		world.trace_task_event(task, "haul_cancelled", "reason=invalid_reservation_or_destination")
		if _diagnostics_enabled():
			world.live_diagnostics.observe("item", str(item_id), "haul_cancelled", {"task_id": task.id, "cause": "invalid_reservation_or_destination"})


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


func has_assignable_pending_task_for_worker(worker: Worker, priority_below: int = 10) -> bool:
	if worker == null or not _is_worker_available(worker):
		return false
	var now_msec := Time.get_ticks_msec()
	for task_type in ASSIGNMENT_TASK_TYPES:
		for task in task_queue.tasks:
			if task.status != TaskQueue.TaskStatus.PENDING:
				continue
			if task.type != task_type or task.accessibility == TaskQueue.TaskAccessibility.UNREACHABLE:
				continue
			if not worker.can_accept_task(task):
				continue
			if not _task_material_available(task):
				continue
			if worker.get_work_priority(Worker.WorkPrioritiesScript.task_work_id(task.type)) >= priority_below:
				continue
			if task.is_worker_unreachable(worker.worker_id, now_msec):
				continue
			return true
	return false


func request_assist_path(worker: Worker, candidates: Array) -> bool:
	if worker == null or candidates.is_empty():
		return false
	if assist_requests_by_worker.has(worker.worker_id):
		return true
	var goals: Array = []
	var goal_task_ids: Dictionary = {}
	var best_priority := 10
	for entry: Dictionary in candidates:
		var goal: Vector3i = entry["pos"]
		var task = entry["task"]
		if not worker.can_accept_task(task) or task.type == TaskQueue.TaskType.HAUL:
			continue
		var priority := worker.get_work_priority(Worker.WorkPrioritiesScript.task_work_id(task.type))
		if priority > best_priority:
			continue
		if priority < best_priority:
			best_priority = priority
			goals.clear()
			goal_task_ids.clear()
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
		"configuration": worker.get_work_configuration(),
	}
	assist_requests_by_worker[worker.worker_id] = request
	assist_requests_by_id[request_id] = request
	if _diagnostics_enabled():
		world.live_diagnostics.observe("worker", str(worker.worker_id), "assist_path_queued", {"request_id": request_id, "job_id": job_id, "goal_count": goals.size()})
	world.trace_worker_event(worker, "assist_path_queued", null, "job_id=%d goals=%d" % [job_id, goals.size()])
	return true


func request_haul_delivery_path(worker: Worker, task, destination: Vector3i) -> bool:
	if worker == null or task == null:
		return false
	if haul_path_requests_by_worker.has(worker.worker_id):
		return true
	var request_id := next_haul_path_request_id
	next_haul_path_request_id += 1
	var job_id := path_search_scheduler.enqueue_exact(
		world,
		request_id,
		worker,
		destination,
		Worker.WORKER_PATH_SEARCH_MAX_ITERATIONS,
		"haul_delivery"
	)
	var request := {
		"request_id": request_id,
		"job_id": job_id,
		"worker": worker,
		"task_id": task.id,
		"destination": destination,
	}
	haul_path_requests_by_worker[worker.worker_id] = request
	haul_path_requests_by_id[request_id] = request
	if _diagnostics_enabled():
		world.live_diagnostics.observe("worker", str(worker.worker_id), "haul_delivery_path_queued", {"task_id": task.id, "request_id": request_id, "job_id": job_id, "destination": destination})
	world.trace_worker_event(worker, "haul_delivery_path_queued", task, "job_id=%d destination=%s" % [job_id, destination])
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
			if task.accessibility == TaskQueue.TaskAccessibility.UNREACHABLE:
				continue
			if not world.is_block_coord_valid(task.pos.x, task.pos.y, task.pos.z):
				continue
			if task.type == TaskQueue.TaskType.DIG and world.is_block_protected_from_dig(task.pos):
				continue
			for worker: Worker in world.workers:
				if worker.can_accept_task(task) \
						and _is_worker_available(worker) \
						and not task.is_worker_unreachable(worker.worker_id, now_msec):
					return task
	return null


func _start_assignment_auction(task) -> void:
	# SEE-ADR-012: Only workers whose current role accepts this task may bid.
	assignment_task_id = task.id
	assignment_auction_id = next_assignment_auction_id
	next_assignment_auction_id += 1
	assignment_workers.clear()
	for worker: Worker in world.workers:
		if worker.can_accept_task(task) and _is_worker_available(worker):
			assignment_workers.append(worker)
		elif _diagnostics_enabled():
			world.live_diagnostics.observe("worker", str(worker.worker_id), "auction_candidate_excluded", {"task_id": task.id, "role_id": worker.role_id, "state": worker.state, "current_task_id": worker.current_task_id, "assist_request_pending": assist_requests_by_worker.has(worker.worker_id)})
	assignment_workers.sort_custom(func(a: Worker, b: Worker):
		return a.worker_id < b.worker_id
	)
	assignment_worker_index = 0
	assignment_best_worker = null
	assignment_best_path = []
	assignment_best_search_ms = 0.0
	assignment_bids.clear()
	assignment_pending_jobs.clear()
	assignment_job_context.clear()
	assignment_failed_starts.clear()
	assignment_failed_count = 0
	assignment_auction_dispatched = false
	assignment_legacy_workers.clear()
	world.trace_task_event(task, "assignment_auction_started", "candidate_workers=%s" % _worker_ids(assignment_workers))
	if _diagnostics_enabled():
		world.live_diagnostics.observe("task", str(task.id), "auction_started", {"auction_id": assignment_auction_id, "candidate_count": assignment_workers.size()})


## Filters shared by grid and per-worker bids. False means no search is needed
## (ineligible, outranked, or already proven unreachable).
func _bid_precheck(task, worker: Worker) -> bool:
	if not worker.can_accept_task(task) or not _is_worker_available(worker):
		if _diagnostics_enabled():
			world.live_diagnostics.observe("worker", str(worker.worker_id), "bid_ineligible", {"task_id": task.id, "role_id": worker.role_id, "state": worker.state, "current_task_id": worker.current_task_id})
		return false
	if not _task_material_available(task) or not _can_improve_priority_choice(task, worker):
		# A proven higher-priority choice makes this path unnecessary this round.
		# If it goes stale before commit, the next round retries all candidates.
		return false
	var now_msec := Time.get_ticks_msec()
	if task.is_worker_unreachable(worker.worker_id, now_msec):
		if _diagnostics_enabled():
			world.live_diagnostics.observe("worker", str(worker.worker_id), "bid_excluded_until_retry", {"task_id": task.id, "marked_msec": int(task.unreachable_workers[worker.worker_id]), "ttl_msec": TaskQueue.WORKER_UNREACHABLE_TTL_MSEC})
		return false
	if task.id == assignment_task_id and assignment_failed_starts.has(worker.get_block_coord()):
		# Same start cell, same snapshot terrain: this search would fail identically.
		world.trace_worker_event(worker, "assignment_bid_skipped", task, "reason=start_cell_already_failed")
		mark_worker_unreachable_for_task(task, worker)
		return false
	return true


## One reverse navigation-grid search for every eligible candidate near the
## task; candidates farther away fall back to per-worker searches.
func _dispatch_grid_auction(task) -> void:
	var near: Array = []
	assignment_legacy_workers.clear()
	assignment_worker_index = 0
	# Test doubles that only implement per-worker jobs keep the per-worker path.
	var grid_supported: bool = path_search_scheduler.has_method("enqueue_auction")
	for worker: Worker in assignment_workers:
		if not grid_supported:
			assignment_legacy_workers.append(worker)
			continue
		var start := worker.get_block_coord()
		if absi(start.x - task.pos.x) > GRID_AUCTION_RADIUS_XZ or absi(start.z - task.pos.z) > GRID_AUCTION_RADIUS_XZ \
				or absi(start.y - task.pos.y) > GRID_AUCTION_RADIUS_Y:
			assignment_legacy_workers.append(worker)
			continue
		if _bid_precheck(task, worker):
			near.append(worker)
	if near.is_empty():
		return
	var job_id: int = path_search_scheduler.enqueue_auction(world, assignment_auction_id, task, near)
	var workers := {}
	for worker: Worker in near:
		workers[worker.worker_id] = {"worker": worker, "configuration": worker.get_work_configuration(), "start": worker.get_block_coord()}
		world.trace_worker_event(worker, "assignment_bid_queued", task, "job_id=%d grid=true" % job_id)
	assignment_pending_jobs[job_id] = null
	assignment_job_context[job_id] = {"task": task, "workers": workers}
	if _diagnostics_enabled():
		world.live_diagnostics.observe("task", str(task.id), "grid_auction_queued", {"auction_id": assignment_auction_id, "job_id": job_id, "workers": near.size(), "legacy_workers": assignment_legacy_workers.size()})


func _queue_worker_bid(task, worker: Worker) -> void:
	if not _bid_precheck(task, worker):
		return
	var job_id: int = path_search_scheduler.enqueue(
		world,
		assignment_auction_id,
		task,
		worker,
		Worker.WORKER_PATH_SEARCH_MAX_ITERATIONS
	)
	assignment_pending_jobs[job_id] = worker
	assignment_job_context[job_id] = {"task": task, "configuration": worker.get_work_configuration(), "start": worker.get_block_coord()}
	if _diagnostics_enabled():
		world.live_diagnostics.observe("worker", str(worker.worker_id), "assignment_bid_queued", {"task_id": task.id, "auction_id": assignment_auction_id, "job_id": job_id})
	world.trace_worker_event(worker, "assignment_bid_queued", task, "job_id=%d" % job_id)


func _process_path_results() -> void:
	var restart_auction := false
	while true:
		var result: Dictionary = path_search_scheduler.pop_result()
		if result.is_empty():
			break
		var kind := String(result.get("kind", "assignment"))
		_record_path_performance(result)
		if kind == "goals":
			_process_assist_result(result)
			continue
		if kind == "haul_delivery":
			_process_haul_delivery_result(result)
			continue
		if int(result.get("auction_id", -1)) != assignment_auction_id:
			_observe_path_result(result, "assignment_result_cancelled", "auction_replaced")
			_record_path_disposition("assignment", "cancelled")
			continue
		if kind == "auction":
			if _process_grid_auction_result(result):
				restart_auction = true
			continue
		var job_id: int = int(result.get("job_id", -1))
		var worker: Worker = assignment_pending_jobs.get(job_id, null)
		assignment_pending_jobs.erase(job_id)
		var context: Dictionary = assignment_job_context.get(job_id, {})
		assignment_job_context.erase(job_id)
		var task = task_queue.get_task(int(result.get("task_id", -1)))
		if not is_instance_valid(worker) or task == null:
			_observe_path_result(result, "assignment_result_cancelled", "worker_or_task_missing")
			_record_path_disposition("assignment", "cancelled")
			continue
		if not context.is_empty() and (context["task"] != task \
				or context["configuration"] != worker.get_work_configuration() \
				or context["start"] != worker.get_block_coord()):
			_record_path_disposition("assignment", "stale")
			_observe_path_result(result, "assignment_bid_stale", "worker_configuration_or_identity_changed")
			restart_auction = true
			continue
		var snapshot = result.get("snapshot", null)
		if snapshot == null or not snapshot.revisions_match(world):
			_observe_path_result(result, "assignment_bid_stale", "snapshot_revision_mismatch")
			_record_path_disposition("assignment", "stale")
			world.trace_worker_event(worker, "assignment_bid_stale", task, "job_id=%d" % job_id)
			restart_auction = true
			continue
		_record_path_disposition("assignment", "accepted")
		_observe_path_result(result, "assignment_result_accepted", "revisions_match")
		_collect_worker_bid_result(task, worker, result)
	if restart_auction:
		_reset_assignment_auction()
		_reset_priority_round()


## Splits a grid auction result into per-worker bids for the unchanged ADR-005
## collection/priority path. Returns true when the auction must restart.
func _process_grid_auction_result(result: Dictionary) -> bool:
	var job_id: int = int(result.get("job_id", -1))
	assignment_pending_jobs.erase(job_id)
	var context: Dictionary = assignment_job_context.get(job_id, {})
	assignment_job_context.erase(job_id)
	var task = task_queue.get_task(int(result.get("task_id", -1)))
	if task == null or context.is_empty() or context["task"] != task:
		_observe_path_result(result, "assignment_result_cancelled", "task_missing")
		_record_path_disposition("assignment", "cancelled")
		return false
	var snapshot = result.get("snapshot", null)
	if snapshot == null or not snapshot.revisions_match(world):
		_observe_path_result(result, "assignment_bid_stale", "snapshot_revision_mismatch")
		_record_path_disposition("assignment", "stale")
		return true
	_record_path_disposition("assignment", "accepted")
	var stats: Dictionary = result.get("search_stats", {})
	var bids: Array = result.get("bids", [])
	var per_bid_ms: float = float(result.get("search_ms", 0.0)) / maxf(1.0, bids.size())
	var stale := false
	for bid: Dictionary in bids:
		var entry: Dictionary = context["workers"].get(int(bid["worker_id"]), {})
		var worker: Worker = entry.get("worker", null)
		if not is_instance_valid(worker):
			continue
		if entry["configuration"] != worker.get_work_configuration() or entry["start"] != worker.get_block_coord():
			world.trace_worker_event(worker, "assignment_bid_stale", task, "job_id=%d grid=true" % job_id)
			stale = true
			continue
		_collect_worker_bid_result(task, worker, {
			"job_id": job_id, "worker_id": worker.worker_id, "task_id": task.id, "path": bid["path"],
			"snapshot_ms": float(result.get("snapshot_ms", 0.0)), "queue_wait_ms": float(result.get("queue_wait_ms", 0.0)),
			"search_ms": per_bid_ms, "snapshot": snapshot,
			"search_stats": {"reason": bid["reason"], "hit_iteration_cap": not bool(bid["conclusive"]),
				"iterations_used": int(stats.get("flood_nodes", 0)), "max_iterations": 0, "grid": true},
		})
	return stale


## Exactly once per popped result, before any request/lifetime rejection.
## These are completed-job costs, not additional main-thread frame cost.
func _record_path_performance(result: Dictionary) -> void:
	if world.performance_recorder == null or not world.performance_recorder.enabled:
		return
	var recorder = world.performance_recorder
	var kind := String(result.get("kind", "assignment"))
	if kind not in ["assignment", "goals", "haul_delivery"]:
		kind = "other"
	recorder.add_counter("Path.results")
	recorder.add_counter("Path." + kind + ".results")
	var path: Array = result.get("path", [])
	recorder.add_counter("Path.found" if not path.is_empty() else "Path.not_found")
	for metric in ["snapshot_ms", "queue_wait_ms", "search_ms"]:
		if result.has(metric):
			recorder.add_timing("Path.completed." + metric, float(result[metric]))


func _record_path_disposition(kind: String, disposition: String) -> void:
	if world.performance_recorder != null and world.performance_recorder.enabled:
		world.performance_recorder.add_counter("Path." + kind + "." + disposition)


func _process_haul_delivery_result(result: Dictionary) -> void:
	var request_id := int(result.get("request_id", -1))
	var request: Dictionary = haul_path_requests_by_id.get(request_id, {})
	if request.is_empty():
		_record_path_disposition("haul_delivery", "cancelled")
		_observe_path_result(result, "haul_delivery_path_cancelled", "request_missing")
		return
	haul_path_requests_by_id.erase(request_id)
	var worker: Worker = request.get("worker", null)
	if worker != null:
		haul_path_requests_by_worker.erase(worker.worker_id)
	if worker == null or not is_instance_valid(worker):
		_record_path_disposition("haul_delivery", "cancelled")
		_observe_path_result(result, "haul_delivery_path_cancelled", "worker_missing")
		return
	var task = task_queue.get_task(int(request.get("task_id", -1)))
	if task == null \
			or task.status != TaskQueue.TaskStatus.IN_PROGRESS \
			or task.assigned_worker != worker \
			or worker.current_task_id != task.id:
		_record_path_disposition("haul_delivery", "cancelled")
		_observe_path_result(result, "haul_delivery_path_cancelled", "task_owner_changed", int(request.get("task_id", -1)))
		return
	var snapshot = result.get("snapshot", null)
	if snapshot == null or not snapshot.revisions_match(world):
		world.trace_worker_event(worker, "haul_delivery_path_stale", task, "request_id=%d" % request_id)
		_observe_path_result(result, "haul_delivery_path_stale", "snapshot_revision_mismatch", task.id)
		_record_path_disposition("haul_delivery", "stale")
		request_haul_delivery_path(worker, task, request.get("destination", Vector3i.ZERO))
		return
	_record_path_disposition("haul_delivery", "accepted")
	var found_path: Array = result.get("path", [])
	if found_path.is_empty():
		_observe_path_result(result, "haul_delivery_path_failed", "empty_path", task.id)
		var stats: Dictionary = result.get("search_stats", {})
		worker.fail_haul_delivery_path(
			world,
			task_queue,
			task,
			"reason=%s iterations=%d/%d" % [
				str(stats.get("reason", "unknown")),
				int(stats.get("iterations_used", 0)),
				int(stats.get("max_iterations", 0)),
			]
		)
		return
	worker.start_haul_delivery_path(
		world,
		task,
		found_path,
		float(result.get("search_ms", 0.0)),
		float(result.get("snapshot_ms", 0.0)),
		float(result.get("queue_wait_ms", 0.0))
	)


func _clear_haul_path_request_for_task(task_id: int) -> void:
	for request_id in haul_path_requests_by_id.keys().duplicate():
		var request: Dictionary = haul_path_requests_by_id[request_id]
		if int(request.get("task_id", -1)) != task_id:
			continue
		haul_path_requests_by_id.erase(request_id)
		var worker: Worker = request.get("worker", null)
		if worker != null:
			haul_path_requests_by_worker.erase(worker.worker_id)


func _process_assist_result(result: Dictionary) -> void:
	var request_id: int = int(result.get("request_id", -1))
	var request: Dictionary = assist_requests_by_id.get(request_id, {})
	if request.is_empty():
		_record_path_disposition("goals", "cancelled")
		_observe_path_result(result, "assist_path_cancelled", "request_missing")
		return
	assist_requests_by_id.erase(request_id)
	var worker: Worker = request["worker"]
	if not is_instance_valid(worker):
		_record_path_disposition("goals", "cancelled")
		return
	assist_requests_by_worker.erase(worker.worker_id)
	if request.get("configuration", worker.get_work_configuration()) != worker.get_work_configuration():
		_record_path_disposition("goals", "stale")
		worker.task_search_timer = 0.0
		return
	var snapshot = result.get("snapshot", null)
	if snapshot == null or not snapshot.revisions_match(world):
		world.trace_worker_event(worker, "assist_path_stale", null, "request_id=%d" % request_id)
		_observe_path_result(result, "assist_path_stale", "snapshot_revision_mismatch")
		_record_path_disposition("goals", "stale")
		worker.task_search_timer = 0.0
		return
	if worker.current_task_id >= 0 or worker.state != Worker.WorkerState.IDLE:
		_record_path_disposition("goals", "cancelled")
		_observe_path_result(result, "assist_path_cancelled", "worker_unavailable")
		return
	var path: Array = result.get("path", [])
	if path.is_empty():
		_observe_path_result(result, "assist_path_failed", "empty_path")
		_record_path_disposition("goals", "accepted")
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
		or task.assigned_worker == worker \
		or not worker.can_accept_task(task) \
		or has_assignable_pending_task_for_worker(worker):
		_record_path_disposition("goals", "cancelled")
		worker.task_search_timer = 0.0
		return
	_record_path_disposition("goals", "accepted")
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
	if maybe_path.is_empty() and bool(stats.get("hit_iteration_cap", false)):
		# Inconclusive: the search ran out of budget (e.g. a stair detour several
		# levels down). That proves nothing about reachability, so the worker is
		# neither excluded nor counted toward blocking the task.
		_observe_path_result(result, "assignment_bid_inconclusive", "iteration_cap")
		world.trace_worker_event(worker, "assignment_bid_inconclusive", task, "snapshot_ms=%.3f queue_wait_ms=%.3f search_ms=%.3f iterations=%d/%d" % [
			float(result.get("snapshot_ms", 0.0)),
			float(result.get("queue_wait_ms", 0.0)),
			search_ms,
			int(stats.get("iterations_used", 0)),
			int(stats.get("max_iterations", 0)),
		])
		return
	if maybe_path.is_empty():
		_observe_path_result(result, "assignment_bid_failed", "empty_path")
		world.trace_worker_event(worker, "assignment_bid_failed", task, "snapshot_ms=%.3f queue_wait_ms=%.3f search_ms=%.3f reason=%s iterations=%d/%d hit_iteration_cap=%s" % [
			float(result.get("snapshot_ms", 0.0)),
			float(result.get("queue_wait_ms", 0.0)),
			search_ms,
			str(stats.get("reason", "unknown")),
			int(stats.get("iterations_used", 0)),
			int(stats.get("max_iterations", 0)),
			str(stats.get("hit_iteration_cap", false)),
		])
		if task.id == assignment_task_id:
			# An exhausted search fails identically for every worker on this cell.
			assignment_failed_starts[worker.get_block_coord()] = true
		mark_worker_unreachable_for_task(task, worker)
		return
	world.trace_worker_event(worker, "assignment_bid", task, "path_length=%d snapshot_ms=%.3f queue_wait_ms=%.3f search_ms=%.3f" % [
		maybe_path.size(),
		float(result.get("snapshot_ms", 0.0)),
		float(result.get("queue_wait_ms", 0.0)),
		search_ms,
	])
	task.path_block_streak = 0
	task.set_accessibility(TaskQueue.TaskAccessibility.REACHABLE, Time.get_ticks_msec())
	if _diagnostics_enabled():
		world.live_diagnostics.observe("task", str(task.id), "assignment_bid_received", {"worker_id": worker.worker_id, "path_length": maybe_path.size(), "search_ms": search_ms})
	var bid := {
		"worker": worker,
		"path": maybe_path,
		"path_length": maybe_path.size(),
		"worker_id": worker.worker_id,
		"search_ms": search_ms,
		"snapshot": result.get("snapshot"),
	}
	assignment_bids.append(bid)
	_remember_priority_bid(task, worker, bid)
	if _is_better_assignment_bid(maybe_path.size(), worker.worker_id):
		assignment_best_worker = worker
		assignment_best_path = maybe_path.duplicate()
		assignment_best_search_ms = search_ms


func _best_available_assignment_bid() -> Dictionary:
	var best: Dictionary = {}
	for bid: Dictionary in assignment_bids:
		var worker: Worker = bid["worker"]
		if not _is_worker_available(worker) or not worker.can_accept_task(task_queue.get_task(assignment_task_id)):
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


func _has_eligible_worker(task) -> bool:
	if task == null:
		return false
	for worker: Worker in world.workers:
		if worker != null and worker.can_accept_task(task):
			return true
	return false


func _reset_assignment_auction() -> void:
	if _diagnostics_enabled() and assignment_task_id >= 0:
		var task = task_queue.get_task(assignment_task_id)
		if task != null and task.status == TaskQueue.TaskStatus.PENDING:
			world.live_diagnostics.invalidate("task", str(assignment_task_id), "auction_reset")
	assignment_task_id = -1
	assignment_auction_id = 0
	assignment_workers.clear()
	assignment_worker_index = 0
	assignment_best_worker = null
	assignment_best_path = []
	assignment_best_search_ms = 0.0
	assignment_bids.clear()
	assignment_pending_jobs.clear()
	assignment_job_context.clear()
	assignment_failed_starts.clear()
	assignment_failed_count = 0
	assignment_auction_dispatched = false
	assignment_legacy_workers.clear()


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
	if task_type == TaskQueue.TaskType.DIG and not world.stair_dig_reject_reason(pos).is_empty():
		return false
	if is_task_already_queued(task_type, pos):
		return false
	if task_type == TaskQueue.TaskType.STAIRS \
			and task_queue.has_active_task_at(pos, TaskQueue.TaskType.DIG) \
			and not task_queue.remove_pending_task_at(pos, TaskQueue.TaskType.DIG):
		return false
	return add_task_to_queue(task_type, pos, material)


func queue_stair_flight(anchor: Vector3i, rotation: int, up: bool) -> bool:
	if world == null or not world.can_place_stair_flight(anchor, rotation, up):
		return false
	var cells := StairFlightScript.cells(anchor, rotation)
	var expected: Array[int] = []
	for cell: Vector3i in cells:
		for existing_task in task_queue.get_active_tasks_at(cell):
			if existing_task.type == TaskQueue.TaskType.DIG \
					and existing_task.status == TaskQueue.TaskStatus.PENDING:
				continue
			return false
		expected.append(world.get_block_no_generate(cell.x, cell.y, cell.z))
	for cell: Vector3i in cells:
		task_queue.remove_pending_task_at(cell, TaskQueue.TaskType.DIG)
	var task_id := task_queue.add_stair_flight_task(
		anchor,
		rotation,
		up,
		StairFlightScript.lower_id(rotation),
		StairFlightScript.upper_id(rotation),
		expected
	)
	if task_id < 0:
		return false
	var task = task_queue.get_task(task_id)
	if task == null:
		return false
	return true


func cancel_pending_task_requests_at(pos: Vector3i) -> Array:
	if world == null or not world.is_block_coord_valid(pos.x, pos.y, pos.z):
		return []
	var removed: Array = task_queue.remove_pending_tasks_at(pos, ASSIGNMENT_TASK_TYPES)
	if removed.is_empty():
		return removed
	for task in removed:
		_finish_player_cancellation(task)
	return removed


func cancel_pending_task(task_id: int, expected_task) -> bool:
	var task = task_queue.get_task(task_id)
	if task == null or task != expected_task or task.status != TaskQueue.TaskStatus.PENDING:
		return false
	if not task_queue.remove_task(task):
		return false
	_finish_player_cancellation(task)
	return true


func _finish_player_cancellation(task) -> void:
	# SEE-ADR-008: Both UI cancellation routes preserve hauling cleanup.
	if task.type == TaskQueue.TaskType.HAUL:
		world.item_store.release_reservation(int(task.data.get("item_id", -1)), task.id)
	world.trace_task_event(task, "task_cancelled", "reason=player_erase")
	if task.id == assignment_task_id:
		_reset_assignment_auction()


func add_task_to_queue(task_type: int, pos: Vector3i, material: int) -> bool:
	match task_type:
		TaskQueue.TaskType.DIG:
			if not world.stair_dig_reject_reason(pos).is_empty():
				return false
			return task_queue.add_dig_task(pos) >= 0
		TaskQueue.TaskType.PLACE:
			return task_queue.add_place_task(pos, material) >= 0
		TaskQueue.TaskType.STAIRS:
			return task_queue.add_stairs_task(pos, material) >= 0
		TaskQueue.TaskType.HAUL:
			return false
	return false


func _stair_work_positions_for_task(task) -> Array[Vector3i]:
	var rotation := -1
	if task != null and task.data is Dictionary and bool(task.data.get("flight", false)):
		rotation = int(task.data.get("rotation", -1))
	return TaskWorkPositionRulesScript.stair_work_positions(
		world,
		world.pathfinder,
		task.pos,
		rotation,
		TaskWorkPositionRulesScript.stair_excluded_cells_for_task(task)
	)
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
		task.path_block_streak = 0
		_clear_path_retry(task.id)
		task.set_accessibility(TaskQueue.TaskAccessibility.UNKNOWN, Time.get_ticks_msec())
		request_accessibility_check(task.id, "nearby_terrain_changed")
		if _diagnostics_enabled():
			world.live_diagnostics.invalidate("task", str(task.id), "nearby_terrain_changed")


func mark_worker_unreachable_for_task(task, worker: Worker) -> void:
	if task == null or worker == null or task.status != TaskQueue.TaskStatus.PENDING:
		return
	var now_msec := Time.get_ticks_msec()
	task.mark_worker_unreachable(worker.worker_id, now_msec)
	if _diagnostics_enabled():
		world.live_diagnostics.observe("worker", str(worker.worker_id), "task_worker_unreachable", {"task_id": task.id, "marked_msec": now_msec, "ttl_msec": TaskQueue.WORKER_UNREACHABLE_TTL_MSEC})
	world.trace_worker_event(worker, "task_worker_unreachable", task, "worker excluded from task assignment")
	# Every candidate of this auction failed: block now. Per-worker marks expire
	# after a few seconds, so with many workers the loop below alone could never
	# see all of them unreachable at once.
	if task.id == assignment_task_id:
		assignment_failed_count += 1
		if assignment_failed_count >= assignment_workers.size():
			_mark_task_path_blocked(task, now_msec)
			return
	for candidate: Worker in world.workers:
		if not candidate.can_accept_task(task):
			continue
		if not task.is_worker_unreachable(candidate.worker_id, now_msec):
			return
	_mark_task_path_blocked(task, now_msec)
#endregion


func is_task_already_queued(task_type: int, pos: Vector3i) -> bool:
	return task_queue.has_active_task_at(pos, task_type)


func _diagnostics_enabled() -> bool:
	return world != null and world.live_diagnostics != null and world.live_diagnostics.enabled


func _observe_path_result(result: Dictionary, reason: String, cause: String, task_id: int = -1) -> void:
	if not _diagnostics_enabled():
		return
	var stats: Dictionary = result.get("search_stats", {})
	world.live_diagnostics.observe("worker", str(int(result.get("worker_id", -1))), reason, {
		"task_id": task_id if task_id >= 0 else int(result.get("task_id", -1)),
		"job_id": int(result.get("job_id", -1)),
		"request_id": int(result.get("request_id", -1)),
		"auction_id": int(result.get("auction_id", -1)),
		"cause": cause,
		"path_length": result.get("path", []).size(),
		"search_reason": str(stats.get("reason", "unknown")).left(128),
		"iterations_used": int(stats.get("iterations_used", 0)),
		"max_iterations": int(stats.get("max_iterations", 0)),
		"hit_iteration_cap": bool(stats.get("hit_iteration_cap", false)),
	})
#endregion
