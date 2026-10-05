extends SceneTree

## Contract tests for the isolated playtest controller and its simulation gate.
## This suite deliberately uses bounded fakes for the controller protocol, then
## exercises the real World.update_world_controlled implementation separately.

const Controller = preload("res://scripts/playtest/playtest_controller.gd")
const MainScript = preload("res://scripts/Main.gd")
const Transport = preload("res://scripts/playtest/playtest_transport.gd")

class FakeViewport extends RefCounted:
	func get_visible_rect() -> Rect2:
		return Rect2(Vector2.ZERO, Vector2(800, 600))


class FakeInspector extends RefCounted:
	var current_id := "view-1"

	func view_id() -> String:
		return current_id


class FakeService extends RefCounted:
	var world_epoch := 1


class FakeDiagnostics extends RefCounted:
	var service := FakeService.new()
	var inspector := FakeInspector.new()


class FakeSelection extends RefCounted:
	signal selection_feedback(message: String)
	var stair_rotation := 0
	var is_dragging := false


class FakeContext extends RefCounted:
	signal action_feedback(message: String)


class FakeTask extends RefCounted:
	var id: int
	var status: int

	func _init(task_id: int, task_status: int) -> void:
		id = task_id
		status = task_status


class FakeTaskQueue extends RefCounted:
	signal task_added(task)
	signal task_visual_state_changed(id)
	var tasks: Dictionary = {}

	func get_task(id: int):
		return tasks.get(id, null)


class FakeWorld extends RefCounted:
	var world_size_y := 8
	var top_render_y := 0
	var player_mode := 0
	var task_queue := FakeTaskQueue.new()
	var diagnostics_workers_by_id: Dictionary = {}

	func is_block_coord_valid(_x: int, y: int, _z: int) -> bool:
		return y >= 0 and y < world_size_y

	func set_top_render_y(value: int) -> void:
		top_render_y = value

	func get_chunk(_coord: Vector3i):
		return null

	func get_block_no_generate(_x: int, _y: int, _z: int) -> int:
		return 0


class FakeCameraController extends RefCounted:
	var cam_zoom_min := 1.0
	var cam_zoom_max := 100.0
	var reset_count := 0
	var cam_pitch := 0.0
	var cam_yaw := 0.0

	func reset_mouse_state() -> void:
		reset_count += 1

	func _apply_camera_rotation() -> void:
		pass

	func _clamp_camera_to_world() -> void:
		pass


class FakeCamera extends RefCounted:
	var position := Vector3.ZERO
	var rotation := Vector3.ZERO
	var size := 10.0


class FakeInputState extends RefCounted:
	var pointer := Vector2.ZERO


class FakeMain extends RefCounted:
	var diagnostics_controller := FakeDiagnostics.new()
	var selection_controller := FakeSelection.new()
	var context_menu_controller := FakeContext.new()
	var world := FakeWorld.new()
	var camera_controller := FakeCameraController.new()
	var camera := FakeCamera.new()
	var input_state := FakeInputState.new()
	var menu_open := false
	var loading_active := false
	var world_started := true

	func get_viewport() -> FakeViewport:
		return FakeViewport.new()


class FakeGestures extends RefCounted:
	var compile_count := 0
	var deliver_count := 0
	var finish_count := 0
	var cancel_count := 0
	var delivering := false

	func compile(_events: Array) -> Dictionary:
		compile_count += 1
		return {"stages": [{"type": "noop"}]}

	func deliver(_stage: Dictionary) -> Dictionary:
		deliver_count += 1
		return {}

	func finish() -> void:
		finish_count += 1

	func cancel() -> void:
		cancel_count += 1


class FakeObserver extends RefCounted:
	func tick() -> void:
		pass

	func shutdown() -> void:
		pass

	func request(_args: Dictionary) -> Dictionary:
		return {"operation_id": "observation-1"}

	func status(_id: String) -> Dictionary:
		return {"state": "pending"}


class FakeTransport extends RefCounted:
	func poll(_handler: Callable, _now_usec: int) -> void:
		pass

	func stop() -> void:
		pass


class FakeStepController extends RefCounted:
	var advance_this_frame := false
	var did_advance_count := 0

	func did_advance() -> void:
		did_advance_count += 1


class ProbeMain extends "res://scripts/Main.gd":
	func update_camera(_dt: float) -> void:
		pass

	func get_stream_view_rect() -> Rect2:
		return Rect2(Vector2.ZERO, Vector2(64, 64))

	func handle_mouse() -> void:
		pass

	func update_hover_preview() -> void:
		pass

	func update_info_hover() -> void:
		pass


