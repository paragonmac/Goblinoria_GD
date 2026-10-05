extends RefCounted
class_name PlaytestObserver
## Read-only evidence collection for the approved autonomous playtest harness.
## The main controller owns actions and pausing; this class only observes.

const FrameCaptureScript = preload("res://scripts/diagnostics/frame_capture.gd")
const WriterScript = preload("res://scripts/diagnostics/bug_capture_writer.gd")
const MAX_REQUESTS_PER_SECOND := 2
const REQUEST_TIMEOUT_USEC := 10000000
const MAX_RETAINED_OPERATIONS := 32

var main_ref
var control_ref
var run_root := "user://playtest"
var writer
var frame_capture
var _active: Dictionary = {}
var _operations: Dictionary = {}
var _request_times: Array[int] = []
var _errors: Array = []
var _shutdown := false
var _sequence := 0


func initialize(main_owner, control_owner, run_root_path: String) -> void:
	shutdown()
	main_ref = main_owner
	control_ref = control_owner
	run_root = run_root_path if not run_root_path.is_empty() else "user://playtest"
	writer = WriterScript.new()
	writer.root_path = run_root.path_join("observations")
	frame_capture = FrameCaptureScript.new()
	frame_capture.initialize(main_ref)
	_shutdown = false
	_active.clear()
	_operations.clear()
	_request_times.clear()
	_errors.clear()
	_sequence = 0


func request(args: Dictionary) -> Dictionary:
	var operation_id := _new_operation_id()
	var now := Time.get_ticks_usec()
	_prune_request_times(now)
	if _shutdown or main_ref == null or control_ref == null:
		return _receipt(operation_id, "failed", "observer_unavailable")
	if not _active.is_empty() and not _is_terminal(str(_active.get("state", ""))):
		return _receipt(str(_active.get("operation_id", operation_id)), "busy", "capture_in_flight")
	if _request_times.size() >= MAX_REQUESTS_PER_SECOND:
		return _receipt(operation_id, "rate_limited", "request_rate_limit")
	_request_times.append(now)
	var clean_args := args.duplicate(true)
	var operation := {
		"operation_id": operation_id,
		"state": "pending",
		"requested_usec": now,
		"started_usec": now,
		"finished_usec": 0,
		"finished": false,
		"deadline_usec": now + REQUEST_TIMEOUT_USEC,
		"args": clean_args,
		"label": str(clean_args.get("label", clean_args.get("name", "observation"))).left(128),
		"action": str(clean_args.get("action", "observe")).left(128),
		"readiness": {},
		"checks": {},
		"paths": {},
		"error": "",
		"stable_frames": 0,
		"timeout": false,
		"control_before": {},
		"control_after": {},
		"request_world_epoch": _world_epoch(),
		"request_view_id": _view_id(),
	}
	_active = operation
	_operations[operation_id] = operation.duplicate(true)
	return {"operation_id": operation_id, "state": "pending"}


func tick() -> void:
	if writer != null:
		writer.poll()
		_poll_writer()
	if _active.is_empty() or _is_terminal(str(_active.get("state", ""))):
		return
	var now := Time.get_ticks_usec()
	if int(_active.get("deadline_usec", 0)) <= now and not bool(_active.get("timeout", false)):
		_timeout_capture()
	if str(_active.get("state", "")) == "pending":
		_update_readiness()
		if bool(_active.get("timeout", false)):
			_begin_frame_capture()
		elif bool(_active.get("readiness", {}).get("ready", false)):
			_active["stable_frames"] = int(_active.get("stable_frames", 0)) + 1
			_active["readiness"]["stable_frames"] = _active.stable_frames
			if int(_active.stable_frames) >= 2:
				_begin_frame_capture()
		else:
			_active["stable_frames"] = 0
			_active["readiness"]["stable_frames"] = 0
	if str(_active.get("state", "")) == "capturing":
		var result: Dictionary = frame_capture.take_result()
		if result.is_empty() and DisplayServer.get_name() == "headless":
			result = frame_capture.poll_headless()
		if not result.is_empty():
			_finish_frame(result)
	if str(_active.get("state", "")) == "capturing" and int(_active.get("deadline_usec", 0)) <= now:
		# A blocked or minimized renderer must still leave evidence. This does not
		# change the unmet readiness checks collected above.
		var forced: Dictionary = frame_capture.timeout_result()
		if not forced.is_empty():
			_finish_frame(forced)
	_update_operation_copy()


func status(operation_id: String) -> Dictionary:
	if operation_id == str(_active.get("operation_id", "")) and not _active.is_empty():
		_update_operation_copy()
		return _public_status(_active)
	return _public_status(_operations.get(operation_id, {"operation_id": operation_id, "state": "unknown", "error": "operation_not_found"}))


