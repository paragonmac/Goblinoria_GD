extends RefCounted
class_name WorldRendererMeshScheduler
## Owns async mesh job queues, result queues, and the worker thread.

#region State
var mesh_thread: Thread
var mesh_thread_running: bool = false
var mesh_job_queue: Array = []
var mesh_job_set: Dictionary = {}
var mesh_job_mutex := Mutex.new()
# Protected by mesh_job_mutex, including the worker's publication check.
var mesh_epoch: int = 0
var coord_epochs: Dictionary = {}
var mesh_job_semaphore := Semaphore.new()
var mesh_result_queue: Array = []
var mesh_result_mutex := Mutex.new()
var mesh_prefetch_set: Dictionary = {}
var build_callback: Callable
var result_backlog_max: int = 32
var result_backlog_sleep_usec: int = 500
# Protected by mesh_job_mutex. Includes a dequeued job waiting on backlog,
# not jobs still queued or completed results awaiting main-thread application.
var in_flight_jobs := 0
# All capture fields use mesh_job_mutex. This epoch is independent of mesh
# invalidation: resetting capture must never affect scheduling/publication.
var _capture_enabled := false
var _capture_epoch := 0
var _capture_pending_count := 0
var _capture_pending_ms := 0.0
var _capture_totals := {
	"completed_count": 0, "completed_ms": 0.0,
	"delivered_count": 0, "delivered_ms": 0.0,
	"lost_before_publication_count": 0, "lost_before_publication_ms": 0.0,
	"discarded_pending_count": 0, "discarded_pending_ms": 0.0,
}
#endregion


#region Lifecycle
func configure(callback: Callable, backlog_max: int, backlog_sleep_usec: int) -> void:
	build_callback = callback
	result_backlog_max = backlog_max
	result_backlog_sleep_usec = backlog_sleep_usec


func is_running() -> bool:
	return mesh_thread_running


func start(enabled: bool) -> void:
	if not enabled or mesh_thread_running:
		return
	mesh_thread_running = true
	mesh_thread = Thread.new()
	mesh_thread.start(Callable(self, "_mesh_worker_loop"))


func stop() -> void:
	if not mesh_thread_running:
		return
	mesh_thread_running = false
	mesh_job_semaphore.post()
	if mesh_thread != null:
		mesh_thread.wait_to_finish()
	mesh_thread = null


func clear() -> void:
	mesh_job_mutex.lock()
	mesh_epoch += 1
	coord_epochs.clear()
	mesh_job_queue.clear()
	mesh_result_mutex.lock()
	# Running totals avoid scanning an arbitrarily large result queue on clear.
	if _capture_enabled:
		_capture_totals["discarded_pending_count"] += _capture_pending_count
		_capture_totals["discarded_pending_ms"] += _capture_pending_ms
	_capture_pending_count = 0
	_capture_pending_ms = 0.0
	mesh_result_queue.clear()
	mesh_result_mutex.unlock()
	mesh_job_mutex.unlock()
	mesh_job_set.clear()
	mesh_prefetch_set.clear()
#endregion


#region Enqueue
func stamp_job(job: Dictionary) -> void:
	mesh_job_mutex.lock()
	job["mesh_epoch"] = mesh_epoch
	job["coord_epoch"] = int(coord_epochs.get(job.get("coord", Vector3i.ZERO), 0))
	mesh_job_mutex.unlock()


func enqueue_visible_job(job: Dictionary, revision: int, high_priority: bool) -> void:
	if not job.has("mesh_epoch"):
		stamp_job(job)
	var coord: Vector3i = job.get("coord", Vector3i.ZERO)
	mesh_job_set[coord] = revision
	mesh_job_mutex.lock()
	if high_priority:
		mesh_job_queue.insert(0, job)
	else:
		var insert_index := mesh_job_queue.size()
		for i in range(mesh_job_queue.size()):
			if bool(mesh_job_queue[i].get("prefetch", false)):
				insert_index = i
				break
		mesh_job_queue.insert(insert_index, job)
	mesh_job_mutex.unlock()
	mesh_job_semaphore.post()


