extends RefCounted
class_name RenderZoneCullScheduler
## Main-thread lifecycle/submission API. A static thread entry owns only State,
## never this scheduler, so PREDELETE can wake and join even an idle worker.
## Jobs contain values only; submit snapshots/freezes all nested containers.

const KernelScript = preload("res://scripts/rendering/render_zone_cull_kernel.gd")
const EPOCH_CHECK_STEPS := 256

var force_start_failure := false
var _thread: Thread
var _state := WorkerState.new()


class WorkerState extends RefCounted:
	var mutex := Mutex.new()
	var wake := Semaphore.new()
	var wake_posted := false
	var stopping := true
	var fallback := false
	var epoch := 0
	var pending: Dictionary = {}
	var pending_capture := -1
	var result: Dictionary = {}
	var result_capture := -1
	# Only the worker (or main-thread fallback) touches a live kernel's buffers.
	var kernel: RefCounted
	var active_capture := -1
	var worker_usec := 0
	var queue_wait_usec := 0
	var capture_enabled := false
	var capture_epoch := 0
	var capture := fresh_totals()
	var totals := fresh_totals()
	var submitted_count := 0
	var started_count := 0
	var rejected_count := 0
	var processed_steps := 0

	static func fresh_totals() -> Dictionary:
		return {
			"completed_count": 0, "completed_ms": 0.0, "queue_wait_ms": 0.0,
			"cancelled_count": 0, "cancelled_ms": 0.0,
			"replaced_result_count": 0, "replaced_pending_count": 0,
		}

	func record(key: String, amount: float, job_capture: int) -> void:
		# All accounting and publication use the same mutex as invalidation.
		totals[key] += amount
		if capture_enabled and job_capture == capture_epoch:
			capture[key] += amount

	# Called under mutex. The caller must retain the returned owner until unlock.
	func discard_pending() -> Dictionary:
		var retired := pending
		if not pending.is_empty():
			record("cancelled_count", 1, pending_capture)
			pending = {}
		return retired

	func cancel_active() -> RefCounted:
		var retired := kernel
		if kernel != null:
			record("cancelled_count", 1, active_capture)
			record("cancelled_ms", float(worker_usec) / 1000.0, active_capture)
			kernel = null
		return retired

	func shutdown(thread: Thread) -> void:
		mutex.lock()
		stopping = true
		var retired_pending := discard_pending()
		var retired_result := result
		result = {}
		wake.post()
		mutex.unlock()
		retired_pending = {}
		retired_result = {}
		if thread != null:
			thread.wait_to_finish()
		mutex.lock()
		var retired_kernel := cancel_active()
		fallback = false
		mutex.unlock()
		retired_kernel = null

	func advance_kernel(max_steps: int, deadline_usec: int) -> int:
		return kernel.advance(max_steps, deadline_usec)

	func step(max_steps: int, deadline_usec: int) -> int:
		var retired_kernel: RefCounted
		mutex.lock()
		if stopping or (kernel != null and int(kernel.job.epoch) != epoch):
			retired_kernel = cancel_active()
		if stopping:
			mutex.unlock()
			retired_kernel = null
			return 0
		if kernel == null and not pending.is_empty():
			kernel = KernelScript.new(pending)
			active_capture = pending_capture
			pending = {}
			worker_usec = 0
			queue_wait_usec = maxi(0, Time.get_ticks_usec() - int(kernel.job.submitted_usec))
			started_count += 1
		if kernel == null:
			mutex.unlock()
			retired_kernel = null
			return 0
		mutex.unlock()
		retired_kernel = null
		var started := Time.get_ticks_usec()
		var processed := advance_kernel(mini(max_steps, EPOCH_CHECK_STEPS), deadline_usec)
		var elapsed := Time.get_ticks_usec() - started
		var retired_result: Dictionary = {}
		mutex.lock()
		worker_usec += elapsed
		processed_steps += processed
		# Recheck before publishing, including for jobs smaller than 256 coords.
		if stopping or int(kernel.job.epoch) != epoch:
			retired_kernel = cancel_active()
		elif kernel.done:
			record("completed_count", 1, active_capture)
			record("completed_ms", float(worker_usec) / 1000.0, active_capture)
			record("queue_wait_ms", float(queue_wait_usec) / 1000.0, active_capture)
			if not result.is_empty():
				record("replaced_result_count", 1, result_capture)
			retired_result = result
			result = kernel.take_result()
			result["worker_usec"] = worker_usec
			result["queue_wait_usec"] = queue_wait_usec
			result["completed_usec"] = Time.get_ticks_usec()
			result_capture = active_capture
			retired_kernel = kernel
			kernel = null
		mutex.unlock()
		# Releasing a large accepted set/job can be linear in its size. Keep
		# destruction outside the shared lock, including normal completion.
		retired_result = {}
		retired_kernel = null
		return processed


func start() -> bool:
	_state.mutex.lock()
	if not _state.stopping:
		var threaded := not _state.fallback
		_state.mutex.unlock()
		return threaded
	_state.stopping = false
	_state.wake = Semaphore.new()
	_state.wake_posted = false
	_state.fallback = force_start_failure
	_state.mutex.unlock()
	if force_start_failure:
		return false
	_thread = Thread.new()
	var error := _thread.start(_worker_loop.bind(_state))
	if error != OK:
		_thread = null
		_state.mutex.lock()
		_state.fallback = true
		_state.mutex.unlock()
		return false
	return true


func invalidate(epoch: int) -> void:
	_state.mutex.lock()
	_state.epoch = epoch
	var retired_pending := _state.discard_pending()
	var retired_result := _state.result
	_state.result = {}
	# The worker observes this epoch within at most 256 candidates; never join.
	_state.mutex.unlock()
	retired_pending = {}
	retired_result = {}


