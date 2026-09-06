extends SceneTree
## Isolated value-kernel and real-thread contracts. No world, editor, or GUI.

const Scheduler = preload("res://scripts/rendering/render_zone_cull_scheduler.gd")
const Kernel = preload("res://scripts/rendering/render_zone_cull_kernel.gd")
const Culler = preload("res://scripts/rendering/frustum_culler.gd")
const WAIT_MS := 5000
var failures := 0
var checks := 0


class GatedState extends Scheduler.WorkerState:
	# Configured before start; only the worker mutates this dictionary.
	var gate_ids: Dictionary = {}
	var entered := Semaphore.new()
	var release := Semaphore.new()

	func advance_kernel(max_steps: int, deadline_usec: int) -> int:
		var processed := super.advance_kernel(max_steps, deadline_usec)
		var request_id: int = kernel.job.request_id
		if gate_ids.has(request_id):
			gate_ids.erase(request_id)
			entered.post()
			release.wait()
		return processed


class ReleaseAudit extends RefCounted:
	var mutex: Mutex
	var unlocked: Array[bool] = []

	func observe() -> void:
		# Mutex is recursive: another thread must probe the destruction lock.
		var probe_thread := Thread.new()
		if probe_thread.start(_try_lock.bind(mutex)) != OK:
			unlocked.append(false)
			return
		unlocked.append(bool(probe_thread.wait_to_finish()))

	static func _try_lock(target: Mutex) -> bool:
		if not target.try_lock():
			return false
		target.unlock()
		return true


class ReleaseProbe extends RefCounted:
	var audit: ReleaseAudit

	func _init(owner_audit: ReleaseAudit) -> void:
		audit = owner_audit

	func _notification(what: int) -> void:
		if what == NOTIFICATION_PREDELETE:
			audit.observe()


class RetiringKernel extends Kernel:
	var audit: ReleaseAudit

	func _init(snapshot: Dictionary, owner_audit: ReleaseAudit) -> void:
		super(snapshot)
		audit = owner_audit

	func _notification(what: int) -> void:
		if what == NOTIFICATION_PREDELETE:
			audit.observe()


class InvalidatingState extends Scheduler.WorkerState:
	func advance_kernel(max_steps: int, deadline_usec: int) -> int:
		var processed := super.advance_kernel(max_steps, deadline_usec)
		mutex.lock()
		epoch += 1
		mutex.unlock()
		return processed


func _init() -> void:
	_test_kernel()
	_test_fallback()
	_test_fallback_deadline_and_capture()
	_test_thread_coalescing()
	_test_hard_cancel()
	_test_publication_cancel()
	_test_capture_epochs()
	_test_atomic_capture_rotation()
	_test_retirement_outside_lock()
	_test_stop_and_predelete()
	if failures:
		push_error("Render zone cull scheduler FAILED: %d/%d" % [failures, checks])
		quit(1)
	else:
		print("RENDER_ZONE_CULL_SCHEDULER_OK (%d checks)" % checks)
		quit(0)


func _check(ok: bool, message: String) -> void:
	checks += 1
	if not ok:
		failures += 1
		push_error(message)


func _job(id: int, maximum := Vector3i(3, 1, 2), epoch: int = 1) -> Dictionary:
	return {
		"min": Vector3i.ZERO, "max": maximum, "chunk_size": 16, "padding": 0.0,
		"planes": [], "request_id": id, "epoch": epoch,
		"submitted_usec": Time.get_ticks_usec() - 100,
		"view_key": [id, {"camera": [1, 2]}], "bounds": {"tag": ["original"]},
	}


func _wait_gate(state: GatedState) -> bool:
	var deadline := Time.get_ticks_msec() + WAIT_MS
	while Time.get_ticks_msec() < deadline:
		if state.entered.try_wait():
			return true
		OS.delay_msec(1)
	return false