func enqueue_prefetch_job(key: String, job: Dictionary, revision: int, high_priority: bool = false) -> void:
	if not job.has("mesh_epoch"):
		stamp_job(job)
	mesh_prefetch_set[key] = revision
	mesh_job_mutex.lock()
	if high_priority:
		mesh_job_queue.insert(0, job)
	else:
		mesh_job_queue.append(job)
	mesh_job_mutex.unlock()
	mesh_job_semaphore.post()


func reprioritize_job(coord: Vector3i) -> void:
	mesh_job_mutex.lock()
	for i in range(mesh_job_queue.size()):
		var job: Dictionary = mesh_job_queue[i]
		var job_coord: Vector3i = job.get("coord", Vector3i.ZERO)
		if job_coord != coord:
			continue
		mesh_job_queue.remove_at(i)
		mesh_job_queue.insert(0, job)
		break
	mesh_job_mutex.unlock()
#endregion


#region Records
func get_job_revision(coord: Vector3i) -> int:
	return int(mesh_job_set.get(coord, -1))


func get_prefetch_revision(key: String) -> int:
	return int(mesh_prefetch_set.get(key, -1))


func clear_job_record(coord: Vector3i, revision: int) -> void:
	if not mesh_job_set.has(coord):
		return
	var queued_rev: int = int(mesh_job_set.get(coord, -1))
	if queued_rev <= revision:
		mesh_job_set.erase(coord)


func clear_prefetch_job_record(coord: Vector3i, local_top: int, revision: int) -> void:
	var key := prefetch_key(coord, local_top)
	if not mesh_prefetch_set.has(key):
		return
	var queued_rev: int = int(mesh_prefetch_set.get(key, -1))
	if queued_rev <= revision:
		mesh_prefetch_set.erase(key)


func cancel_coord(coord: Vector3i) -> void:
	mesh_job_mutex.lock()
	coord_epochs[coord] = int(coord_epochs.get(coord, 0)) + 1
	for i in range(mesh_job_queue.size() - 1, -1, -1):
		var job: Dictionary = mesh_job_queue[i]
		if job.get("coord", null) == coord:
			mesh_job_queue.remove_at(i)
	mesh_result_mutex.lock()
	for i in range(mesh_result_queue.size() - 1, -1, -1):
		var result: Dictionary = mesh_result_queue[i]
		if result.get("coord", null) == coord:
			_remove_capture_pending_locked(result, "discarded_pending")
			mesh_result_queue.remove_at(i)
	mesh_result_mutex.unlock()
	mesh_job_mutex.unlock()
	mesh_job_set.erase(coord)
	purge_prefetch_for_coord(coord)


func purge_prefetch_for_coord(coord: Vector3i) -> void:
	for key in mesh_prefetch_set.keys():
		var key_str: String = key
		if key_str.begins_with("%d,%d,%d," % [coord.x, coord.y, coord.z]):
			mesh_prefetch_set.erase(key_str)


func prefetch_key(coord: Vector3i, local_top: int) -> String:
	return "%d,%d,%d,%d" % [coord.x, coord.y, coord.z, local_top]
#endregion


#region Results
func is_result_current(result: Dictionary) -> bool:
	mesh_job_mutex.lock()
	var current := _is_result_current_locked(result)
	mesh_job_mutex.unlock()
	return current


func _is_result_current_locked(result: Dictionary) -> bool:
	var coord: Vector3i = result.get("coord", Vector3i.ZERO)
	return int(result.get("mesh_epoch", -1)) == mesh_epoch \
		and int(result.get("coord_epoch", -1)) == int(coord_epochs.get(coord, 0))


func pop_result() -> Dictionary:
	mesh_job_mutex.lock()
	mesh_result_mutex.lock()
	if mesh_result_queue.is_empty():
		mesh_result_mutex.unlock()
		mesh_job_mutex.unlock()
		return {}
	var result: Dictionary = mesh_result_queue.pop_front()
	_remove_capture_pending_locked(result, "delivered")
	mesh_result_mutex.unlock()
	mesh_job_mutex.unlock()
	return result


