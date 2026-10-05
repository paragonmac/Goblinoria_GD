extends RefCounted
## Development-only control of a separately bootstrapped, isolated game.
const Transport = preload("res://scripts/playtest/playtest_transport.gd")
const Gestures = preload("res://scripts/playtest/playtest_gestures.gd")
const Observer = preload("res://scripts/playtest/playtest_observer.gd")
const Plain = preload("res://scripts/diagnostics/live_diagnostics_service.gd")
const SIMULATION_DELTA := 1.0 / 60.0
const RECEIPT_LIMIT := 128
const JOURNAL_LIMIT := 16 * 1024 * 1024

class WindowInputGuard extends Node:
	var controller_ref: WeakRef
	func _input(event: InputEvent) -> void:
		var controller = controller_ref.get_ref()
		if controller != null and controller.observe_physical_input(event):
			get_viewport().set_input_as_handled()

var main
var transport = Transport.new()
var gestures = Gestures.new()
var observer = Observer.new()
var run_root := ""
var run_id := ""
var session_id := Crypto.new().generate_random_bytes(16).hex_encode()
var scenario: Dictionary = {}
var ready := false
var advance_this_frame := false
var simulation_steps := 0
var last_sequence := 0
var active: Dictionary = {}
var receipts: Dictionary = {}
var observed_tasks: Dictionary = {}
var recent_feedback: Array = []
var recent_task_ids: Array = []
var journal: FileAccess
var startup_error := ""
var source: Dictionary = {}
var _shutdown_frames := -1
var _closed := false
var _advanced := false
var _guarded_windows: Dictionary = {}


func initialize(owner, directory: String, identity: String, definition: Dictionary = {}) -> void:
	main = owner
	main.get_tree().node_added.connect(_on_node_added)
	_install_existing_window_guards(main.get_tree().root)
	run_root = directory
	run_id = identity
	scenario = definition.duplicate(true)
	gestures.initialize(main)
	observer.initialize(main, self, run_root)
	transport.descriptor_root = run_root.path_join("control")
	journal = FileAccess.open(run_root.path_join("actions.jsonl"), FileAccess.WRITE)
	if journal == null:
		startup_error = "journal_unwritable"
		return
	var metadata_path := run_root.path_join("session.json")
	if FileAccess.file_exists(metadata_path):
		var parsed = JSON.parse_string(FileAccess.get_file_as_string(metadata_path))
		if parsed is Dictionary:
			for key in ["source_revision", "dirty", "dirty_worktree", "godot", "godot_executable", "scenario"]:
				if parsed.has(key): source[key] = parsed[key]
	main.selection_controller.selection_feedback.connect(_on_feedback)
	main.context_menu_controller.action_feedback.connect(_on_feedback)
	main.world.task_queue.task_added.connect(_on_task_added)
	main.world.task_queue.task_visual_state_changed.connect(_on_task_changed)
	if transport.start(session_id) != OK:
		startup_error = "control_transport_failed: " + transport.last_error
	_record("session_started", {"scenario": scenario, "source": source})


func set_ready(definition: Dictionary) -> void:
	scenario = definition.duplicate(true)
	ready = startup_error.is_empty()
	_record("scenario_ready", {"scenario": scenario, "state": snapshot()})


