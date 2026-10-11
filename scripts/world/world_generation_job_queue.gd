extends RefCounted
class_name WorldGenerationJobQueue
## Thread-safe queue state for asynchronous chunk generation jobs.



var jobs: Array = []
var job_set: Dictionary = {}
var job_epochs: Dictionary = {}
var results: Array = []
var mutex := Mutex.new()
var semaphore := Semaphore.new()
var active: int = 0
var epoch: int = 0


func get_epoch() -> int:
	return epoch


func contains(coord: Vector3i) -> bool:
	mutex.lock()
	var found := job_set.has(coord)
	mutex.unlock()
	return found


func enqueue(coord: Vector3i, job: Dictionary, high_priority: bool, queue_mesh_on_complete: bool) -> bool:
	var should_wake := false
	var queued := false
	mutex.lock()
	if job_set.has(coord):
		var existing_prio: int = int(job_set.get(coord, 0))
		var found_queued_job := false
		for i in range(jobs.size()):
			var existing_job: Dictionary = jobs[i]
			var job_coord: Vector3i = existing_job.get("coord", Vector3i.ZERO)
			if job_coord == coord:
				found_queued_job = true
				if queue_mesh_on_complete:
					existing_job["queue_mesh_on_complete"] = true
				if high_priority and existing_prio < 2:
					job_set[coord] = 2
					existing_job["high_priority"] = true
					jobs.remove_at(i)
					jobs.insert(0, existing_job)
					queued = true
					should_wake = true
				else:
					jobs[i] = existing_job
				break
		if not found_queued_job and high_priority and existing_prio < 2:
			queued = true
			should_wake = true
		mutex.unlock()
		if should_wake:
			semaphore.post()
		return queued
	job_set[coord] = 2 if high_priority else 1
	job_epochs[coord] = int(job.get("epoch", epoch))
	if high_priority:
		jobs.insert(0, job)
	else:
		jobs.append(job)
	queued = true
	should_wake = true
	mutex.unlock()
	if should_wake:
		semaphore.post()
	return queued


func wait_for_job_signal() -> void:
	semaphore.wait()


func wake() -> void:
	semaphore.post()


func pop_job() -> Dictionary:
	mutex.lock()
	if jobs.is_empty():
		mutex.unlock()
		return {}
	var job: Dictionary = jobs.pop_front()
	active += 1
	mutex.unlock()
	return job


func push_result(result: Dictionary) -> void:
	mutex.lock()
	active -= 1
	results.append(result)
	mutex.unlock()


func pop_result() -> Dictionary:
	mutex.lock()
	if results.is_empty():
		mutex.unlock()
		return {}
	var result: Dictionary = results.pop_front()
	mutex.unlock()
	return result


func clear_job(coord: Vector3i, job_epoch: int) -> bool:
	mutex.lock()
	var had_job := job_set.has(coord) and int(job_epochs.get(coord, -1)) == job_epoch
	if had_job:
		job_set.erase(coord)
		job_epochs.erase(coord)
	mutex.unlock()
	return had_job


func get_stats() -> Dictionary:
	mutex.lock()
	var stats := {
		"queued": jobs.size(),
		"results": results.size(),
		"active": active,
	}
	mutex.unlock()
	return stats


func reset() -> int:
	epoch += 1
	mutex.lock()
	var outstanding := job_set.size()
	jobs.clear()
	results.clear()
	job_set.clear()
	job_epochs.clear()
	mutex.unlock()
	return outstanding