func peek_next_result_build_ms() -> float:
	mesh_result_mutex.lock()
	if mesh_result_queue.is_empty():
		mesh_result_mutex.unlock()
		return -1.0
	var build_ms := float(mesh_result_queue[0].get("build_ms", 0.0))
	mesh_result_mutex.unlock()
	return build_ms
#endregion


#region Pending Checks
func has_visible_records() -> bool:
	return mesh_job_set.size() > 0


func has_prefetch_records() -> bool:
	return mesh_prefetch_set.size() > 0


func has_non_prefetch_jobs() -> bool:
	mesh_job_mutex.lock()
	for job in mesh_job_queue:
		if not bool(job.get("prefetch", false)):
			mesh_job_mutex.unlock()
			return true
	mesh_job_mutex.unlock()
	return false


func has_non_prefetch_results() -> bool:
	mesh_result_mutex.lock()
	for result in mesh_result_queue:
		if not bool(result.get("prefetch", false)):
			mesh_result_mutex.unlock()
			return true
	mesh_result_mutex.unlock()
	return false


func has_any_jobs() -> bool:
	var pending := false
	mesh_job_mutex.lock()
	pending = mesh_job_queue.size() > 0
	mesh_job_mutex.unlock()
	return pending


func has_any_results() -> bool:
	var pending := false
	mesh_result_mutex.lock()
	pending = mesh_result_queue.size() > 0
	mesh_result_mutex.unlock()
	return pending


func has_pending_mesh_work(include_prefetch: bool) -> bool:
	if has_visible_records():
		return true
	if include_prefetch and has_prefetch_records():
		return true
	if include_prefetch:
		if has_any_jobs():
			return true
		if has_any_results():
			return true
		return false
	if has_non_prefetch_jobs():
		return true
	if has_non_prefetch_results():
		return true
	return false
#endregion


#region Stats
## Main-thread boundary. Always rotates capture epoch, even true -> true.
## Returns the old, undrained totals atomically so boundary races lose no data.
func set_performance_capture_enabled(enabled: bool) -> Dictionary:
	mesh_job_mutex.lock()
	var totals := _take_capture_totals_locked()
	_capture_enabled = enabled
	_capture_epoch += 1
	_capture_pending_count = 0
	_capture_pending_ms = 0.0
	mesh_job_mutex.unlock()
	return totals


func drain_performance_capture() -> Dictionary:
	mesh_job_mutex.lock()
	var totals := _take_capture_totals_locked()
	mesh_job_mutex.unlock()
	return totals


func is_result_in_performance_capture(result: Dictionary) -> bool:
	mesh_job_mutex.lock()
	var current := _capture_result_current_locked(result)
	mesh_job_mutex.unlock()
	return current


func _capture_result_current_locked(result: Dictionary) -> bool:
	return _capture_enabled and int(result.get("performance_capture_epoch", -1)) == _capture_epoch


func _take_capture_totals_locked() -> Dictionary:
	var totals := _capture_totals.duplicate()
	for kind in ["completed", "delivered", "lost_before_publication", "discarded_pending"]:
		_capture_totals[kind + "_count"] = 0
		_capture_totals[kind + "_ms"] = 0.0
	return totals


func _remove_capture_pending_locked(result: Dictionary, disposition: String) -> void:
	if not _capture_result_current_locked(result):
		return
	var build_ms := float(result.get("performance_build_ms", 0.0))
	_capture_pending_count -= 1
	_capture_pending_ms -= build_ms
	if _capture_pending_count == 0:
		_capture_pending_ms = 0.0
	_capture_totals[disposition + "_count"] += 1
	_capture_totals[disposition + "_ms"] += build_ms