class ProbeWorld extends World:
	var generation_calls := 0
	var render_height_calls := 0
	var assignment_calls := 0
	var worker_calls := 0
	var queue_calls := 0
	var accessibility_calls := 0
	var reassign_calls := 0
	var overlay_calls := 0

	func process_generation_results() -> void:
		generation_calls += 1

	func update_render_height_queue() -> void:
		render_height_calls += 1

	func update_task_assignments() -> void:
		assignment_calls += 1

	func update_workers(_dt: float) -> void:
		worker_calls += 1

	func update_task_queue() -> void:
		queue_calls += 1

	func update_task_accessibility() -> void:
		accessibility_calls += 1

	func update_reassign_tasks(_dt: float) -> void:
		reassign_calls += 1

	func update_task_overlays_phase() -> void:
		overlay_calls += 1

	func update_streaming(_view_rect: Rect2, _plane_y: float, _dt: float, _camera: Camera3D = null,
		_render_band_rects: Dictionary = {}) -> void:
		pass


var _checks := 0
var _errors: Array[String] = []
var _root := ""


func _init() -> void:
	_run.call_deferred()


func _run() -> void:
	_root = ProjectSettings.globalize_path("res://.playtest/test-control").path_join("%d-%d" % [OS.get_process_id(), Time.get_ticks_usec()])
	DirAccess.make_dir_recursive_absolute(_root)
	_test_native_mode_is_quiet()
	_test_ordered_receipts_and_eviction()
	_test_stale_identity_and_view()
	_test_invalid_args_are_atomic()
	_test_busy_and_cancel_release()
	_test_window_guard_and_observation_validation()
	_test_advance_steps_are_simulation_steps()
	_test_pause_does_not_progress_world()
	_test_missing_task_conditions_do_not_succeed()
	_cleanup()
	if _errors.is_empty():
		print("PLAYTEST_CONTROL_OK: %d checks" % _checks)
		quit(0)
	else:
		for error in _errors:
			push_error(error)
		quit(1)


func _new_controller(label: String):
	var controller: Variant = Controller.new()
	controller.main = FakeMain.new()
	controller.run_id = label
	controller.session_id = "session-1"
	controller.ready = true
	controller.gestures = FakeGestures.new()
	controller.observer = FakeObserver.new()
	controller.transport = FakeTransport.new()
	var journal_path := _root.path_join(label + ".jsonl")
	controller.journal = FileAccess.open(journal_path, FileAccess.WRITE)
	return controller


func _base_args(controller: Controller, sequence: int) -> Dictionary:
	return {"session_id": controller.session_id, "seq": sequence,
		"world_epoch": controller.main.diagnostics_controller.service.world_epoch,
		"view_id": controller.main.diagnostics_controller.inspector.view_id()}


func _set_view_args(controller: Controller, sequence: int) -> Dictionary:
	var args := _base_args(controller, sequence)
	args.merge({"view_id": controller.main.diagnostics_controller.inspector.view_id(),
		"position": [0, 0, 0], "rotation": [0, 0, 0], "size": 10.0, "render_level": 0})
	return args


func _test_native_mode_is_quiet() -> void:
	var main_probe = MainScript.new()
	_check(not main_probe.playtest_mode, "native Main defaults to playtest mode off")
	_check(main_probe.playtest_controller == null, "native Main has no playtest controller")
	var transport = Transport.new()
	_check(not transport.enabled and transport.port == 0, "native playtest transport has no listener")
	main_probe.free()


func _test_ordered_receipts_and_eviction() -> void:
	var controller: Variant = _new_controller("receipts")
	var first: Dictionary = controller.dispatch("set_view", _set_view_args(controller, 1))
	var duplicate: Dictionary = controller.dispatch("set_view", _set_view_args(controller, 1))
	_check(first.get("state", "") == "complete", "first ordered receipt completes")
	_check(duplicate == first, "duplicate sequence returns the original receipt idempotently")
	for sequence in range(2, 132):
		var receipt: Dictionary = controller.dispatch("pause", _base_args(controller, sequence))
		_check(not receipt.has("error"), "ordered pause receipt %d accepted" % sequence)
	var evicted: Dictionary = controller.dispatch("pause", _base_args(controller, 1))
	_check(evicted.get("error", "") == "discarded_sequence", "evicted old sequence is rejected")
	_dispose_controller(controller)