func cancel(operation_id: String) -> Dictionary:
	if _active.is_empty() or str(_active.get("operation_id", "")) != operation_id:
		return status(operation_id)
	if _is_terminal(str(_active.get("state", ""))):
		return _public_status(_active)
	if str(_active.get("state", "")) == "writing":
		# Let the sole writer finish its owned copies before permitting a new
		# operation. A cancellation never abandons or replaces that thread.
		_active["cancel_requested"] = true
		_active["error"] = "cancel_requested"
		_update_operation_copy()
		return _public_status(_active)
	if frame_capture != null:
		frame_capture.shutdown()
		frame_capture = FrameCaptureScript.new()
		frame_capture.initialize(main_ref)
	_active["state"] = "cancelled"
	_active["error"] = "cancelled"
	_active["finished_usec"] = Time.get_ticks_usec()
	_update_operation_copy()
	return _public_status(_active)


func get_pending() -> Dictionary:
	if _active.is_empty() or _is_terminal(str(_active.get("state", ""))):
		return {}
	return _public_status(_active)


func capture_errors() -> Array:
	return _errors.duplicate(true)


func shutdown() -> void:
	if frame_capture != null:
		frame_capture.shutdown()
	if not _active.is_empty() and str(_active.get("state", "")) == "writing":
		# Drain the sole writer before releasing the observer. This preserves a
		# complete bundle and its cancellation metadata when shutdown races a write.
		_active["cancel_requested"] = true
	if writer != null:
		writer.shutdown()
	if not _active.is_empty() and str(_active.get("state", "")) == "writing":
		_poll_writer()
	if not _active.is_empty() and not _is_terminal(str(_active.get("state", ""))):
		_active["state"] = "cancelled"
		_active["error"] = "observer_shutdown"
		_active["finished_usec"] = Time.get_ticks_usec()
		_update_operation_copy()
	_active.clear()
	main_ref = null
	control_ref = null
	writer = null
	frame_capture = null
	_shutdown = true


func _new_operation_id() -> String:
	_sequence += 1
	return "%s-%04d" % [Time.get_datetime_string_from_system(true).replace(":", "-"), _sequence]


func _receipt(operation_id: String, state: String, error: String) -> Dictionary:
	return {"operation_id": operation_id, "state": state, "error": error}


func _prune_request_times(now: int) -> void:
	while not _request_times.is_empty() and now - int(_request_times[0]) >= 1000000:
		_request_times.pop_front()


func _timeout_capture() -> void:
	_active["timeout"] = true
	_active["readiness"]["timed_out"] = true
	_active["readiness"]["label"] = "notready"
	_active["readiness"]["ready"] = false
	_active["readiness"]["timeout_reason"] = "readiness_timeout"
	_active["error"] = ""


func _update_readiness() -> void:
	var current := _readiness_sample()
	var previous: Dictionary = _active.get("readiness", {})
	current["stable_frames"] = int(_active.get("stable_frames", 0))
	current["timed_out"] = bool(previous.get("timed_out", false))
	current["label"] = "notready" if current.timed_out else ("ready" if current.ready else "waiting")
	_active["readiness"] = current
	_active["checks"] = current.get("checks", {})


func _readiness_sample() -> Dictionary:
	var control_snapshot: Dictionary = _control_snapshot()
	var epoch: int = _world_epoch()
	var visibility: Dictionary = _visibility_snapshot()
	var visibility_keys: Array = ["requested_sequence", "accepted_sequence", "applied_sequence",
		"application_pending", "requested_view_pending", "epoch", "applied_epoch", "mixed_view"]
	var visibility_complete: bool = true
	for key in visibility_keys:
		if not visibility.has(key):
			visibility_complete = false
	var requested: int = int(visibility.get("requested_sequence", -1))
	var accepted: int = int(visibility.get("accepted_sequence", -1))
	var applied: int = int(visibility.get("applied_sequence", -1))
	var visibility_pending: bool = bool(visibility.get("application_pending", true)) or bool(visibility.get("requested_view_pending", true)) or bool(visibility.get("mixed_view", true))
	var visibility_settled: bool = visibility_complete and not visibility_pending and requested == accepted and accepted == applied \
		and int(visibility.get("applied_epoch", -1)) == int(visibility.get("epoch", -2))
	var world_epoch: int = epoch
	var world_stable: bool = epoch >= 0 and epoch == int(_active.get("request_world_epoch", epoch))
	var requested_view: String = str(_active.get("request_view_id", ""))
	var current_view: String = _view_id()
	var view_stable: bool = requested_view.is_empty() or current_view.is_empty() or requested_view == current_view
	var geometry: Dictionary = _geometry_readiness()
	var loading_active: bool = bool(main_ref.get("loading_active")) if main_ref is Object else true
	var control_ready: bool = not control_snapshot.has("ready") or bool(control_snapshot.get("ready", false))
	var checks: Dictionary = {
		"world_epoch_stable": world_stable,
		"view_stable": view_stable,
		"visibility_settled": visibility_settled,
		"geometry_ready": bool(geometry.get("ready", false)),
		"control_ready": control_ready,
		"loading_clear": not loading_active,
	}
	var unmet: Array[String] = []
	for key in checks:
		if not bool(checks[key]):
			unmet.append(str(key))
	var ready: bool = unmet.is_empty()
	return {"ready": ready, "timed_out": false, "label": "ready" if ready else "waiting",
		"checks": checks, "unmet": unmet, "epoch": epoch, "world_epoch": world_epoch,
		"request_view_id": requested_view, "current_view_id": current_view,
		"visibility": visibility.duplicate(true), "geometry": geometry,
		"control": {"ready": control_ready, "simulation_steps": control_snapshot.get("simulation_steps")}}