func _wait_idle(scheduler) -> bool:
	var deadline := Time.get_ticks_msec() + WAIT_MS
	while Time.get_ticks_msec() < deadline:
		var stats: Dictionary = scheduler.get_stats()
		if stats.pending == 0 and stats.in_flight == 0:
			return true
		OS.delay_msec(1)
	return false


func _gated_scheduler(ids: Array):
	var scheduler := Scheduler.new()
	var state := GatedState.new()
	for id in ids:
		state.gate_ids[id] = true
	scheduler._state = state
	scheduler.invalidate(1)
	_check(scheduler.start(), "dedicated thread starts")
	return scheduler


func _check_result(result: Dictionary, job: Dictionary, expected: Array[Vector3i]) -> void:
	_check(not result.is_empty(), "result exists")
	if result.is_empty():
		return
	for key in job:
		_check(result.get(key) == job[key], "echo metadata: " + str(key))
	_check(result.accepted_coords == expected, "ordered accepted coordinates match reference")
	_check(result.accepted_count == expected.size(), "accepted count matches reference")
	_check(result.accepted.size() == expected.size(), "accepted set has no duplicates")
	for coord in expected:
		_check(result.accepted.get(coord, false) == true, "accepted lookup contains coordinate")


func _reference(job: Dictionary) -> Array[Vector3i]:
	var culler := Culler.new()
	var expected: Array[Vector3i] = []
	for cy in range(job.min.y, job.max.y + 1):
		for cx in range(job.min.x, job.max.x + 1):
			for cz in range(job.min.z, job.max.z + 1):
				var coord := Vector3i(cx, cy, cz)
				if culler.is_chunk_in_view(job.planes, coord, job.chunk_size, job.padding):
					expected.append(coord)
	return expected


func _test_kernel() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 42671
	for trial in range(48):
		var job := _job(trial, Vector3i(2, 2, 3))
		job.min = Vector3i(-2, -1, -3)
		job.chunk_size = [1, 7, 16][trial % 3]
		job.padding = [-3.0, 0.0, 0.25, 16.0][trial % 4]
		if trial % 8 != 0:
			for p in range(6):
				var normal := Vector3(rng.randf_range(-1, 1), rng.randf_range(-1, 1), rng.randf_range(-1, 1))
				job.planes.append({"plane": Plane(normal, rng.randf_range(-25, 25)), "inside_positive": p % 2 == 0})
		var kernel := Kernel.new(job)
		_check(kernel.advance(0) == 0 and kernel.candidate_count == 0, "zero kernel budget")
		_check(kernel.advance(99, Time.get_ticks_usec() - 1) == 0, "expired kernel deadline")
		var processed := 0
		while not kernel.done:
			var step := kernel.advance(7)
			_check(step > 0 and step <= 7, "bounded incremental kernel advance")
			processed += step
		var result := kernel.take_result()
		_check(processed == 140 and result.candidate_count == 140, "each inclusive candidate visited exactly once")
		_check_result(result, job, _reference(job))
		_check(kernel.advance(8) == 0, "completed kernel does no more work")
	# AABB tangencies must remain accepted for both plane orientations.
	for positive in [false, true]:
		for normal in [Vector3.RIGHT, Vector3.LEFT, Vector3.UP, Vector3.DOWN, Vector3.FORWARD, Vector3.BACK]:
			var job := _job(60, Vector3i.ZERO)
			job.planes = [{"plane": Plane(normal, 0), "inside_positive": positive}]
			var kernel := Kernel.new(job)
			kernel.advance(1)
			_check_result(kernel.take_result(), job, _reference(job))
	for axis in range(3):
		var job := _job(61)
		job.max[axis] = -1
		var kernel := Kernel.new(job)
		_check(kernel.done and kernel.advance(256) == 0, "inverted bounds finish empty on any axis")
		_check_result(kernel.take_result(), job, [])
	var edge := _job(62, Vector3i(2147483647, 2147483647, 2147483647))
	edge.min = edge.max
	var edge_kernel := Kernel.new(edge)
	_check(edge_kernel.advance(2) == 1 and edge_kernel.done, "Vector3i maximum does not overflow cursor")