func _test_stale_identity_and_view() -> void:
	var controller: Variant = _new_controller("stale")
	var wrong_session := _base_args(controller, 1)
	wrong_session.session_id = "other-session"
	_check(controller.dispatch("pause", wrong_session).get("error", "") == "stale_session", "stale session is rejected")
	var wrong_world := _base_args(controller, 1)
	wrong_world.world_epoch = 99
	_check(controller.dispatch("pause", wrong_world).get("error", "") == "stale_world", "stale world is rejected")
	var wrong_view := _set_view_args(controller, 1)
	wrong_view.view_id = "view-old"
	_check(controller.dispatch("set_view", wrong_view).get("error", "") == "stale_view", "stale view is rejected")
	_check(controller.last_sequence == 0 and controller.receipts.is_empty(), "stale requests do not consume sequence state")
	_dispose_controller(controller)


func _test_invalid_args_are_atomic() -> void:
	var controller: Variant = _new_controller("invalid")
	var invalid := _base_args(controller, 1)
	invalid["events"] = "not-an-array"
	var response: Dictionary = controller.dispatch("act", invalid)
	_check(response.get("error", "") == "events_required", "invalid act arguments are rejected")
	_check(controller.last_sequence == 0 and controller.active.is_empty() and controller.receipts.is_empty(),
		"invalid arguments do not mutate receipt or active state")
	var valid := _base_args(controller, 1)
	valid["events"] = []
	var accepted: Dictionary = controller.dispatch("act", valid)
	_check(not accepted.has("error") and controller.last_sequence == 1, "valid sequence remains usable after invalid request")
	_dispose_controller(controller)


func _test_busy_and_cancel_release() -> void:
	var controller: Variant = _new_controller("cancel")
	var gestures: FakeGestures = controller.gestures
	var act := _base_args(controller, 1)
	act["events"] = [{"type": "noop"}]
	_check(not controller.dispatch("act", act).has("error"), "act starts a cancellable operation")
	var busy: Dictionary = controller.dispatch("advance", {"session_id": controller.session_id, "seq": 2,
		"world_epoch": 1, "steps": 1})
	_check(busy.get("error", "") == "busy", "second operation is rejected while busy")
	var release := InputEventMouseButton.new()
	release.button_index = MOUSE_BUTTON_LEFT
	release.pressed = false
	_check(controller.observe_physical_input(release), "physical release is consumed by playtest control")
	_check(controller.active.is_empty() and gestures.cancel_count >= 1 and gestures.finish_count == 0,
		"cancelled release clears input without accidental commit")
	_dispose_controller(controller)


func _test_window_guard_and_observation_validation() -> void:
	var controller: Variant = _new_controller("window-guard")
	controller._install_existing_window_guards(root)
	_check(controller._guarded_windows.size() >= 1, "existing window receives a physical-input guard")
	var act := _base_args(controller, 1)
	act["events"] = [{"type": "noop"}]
	_check(not controller.dispatch("act", act).has("error"), "window guard test starts an active gesture")
	var gestures: FakeGestures = controller.gestures
	var synthetic := InputEventKey.new()
	synthetic.keycode = KEY_A
	synthetic.physical_keycode = KEY_A
	synthetic.pressed = true
	gestures.delivering = true
	root.push_input(synthetic, true)
	_check(not controller.active.is_empty() and gestures.cancel_count == 0,
		"synthetic event passes the window guard during gesture delivery")
	gestures.delivering = false
	var physical := InputEventKey.new()
	physical.keycode = KEY_B
	physical.physical_keycode = KEY_B
	physical.pressed = true
	root.push_input(physical, true)
	_check(controller.active.is_empty() and gestures.cancel_count >= 1 and gestures.finish_count == 0,
		"physical window event cancels the active gesture without committing it")
	var valid_observe := _base_args(controller, 1)
	valid_observe["tasks"] = [1, 2]
	_check(not controller._validate("observe", valid_observe).has("error"),
		"bounded observation query is accepted")
	var too_many: Array = []
	for index in range(129): too_many.append(index)
	var over_limit := _base_args(controller, 1)
	over_limit["tasks"] = too_many
	_check(controller._validate("observe", over_limit).get("error", "") == "observation_query_limit",
		"observation query limit rejects more than 128 entries")
	var malformed_id := _base_args(controller, 1)
	malformed_id["tasks"] = [-1]
	_check(controller._validate("observe", malformed_id).get("error", "") == "invalid_observation_id",
		"malformed observation task id is rejected")
	var malformed_cell := _base_args(controller, 1)
	malformed_cell["cells"] = [[1, 2]]
	_check(controller._validate("observe", malformed_cell).get("error", "") == "invalid_observation_position",
		"malformed observation cell is rejected")
	_dispose_controller(controller)