func _probe_snapshot(inspector: Variant) -> Dictionary:
	if inspector == null or not inspector.has_method("capture_snapshot"):
		return {"unavailable": "diagnostics_snapshot"}
	var probe: Variant = inspector.capture_snapshot()
	if not probe is Dictionary:
		return {"unavailable": "diagnostics_snapshot"}
	var metadata: Dictionary = probe.get("metadata", {})
	return metadata if metadata is Dictionary else {"unavailable": "diagnostics_metadata"}


func _world_epoch() -> int:
	var service: Variant = _diagnostics_service()
	if service == null:
		return -1
	return int(service.world_epoch)


func _view_id() -> String:
	var inspector: Variant = _diagnostics_inspector()
	if inspector != null and inspector.has_method("view_id"):
		return str(inspector.view_id())
	return ""


func _begin_frame_capture() -> void:
	if str(_active.get("state", "")) != "pending" or frame_capture == null:
		return
	_active["state"] = "capturing"
	_active["capture_started_usec"] = Time.get_ticks_usec()
	var operation_id := str(_active.operation_id)
	var result: Dictionary = frame_capture.begin(operation_id,
		Callable(self, "_capture_pre_snapshot").bind(operation_id),
		Callable(self, "_capture_post_snapshot").bind(operation_id),
		{"timed_out": bool(_active.get("timeout", false)), "readiness": _active.get("readiness", {}).duplicate(true)})
	if str(result.get("state", "")) == "busy":
		_active["state"] = "failed"
		_active["error"] = "frame_capture_busy"
		_active["finished_usec"] = Time.get_ticks_usec()
		_update_operation_copy()
		return
	if DisplayServer.get_name() == "headless":
		var headless_result: Dictionary = frame_capture.poll_headless()
		if not headless_result.is_empty():
			_finish_frame(headless_result)


func _capture_pre_snapshot(operation_id: String) -> Dictionary:
	var inspector: Variant = _diagnostics_inspector()
	var snapshot: Dictionary = {}
	if inspector != null and inspector.has_method("capture_snapshot"):
		var value: Variant = inspector.capture_snapshot()
		if value is Dictionary:
			snapshot = value.duplicate(true)
	if snapshot.is_empty():
		snapshot = {"unavailable": "diagnostics_snapshot"}
	var base: Dictionary = snapshot.get("metadata", {}) if snapshot.get("metadata", {}) is Dictionary else {}
	snapshot["playtest_observation"] = _collect_observation(operation_id, base)
	_active["control_before"] = _control_snapshot()
	return snapshot


func _capture_post_snapshot(operation_id: String) -> Dictionary:
	var inspector: Variant = _diagnostics_inspector()
	var post: Dictionary = {}
	if inspector != null and inspector.has_method("capture_snapshot"):
		var value: Variant = inspector.capture_snapshot()
		if value is Dictionary:
			post = value.duplicate(true)
	var base: Dictionary = post.get("metadata", {}) if post.get("metadata", {}) is Dictionary else {}
	_active["control_after"] = _control_snapshot()
	return {"operation_id": operation_id, "metadata": base,
		"world_epoch": post.get("world_epoch", null), "frame_id": post.get("frame_id", null),
		"control": _active.get("control_after", {}).duplicate(true),
		"ui": _collect_ui_state()}