func _test_fallback() -> void:
	var scheduler := Scheduler.new()
	scheduler.force_start_failure = true
	_check(not scheduler.start() and not scheduler.start(), "start failure selects idempotent fallback")
	scheduler.invalidate(1)
	scheduler.set_performance_capture(true)
	var job := _job(1, Vector3i(19, 1, 1))
	var original := job.duplicate(true)
	scheduler.submit(job)
	job.max = Vector3i.ZERO
	job.view_key[1].camera[0] = 99
	job.bounds.tag[0] = "mutated"
	job.planes.append({"plane": Plane(Vector3.RIGHT, 9000), "inside_positive": true})
	_check(scheduler.pump_fallback(0, 0) == 0, "fallback zero step budget does not start work")
	_check(scheduler.pump_fallback(50, Time.get_ticks_usec() - 1) == 0, "fallback respects shared expired deadline")
	_check(scheduler.get_stats().pending == 1, "expired/zero budgets retain pending job")
	_check(scheduler.pump_fallback(7, Time.get_ticks_usec() + 1000000) == 7, "fallback shares renderer remaining step budget")
	_check(scheduler.get_stats().in_flight == 1 and scheduler.take_result().is_empty(), "partial fallback work stays unpublished")
	var next := _job(2, Vector3i.ZERO)
	scheduler.submit(_job(99))
	scheduler.submit(next)
	_check(scheduler.pump_fallback(73, 0) == 73, "soft request does not cancel incremental progress")
	var result := scheduler.take_result()
	_check_result(result, original, _reference(original))
	_check(result.get("candidate_count") == 80, "fallback processed full original snapshot")
	_check(result.get("queue_wait_usec", -1) >= 100 and result.get("worker_usec", -1) >= 0, "fallback records numeric timings")
	_check(result.get("completed_usec", 0) >= result.get("submitted_usec", 0), "completion timestamp follows submission")
	_check(scheduler.pump_fallback(1, 0) == 1, "next fallback work gets only remaining budget")
	_check_result(scheduler.take_result(), next, _reference(next))
	var captured := scheduler.drain_performance_capture()
	_check(captured.completed_count == 2 and captured.replaced_pending_count == 1, "fallback completion/replacement capture")
	_check(captured.cancelled_count == 0, "soft fallback requests never cancel")
	_check(captured.completed_ms >= 0 and captured.queue_wait_ms >= 0, "fallback captures durations")
	_check(scheduler.drain_performance_capture().completed_count == 0, "capture drain resets totals")
	# A huge candidate volume must never be pre-enumerated on submission/start.
	scheduler.submit(_job(3, Vector3i(1000000, 1000000, 1000000)))
	_check(scheduler.pump_fallback(3, 0) == 3, "huge bounds remain incremental")
	scheduler.invalidate(2)
	scheduler.submit(_job(4, Vector3i.ZERO, 2))
	_check(scheduler.pump_fallback(2, 0) == 1, "hard fallback cancel starts new epoch within same budget")
	_check(scheduler.take_result().get("request_id") == 4, "fallback suppresses old epoch")
	_check(scheduler.drain_performance_capture().cancelled_count == 1, "fallback cancellation captured once")
	var invalid := _job(5, Vector3i(-1, 2, 2), 2)
	scheduler.submit(invalid)
	_check(scheduler.pump_fallback(1, 0) == 0, "invalid bounds spend no candidate steps")
	_check_result(scheduler.take_result(), invalid, [])
	var bad := _job(6, Vector3i.ZERO, 2)
	bad.bounds["object"] = RefCounted.new()
	scheduler.submit(bad)
	scheduler.submit(_job(7, Vector3i.ZERO, 1))
	_check(scheduler.get_stats().rejected_count == 2, "reject object payloads and old epoch submissions")
	scheduler.stop()
	_check(scheduler.pump_fallback(10, 0) == 0, "stopped fallback performs no work")