func snapshot() -> Dictionary:
	var inspector = main.diagnostics_controller.inspector
	var selection = main.selection_controller
	var result := {
		"run_id": run_id, "session_id": session_id, "pid": OS.get_process_id(),
		"run_root": run_root, "user_data_dir": OS.get_user_data_dir(),
		"ready": ready, "startup_error": startup_error,
		"world_epoch": main.diagnostics_controller.service.world_epoch,
		"view_id": inspector.view_id(), "frame_id": Engine.get_process_frames(),
		"simulation_steps": simulation_steps, "simulation_delta": SIMULATION_DELTA,
		"paused": active.is_empty() or not active.get("op", "") in ["advance", "run_until"],
		"last_sequence": last_sequence, "active_operation": active.get("operation_id", ""),
		"scenario": scenario, "source": source,
		"screen_targets": _screen_targets(),
		"window_has_focus": main.get_window().has_focus(),
		"desktop_pointer": Plain.plain(DisplayServer.mouse_get_position()) if DisplayServer.get_name() != "headless" else null,
		"viewport": Plain.plain(main.get_viewport().get_visible_rect().size),
		"camera": {"position": Plain.plain(main.camera.position), "rotation": Plain.plain(main.camera.rotation), "size": main.camera.size},
		"render_level": main.world.top_render_y, "player_mode": main.world.player_mode,
		"pointer": Plain.plain(main.input_state.pointer), "stair_rotation": selection.stair_rotation,
		"dragging": selection.is_dragging, "feedback": recent_feedback.duplicate(true),
		"created_task_ids": recent_task_ids.duplicate(),
		"operations": ["status", "act", "set_view", "advance", "run_until", "pause", "observe", "operation_status", "shutdown"],
	}
	return result


func _screen_targets() -> Dictionary:
	var targets := {}
	var positions: Dictionary = scenario.get("named_positions", {})
	for name in positions:
		if targets.size() >= 32: break
		var value: Variant = positions[name]
		var pos := Vector3.ZERO
		if value is Vector3 or value is Vector3i:
			pos = Vector3(value)
		elif _vector(value):
			pos = _vec(value)
		else: continue
		var surface := pos + Vector3(0, 0.5, 0)
		var point: Vector2 = main.camera.unproject_position(surface)
		targets[name] = {"cell": Plain.plain(pos), "point": Plain.plain(point),
			"inside_viewport": main.get_viewport().get_visible_rect().has_point(point),
			"behind_camera": main.camera.is_position_behind(surface)}
	return targets


func dispatch(operation: String, args: Dictionary) -> Dictionary:
	if operation == "status": return snapshot()
	if args.get("session_id") != session_id: return {"error": "stale_session"}
	if operation == "operation_status":
		var operation_id := str(args.get("operation_id", ""))
		for receipt in receipts.values():
			if receipt.operation_id == operation_id: return receipt.duplicate(true)
		return {"error": "unknown_operation_id"}
	if not _integer(args.get("seq")) or int(args.seq) < 1:
		return {"error": "sequence_required"}
	var sequence := int(args.seq)
	if receipts.has(sequence): return receipts[sequence].duplicate(true)
	if sequence <= last_sequence: return {"error": "discarded_sequence", "last_sequence": last_sequence}
	if sequence != last_sequence + 1: return {"error": "sequence_gap", "last_sequence": last_sequence}
	if args.get("world_epoch") != main.diagnostics_controller.service.world_epoch:
		return {"error": "stale_world"}
	if not active.is_empty() and operation not in ["pause", "shutdown"]:
		return {"error": "busy", "operation_id": active.operation_id}
	if journal == null or journal.get_length() >= JOURNAL_LIMIT:
		return {"error": "journal_unavailable_or_full"}
	if not ready and operation not in ["pause", "shutdown"]:
		return {"error": "not_ready", "detail": startup_error}
	var validation := _validate(operation, args)
	if validation.has("error"): return validation
	if operation in ["pause", "shutdown"] and not active.is_empty():
		_finish("cancelled", "cancelled_by_" + operation)
	last_sequence = sequence
	var receipt := {"operation_id": str(sequence), "seq": sequence, "op": operation,
		"state": "running", "session_id": session_id, "run_id": run_id,
		"world_epoch": main.diagnostics_controller.service.world_epoch,
		"view_id": main.diagnostics_controller.inspector.view_id(),
		"start_frame": Engine.get_process_frames(), "start_steps": simulation_steps,
		"started_usec": Time.get_ticks_usec(), "executed_stages": 0, "created_task_ids": []}
	receipts[sequence] = receipt
	while receipts.size() > RECEIPT_LIMIT: receipts.erase(receipts.keys()[0])
	active = receipt.duplicate(true)
	active["args"] = args.duplicate(true)
	active["deadline_usec"] = Time.get_ticks_usec() + int(float(args.get("timeout_sec", 30.0)) * 1000000.0)
	_record("action_started", {"receipt": receipt, "args": args})
	match operation:
		"act":
			active["stages"] = validation.stages
			active["deadline_usec"] = Time.get_ticks_usec() + 10000000
		"advance":
			active["remaining"] = int(args.steps)
		"run_until": pass
		"set_view":
			_set_view(args)
			_finish("complete")
		"observe":
			var request: Dictionary = observer.request(args)
			if request.has("error"):
				_finish("failed", str(request.error))
			else:
				active["observation_id"] = request.operation_id
		"pause": _finish("complete")
		"shutdown":
			ready = false
			_shutdown_frames = 3
			_finish("complete")
	return receipts[sequence].duplicate(true)