func _finish_frame(frame_result: Dictionary) -> void:
	if _active.is_empty() or _is_terminal(str(_active.get("state", ""))):
		return
	var pre: Dictionary = frame_result.get("pre_snapshot", {})
	var post: Dictionary = frame_result.get("post_snapshot", {})
	var screenshot: Dictionary = frame_result.get("screenshot", {}).duplicate(true)
	var readiness: Dictionary = _active.get("readiness", {}).duplicate(true)
	if bool(_active.get("timeout", false)):
		readiness["timed_out"] = true
		readiness["label"] = "notready"
		readiness["ready"] = false
	var coherence := _coherence(pre, post, screenshot)
	var observation: Dictionary = pre.get("playtest_observation", {}) if pre is Dictionary else {}
	observation["operation_id"] = _active.operation_id
	observation["readiness"] = readiness
	observation["coherence"] = coherence
	observation["screenshot"] = screenshot
	observation["control_before"] = _active.get("control_before", {}).duplicate(true)
	observation["control_after"] = _active.get("control_after", {}).duplicate(true)
	observation["simulation"] = _simulation_observation()
	var snapshot := pre.duplicate(true)
	snapshot["playtest_observation"] = observation
	snapshot["coherence"] = coherence
	snapshot["screenshot"] = screenshot
	# Image never enters the JSON snapshot. It is passed only to the bounded writer.
	var image: Image = frame_result.get("image") as Image
	_active["snapshot"] = snapshot
	_active["state"] = "writing"
	_active["screenshot_available"] = image != null and bool(screenshot.get("available", false))
	var history := {"history_available": false, "events": [], "dropped_events": 0, "dropped_decisions": 0}
	var errors := {"rows": _errors.duplicate(true), "dropped": 0}
	var service: Variant = _diagnostics_service()
	if service != null and service.has_method("recent_events"):
		history = service.recent_events(128)
	var diagnostics: Variant = _diagnostics_controller()
	if diagnostics != null:
		var runtime_errors: Variant = diagnostics.get("errors")
		if runtime_errors is Array:
			errors.rows.append_array(runtime_errors.slice(-128).duplicate(true))
			var dropped: Variant = diagnostics.get("dropped_errors")
			errors.dropped = int(dropped) if dropped != null else 0
	var started: bool = writer.start(str(_active.operation_id), snapshot, history, errors, image)
	if not started:
		_active["state"] = "failed"
		_active["error"] = "writer_start_failed"
		_active["finished_usec"] = Time.get_ticks_usec()
		_update_operation_copy()


func _poll_writer() -> void:
	if _active.is_empty() or str(_active.get("state", "")) != "writing":
		return
	if writer.status.get("state", "") == "writing":
		return
	var result: Dictionary = writer.status.duplicate(true)
	_active["finished_usec"] = Time.get_ticks_usec()
	_active["paths"] = _paths_for_result(result)
	_active["artifacts_complete"] = result.get("state") == "complete"
	if result.get("state") == "complete":
		if bool(_active.get("cancel_requested", false)):
			_active["state"] = "cancelled"
			_active["error"] = "cancel_requested"
		else:
			var snapshot: Dictionary = _active.get("snapshot", {})
			var screenshot: Dictionary = snapshot.get("screenshot", {}) if snapshot.get("screenshot", {}) is Dictionary else {}
			var coherence: Dictionary = snapshot.get("coherence", {}) if snapshot.get("coherence", {}) is Dictionary else {}
			if bool(_active.get("timeout", false)):
				_active["state"] = "failed"
				_active["error"] = "render_readiness_timeout"
			elif not bool(screenshot.get("available", false)):
				_active["state"] = "failed"
				_active["error"] = "image_unavailable:" + str(screenshot.get("reason", "unknown"))
			elif not bool(coherence.get("coherent", false)):
				_active["state"] = "failed"
				_active["error"] = "incoherent_capture"
			else:
				_active["state"] = "complete"
				_active["error"] = ""
		_write_observation_metadata(result.get("path", ""))
	else:
		_active["state"] = "failed"
		_active["error"] = str(result.get("error", "writer_failed"))
		_record_error(str(_active.get("error", "writer_failed")))
	_update_operation_copy()
	if _operations.size() > MAX_RETAINED_OPERATIONS:
		var oldest: Variant = _operations.keys()[0]
		_operations.erase(oldest)


func _write_observation_metadata(path: String) -> void:
	if path.is_empty():
		return
	var metadata := {
		"format_version": 1,
		"complete": true,
		"artifacts_complete": true,
		"operation_id": _active.operation_id,
		"label": _active.label,
		"action": _active.action,
		"readiness": _active.get("readiness", {}),
		"checks": _active.get("checks", {}),
		"coherence": _active.get("snapshot", {}).get("coherence", {}),
		"screenshot": _active.get("snapshot", {}).get("screenshot", {}),
		"state": _active.get("state", "complete"),
		"error": _active.get("error", ""),
		"paths": _paths_for_result({"path": path}),
	}
	var metadata_path := path.path_join("observation.json")
	if not _store_json(metadata_path, metadata):
		_record_error("observation_metadata_write_failed")
	_active["paths"]["observation"] = metadata_path
	var manifest_path := path.path_join("manifest.json")
	var manifest: Variant = JSON.parse_string(FileAccess.get_file_as_string(manifest_path)) if FileAccess.file_exists(manifest_path) else {}
	if not manifest is Dictionary:
		manifest = {}
	manifest["observation"] = metadata
	manifest["coherence"] = metadata.coherence
	manifest["readiness"] = metadata.readiness
	manifest["screenshot"] = metadata.screenshot
	_store_json(manifest_path, manifest)


func _store_json(path: String, value: Dictionary) -> bool:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return false
	file.store_string(JSON.stringify(value, "\t"))
	file.flush()
	var ok := file.get_error() == OK
	file.close()
	return ok


