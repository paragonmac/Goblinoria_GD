extends RefCounted
class_name PathSearchScheduler
## Owns immutable path jobs, one background search thread, and result handoff.

const PathWorldSnapshotScript = preload("res://scripts/pathfinding/path_world_snapshot.gd")
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
		"max_iterations": max_iterations,
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


func _search_worker_loop() -> void:
	while thread_running:
		job_semaphore.wait()
		if not thread_running:
			break
		var job: Dictionary = {}
		job_mutex.lock()
		if not job_queue.is_empty():
			job = job_queue.pop_front()
		job_mutex.unlock()
		if job.is_empty():
			continue
		var result := _run_search(job)
		result_mutex.lock()
		result_queue.append(result)
		result_mutex.unlock()


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
	if String(job.get("kind", "assignment")) == "goals":
		path = pathfinder.find_path_to_any(snapshot, start, job.get("goals", []), max_iterations)
	elif task_type == TaskQueue.TaskType.STAIRS:
		path = _find_stairs_path(snapshot, pathfinder, start, target, max_iterations)
	elif task_type == TaskQueue.TaskType.HAUL:
		path = pathfinder.find_path(snapshot, start, target, false, false, max_iterations)
	else:
		path = _find_work_path(snapshot, pathfinder, start, target, max_iterations)
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


func _find_work_path(
	snapshot,
	pathfinder: Pathfinder,
	start: Vector3i,
	target: Vector3i,
	max_iterations: int
) -> Array:
	var work_positions: Array[Vector3i] = []
	for candidate in pathfinder.get_walkable_adjacent_on_level(snapshot, target, target.y):
		if pathfinder.can_move_same_level(snapshot, candidate, target):
			work_positions.append(candidate)
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
	max_iterations: int
) -> Array:
	var candidates: Array[Vector3i] = []
	for dy in range(0, 3):
		for dx in range(-1, 2):
			for dz in range(-1, 2):
				var candidate := Vector3i(target.x + dx, target.y + dy, target.z + dz)
				if pathfinder.is_walkable(snapshot, candidate.x, candidate.y, candidate.z):
					candidates.append(candidate)
	return pathfinder.find_path_to_any(snapshot, start, candidates, max_iterations)