func _validate(operation: String, args: Dictionary) -> Dictionary:
	if operation in ["act", "set_view"] and args.get("view_id") != main.diagnostics_controller.inspector.view_id():
		return {"error": "stale_view"}
	match operation:
		"act":
			if not args.get("events") is Array: return {"error": "events_required"}
			return gestures.compile(args.events)
		"advance":
			if not _integer(args.get("steps")) or int(args.steps) < 1 or int(args.steps) > 7200:
				return {"error": "steps_must_be_1_to_7200"}
		"run_until":
			if not args.get("condition") is Dictionary: return {"error": "condition_required"}
			var condition_error := _condition_error(args.condition)
			if not condition_error.is_empty(): return {"error": condition_error}
		"set_view":
			for field in ["position", "rotation"]:
				if not _vector(args.get(field)): return {"error": field + "_required"}
			if absf(float(args.rotation[2])) > 0.0001: return {"error": "camera_roll_unsupported"}
			if not _number(args.get("size")) or float(args.size) < main.camera_controller.cam_zoom_min or float(args.size) > main.camera_controller.cam_zoom_max:
				return {"error": "invalid_camera_size"}
			if not _integer(args.get("render_level")) or int(args.render_level) < 0 or int(args.render_level) >= main.world.world_size_y:
				return {"error": "invalid_render_level"}
		"observe":
			var query_count := 0
			for field in ["cells", "requested_cells", "chunks", "requested_chunks", "workers", "requested_workers", "tasks", "requested_tasks"]:
				if not args.has(field): continue
				if not args[field] is Array: return {"error": "invalid_observation_queries"}
				query_count += args[field].size()
				if query_count > 128: return {"error": "observation_query_limit"}
				for value in args[field]:
					if field in ["cells", "requested_cells", "chunks", "requested_chunks"]:
						if not _vector(value) or not _integer(value[0]) or not _integer(value[1]) or not _integer(value[2]): return {"error": "invalid_observation_position"}
					elif not _integer(value) or int(value) < 0: return {"error": "invalid_observation_id"}
		"pause", "shutdown": pass
		_: return {"error": "unknown_operation"}
	if args.has("timeout_sec") and (not _number(args.timeout_sec) or float(args.timeout_sec) <= 0 or float(args.timeout_sec) > 120):
		return {"error": "invalid_timeout"}
	return {}


func begin_frame() -> void:
	advance_this_frame = false
	_advanced = false
	if _shutdown_frames >= 0:
		_shutdown_frames -= 1
		if _shutdown_frames == 0:
			main.get_tree().quit()
		return
	if active.is_empty(): return
	if active.world_epoch != main.diagnostics_controller.service.world_epoch:
		_finish("cancelled", "world_replaced")
		return
	if Time.get_ticks_usec() > int(active.deadline_usec) and active.op != "observe":
		_finish("failed", "operation_timeout")
		return
	match active.op:
		"act":
			var index := int(active.executed_stages)
			if index < active.stages.size():
				var delivered: Dictionary = gestures.deliver(active.stages[index])
				if delivered.has("error"):
					_finish("failed", str(delivered.error))
				else:
					active.executed_stages = index + 1
		"advance", "run_until":
			if active.op == "run_until" and _condition_met(active.args.condition):
				_finish("complete")
			elif not main.loading_active and not main.menu_open and main.world_started:
				advance_this_frame = true