func _paths_for_result(result: Dictionary) -> Dictionary:
	var path := str(result.get("path", ""))
	if path.is_empty():
		return {}
	var output := {"bundle": path, "manifest": path.path_join("manifest.json"),
		"snapshot": path.path_join("snapshot.json"), "observation": path.path_join("observation.json")}
	if bool(_active.get("screenshot_available", false)):
		output["screenshot"] = path.path_join("screenshot.png")
	return output


func _collect_observation(operation_id: String, base_metadata: Dictionary) -> Dictionary:
	var args: Dictionary = _active.get("args", {})
	var queries: Dictionary = _collect_queries(args)
	return {"format_version": 1, "operation_id": operation_id,
		"label": _active.get("label", "observation"), "action": _active.get("action", "observe"),
		"run_root": run_root, "requested_usec": _active.get("requested_usec", 0),
		"base_metadata": base_metadata.duplicate(true), "control": _control_snapshot(),
		"ui": _collect_ui_state(), "queries": queries,
		"rendering": _collect_rendering(args), "actions": args.get("actions", []),
		"expected": args.get("expected", []), "observations": args.get("observations", []),
		"category": str(args.get("category", "gameplay")).left(64)}


func _collect_queries(args: Dictionary) -> Dictionary:
	var cells: Array = []
	var workers: Array = []
	var tasks: Array = []
	for value in _values_for(args, ["cells", "requested_cells"]):
		var pos := _position_array(value)
		if pos.is_empty():
			continue
		cells.append({"pos": pos, "result": _inspector_query("inspect_cell", {"pos": pos})})
	for value in _values_for(args, ["workers", "requested_workers"]):
		var id := _integer_value(value, -1)
		if id >= 0:
			workers.append({"id": id, "result": _inspector_query("inspect_worker", {"id": id})})
	for value in _values_for(args, ["tasks", "requested_tasks"]):
		var task_id := _integer_value(value, -1)
		if task_id >= 0:
			tasks.append({"id": task_id, "result": _inspector_query("inspect_task", {"id": task_id})})
	return {"cells": cells, "workers": workers, "tasks": tasks}


func _inspector_query(operation: String, args: Dictionary) -> Dictionary:
	var inspector: Variant = _diagnostics_inspector()
	if inspector == null or not inspector.has_method("query"):
		return {"error": "diagnostics_unavailable"}
	var epoch: int = _world_epoch()
	var request: Dictionary = args.duplicate(true)
	request["world_epoch"] = epoch
	var result: Variant = inspector.query(operation, request)
	return result if result is Dictionary else {"error": "query_unavailable"}


func _collect_rendering(args: Dictionary) -> Dictionary:
	var coords: Array = _relevant_coords(args)
	var preview_rows: Array = _collect_drag_previews()
	for row in preview_rows:
		var pos: Array = row.get("position", [])
		var coord: Array = _chunk_for_position(pos)
		if coord.size() == 3:
			coords.append(coord)
	var unique: Array = []
	var seen: Dictionary = {}
	for coord in coords:
		var key := JSON.stringify(coord)
		if not seen.has(key):
			seen[key] = true
			unique.append(coord)
	var chunks: Array = []
	for coord in unique:
		chunks.append(_chunk_render_observation(coord))
	return {"visibility": _visibility_snapshot(), "previews": preview_rows, "chunks": chunks}


func _relevant_coords(args: Dictionary) -> Array:
	var coords: Array = []
	for value in _values_for(args, ["chunks", "requested_chunks"]):
		var coord := _position_array(value)
		if coord.size() == 3:
			coords.append(coord)
	for value in _values_for(args, ["cells", "requested_cells"]):
		var pos := _position_array(value)
		var coord := _chunk_for_position(pos)
		if coord.size() == 3:
			coords.append(coord)
	var scenario: Dictionary = _scenario()
	for value in scenario.get("affected_chunks", []):
		var coord := _position_array(value)
		if coord.size() == 3:
			coords.append(coord)
	for row in _collect_drag_previews():
		var preview_coord := _chunk_for_position(row.get("position", []))
		if preview_coord.size() == 3:
			coords.append(preview_coord)
	return coords