func submit(job: Dictionary) -> void:
	# Contract violations cannot smuggle Nodes, Resources, or callables across.
	if not _is_value_tree(job) or not _valid_job(job):
		_state.mutex.lock()
		_state.rejected_count += 1
		_state.mutex.unlock()
		return
	var snapshot := job.duplicate(true)
	_freeze(snapshot)
	_state.mutex.lock()
	if _state.stopping or int(snapshot.epoch) != _state.epoch:
		_state.rejected_count += 1
		_state.mutex.unlock()
		return
	_state.submitted_count += 1
	if not _state.pending.is_empty():
		_state.record("replaced_pending_count", 1, _state.pending_capture)
	var retired_pending := _state.pending
	_state.pending = snapshot
	_state.pending_capture = _state.capture_epoch if _state.capture_enabled else -1
	if not _state.fallback and not _state.wake_posted:
		_state.wake_posted = true
		_state.wake.post()
	_state.mutex.unlock()
	retired_pending = {}


func take_result() -> Dictionary:
	_state.mutex.lock()
	var result := _state.result
	_state.result = {}
	_state.mutex.unlock()
	return result


## Uses the caller's remaining candidate budget and absolute frame deadline.
## Timing sums only active advances, excluding time between fallback pumps.
func pump_fallback(max_steps: int, deadline_usec: int) -> int:
	var processed := 0
	while processed < max_steps:
		if deadline_usec > 0 and Time.get_ticks_usec() >= deadline_usec:
			break
		_state.mutex.lock()
		var can_pump := _state.fallback and not _state.stopping
		var has_work := _state.kernel != null or not _state.pending.is_empty()
		_state.mutex.unlock()
		if not can_pump or not has_work:
			break
		processed += _state.step(max_steps - processed, deadline_usec)
	return processed


func stop() -> void:
	_state.shutdown(_thread)
	_thread = null


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		# At refcount zero Godot cannot invoke another method on self. State
		# is still referenced here, so perform teardown through that object.
		_state.shutdown(_thread)
		_thread = null


## Every lifecycle call rotates/reset capture, including true -> true.
## Atomically returns the old undrained totals so boundary completions cannot
## fall between a separate drain and reset. The caller emits this returned tail.
func set_performance_capture(enabled: bool) -> Dictionary:
	_state.mutex.lock()
	var totals := _state.capture
	_state.capture_enabled = enabled
	_state.capture_epoch += 1
	_state.capture = WorkerState.fresh_totals()
	_state.mutex.unlock()
	return totals


func drain_performance_capture() -> Dictionary:
	_state.mutex.lock()
	var totals := _state.capture
	_state.capture = WorkerState.fresh_totals()
	_state.mutex.unlock()
	return totals


## Lifetime counters are independent of capture; slot counts are always 0/1.
func get_stats() -> Dictionary:
	_state.mutex.lock()
	var stats := _state.totals.duplicate()
	stats.merge({
		"pending": int(not _state.pending.is_empty()),
		"in_flight": int(_state.kernel != null),
		"result_pending": int(not _state.result.is_empty()),
		"fallback": _state.fallback,
		"submitted_count": _state.submitted_count,
		"started_count": _state.started_count,
		"rejected_count": _state.rejected_count,
		"processed_steps": _state.processed_steps,
	})
	_state.mutex.unlock()
	return stats


static func _worker_loop(state: WorkerState) -> void:
	while true:
		state.wake.wait()
		state.mutex.lock()
		state.wake_posted = false
		var stopping := state.stopping
		state.mutex.unlock()
		if stopping:
			break
		while true:
			state.step(EPOCH_CHECK_STEPS, 0)
			state.mutex.lock()
			var active := state.kernel != null
			state.mutex.unlock()
			if not active:
				break
	state.mutex.lock()
	var retired_kernel := state.cancel_active()
	state.mutex.unlock()
	retired_kernel = null


static func _valid_job(job: Dictionary) -> bool:
	for key in ["min", "max"]:
		if typeof(job.get(key)) != TYPE_VECTOR3I:
			return false
	for key in ["chunk_size", "request_id", "epoch", "submitted_usec"]:
		if typeof(job.get(key)) != TYPE_INT:
			return false
	if int(job.chunk_size) <= 0 or typeof(job.get("planes")) != TYPE_ARRAY:
		return false
	if typeof(job.get("padding")) not in [TYPE_INT, TYPE_FLOAT]:
		return false
	if typeof(job.get("view_key")) != TYPE_ARRAY or typeof(job.get("bounds")) != TYPE_DICTIONARY:
		return false
	for entry in job.planes:
		if typeof(entry) != TYPE_DICTIONARY:
			return false
		if typeof(entry.get("plane")) != TYPE_PLANE or typeof(entry.get("inside_positive")) != TYPE_BOOL:
			return false
	return true


static func _is_value_tree(value: Variant, depth: int = 0) -> bool:
	# A depth bound also rejects cyclic containers before duplicate(true).
	if depth > 64 or typeof(value) in [TYPE_OBJECT, TYPE_CALLABLE, TYPE_SIGNAL, TYPE_RID]:
		return false
	if value is Dictionary:
		for key in value:
			if not _is_value_tree(key, depth + 1) or not _is_value_tree(value[key], depth + 1):
				return false
	elif value is Array:
		for item in value:
			if not _is_value_tree(item, depth + 1):
				return false
	return true


static func _freeze(value: Variant) -> void:
	if value is Dictionary:
		for key in value:
			_freeze(key)
			_freeze(value[key])
		value.make_read_only()
	elif value is Array:
		for item in value:
			_freeze(item)
		value.make_read_only()