func _test_fallback_deadline_and_capture() -> void:
	var scheduler := Scheduler.new()
	scheduler.force_start_failure = true
	scheduler.start()
	scheduler.invalidate(1)
	scheduler.submit(_job(1, Vector3i(1000000, 0, 0)))
	var steps := scheduler.pump_fallback(1000000, Time.get_ticks_usec() + 2000)
	_check(steps < 1000000 and scheduler.take_result().is_empty(), "live deadline interrupts large fallback advance")
	_check(scheduler.get_stats().processed_steps == steps, "deadline return counts actual candidate work")
	scheduler.invalidate(2)
	scheduler.pump_fallback(1, 0)
	# Work submitted before capture cannot acquire a new capture at dequeue.
	scheduler.submit(_job(2, Vector3i.ZERO, 2))
	scheduler.set_performance_capture(true)
	scheduler.submit(_job(3, Vector3i(4, 0, 0), 2))
	_check(scheduler.drain_performance_capture().replaced_pending_count == 0, "replacing old capture pending excludes old job")
	_check(scheduler.pump_fallback(2, 0) == 2, "fallback begins current captured job")
	scheduler.submit(_job(4, Vector3i(9, 0, 0), 2))
	_check(scheduler.pump_fallback(6, 0) == 6, "one pump shares six steps across completion and next job")
	var first := scheduler.take_result()
	_check(first.get("request_id") == 3 and scheduler.get_stats().in_flight == 1, "first completion transfers while second stays incremental")
	_check(scheduler.pump_fallback(7, 0) == 7, "next pump resumes at exact residual cursor")
	var second := scheduler.take_result()
	var totals := scheduler.drain_performance_capture()
	_check(totals.completed_count == 2, "both fallback completions captured")
	_check(is_equal_approx(totals.completed_ms, float(first.get("worker_usec", 0) + second.get("worker_usec", 0)) / 1000.0), "capture sums actual fallback worker durations")
	_check(is_equal_approx(totals.queue_wait_ms, float(first.get("queue_wait_usec", 0) + second.get("queue_wait_usec", 0)) / 1000.0), "capture sums actual queue waits")
	scheduler.stop()


func _test_thread_coalescing() -> void:
	var scheduler = _gated_scheduler([1, 3])
	var state: GatedState = scheduler._state
	scheduler.set_performance_capture(true)
	var job := _job(1)
	var original := job.duplicate(true)
	scheduler.submit(job)
	_check(_wait_gate(state), "first real-thread job reaches latch")
	job.view_key.clear()
	job.bounds.tag.clear()
	scheduler.submit(_job(2))
	scheduler.submit(_job(3))
	var stats: Dictionary = scheduler.get_stats()
	_check(stats.in_flight == 1 and stats.pending == 1 and stats.replaced_pending_count == 1, "one running plus latest pending")
	_check(scheduler.pump_fallback(1000, 0) == 0, "main cannot pump a threaded kernel")
	state.release.post()
	_check(_wait_gate(state), "latest pending gets next worker turn")
	_check_result(scheduler.take_result(), original, _reference(original))
	_check(scheduler.get_stats().cancelled_count == 0, "soft-stale completed result remains publishable")
	state.release.post()
	_check(_wait_idle(scheduler), "latest request completes")
	scheduler.submit(_job(4))
	_check(_wait_idle(scheduler), "replacement result completes")
	_check(scheduler.take_result().get("request_id") == 4, "result slot retains only newest completion")
	_check(scheduler.take_result().is_empty(), "result ownership transferred once")
	stats = scheduler.get_stats()
	_check(stats.completed_count == 3 and stats.started_count == 3 and stats.submitted_count == 4, "coalesced pending job never executes")
	_check(stats.replaced_result_count == 1, "overwritten unpublished result counted")
	var totals: Dictionary = scheduler.drain_performance_capture()
	_check(totals.completed_count == 3 and totals.replaced_result_count == 1 and totals.replaced_pending_count == 1, "thread capture matches lifetime operations")
	for key in totals:
		_check(typeof(totals[key]) in [TYPE_INT, TYPE_FLOAT], "capture totals are numeric: " + key)
	scheduler.stop()