func did_advance() -> void:
	simulation_steps += 1
	_advanced = true


func end_frame() -> void:
	observer.tick()
	if not active.is_empty():
		match active.op:
			"act":
				if int(active.executed_stages) >= active.stages.size(): _finish("complete")
			"advance":
				if _advanced:
					active.remaining -= 1
					if active.remaining <= 0: _finish("complete")
			"run_until":
				if _condition_met(active.args.condition): _finish("complete")
			"observe":
				var observation: Dictionary = observer.status(str(active.observation_id))
				if observation.get("state", "") in ["complete", "failed", "cancelled"]:
					active["observation"] = observation
					_finish(str(observation.state), str(observation.get("error", "")))
		if not active.is_empty(): _publish()
	transport.poll(dispatch, Time.get_ticks_usec())


func _publish() -> void:
	var receipt := active.duplicate(true)
	for key in ["args", "stages", "deadline_usec", "remaining"]: receipt.erase(key)
	receipt["simulation_steps"] = simulation_steps
	receipt["frame_id"] = Engine.get_process_frames()
	receipts[int(active.seq)] = receipt


func _finish(state: String, error: String = "") -> void:
	if active.is_empty(): return
	advance_this_frame = false
	if state == "cancelled" and active.op == "observe" and active.has("observation_id"):
		observer.cancel(str(active.observation_id))
	if state == "complete":
		gestures.finish()
	else:
		gestures.cancel()
	active["state"] = state
	if not error.is_empty(): active["error"] = error
	active["end_frame"] = Engine.get_process_frames()
	active["end_steps"] = simulation_steps
	active["end_view_id"] = main.diagnostics_controller.inspector.view_id()
	active["finished_usec"] = Time.get_ticks_usec()
	_publish()
	_record("action_finished", {"receipt": receipts[int(active.seq)], "feedback": recent_feedback.duplicate(true)})
	active = {}


func observe_physical_input(event: InputEvent) -> bool:
	if gestures.delivering: return false
	if event is InputEventMouse or event is InputEventKey or event is InputEventJoypadButton or event is InputEventJoypadMotion:
		if not active.is_empty(): _finish("cancelled", "physical_input")
		gestures.cancel()
		return true
	return false


func _on_node_added(node: Node) -> void:
	if node is Window: _install_window_guard.call_deferred(node)


func _install_existing_window_guards(node: Node) -> void:
	for child in node.get_children(): _install_existing_window_guards(child)
	if node is Window: _install_window_guard(node)


func _install_window_guard(window: Window) -> void:
	if _closed or not is_instance_valid(window): return
	var id := window.get_instance_id()
	if _guarded_windows.has(id): return
	var guard := WindowInputGuard.new()
	guard.name = "PlaytestPhysicalInputGuard"
	guard.controller_ref = weakref(self)
	# Window-local popups can consume events before Main sees them. A guard
	# added last receives input first, including in dynamically created popups.
	window.add_child(guard)
	_guarded_windows[id] = weakref(guard)


func _set_view(args: Dictionary) -> void:
	gestures.cancel()
	main.camera.position = _vec(args.position)
	main.camera.rotation = _vec(args.rotation)
	main.camera.size = float(args.size)
	main.camera_controller.cam_pitch = rad_to_deg(float(args.rotation[0]))
	main.camera_controller.cam_yaw = rad_to_deg(float(args.rotation[1]))
	main.camera_controller._apply_camera_rotation()
	main.camera_controller._clamp_camera_to_world()
	main.world.set_top_render_y(int(args.render_level))
	main.camera_controller.reset_mouse_state()


func _condition_error(condition: Dictionary) -> String:
	match str(condition.get("kind", "")):
		"cells_match":
			if not condition.get("cells") is Array or condition.cells.is_empty() or condition.cells.size() > 128: return "invalid_condition_cells"
			for cell in condition.cells:
				if not cell is Dictionary or not _cell(cell.get("pos")) or not _integer(cell.get("block_id")) or int(cell.block_id) < 0 or int(cell.block_id) > 255: return "invalid_condition_cell"
		"task_state":
			if not _integer(condition.get("id")) or str(condition.get("status", "")) not in ["pending", "in_progress", "completed"]: return "invalid_condition_task"
		"worker_at":
			if not _integer(condition.get("id")) or not _cell(condition.get("pos")): return "invalid_condition_worker"
		_: return "unknown_condition"
	return ""