func _test_advance_steps_are_simulation_steps() -> void:
	var controller: Variant = _new_controller("steps")
	var args := _base_args(controller, 1)
	args["steps"] = 3
	_check(not controller.dispatch("advance", args).has("error"), "advance operation starts")
	var draw_count := 0
	for _index in range(3):
		controller.begin_frame()
		_check(controller.advance_this_frame, "advance requests one controlled simulation frame")
		draw_count += 7
		controller.did_advance()
		controller.end_frame()
	_check(controller.simulation_steps == 3 and draw_count == 21, "step count is independent of draw count")
	_check(controller.active.is_empty() and controller.receipts[1].state == "complete", "advance completes at requested step count")
	_dispose_controller(controller)


func _test_pause_does_not_progress_world() -> void:
	var world := ProbeWorld.new()
	var main := ProbeMain.new()
	var stepper := FakeStepController.new()
	main.world = world
	main.playtest_mode = true
	main.playtest_controller = stepper
	main._run_shared_updates(1.0 / 60.0)
	_check(world.generation_calls == 1 and world.render_height_calls == 1 and world.overlay_calls == 1,
		"paused controlled world still services generation and overlays")
	_check(world.assignment_calls == 0 and world.worker_calls == 0 and world.queue_calls == 0 and
		world.accessibility_calls == 0 and world.reassign_calls == 0,
		"paused controlled world does not progress workers or tasks")
	_check(stepper.did_advance_count == 0, "paused Main does not count a simulation step")
	stepper.advance_this_frame = true
	main._run_shared_updates(1.0 / 60.0)
	_check(world.assignment_calls == 1 and world.worker_calls == 1 and world.queue_calls == 1 and
		world.accessibility_calls == 1 and world.reassign_calls == 1,
		"controlled world advances worker and task phases when enabled")
	_check(stepper.did_advance_count == 1, "Main counts one controlled simulation step")
	main.free()
	world.free()


func _test_missing_task_conditions_do_not_succeed() -> void:
	var controller: Variant = _new_controller("conditions")
	var no_history := {"kind": "task_state", "id": 7, "status": "completed"}
	_check(not controller._condition_met(no_history), "missing task alone does not imply completion")
	controller.observed_tasks[8] = {"status": 0, "world_epoch": 1}
	var pending_history := {"kind": "task_state", "id": 8, "status": "completed"}
	_check(not controller._condition_met(pending_history), "pending task history does not imply completion")
	controller.main.world.task_queue.tasks[9] = FakeTask.new(9, 2)
	controller.main.world.task_queue.task_visual_state_changed.connect(controller._on_task_changed)
	controller.main.world.task_queue.task_visual_state_changed.emit(9)
	controller.main.world.task_queue.tasks.erase(9)
	var completed_history := {"kind": "task_state", "id": 9, "status": "completed"}
	_check(controller._condition_met(completed_history), "observed completed task history resolves after removal")
	controller.observed_tasks[10] = {"status": 2, "world_epoch": 0}
	var old_world := {"kind": "task_state", "id": 10, "status": "completed"}
	_check(not controller._condition_met(old_world), "old-world task history is rejected")
	_dispose_controller(controller)


func _dispose_controller(controller: Variant) -> void:
	if controller == null:
		return
	var task_queue: Variant = controller.main.world.task_queue
	var changed := Callable(controller, "_on_task_changed")
	if task_queue.task_visual_state_changed.is_connected(changed):
		task_queue.task_visual_state_changed.disconnect(changed)
	controller.shutdown()
	controller.main = null
	controller.gestures = null
	controller.observer = null
	controller.transport = null


func _cleanup() -> void:
	if _root.is_empty() or not DirAccess.dir_exists_absolute(_root):
		return
	var directory := DirAccess.open(_root)
	if directory != null:
		directory.list_dir_begin()
		var name := directory.get_next()
		while not name.is_empty():
			if not directory.current_is_dir():
				directory.remove(name)
			name = directory.get_next()
		directory.list_dir_end()
	DirAccess.remove_absolute(_root)


func _check(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_errors.append(message)