func _chunk_render_observation(coord: Array) -> Dictionary:
	var renderer: Variant = _renderer()
	if renderer == null:
		return {"coord": coord, "node_exists": false, "generated": false, "geometry": "renderer_unavailable", "mesh_revision": null}
	var cache: Variant = renderer.get("chunk_cache") if renderer is Object else null
	var node: Variant = cache.get_chunk(Vector3i(int(coord[0]), int(coord[1]), int(coord[2]))) if cache != null and cache.has_method("get_chunk") else null
	var has_mesh := false
	if node is Object:
		has_mesh = node.get("mesh") != null
	var mesh_revision: Variant = null
	if node is Object and node.has_method("has_meta") and node.has_meta("diagnostics_mesh_revision"):
		mesh_revision = node.get_meta("diagnostics_mesh_revision")
	var world: Variant = main_ref.get("world") if main_ref is Object else null
	var chunk: Variant = world.get_chunk(Vector3i(int(coord[0]), int(coord[1]), int(coord[2]))) if world != null and world.has_method("get_chunk") else null
	var generated := false
	var chunk_revision: Variant = null
	if chunk is Object:
		generated = bool(chunk.get("generated"))
		chunk_revision = chunk.get("mesh_revision")
	var revision_matches: bool = mesh_revision != null and chunk_revision != null and mesh_revision == chunk_revision
	var scheduler: Variant = renderer.get("mesh_scheduler") if renderer is Object else null
	var queued_revision: int = scheduler.get_job_revision(Vector3i(int(coord[0]), int(coord[1]), int(coord[2]))) if scheduler != null and scheduler.has_method("get_job_revision") else -1
	var pending_mesh_revision: bool = queued_revision >= 0 and (chunk_revision == null or queued_revision >= int(chunk_revision))
	var visibility: Dictionary = _visibility_snapshot()
	var visible_set: Variant = renderer.get("render_zone_visible") if renderer is Object else null
	var view_eligible: bool = true
	if visible_set is Dictionary and bool(visibility.get("initialized", false)):
		view_eligible = visible_set.has(Vector3i(int(coord[0]), int(coord[1]), int(coord[2])))
	var missing_neighbors: Variant = renderer.get("chunk_missing_neighbors") if renderer is Object else {}
	if missing_neighbors == null:
		missing_neighbors = {}
	var pending_neighbor_remesh: Variant = renderer.get("pending_neighbor_remesh") if renderer is Object else {}
	if pending_neighbor_remesh == null:
		pending_neighbor_remesh = {}
	var neighbor_waiting: bool = false
	if missing_neighbors is Dictionary:
		var neighbor_value: Variant = missing_neighbors.get(Vector3i(int(coord[0]), int(coord[1]), int(coord[2])), {})
		neighbor_waiting = neighbor_value is Dictionary and not neighbor_value.is_empty()
	if pending_neighbor_remesh is Dictionary:
		neighbor_waiting = neighbor_waiting or pending_neighbor_remesh.has(Vector3i(int(coord[0]), int(coord[1]), int(coord[2])))
	# A generated chunk outside the current effective view need not own a mesh
	# node yet. In-view chunks require the renderer-applied revision metadata,
	# including a valid empty-geometry result.
	var geometry_ready: bool = generated and not neighbor_waiting and not pending_mesh_revision and (not view_eligible or (node != null and revision_matches))
	return {"coord": coord, "node_exists": node != null, "generated": generated,
		"chunk_mesh_revision": chunk_revision, "visible": bool(node.visible) if node is Object else null,
		"in_tree": bool(node.is_inside_tree()) if node is Object else null, "has_mesh": has_mesh,
		"mesh_revision": mesh_revision, "revision_matches": revision_matches,
		"queued_mesh_revision": queued_revision, "pending_mesh_revision": pending_mesh_revision,
		"view_eligible": view_eligible, "neighbor_waiting": neighbor_waiting,
		"geometry": "ready" if geometry_ready else "unavailable"}


func _geometry_readiness() -> Dictionary:
	var rows: Array = []
	var operation_args: Dictionary = _active.get("args", {})
	for coord in _relevant_coords(operation_args):
		var exists: bool = false
		for row in rows:
			if row.get("coord", []) == coord:
				exists = true
				break
		if not exists:
			rows.append(_chunk_render_observation(coord))
	var missing: Array = []
	for row in rows:
		if str(row.get("geometry", "")) != "ready":
			missing.append(row.get("coord", []))
	return {"ready": missing.is_empty(), "requested": rows.size(), "missing": missing, "chunks": rows}


func _collect_drag_previews() -> Array:
	var renderer: Variant = _renderer()
	var overlay: Variant = renderer.get("overlay_renderer") if renderer is Object else null
	var result: Array = []
	if overlay == null:
		return result
	var previews: Variant = overlay.get("drag_previews") if overlay is Object else {}
	if not previews is Dictionary:
		return result
	for key in previews:
		var node: Variant = previews[key]
		if node == null or not is_instance_valid(node):
			continue
		var metadata: Dictionary = node.get_meta("drag_preview", {}) if node.has_method("get_meta") else {}
		var pos: Array = [int(metadata.get("x", node.position.x)), int(metadata.get("y", node.position.y)), int(metadata.get("z", node.position.z))]
		result.append({"key": str(key), "position": pos, "visible": bool(node.visible),
			"in_tree": bool(node.is_inside_tree()), "has_mesh": node.mesh != null,
			"metadata": metadata.duplicate(true)})
	return result