func _test_hard_cancel() -> void:
	var scheduler = _gated_scheduler([1])
	var state: GatedState = scheduler._state
	scheduler.set_performance_capture(true)
	scheduler.submit(_job(1, Vector3i(4095, 0, 0)))
	_check(_wait_gate(state), "hard-cancel job reaches first 256-candidate boundary")
	scheduler.submit(_job(2))
	scheduler.invalidate(2)
	_check(scheduler.get_stats().in_flight == 1 and scheduler.get_stats().pending == 0, "invalidate returns without joining blocked worker")
	scheduler.submit(_job(3, Vector3i.ZERO, 2))
	state.release.post()
	_check(_wait_idle(scheduler), "hard-cancel worker moves to new epoch")
	_check(scheduler.take_result().get("request_id") == 3, "only new epoch publishes")
	var stats: Dictionary = scheduler.get_stats()
	_check(stats.processed_steps == 257 and stats.cancelled_count == 2, "cancel at 256 coords and discard old pending")
	var totals: Dictionary = scheduler.set_performance_capture(true)
	_check(totals.completed_count == 1 and totals.cancelled_count == 2 and totals.cancelled_ms >= 0, "hard-cancel capture accounts active and queued work")
	_check(scheduler.drain_performance_capture().cancelled_count == 0, "atomic rotation returns cancellation tail only once")
	scheduler.submit(_job(4, Vector3i.ZERO, 2))
	_check(_wait_idle(scheduler), "result available before invalidation")
	scheduler.invalidate(3)
	_check(scheduler.take_result().is_empty(), "invalidation drops previously published old epoch")
	scheduler.stop()


func _test_publication_cancel() -> void:
	var scheduler = _gated_scheduler([1])
	var state: GatedState = scheduler._state
	scheduler.submit(_job(1, Vector3i.ZERO))
	_check(_wait_gate(state), "single-candidate job pauses after finishing kernel")
	scheduler.invalidate(2)
	state.release.post()
	_check(_wait_idle(scheduler), "completed kernel observes invalidation before publication")
	_check(scheduler.take_result().is_empty() and scheduler.get_stats().cancelled_count == 1, "publication check suppresses jobs smaller than 256 candidates")
	scheduler.stop()


func _test_capture_epochs() -> void:
	var scheduler = _gated_scheduler([1, 3, 5])
	var state: GatedState = scheduler._state
	scheduler.submit(_job(1))
	_check(_wait_gate(state), "disabled capture job enters latch")
	scheduler.submit(_job(2))
	scheduler.set_performance_capture(true)
	state.release.post()
	_check(_wait_idle(scheduler), "disabled capture jobs still publish after enable")
	_check(scheduler.drain_performance_capture().completed_count == 0, "old active AND pending jobs excluded from new capture")
	scheduler.take_result()
	scheduler.submit(_job(3))
	_check(_wait_gate(state), "captured job enters latch")
	scheduler.set_performance_capture(true)
	state.release.post()
	_check(_wait_idle(scheduler), "true-to-true reset preserves valid publication")
	_check(scheduler.drain_performance_capture().completed_count == 0, "old capture completion excluded after reset")
	scheduler.submit(_job(4))
	_check(_wait_idle(scheduler), "current capture job replaces old capture result")
	var totals: Dictionary = scheduler.drain_performance_capture()
	_check(totals.completed_count == 1 and totals.replaced_result_count == 0, "replacing old capture result does not leak its accounting")
	scheduler.submit(_job(5, Vector3i(999, 0, 0)))
	_check(_wait_gate(state), "old capture cancellation enters latch")
	scheduler.set_performance_capture(false)
	scheduler.set_performance_capture(true)
	scheduler.invalidate(2)
	state.release.post()
	_check(_wait_idle(scheduler), "cancel after capture lifecycle change")
	totals = scheduler.drain_performance_capture()
	_check(totals.cancelled_count == 0 and totals.completed_count == 0, "old capture cancellation excluded")
	scheduler.submit(_job(6, Vector3i.ZERO, 2))
	_check(_wait_idle(scheduler), "capture still works after resets")
	_check(scheduler.get_stats().completed_count == 5, "lifetime accounting survives capture resets")
	_check(scheduler.drain_performance_capture().completed_count == 1, "snapshots do not drain capture")
	for value in scheduler.drain_performance_capture().values():
		_check(value == 0, "second drain returns numeric zero")
	scheduler.set_performance_capture(false)
	scheduler.submit(_job(7, Vector3i.ZERO, 2))
	_check(_wait_idle(scheduler), "disabled capture job completes")
	for value in scheduler.drain_performance_capture().values():
		_check(value == 0, "disabled capture accumulates no totals")
	scheduler.stop()


