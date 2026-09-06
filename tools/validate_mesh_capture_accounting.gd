extends SceneTree
## Isolated scheduler loss-accounting contract; no renderer or scene startup.

const SchedulerScript = preload("res://scripts/rendering/world_renderer_mesh_scheduler.gd")
const WAIT_MS := 5000
var failures := 0


class RecorderProbe extends RefCounted:
	var enabled := true
	var counters := {}
	var timings := {}

	func add_counter(label: String, count: int = 1) -> void:
		counters[label] = int(counters.get(label, 0)) + count

	func add_timing(label: String, elapsed_ms: float) -> void:
		var values: Array = timings.get(label, [])
		values.append(elapsed_ms)
		timings[label] = values


class BuildGate extends RefCounted:
	var entered := Semaphore.new()
	var release := Semaphore.new()
	var gated := false

	func build(job: Dictionary) -> Dictionary:
		if gated:
			entered.post()
			release.wait()
		return {"coord": job.coord, "build_ms": 7.5}


func _init() -> void:
	_test_delivery_and_queue_discards()
	for clear_all in [false, true]:
		_test_suppressed_completion(clear_all)
	_test_capture_boundaries()
	_test_renderer_drain()
	if failures:
		push_error("Mesh capture accounting failed: %d" % failures)
		quit(1)
	else:
		print("Mesh capture accounting OK (delivery, cancellation, clear, suppression, capture epochs)")
		quit(0)


func _check(ok: bool, message: String) -> void:
	if not ok:
		failures += 1
		push_error(message)


func _wait_pending(scheduler, count: int) -> bool:
	var deadline := Time.get_ticks_msec() + WAIT_MS
	while Time.get_ticks_msec() < deadline:
		if int(scheduler.get_performance_snapshot().results_pending) == count:
			return true
		OS.delay_msec(1)
	return false


func _wait_idle(scheduler) -> bool:
	var deadline := Time.get_ticks_msec() + WAIT_MS
	while Time.get_ticks_msec() < deadline:
		var snapshot: Dictionary = scheduler.get_performance_snapshot()
		if snapshot.queued == 0 and snapshot.in_flight == 0:
			return true
		OS.delay_msec(1)
	return false


func _wait_gate(gate: BuildGate) -> bool:
	var deadline := Time.get_ticks_msec() + WAIT_MS
	while Time.get_ticks_msec() < deadline:
		if gate.entered.try_wait():
			return true
		OS.delay_msec(1)
	return false


func _new_scheduler(gate: BuildGate):
	var scheduler = SchedulerScript.new()
	scheduler.configure(gate.build, 32, 500)
	scheduler.start(true)
	return scheduler


func _enqueue(scheduler, x: int) -> void:
	scheduler.enqueue_visible_job({"coord": Vector3i(x, 0, 0)}, 1, false)


func _test_delivery_and_queue_discards() -> void:
	var gate := BuildGate.new()
	var scheduler = _new_scheduler(gate)
	_enqueue(scheduler, 0)
	_check(_wait_pending(scheduler, 1), "disabled build completes")
	scheduler.pop_result()
	_check(scheduler.drain_performance_capture().completed_count == 0, "disabled builds do not accumulate")
	scheduler.set_performance_capture_enabled(true)
	for x in range(3):
		_enqueue(scheduler, x)
	_check(_wait_pending(scheduler, 3), "three captured builds publish")
	var completed: Dictionary = scheduler.drain_performance_capture()
	_check(completed.completed_count == 3 and completed.completed_ms == 22.5, "all completed costs counted once")
	scheduler.cancel_coord(Vector3i(1, 0, 0))
	var result: Dictionary = scheduler.pop_result()
	_check(scheduler.is_result_in_performance_capture(result), "delivered result belongs to capture")
	scheduler.clear()
	var totals: Dictionary = scheduler.drain_performance_capture()
	_check(totals.completed_count == 0, "drain does not repeat completions")
	_check(totals.delivered_count == 1 and totals.delivered_ms == 7.5, "delivery counted once")
	_check(totals.discarded_pending_count == 2 and totals.discarded_pending_ms == 15.0, "cancel and clear preserve discarded costs after prior drain")
	_check(totals.lost_before_publication_count == 0, "queue discards are distinct from suppression")
	scheduler.clear()
	_check(scheduler.drain_performance_capture().discarded_pending_count == 0, "repeated clear/drain does not duplicate costs")
	scheduler.stop()


func _test_suppressed_completion(clear_all: bool) -> void:
	var gate := BuildGate.new()
	gate.gated = true
	var scheduler = _new_scheduler(gate)
	scheduler.set_performance_capture_enabled(true)
	_enqueue(scheduler, 4)
	_check(_wait_gate(gate), "build reached publication barrier")
	if clear_all:
		scheduler.clear()
	else:
		scheduler.cancel_coord(Vector3i(4, 0, 0))
	gate.release.post()
	_check(_wait_idle(scheduler), "invalidated build finishes")
	_check(scheduler.pop_result().is_empty(), "invalidation still suppresses publication")
	var totals: Dictionary = scheduler.drain_performance_capture()
	_check(totals.completed_count == 1 and totals.completed_ms == 7.5, "suppressed completion cost retained")
	_check(totals.lost_before_publication_count == 1 and totals.lost_before_publication_ms == 7.5, "suppressed cost classified once")
	_check(totals.delivered_count == 0 and totals.discarded_pending_count == 0, "suppression is not delivery or pending discard")
	scheduler.stop()