func _coherence(pre: Dictionary, post: Dictionary, screenshot: Dictionary) -> Dictionary:
	var pre_meta: Dictionary = pre.get("metadata", {}) if pre.get("metadata", {}) is Dictionary else {}
	var post_meta: Dictionary = post.get("metadata", {}) if post.get("metadata", {}) is Dictionary else {}
	var pre_epoch: Variant = pre.get("world_epoch", pre_meta.get("world_epoch", null))
	var post_epoch: Variant = post.get("world_epoch", post_meta.get("world_epoch", null))
	var pre_view: Variant = pre_meta.get("view_id", null)
	var post_view: Variant = post_meta.get("view_id", null)
	var pre_frame: Variant = pre.get("frame_id", pre_meta.get("frame_id", null))
	var post_frame: Variant = post.get("frame_id", post_meta.get("frame_id", null))
	var known: bool = pre_epoch != null and post_epoch != null and pre_view != null and post_view != null \
		and pre_frame != null and post_frame != null
	return {"world_same": known and pre_epoch == post_epoch, "view_same": known and pre_view == post_view,
		"frame_same": pre_frame == post_frame, "pre_world_epoch": pre_epoch,
		"post_world_epoch": post_epoch, "pre_view_id": pre_view, "post_view_id": post_view,
		"pre_frame_id": pre_frame, "post_frame_id": post_frame,
		"screenshot_boundary": screenshot.duplicate(true),
		"coherent": known and pre_epoch == post_epoch and pre_view == post_view and pre_frame == post_frame \
			and bool(screenshot.get("available", false))}


func _simulation_observation() -> Dictionary:
	var before: Dictionary = _active.get("control_before", {})
	var after: Dictionary = _active.get("control_after", {})
	var before_steps: Variant = before.get("simulation_steps", null)
	var after_steps: Variant = after.get("simulation_steps", null)
	return {"before": before_steps, "after": after_steps,
		"advanced": before_steps != null and after_steps != null and int(after_steps) != int(before_steps),
		"observer_does_not_advance": true}


func _collect_ui_state() -> Dictionary:
	var state: Dictionary = _control_snapshot().get("ui", {})
	var viewport: Viewport = main_ref.get_viewport() if main_ref != null and main_ref.has_method("get_viewport") else null
	if viewport != null:
		var focus_owner: Control = viewport.gui_get_focus_owner()
		if focus_owner != null and is_instance_valid(focus_owner):
			var focus_details: Dictionary = {"path": str(focus_owner.get_path()), "class": focus_owner.get_class(),
				"name": focus_owner.name}
			if focus_owner is LineEdit:
				focus_details["text"] = focus_owner.text.left(256)
			elif focus_owner is TextEdit:
				focus_details["text"] = focus_owner.text.left(256)
			state["focused_control"] = focus_details
		else:
			state["focused_control"] = {}
		var embedded: Array = []
		var popup_count := 0
		var windows: Array[Window] = viewport.get_embedded_subwindows()
		for i in range(mini(windows.size(), 32)):
			var details: Dictionary = _window_details(windows[i])
			embedded.append(details)
			if bool(details.get("visible", false)) and bool(details.get("popup_window", false)):
				popup_count += 1
		state["embedded_windows"] = embedded
		state["visible_popup_count"] = popup_count
	if main_ref != null:
		state["menu_open"] = bool(main_ref.get("menu_open")) if main_ref is Object else state.get("menu_open", false)
		state["loading_active"] = bool(main_ref.get("loading_active")) if main_ref is Object else state.get("loading_active", false)
	var diagnostics: Variant = main_ref.get("diagnostics_controller") if main_ref is Object else null
	if diagnostics != null:
		state["focused"] = bool(diagnostics.get("_focused")) if diagnostics is Object else state.get("focused", true)
	var context_menu: Variant = main_ref.get("context_menu_controller") if main_ref is Object else null
	if context_menu != null and context_menu.has_method("is_visible"):
		state["context_menu_visible"] = bool(context_menu.is_visible())
	var context_popup: Variant = context_menu.get("popup") if context_menu is Object else null
	if context_popup != null:
		state["context_menu"] = _window_details(context_popup)
	var worker_window: Variant = main_ref.get("worker_window_controller") if main_ref is Object else null
	if worker_window != null:
		state["worker_window_visible"] = bool(worker_window.get("visible")) if worker_window is Object else false
	if main_ref.has_method("get_window"):
		var window: Window = main_ref.get_window()
		state["window_focused"] = window.has_focus() if window != null else null
	var colony: Variant = main_ref.get("colony_ui") if main_ref is Object else null
	if colony != null and colony.has_method("pointer_owned"):
		state["pointer_owned"] = colony.pointer_owned()
	if colony != null and colony.has_method("keyboard_owned"):
		state["keyboard_owned"] = colony.keyboard_owned()
	var input_state: Variant = main_ref.get("input_state") if main_ref is Object else null
	if input_state != null:
		if viewport != null and input_state.has_method("mouse_position"):
			var pointer: Vector2 = input_state.mouse_position(viewport)
			state["pointer"] = [pointer.x, pointer.y]
		if input_state.has_method("button_mask"):
			state["button_mask"] = int(input_state.button_mask())
	return state


