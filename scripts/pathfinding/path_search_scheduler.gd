extends RefCounted
class_name PathSearchScheduler
## Owns immutable path jobs, one background search thread, and result handoff.

const PathWorldSnapshotScript = preload("res://scripts/pathfinding/path_world_snapshot.gd")
const TaskWorkPositionRulesScript = preload("res://scripts/task_work_position_rules.gd")
const NavGridScript = preload("res://scripts/pathfinding/nav_grid.gd")
const SNAPSHOT_MARGIN_XZ := 32
const SNAPSHOT_MARGIN_Y := 8

var search_thread: Thread
var thread_running := false
var job_queue: Array = []
var job_mutex := Mutex.new()
var job_semaphore := Semaphore.new()
var result_queue: Array = []
var result_mutex := Mutex.new()
var next_job_id := 1
# Protected by job_mutex; excludes queued jobs and completed pending results.
var executing_jobs := 0


func start() -> void:
	if thread_running:
		return
	thread_running = true
	search_thread = Thread.new()
	search_thread.start(Callable(self, "_search_worker_loop"))


func stop() -> void:
	if not thread_running:
		return
	thread_running = false
	job_semaphore.post()
	if search_thread != null:
		search_thread.wait_to_finish()
	search_thread = null
	clear()


func clear() -> void:
	job_mutex.lock()
	job_queue.clear()
	job_mutex.unlock()
	result_mutex.lock()
	result_queue.clear()
	result_mutex.unlock()


func enqueue(world, auction_id: int, task, worker: Worker, max_iterations: int) -> int:
	# SEE-ADR-003: Background searches must read immutable snapshots, not live World data.
	var job_id := next_job_id
	next_job_id += 1
	var snapshot_started_usec := Time.get_ticks_usec()
	var start := worker.get_block_coord()
	var goals: Array = [task.pos]
	var snapshot = PathWorldSnapshotScript.new()
	snapshot.capture_from_world(world, start, goals, SNAPSHOT_MARGIN_XZ, SNAPSHOT_MARGIN_Y)
	var job := {
		"job_id": job_id,
		"kind": "assignment",
		"request_id": 0,
		"auction_id": auction_id,
		"task_id": task.id,
		"task_type": task.type,
		"worker_id": worker.worker_id,
		"start": start,
		"target": task.pos,
		"flight_rotation": int(task.data.get("rotation", -1)) if task.data is Dictionary else -1,
		"stair_excluded_cells": _stair_excluded_cells_for_task(task),
		"max_iterations": max_iterations,
		"snapshot": snapshot,
		"snapshot_ms": float(Time.get_ticks_usec() - snapshot_started_usec) / 1000.0,
		"queued_usec": Time.get_ticks_usec(),
	}
	_enqueue_job(job)
	return job_id


## One job for a whole task auction (SEE-ADR-005 amendment 2026-10-10): one
## snapshot covering the task and every candidate start, one navigation grid
## and one reverse search from the task's work positions. The result carries a
## bid per worker; "conclusive" is false when the search could not prove the
## outcome (flood stopped at the snapshot edge), which must not exclude anyone.
func enqueue_auction(world, auction_id: int, task, workers: Array) -> int:
	var job_id := next_job_id
	next_job_id += 1
	var snapshot_started_usec := Time.get_ticks_usec()
	var worker_ids: Array[int] = []
	var starts: Array = []
	for worker: Worker in workers:
		worker_ids.append(worker.worker_id)
		starts.append(worker.get_block_coord())
	var snapshot = PathWorldSnapshotScript.new()
	snapshot.capture_from_world(world, task.pos, starts, SNAPSHOT_MARGIN_XZ, SNAPSHOT_MARGIN_Y)
	var job := {
		"job_id": job_id,
		"kind": "auction",
		"request_id": 0,
		"auction_id": auction_id,
		"task_id": task.id,
		"task_type": task.type,
		"worker_id": -1,
		"worker_ids": worker_ids,
		"starts": starts,
		"start": task.pos,
		"target": task.pos,
		"flight_rotation": int(task.data.get("rotation", -1)) if task.data is Dictionary else -1,
		"stair_excluded_cells": _stair_excluded_cells_for_task(task),
		"max_iterations": 0,
		"snapshot": snapshot,
		"snapshot_ms": float(Time.get_ticks_usec() - snapshot_started_usec) / 1000.0,
		"queued_usec": Time.get_ticks_usec(),
	}
	_enqueue_job(job)
	return job_id