func _test_atomic_capture_rotation() -> void:
	for next_enabled in [true, false]:
		var scheduler = _gated_scheduler([2, 3])
		var state: GatedState = scheduler._state
		scheduler.set_performance_capture(true)
		scheduler.submit(_job(1, Vector3i.ZERO))
		_check(_wait_idle(scheduler), "capture prefix completes")
		_check(scheduler.drain_performance_capture().completed_count == 1, "capture prefix drained once")
		scheduler.take_result()
		scheduler.submit(_job(2, Vector3i.ZERO))
		_check(_wait_gate(state), "capture tail pauses before publication")
		_check(scheduler.drain_performance_capture().completed_count == 0, "drain before tail publication is empty")
		state.release.post()
		_check(_wait_idle(scheduler), "tail publishes between drain and lifecycle reset")
		var result: Dictionary = scheduler.take_result()
		var tail: Dictionary = scheduler.set_performance_capture(next_enabled)
		_check(tail.completed_count == 1, "atomic reset/disable returns completion after preceding drain")
		_check(is_equal_approx(tail.completed_ms, float(result.worker_usec) / 1000.0), "atomic rotation preserves completed duration")
		_check(is_equal_approx(tail.queue_wait_ms, float(result.queue_wait_usec) / 1000.0), "atomic rotation preserves queue wait duration")
		tail.completed_count = 999
		for value in scheduler.drain_performance_capture().values():
			_check(value == 0, "returned tail is detached from next capture")
		# Exercise the other boundary order: rotate while publication is gated.
		scheduler.submit(_job(3, Vector3i.ZERO))
		_check(_wait_gate(state), "old epoch completion pauses across next rotation")
		_check(scheduler.set_performance_capture(true).completed_count == 0, "rotation cannot include unpublished work")
		state.release.post()
		_check(_wait_idle(scheduler), "old capture work still publishes after rotation")
		_check(scheduler.drain_performance_capture().completed_count == 0, "late old capture completion never leaks into new capture")
		scheduler.stop()


func _test_retirement_outside_lock() -> void:
	var scheduler := Scheduler.new()
	scheduler.force_start_failure = true
	scheduler.start()
	scheduler.invalidate(1)
	var state: RefCounted = scheduler._state
	var audit := ReleaseAudit.new()
	audit.mutex = state.mutex
	# Private test-only probes expose actual last-reference destruction. Jobs
	# submitted through the public API still reject all object payloads.
	state.pending = {"probe": ReleaseProbe.new(audit)}
	state.result = {"probe": ReleaseProbe.new(audit)}
	scheduler.invalidate(1)
	_check(audit.unlocked.size() == 2, "invalidate releases pending and result owners")
	state.pending = {"probe": ReleaseProbe.new(audit)}
	scheduler.submit(_job(1, Vector3i.ZERO))
	_check(audit.unlocked.size() == 3, "submit releases replaced pending owner")
	state.kernel = RetiringKernel.new(_job(2, Vector3i.ZERO, 0), audit)
	scheduler.pump_fallback(1, 0)
	_check(audit.unlocked.size() == 4, "pre-advance epoch cancellation releases kernel")
	state.result = {"probe": ReleaseProbe.new(audit)}
	state.kernel = RetiringKernel.new(_job(3, Vector3i.ZERO), audit)
	scheduler.pump_fallback(1, 0)
	_check(audit.unlocked.size() == 6, "completion releases old result and finished kernel")
	state.pending = {"probe": ReleaseProbe.new(audit)}
	state.result = {"probe": ReleaseProbe.new(audit)}
	state.kernel = RetiringKernel.new(_job(4), audit)
	scheduler.stop()
	_check(audit.unlocked.size() == 9, "shutdown releases all three owners")
	var invalidating := InvalidatingState.new()
	scheduler._state = invalidating
	audit.mutex = invalidating.mutex
	scheduler.start()
	scheduler.invalidate(1)
	invalidating.kernel = RetiringKernel.new(_job(5, Vector3i.ZERO), audit)
	scheduler.pump_fallback(1, 0)
	_check(audit.unlocked.size() == 10, "post-advance epoch cancellation releases kernel")
	for unlocked in audit.unlocked:
		_check(unlocked, "last owner destruction occurs outside scheduler mutex")
	scheduler.stop()