func _window_details(window: Variant) -> Dictionary:
	if window == null or not is_instance_valid(window) or not window is Object:
		return {"valid": false}
	var details: Dictionary = {"valid": true, "class": window.get_class()}
	if window.has_method("get_path"):
		details["path"] = str(window.get_path())
	if window.has_method("get_instance_id"):
		details["instance_id"] = window.get_instance_id()
	var visible_value: Variant = window.get("visible")
	if visible_value != null:
		details["visible"] = bool(visible_value)
	if window is Window:
		details["name"] = window.name
		details["popup_window"] = window.popup_window
		details["position"] = [window.position.x, window.position.y]
		details["size"] = [window.size.x, window.size.y]
		details["has_focus"] = window.has_focus()
	if window is PopupMenu:
		var item_count: int = mini(window.item_count, 32)
		details["item_count"] = window.item_count
		var items: Array = []
		for i in range(item_count):
			items.append({"index": i, "text": window.get_item_text(i).left(128),
				"disabled": window.is_item_disabled(i), "checked": window.is_item_checked(i)})
		details["items"] = items
	return details


func _control_snapshot() -> Dictionary:
	if control_ref != null and control_ref.has_method("snapshot"):
		var value: Variant = control_ref.snapshot()
		if value is Dictionary:
			return value.duplicate(true)
	return {"unavailable": "control_snapshot"}


func _scenario() -> Dictionary:
	var value: Variant = _control_snapshot().get("scenario", {})
	return value if value is Dictionary else {}


func _diagnostics_controller() -> Variant:
	return main_ref.get("diagnostics_controller") if main_ref is Object else null


func _diagnostics_inspector() -> Variant:
	var controller: Variant = _diagnostics_controller()
	return controller.get("inspector") if controller is Object else null


func _diagnostics_service() -> Variant:
	var controller: Variant = _diagnostics_controller()
	return controller.get("service") if controller is Object else null


func _renderer() -> Variant:
	var world: Variant = main_ref.get("world") if main_ref is Object else null
	return world.get("renderer") if world is Object else null


func _visibility_snapshot() -> Dictionary:
	var renderer: Variant = _renderer()
	if renderer != null and renderer.has_method("get_visibility_snapshot"):
		var value: Variant = renderer.get_visibility_snapshot()
		if value is Dictionary:
			return value.duplicate(true)
	return {"unavailable": "visibility"}


func _values_for(args: Dictionary, names: Array) -> Array:
	var result: Array = []
	for name in names:
		var value: Variant = args.get(name, [])
		if value is Array:
			result.append_array(value)
	return result


func _position_array(value: Variant) -> Array:
	if value is Vector3i:
		return [value.x, value.y, value.z]
	if value is Vector3:
		return [int(value.x), int(value.y), int(value.z)]
	if value is Array and value.size() == 3:
		return [int(value[0]), int(value[1]), int(value[2])]
	if value is Dictionary:
		for key in ["pos", "position", "coord", "chunk"]:
			if value.has(key):
				return _position_array(value[key])
	return []


func _chunk_for_position(pos: Array) -> Array:
	var world: Variant = main_ref.get("world") if main_ref is Object else null
	if world != null and world.has_method("world_to_chunk_coords") and pos.size() == 3:
		var coord: Vector3i = world.world_to_chunk_coords(int(pos[0]), int(pos[1]), int(pos[2]))
		return [coord.x, coord.y, coord.z]
	return []


func _integer_value(value: Variant, fallback: int) -> int:
	if value is Dictionary:
		return _integer_value(value.get("id", value.get("worker_id", value.get("task_id", fallback))), fallback)
	if value is int:
		return value
	if value is float and is_finite(value) and floor(value) == value:
		return int(value)
	return fallback


func _is_terminal(state: String) -> bool:
	return state in ["complete", "failed", "cancelled", "unknown", "rate_limited", "busy"]


func _update_operation_copy() -> void:
	if _active.is_empty():
		return
	_active["finished"] = _is_terminal(str(_active.get("state", "")))
	var copy: Dictionary = _active.duplicate(true)
	copy.erase("snapshot")
	copy.erase("args")
	_operations[str(_active.operation_id)] = copy


func _public_status(value: Variant) -> Dictionary:
	if not value is Dictionary:
		return {"state": "unknown", "error": "invalid_operation"}
	var result: Dictionary = value.duplicate(true)
	result.erase("snapshot")
	result.erase("args")
	result.erase("control_before")
	result.erase("control_after")
	return result


func _record_error(message: String) -> void:
	_errors.append({"message": message.left(256), "monotonic_usec": Time.get_ticks_usec()})
	while _errors.size() > 64:
		_errors.pop_front()