func _condition_met(condition: Dictionary) -> bool:
	match condition.kind:
		"cells_match":
			for cell in condition.cells:
				var pos := Vector3i(_vec(cell.pos))
				var chunk = main.world.get_chunk(main.world.world_to_chunk_coords(pos.x, pos.y, pos.z))
				if chunk == null or not chunk.generated or main.world.get_block_no_generate(pos.x, pos.y, pos.z) != int(cell.block_id): return false
			return true
		"task_state":
			var task = main.world.task_queue.get_task(int(condition.id))
			var history: Dictionary = observed_tasks.get(int(condition.id), {})
			if task == null and history.get("world_epoch", -1) != main.diagnostics_controller.service.world_epoch: return false
			var status: int = task.status if task != null else int(history.get("status", -1))
			return status == ["pending", "in_progress", "completed"].find(str(condition.status))
		"worker_at":
			var worker = main.world.diagnostics_workers_by_id.get(int(condition.id))
			return is_instance_valid(worker) and worker.position.distance_to(_vec(condition.pos)) <= 0.2
	return false


func _on_feedback(message: String) -> void:
	recent_feedback.append({"frame_id": Engine.get_process_frames(), "message": message})
	while recent_feedback.size() > 16: recent_feedback.pop_front()


func _on_task_added(task) -> void:
	recent_task_ids.append(task.id)
	while recent_task_ids.size() > 128: recent_task_ids.pop_front()
	if not active.is_empty(): active.created_task_ids.append(task.id)
	_on_task_changed(task.id)


func _on_task_changed(id: int) -> void:
	var task = main.world.task_queue.get_task(id)
	if task == null: return
	observed_tasks[id] = {"status": task.status, "world_epoch": main.diagnostics_controller.service.world_epoch}
	while observed_tasks.size() > 128: observed_tasks.erase(observed_tasks.keys()[0])


func _record(kind: String, data: Dictionary) -> void:
	if journal == null or journal.get_length() >= JOURNAL_LIMIT: return
	journal.store_line(JSON.stringify({"kind": kind, "run_id": run_id, "session_id": session_id,
		"frame_id": Engine.get_process_frames(), "simulation_steps": simulation_steps, "data": data}))
	journal.flush()


func shutdown() -> void:
	if _closed: return
	_closed = true
	ready = false
	if main is Node and is_instance_valid(main) and main.is_inside_tree() and main.get_tree().node_added.is_connected(_on_node_added):
		main.get_tree().node_added.disconnect(_on_node_added)
	for reference in _guarded_windows.values():
		var guard = reference.get_ref()
		if is_instance_valid(guard): guard.queue_free()
	_guarded_windows.clear()
	if not active.is_empty(): _finish("cancelled", "shutdown")
	gestures.cancel()
	observer.shutdown()
	transport.stop()
	_record("session_stopped", {})
	if journal != null:
		journal.close()
		journal = null


func _cell(value: Variant) -> bool:
	return _vector(value) and _integer(value[0]) and _integer(value[1]) and _integer(value[2]) and main.world.is_block_coord_valid(int(value[0]), int(value[1]), int(value[2]))


static func _number(value: Variant) -> bool:
	return (value is int or value is float) and is_finite(float(value))


static func _integer(value: Variant) -> bool:
	return _number(value) and float(value) == floor(float(value)) and absf(float(value)) <= 9007199254740991.0


static func _vector(value: Variant) -> bool:
	return value is Array and value.size() == 3 and _number(value[0]) and _number(value[1]) and _number(value[2])


static func _vec(value: Array) -> Vector3:
	return Vector3(float(value[0]), float(value[1]), float(value[2]))