static func _release_when_stopping(state: GatedState) -> void:
	var deadline := Time.get_ticks_msec() + WAIT_MS
	while Time.get_ticks_msec() < deadline:
		state.mutex.lock()
		var stopping := state.stopping
		state.mutex.unlock()
		if stopping:
			break
		OS.delay_msec(1)
	state.release.post()


func _test_stop_and_predelete() -> void:
	var scheduler = _gated_scheduler([1])
	var state: GatedState = scheduler._state
	scheduler.submit(_job(1, Vector3i(4095, 0, 0)))
	_check(_wait_gate(state), "stop test worker enters latch")
	scheduler.submit(_job(2))
	var releaser := Thread.new()
	_check(releaser.start(_release_when_stopping.bind(state)) == OK, "stop latch releaser starts")
	var worker: Thread = scheduler._thread
	scheduler.stop()
	releaser.wait_to_finish()
	_check(not worker.is_started(), "stop joins dedicated worker")
	var stats: Dictionary = scheduler.get_stats()
	_check(stats.pending == 0 and stats.in_flight == 0 and stats.result_pending == 0, "stop clears all slots")
	_check(stats.cancelled_count == 2 and stats.processed_steps == 256, "stop bounds active work and drops pending")
	scheduler.stop()
	_check(scheduler.start(), "scheduler can restart after explicit stop")
	scheduler.submit(_job(3, Vector3i.ZERO))
	_check(_wait_idle(scheduler) and scheduler.take_result().get("request_id") == 3, "restart has no lost wakeup")
	scheduler.stop()
	var automatic = Scheduler.new()
	_check(automatic.start(), "PREDELETE idle thread starts")
	var automatic_thread: Thread = automatic._thread
	var automatic_state: RefCounted = automatic._state
	automatic = null
	_check(not automatic_thread.is_started() and automatic_state.stopping, "PREDELETE wakes and joins idle worker without self-retention")
	var active_automatic = _gated_scheduler([10])
	var active_state: GatedState = active_automatic._state
	active_automatic.submit(_job(10, Vector3i(999, 0, 0)))
	_check(_wait_gate(active_state), "PREDELETE active worker reaches latch")
	var active_thread: Thread = active_automatic._thread
	var active_releaser := Thread.new()
	_check(active_releaser.start(_release_when_stopping.bind(active_state)) == OK, "PREDELETE active releaser starts")
	active_automatic = null
	active_releaser.wait_to_finish()
	_check(not active_thread.is_started() and active_state.kernel == null, "PREDELETE cancels and joins active worker")
	var fallback = Scheduler.new()
	fallback.force_start_failure = true
	fallback.start()
	fallback.invalidate(1)
	fallback.submit(_job(9))
	fallback.pump_fallback(1, 0)
	var fallback_state: RefCounted = fallback._state
	fallback = null
	_check(fallback_state.stopping and fallback_state.kernel == null, "PREDELETE cleans partial fallback")