func enqueue_goals(
	world,
	request_id: int,
	worker: Worker,
	goals: Array,
	max_iterations: int
) -> int:
	var job_id := next_job_id
	next_job_id += 1
	var snapshot_started_usec := Time.get_ticks_usec()
	var start := worker.get_block_coord()
	var snapshot = PathWorldSnapshotScript.new()
	snapshot.capture_from_world(world, start, goals, SNAPSHOT_MARGIN_XZ, SNAPSHOT_MARGIN_Y)
	var job := {
		"job_id": job_id,
		"kind": "goals",
		"request_id": request_id,
		"auction_id": 0,
		"task_id": -1,
		"task_type": -1,
		"worker_id": worker.worker_id,
		"start": start,
		"target": Vector3i.ZERO,
		"goals": goals.duplicate(),
		"max_iterations": max_iterations,
		"snapshot": snapshot,
		"snapshot_ms": float(Time.get_ticks_usec() - snapshot_started_usec) / 1000.0,
		"queued_usec": Time.get_ticks_usec(),
	}
	_enqueue_job(job)
	return job_id


func enqueue_exact(
	world,
	request_id: int,
	worker: Worker,
	goal: Vector3i,
	max_iterations: int,
	kind: String
) -> int:
	var job_id := next_job_id
	next_job_id += 1
	var snapshot_started_usec := Time.get_ticks_usec()
	var start := worker.get_block_coord()
	var snapshot = PathWorldSnapshotScript.new()
	snapshot.capture_from_world(world, start, [goal], SNAPSHOT_MARGIN_XZ, SNAPSHOT_MARGIN_Y)
	var job := {
		"job_id": job_id,
		"kind": kind,
		"request_id": request_id,
		"auction_id": 0,
		"task_id": -1,
		"task_type": -1,
		"worker_id": worker.worker_id,
		"start": start,
		"target": goal,
		"max_iterations": max_iterations,
		"snapshot": snapshot,
		"snapshot_ms": float(Time.get_ticks_usec() - snapshot_started_usec) / 1000.0,
		"queued_usec": Time.get_ticks_usec(),
	}
	_enqueue_job(job)
	return job_id


func _enqueue_job(job: Dictionary) -> void:
	job_mutex.lock()
	job_queue.append(job)
	job_mutex.unlock()
	job_semaphore.post()


func pop_result() -> Dictionary:
	result_mutex.lock()
	if result_queue.is_empty():
		result_mutex.unlock()
		return {}
	var result: Dictionary = result_queue.pop_front()
	result_mutex.unlock()
	return result


func get_performance_snapshot() -> Dictionary:
	# Lock ordering matches result publication; bounded, no queue scans.
	job_mutex.lock()
	result_mutex.lock()
	var snapshot := {
		"queued": job_queue.size(),
		"executing": executing_jobs,
		"results_pending": result_queue.size(),
	}
	result_mutex.unlock()
	job_mutex.unlock()
	return snapshot


func _search_worker_loop() -> void:
	while thread_running:
		job_semaphore.wait()
		if not thread_running:
			break
		var job: Dictionary = {}
		job_mutex.lock()
		if not job_queue.is_empty():
			job = job_queue.pop_front()
			executing_jobs += 1
		job_mutex.unlock()
		if job.is_empty():
			continue
		var result := _run_search(job)
		job_mutex.lock()
		result_mutex.lock()
		result_queue.append(result)
		executing_jobs -= 1
		result_mutex.unlock()
		job_mutex.unlock()


func _run_search(job: Dictionary) -> Dictionary:
	# SEE-ADR-003: The thread owns a private Pathfinder and searches only the snapshot.
	var started_usec := Time.get_ticks_usec()
	var queue_wait_ms := float(started_usec - int(job.get("queued_usec", started_usec))) / 1000.0
	var snapshot = job["snapshot"]
	var pathfinder := Pathfinder.new()
	var start: Vector3i = job["start"]
	var target: Vector3i = job["target"]
	var task_type: int = int(job["task_type"])
	var max_iterations: int = int(job["max_iterations"])
	var path: Array = []
	var kind := String(job.get("kind", "assignment"))
	if kind == "auction":
		return _run_auction(job, pathfinder, started_usec, queue_wait_ms)
	if kind == "goals":
		path = pathfinder.find_path_to_any(snapshot, start, job.get("goals", []), max_iterations)
	elif kind == "haul_delivery":
		path = pathfinder.find_path(snapshot, start, target, false, false, max_iterations)
	elif task_type == TaskQueue.TaskType.STAIRS:
		path = _find_stairs_path(
			snapshot,
			pathfinder,
			start,
			target,
			max_iterations,
			int(job.get("flight_rotation", -1)),
			job.get("stair_excluded_cells", [])
		)
	elif task_type == TaskQueue.TaskType.HAUL:
		path = pathfinder.find_path(snapshot, start, target, false, false, max_iterations)
	else:
		path = _find_work_path(snapshot, pathfinder, start, target, task_type, max_iterations)
	return {
		"job_id": int(job["job_id"]),
		"kind": String(job.get("kind", "assignment")),
		"request_id": int(job.get("request_id", 0)),
		"auction_id": int(job["auction_id"]),
		"task_id": int(job["task_id"]),
		"worker_id": int(job["worker_id"]),
		"path": path,
		"snapshot_ms": float(job.get("snapshot_ms", 0.0)),
		"queue_wait_ms": queue_wait_ms,
		"search_ms": float(Time.get_ticks_usec() - started_usec) / 1000.0,
		"search_stats": pathfinder.last_search_stats.duplicate(true),
		"snapshot": snapshot,
	}