func _test_capture_boundaries() -> void:
	var gate := BuildGate.new()
	var scheduler = _new_scheduler(gate)
	scheduler.set_performance_capture_enabled(true)
	_enqueue(scheduler, 5)
	_check(_wait_pending(scheduler, 1), "old capture pending result")
	var old_totals: Dictionary = scheduler.set_performance_capture_enabled(true)
	_check(old_totals.completed_count == 1, "atomic boundary returns final old totals")
	var old_result: Dictionary = scheduler.pop_result()
	_check(not scheduler.is_result_in_performance_capture(old_result), "old pending result excluded after reset")
	_check(scheduler.drain_performance_capture().delivered_count == 0, "old pending delivery cannot leak")
	gate.gated = true
	_enqueue(scheduler, 6)
	_check(_wait_gate(gate), "old in-flight build reached barrier")
	scheduler.set_performance_capture_enabled(false)
	scheduler.set_performance_capture_enabled(true)
	gate.release.post()
	_check(_wait_pending(scheduler, 1), "capture reset preserves valid mesh publication")
	var result: Dictionary = scheduler.pop_result()
	_check(not scheduler.is_result_in_performance_capture(result), "old in-flight build excluded from new capture")
	var totals: Dictionary = scheduler.drain_performance_capture()
	_check(totals.completed_count == 0 and totals.delivered_count == 0, "no in-flight costs leak across capture boundary")
	_enqueue(scheduler, 10)
	_check(_wait_gate(gate), "old-world build reached barrier")
	scheduler.clear()
	scheduler.set_performance_capture_enabled(false)
	scheduler.set_performance_capture_enabled(true)
	gate.release.post()
	_check(_wait_idle(scheduler), "old-world invalidated build finishes")
	_check(scheduler.pop_result().is_empty(), "world clear still suppresses old build after new capture")
	var after_world: Dictionary = scheduler.drain_performance_capture()
	_check(after_world.completed_count == 0 and after_world.lost_before_publication_count == 0, "old-world suppressed costs cannot leak into new capture")
	scheduler.stop()


func _test_renderer_drain() -> void:
	var world := World.new()
	var renderer := WorldRenderer.new()
	world.add_child(renderer)
	renderer.add_child(renderer.chunk_cache)
	renderer.add_child(renderer.overlay_renderer)
	renderer.world = world
	var probe := RecorderProbe.new()
	world.performance_recorder = probe
	var gate := BuildGate.new()
	var scheduler = renderer.mesh_scheduler
	scheduler.configure(gate.build, 32, 500)
	scheduler.start(true)
	renderer.set_performance_capture_enabled(true)
	_enqueue(scheduler, 7)
	_enqueue(scheduler, 8)
	_check(_wait_pending(scheduler, 2), "renderer probe builds complete")
	scheduler.clear()
	renderer.get_performance_snapshot()
	_check(probe.counters.is_empty(), "snapshot never drains telemetry")
	renderer.drain_performance_capture()
	_check(probe.counters.get("Mesh.scheduler.completed") == 2, "renderer emits completion denominator")
	_check(probe.counters.get("Mesh.scheduler.discarded_pending") == 2, "renderer emits discard denominator")
	_check(probe.timings.get("Mesh.scheduler.discarded_pending_build_ms_sum") == [15.0], "two discarded jobs emit one honestly labeled elapsed sum")
	renderer.drain_performance_capture()
	_check(probe.timings.get("Mesh.scheduler.discarded_pending_build_ms_sum") == [15.0], "repeated renderer drain emits nothing")
	_enqueue(scheduler, 9)
	_check(_wait_pending(scheduler, 1), "boundary tail build completes")
	renderer.set_performance_capture_enabled(false)
	_check(probe.counters.get("Mesh.scheduler.completed") == 3, "disable atomically forwards undrained tail before recorder stop")
	renderer.set_performance_capture_enabled(true)
	var old_result: Dictionary = scheduler.pop_result()
	scheduler.cancel_coord(Vector3i(9, 0, 0))
	_check(not renderer._apply_mesh_result(old_result), "old-capture invalidated payload still rejected")
	_check(not probe.timings.has("Mesh.completed.build_ms"), "old marked payload cannot add per-job build cost")
	_enqueue(scheduler, 11)
	_check(_wait_pending(scheduler, 1), "current marked payload completes")
	var current_result: Dictionary = scheduler.pop_result()
	scheduler.cancel_coord(Vector3i(11, 0, 0))
	_check(not renderer._apply_mesh_result(current_result), "current marked payload stale at handoff")
	renderer.drain_performance_capture()
	_check(probe.counters.get("Mesh.built") == 1 and probe.counters.get("Mesh.scheduler.delivered") == 1, "handoff and scheduler use distinct single-count denominators")
	_check(probe.timings.get("Mesh.completed.build_ms") == [7.5], "scheduler aggregate never duplicates per-job returned timing")
	scheduler.stop()
	world.free()
