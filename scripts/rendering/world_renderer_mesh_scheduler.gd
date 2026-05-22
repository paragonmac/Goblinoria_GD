extends RefCounted
class_name WorldRendererMeshScheduler
## Owns async mesh job queues, result queues, and the worker thread.

#region State
var mesh_thread: Thread
var mesh_thread_running: bool = false
var mesh_job_queue: Array = []
var mesh_job_set: Dictionary = {}
var mesh_job_mutex := Mutex.new()
var mesh_job_semaphore := Semaphore.new()
var mesh_result_queue: Array = []
var mesh_result_mutex := Mutex.new()
var mesh_prefetch_set: Dictionary = {}
var build_callback: Callable
var result_backlog_max: int = 32
var result_backlog_sleep_usec: int = 500
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
	mesh_job_queue.clear()
	mesh_job_mutex.unlock()
	mesh_result_mutex.lock()
	mesh_result_queue.clear()
	mesh_result_mutex.unlock()
	mesh_job_set.clear()
	mesh_prefetch_set.clear()
#endregion


#region Enqueue
func enqueue_visible_job(job: Dictionary, revision: int, high_priority: bool) -> void:
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
	for i in range(mesh_job_queue.size() - 1, -1, -1):
		var job: Dictionary = mesh_job_queue[i]
		if job.get("coord", null) == coord:
			mesh_job_queue.remove_at(i)
	mesh_job_mutex.unlock()
	mesh_result_mutex.lock()
	for i in range(mesh_result_queue.size() - 1, -1, -1):
		var result: Dictionary = mesh_result_queue[i]
		if result.get("coord", null) == coord:
			mesh_result_queue.remove_at(i)
	mesh_result_mutex.unlock()
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
func pop_result() -> Dictionary:
	mesh_result_mutex.lock()
	if mesh_result_queue.is_empty():
		mesh_result_mutex.unlock()
		return {}
	var result: Dictionary = mesh_result_queue.pop_front()
	mesh_result_mutex.unlock()
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
#endregion


#region Worker
func _mesh_worker_loop() -> void:
	while mesh_thread_running:
		mesh_job_semaphore.wait()
		if not mesh_thread_running:
			break
		var job: Dictionary = {}
		mesh_job_mutex.lock()
		if mesh_job_queue.size() > 0:
			job = mesh_job_queue.pop_front()
		mesh_job_mutex.unlock()
		if job.is_empty():
			continue
		_wait_for_result_backlog()
		if not mesh_thread_running:
			break
		if not build_callback.is_valid():
			continue
		var result_value: Variant = build_callback.call(job)
		if typeof(result_value) != TYPE_DICTIONARY:
			continue
		var result: Dictionary = result_value
		mesh_result_mutex.lock()
		mesh_result_queue.append(result)
		mesh_result_mutex.unlock()


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