func get_stats() -> Dictionary:
	var job_queue := 0
	var result_queue := 0
	mesh_job_mutex.lock()
	job_queue = mesh_job_queue.size()
	mesh_job_mutex.unlock()
	mesh_result_mutex.lock()
	result_queue = mesh_result_queue.size()
	mesh_result_mutex.unlock()
	return {
		"job_queue": job_queue,
		"result_queue": result_queue,
		"job_set": mesh_job_set.size(),
		"prefetch_set": mesh_prefetch_set.size(),
	}


## Main-thread API: visible/prefetch records are owned only by the main thread.
## All fields shared with the worker are read under their owning mutexes.
func get_performance_snapshot() -> Dictionary:
	mesh_job_mutex.lock()
	mesh_result_mutex.lock()
	var snapshot := {
		"queued": mesh_job_queue.size(),
		"results_pending": mesh_result_queue.size(),
		"in_flight": in_flight_jobs,
		"visible_records": mesh_job_set.size(),
		"prefetch_records": mesh_prefetch_set.size(),
	}
	mesh_result_mutex.unlock()
	mesh_job_mutex.unlock()
	return snapshot
#endregion


#region Worker
func _mesh_worker_loop() -> void:
	while mesh_thread_running:
		mesh_job_semaphore.wait()
		if not mesh_thread_running:
			break
		var job: Dictionary = {}
		var job_capture_epoch := -1
		mesh_job_mutex.lock()
		if mesh_job_queue.size() > 0:
			job = mesh_job_queue.pop_front()
			in_flight_jobs += 1
			if _capture_enabled:
				job_capture_epoch = _capture_epoch
		mesh_job_mutex.unlock()
		if job.is_empty():
			continue
		_wait_for_result_backlog()
		if not mesh_thread_running:
			break
		if not build_callback.is_valid():
			_finish_in_flight_job()
			continue
		var build_started_usec := Time.get_ticks_usec() if job_capture_epoch >= 0 else 0
		var result_value: Variant = build_callback.call(job)
		var elapsed_ms := float(Time.get_ticks_usec() - build_started_usec) / 1000.0 if job_capture_epoch >= 0 else 0.0
		if typeof(result_value) != TYPE_DICTIONARY:
			_finish_in_flight_job()
			continue
		var result: Dictionary = result_value
		result["mesh_epoch"] = job.get("mesh_epoch", -1)
		result["coord_epoch"] = job.get("coord_epoch", -1)
		result["performance_capture_epoch"] = job_capture_epoch
		result["performance_build_ms"] = float(result.get("build_ms", elapsed_ms))
		# Use the same lock order as clear/cancel so invalidation cannot race
		# between checking a completed job and publishing its result.
		mesh_job_mutex.lock()
		in_flight_jobs -= 1
		var captured := _capture_result_current_locked(result)
		var build_ms := float(result["performance_build_ms"])
		if captured:
			_capture_totals["completed_count"] += 1
			_capture_totals["completed_ms"] += build_ms
		if _is_result_current_locked(result):
			mesh_result_mutex.lock()
			mesh_result_queue.append(result)
			if captured:
				_capture_pending_count += 1
				_capture_pending_ms += build_ms
			mesh_result_mutex.unlock()
		elif captured:
			_capture_totals["lost_before_publication_count"] += 1
			_capture_totals["lost_before_publication_ms"] += build_ms
		mesh_job_mutex.unlock()
	mesh_job_mutex.lock()
	in_flight_jobs = 0
	mesh_job_mutex.unlock()


func _finish_in_flight_job() -> void:
	mesh_job_mutex.lock()
	in_flight_jobs -= 1
	mesh_job_mutex.unlock()


func _wait_for_result_backlog() -> void:
	if result_backlog_max <= 0:
		return
	var backlog := 0
	mesh_result_mutex.lock()
	backlog = mesh_result_queue.size()
	mesh_result_mutex.unlock()
	while backlog >= result_backlog_max and mesh_thread_running:
		OS.delay_usec(result_backlog_sleep_usec)
		mesh_result_mutex.lock()
		backlog = mesh_result_queue.size()
		mesh_result_mutex.unlock()
#endregion