func _run_auction(job: Dictionary, pathfinder: Pathfinder, started_usec: int, queue_wait_ms: float) -> Dictionary:
	var snapshot = job["snapshot"]
	var target: Vector3i = job["target"]
	var task_type: int = int(job["task_type"])
	var goals: Array = []
	if task_type == TaskQueue.TaskType.STAIRS:
		goals = TaskWorkPositionRulesScript.stair_work_positions(snapshot, pathfinder, target,
			int(job.get("flight_rotation", -1)), job.get("stair_excluded_cells", []))
	elif task_type == TaskQueue.TaskType.HAUL:
		goals = [target]
	else:
		goals = TaskWorkPositionRulesScript.task_work_positions(snapshot, pathfinder, target, task_type)
	var starts: Array = job["starts"]
	var bids: Array = []
	var stats := {"goal_count": goals.size(), "grid_cells": 0, "build_ms": 0.0, "flood_nodes": 0,
		"complete": true, "touched_box_edge": false, "reason": "found"}
	if goals.is_empty():
		# Same evidence as the per-worker search: no workable position at all.
		stats["reason"] = "no_workable_adjacent_candidates"
		for i in range(starts.size()):
			bids.append({"worker_id": job["worker_ids"][i], "path": [], "conclusive": true, "reason": "no_workable_adjacent_candidates"})
	else:
		var grid = NavGridScript.new()
		var build_started := Time.get_ticks_usec()
		grid.build(snapshot, snapshot.min_block, snapshot.max_block, pathfinder)
		stats["build_ms"] = float(Time.get_ticks_usec() - build_started) / 1000.0
		var flood: Dictionary = grid.reverse_distances(goals, starts)
		var distances: Dictionary = flood["distances"]
		var complete: bool = bool(flood["complete"])
		var touched: bool = bool(flood.get("flood_touched_box_edge", flood["touched_box_edge"]))
		stats["flood_nodes"] = int(flood["nodes"])
		stats["complete"] = complete
		stats["touched_box_edge"] = touched
		for i in range(starts.size()):
			var start: Vector3i = starts[i]
			var distance: int = int(distances.get(start, -2))
			var bid := {"worker_id": job["worker_ids"][i], "path": [], "conclusive": false, "reason": "inconclusive"}
			if distance > 0:
				bid["path"] = grid.path_from(start)
				bid["conclusive"] = not bid["path"].is_empty()
				bid["reason"] = "found" if bid["conclusive"] else "path_reconstruction_failed"
			elif distance == -1 and complete and not touched:
				bid["conclusive"] = true
				bid["reason"] = "no_path"
			elif distance == -1:
				bid["reason"] = "snapshot_edge"
			bids.append(bid)
	return {
		"job_id": int(job["job_id"]),
		"kind": "auction",
		"request_id": 0,
		"auction_id": int(job["auction_id"]),
		"task_id": int(job["task_id"]),
		"worker_id": -1,
		"bids": bids,
		"path": [],
		"snapshot_ms": float(job.get("snapshot_ms", 0.0)),
		"queue_wait_ms": queue_wait_ms,
		"search_ms": float(Time.get_ticks_usec() - started_usec) / 1000.0,
		"search_stats": stats,
		"snapshot": snapshot,
	}


func _find_work_path(
	snapshot,
	pathfinder: Pathfinder,
	start: Vector3i,
	target: Vector3i,
	task_type: int,
	max_iterations: int
) -> Array:
	var work_positions: Array[Vector3i] = TaskWorkPositionRulesScript.task_work_positions(
		snapshot,
		pathfinder,
		target,
		task_type
	)
	if work_positions.is_empty():
		pathfinder.last_search_stats = {
			"start": start,
			"goals": [],
			"goal_count": 0,
			"max_iterations": 0,
			"iterations_used": 0,
			"nodes_closed": 0,
			"best_node": start,
			"best_distance_to_goal": 0,
			"hit_iteration_cap": false,
			"open_remaining": 0,
			"result_found": false,
			"returned_best_effort": false,
			"reason": "no_workable_adjacent_candidates",
		}
		return []
	return pathfinder.find_path_to_any(snapshot, start, work_positions, max_iterations)


func _find_stairs_path(
	snapshot,
	pathfinder: Pathfinder,
	start: Vector3i,
	target: Vector3i,
	max_iterations: int,
	flight_rotation: int = -1,
	excluded_cells: Array = []
) -> Array:
	var candidates := TaskWorkPositionRulesScript.stair_work_positions(
		snapshot,
		pathfinder,
		target,
		flight_rotation,
		excluded_cells
	)
	return pathfinder.find_path_to_any(snapshot, start, candidates, max_iterations)


func _stair_excluded_cells_for_task(task) -> Array[Vector3i]:
	return TaskWorkPositionRulesScript.stair_excluded_cells_for_task(task)
