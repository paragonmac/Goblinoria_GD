extends RefCounted
## Debug-build invariant checks that log suspicious simulation and terrain states
## to a JSONL timeline for later review. Observation only: checks never pause,
## repair, generate terrain or change gameplay decisions.
##
## Sustained checks open a record once a condition has held for its threshold and
## resolve it when the condition clears or the entity disappears. Events (falls,
## rescues, removed workers) are logged immediately. Simulation checks use
## simulated seconds; terrain checks use wall time because rendering continues
## while simulation is paused.

const Data = preload("res://scripts/diagnostics/live_diagnostics_service.gd")
const Decision = preload("res://scripts/diagnostics/live_decision_snapshot.gd")

const FORMAT_VERSION := 1
const OUTPUT_ROOT := "user://diagnostics/anomalies"
const SIM_PASS_INTERVAL_SEC := 0.5
const TERRAIN_PASS_INTERVAL_SEC := 0.5
const MAX_TASKS_PER_PASS := 1024
const MAX_TERRAIN_COORDS_PER_PASS := 256
const MAX_RECORDS := 5000
const MAX_FILE_BYTES := 16 * 1024 * 1024
const MAX_EVENTS_PER_CHECK_PER_MINUTE := 20

## Seconds a condition must hold before it is logged.
const THRESHOLDS := {
	"worker_invalid_position": 0.0,
	"worker_out_of_tree": 1.0,
	"worker_in_solid": 1.0,
	"worker_unsupported": 1.0,
	"worker_no_progress": 30.0,
	"worker_task_missing": 2.0,
	"task_assignment_mismatch": 2.0,
	"task_in_progress_too_long": 90.0,
	"task_pending_with_idle_worker": 60.0,
	"terrain_mesh_not_built": 30.0,
	"terrain_ready_without_node": 5.0,
	"terrain_hidden_geometry": 5.0,
	"terrain_stale_mesh": 5.0,
}
const TASK_CYCLE_LIMIT := 4
const TASK_CYCLE_WINDOW_SEC := 120.0
const NO_PROGRESS_STATES := [Worker.WorkerState.MOVING, Worker.WorkerState.WAITING, Worker.WorkerState.WAITING_FOR_PATH]

var enabled := false
## Empty disables file output (tests read records instead).
var output_root := OUTPUT_ROOT
## When true, written records are also retained in memory (bounded by MAX_RECORDS).
var keep_records := false
var records: Array = []
var world = null
var playtest := false
var sim_time := 0.0
var wall_time := 0.0
var output_path := ""
var records_written := 0
var bytes_written := 0
var suppressed := 0
var open_count := 0

var _file: FileAccess = null
var _file_failed := false
var _sim_pass_timer := 0.0
var _terrain_pass_timer := 0.0
var _epoch := -1
## key -> {since, opened, opened_at, seen_cycle, check, subject}
var _conditions := {}
var _sim_cycle := 0
var _terrain_cycle := 0
var _task_offset := 0
var _terrain_keys: Array = []
var _terrain_index := 0
var _mesh_backlog := false
## task_id -> {last_status, releases: Array[float]}
var _task_history := {}
var _known_workers := {}
var _event_windows := {}


func setup(world_ref, is_playtest: bool = false) -> void:
	world = world_ref
	playtest = is_playtest
	enabled = OS.is_debug_build()


## Called once per world update. advanced is false on paused playtest frames;
## sim_steps is how many simulation steps of dt ran this frame (debug speed).
func tick(dt: float, advanced: bool, sim_steps: int = 1) -> void:
	if not enabled or world == null:
		return
	if world.runtime_epoch != _epoch:
		_reset_for_epoch()
	wall_time += dt
	if advanced:
		sim_time += dt * sim_steps
		_sim_pass_timer += dt * sim_steps
		if _sim_pass_timer >= SIM_PASS_INTERVAL_SEC:
			_sim_pass_timer = 0.0
			_sim_cycle += 1
			_check_workers()
			_check_tasks()
			_expire_unseen(_sim_cycle, false)
	_terrain_pass_timer += dt
	if _terrain_pass_timer >= TERRAIN_PASS_INTERVAL_SEC:
		_terrain_pass_timer = 0.0
		_check_terrain()


## Immediate events from gameplay hooks, e.g. falls and rescues.
func report_event(check: String, subject: String, details: Dictionary = {}, worker = null) -> void:
	if not enabled:
		return
	var now := wall_time
	var window: Array = _event_windows.get(check, [])
	while not window.is_empty() and now - float(window[0]) > 60.0:
		window.pop_front()
	if window.size() >= MAX_EVENTS_PER_CHECK_PER_MINUTE:
		suppressed += 1
		return
	window.append(now)
	_event_windows[check] = window
	var record := details.duplicate()
	if worker != null:
		record["worker"] = Decision.worker_snapshot(worker)
	_write("event", check, subject, record)


#region Workers
func _check_workers() -> void:
	var present := {}
	for worker in world.workers:
		if not is_instance_valid(worker):
			continue
		present[worker.worker_id] = true
		var subject := "worker:%d" % worker.worker_id
		var pos: Vector3 = worker.position
		var finite := is_finite(pos.x) and is_finite(pos.y) and is_finite(pos.z)
		_condition("worker_invalid_position", subject, not finite, worker)
		if not finite:
			continue
		var coord: Vector3i = worker.get_block_coord()
		var falling: bool = worker.state == Worker.WorkerState.FALLING
		_condition("worker_out_of_tree", subject, not worker.is_inside_tree(), worker)
		_condition("worker_in_solid", subject, not falling and _is_solid_cell(coord), worker)
		_condition("worker_unsupported", subject, not falling and not _worker_supported(worker), worker)
		_track_progress(worker, subject, coord)
		_condition("worker_task_missing", subject,
			worker.current_task_id >= 0 and world.task_queue.get_task(worker.current_task_id) == null, worker)
	for worker_id in _known_workers.keys():
		if not present.has(worker_id):
			report_event("worker_removed", "worker:%d" % worker_id, {"last_known": _known_workers[worker_id]})
			_known_workers.erase(worker_id)
	for worker in world.workers:
		if is_instance_valid(worker):
			_known_workers[worker.worker_id] = {"pos": Data.plain(worker.get_block_coord()), "role_id": worker.role_id}


func _track_progress(worker, subject: String, coord: Vector3i) -> void:
	var key := "worker_no_progress|" + subject
	var stuck_state: bool = NO_PROGRESS_STATES.has(worker.state)
	var entry: Dictionary = _conditions.get(key, {})
	if stuck_state and not entry.is_empty() and entry.get("coord") == coord and entry.get("state") == worker.state:
		_condition("worker_no_progress", subject, true, worker)
		return
	# Any movement or state change restarts the clock.
	_condition("worker_no_progress", subject, false, worker)
	if stuck_state:
		_condition("worker_no_progress", subject, true, worker)
		_conditions[key]["coord"] = coord
		_conditions[key]["state"] = worker.state


func _is_solid_cell(coord: Vector3i) -> bool:
	if not world.is_block_coord_valid(coord.x, coord.y, coord.z) or not world._is_loaded_generated_cell(coord):
		return false
	var block_id: int = world.get_block_no_generate(coord.x, coord.y, coord.z)
	return world.is_block_solid_id(block_id) and not world.is_ramp_block_id(block_id)


func _worker_supported(worker) -> bool:
	var coord: Vector3i = worker.get_block_coord()
	for cell: Vector3i in [coord, coord + Vector3i.DOWN]:
		if world.is_block_coord_valid(cell.x, cell.y, cell.z) and not world._is_loaded_generated_cell(cell):
			return true # Unknown terrain is not evidence of a fall.
	if worker.state == Worker.WorkerState.MOVING and worker.path_segment_validated:
		return true
	return worker._has_standing_support(world) or worker._has_supported_path_segment(world)
#endregion


#region Tasks
func _check_tasks() -> void:
	var tasks: Array = world.task_queue.tasks
	var count := tasks.size()
	if count == 0:
		_task_history.clear()
		return
	var limit := mini(count, MAX_TASKS_PER_PASS)
	_task_offset = _task_offset % count
	var idle_workers := _idle_workers()
	for i in limit:
		var task = tasks[(_task_offset + i) % count]
		if task == null:
			continue
		_check_task(task, idle_workers)
	_task_offset += limit
	for task_id in _task_history.keys():
		if world.task_queue.get_task(task_id) == null:
			_task_history.erase(task_id)


func _check_task(task, idle_workers: Array) -> void:
	var subject := "task:%d" % task.id
	var in_progress: bool = task.status == TaskQueue.TaskStatus.IN_PROGRESS
	var pending: bool = task.status == TaskQueue.TaskStatus.PENDING
	var assigned = task.assigned_worker
	var mismatch: bool = in_progress and (assigned == null or not is_instance_valid(assigned) or assigned.current_task_id != task.id)
	_condition("task_assignment_mismatch", subject, mismatch, assigned if is_instance_valid(assigned) else null, task)
	_condition("task_in_progress_too_long", subject, in_progress, assigned if is_instance_valid(assigned) else null, task)
	var waiting_on_idle := false
	if pending and task.accessibility != TaskQueue.TaskAccessibility.UNREACHABLE:
		for worker in idle_workers:
			if worker.can_accept_task(task):
				waiting_on_idle = true
				break
	_condition("task_pending_with_idle_worker", subject, waiting_on_idle, null, task)
	# Released-to-pending transitions without completion indicate a retry loop.
	var history: Dictionary = _task_history.get(task.id, {"last_status": task.status, "releases": []})
	if history.last_status == TaskQueue.TaskStatus.IN_PROGRESS and pending:
		history.releases.append(sim_time)
	while not history.releases.is_empty() and sim_time - float(history.releases[0]) > TASK_CYCLE_WINDOW_SEC:
		history.releases.pop_front()
	if history.releases.size() >= TASK_CYCLE_LIMIT and not history.get("reported", false):
		history["reported"] = true
		report_event("task_cycling", subject, {"releases_in_window": history.releases.size(),
			"window_sec": TASK_CYCLE_WINDOW_SEC, "task": Decision.task_snapshot(task)})
	history.last_status = task.status
	_task_history[task.id] = history


func _idle_workers() -> Array:
	var idle := []
	for worker in world.workers:
		if is_instance_valid(worker) and worker.state == Worker.WorkerState.IDLE and worker.current_task_id < 0:
			idle.append(worker)
	return idle
#endregion


#region Terrain
func _check_terrain() -> void:
	var renderer = world.renderer
	if renderer == null or not renderer.is_render_zone_initialized():
		return
	var visibility: Dictionary = renderer.get_visibility_snapshot()
	# Mid-application views are expected to be incomplete. Restart unopened
	# terrain timers so time spent unsettled never counts toward a threshold.
	if visibility.get("mixed_view", false) or visibility.get("requested_view_pending", false) \
			or visibility.get("application_pending", false):
		for key in _conditions.keys():
			var entry: Dictionary = _conditions[key]
			if entry.terrain and not entry.opened:
				_conditions.erase(key)
		return
	# A meshing backlog (startup, cache invalidation) legitimately leaves visible
	# chunks unbuilt for a while; only flag unbuilt chunks once the queue drains.
	_mesh_backlog = renderer.has_pending_mesh_work(false)
	if _terrain_index >= _terrain_keys.size():
		_terrain_cycle += 1
		_expire_unseen(_terrain_cycle, true)
		_terrain_keys = renderer.render_zone_visible.keys()
		_terrain_index = 0
	var end := mini(_terrain_index + MAX_TERRAIN_COORDS_PER_PASS, _terrain_keys.size())
	for i in range(_terrain_index, end):
		_check_chunk(renderer, _terrain_keys[i])
	_terrain_index = end


func _check_chunk(renderer, coord: Vector3i) -> void:
	var chunk = world.get_chunk(coord)
	if chunk == null or not chunk.generated:
		return
	var subject := "chunk:%d,%d,%d" % [coord.x, coord.y, coord.z]
	var job_pending: bool = renderer.mesh_scheduler.mesh_job_set.has(coord)
	var ready: bool = chunk.mesh_state == ChunkData.MESH_STATE_READY
	var node: MeshInstance3D = renderer.chunk_cache.get_chunk(coord)
	var has_geometry := node != null and node.mesh != null and node.mesh.get_surface_count() > 0
	var applied := int(node.get_meta("diagnostics_mesh_revision", -1)) if node != null else -1
	var details := {"coord": coord, "mesh_state": chunk.mesh_state, "mesh_revision": chunk.mesh_revision,
		"applied_revision": applied, "job_pending": job_pending, "node_exists": node != null,
		"node_visible": node.visible if node != null else null, "has_geometry": has_geometry}
	_condition("terrain_mesh_not_built", subject, not ready and not job_pending and not _mesh_backlog, null, null, details, true)
	_condition("terrain_ready_without_node", subject, ready and node == null, null, null, details, true)
	_condition("terrain_hidden_geometry", subject, ready and has_geometry and not node.visible, null, null, details, true)
	_condition("terrain_stale_mesh", subject, ready and node != null and applied >= 0 \
		and applied < chunk.mesh_revision and not job_pending, null, null, details, true)
#endregion


#region Condition lifecycle
func _condition(check: String, subject: String, active: bool, worker = null, task = null,
		details: Dictionary = {}, terrain := false) -> void:
	var key := check + "|" + subject
	var now := wall_time if terrain else sim_time
	var cycle := _terrain_cycle if terrain else _sim_cycle
	var entry: Dictionary = _conditions.get(key, {})
	if not active:
		if entry.is_empty():
			return
		if entry.opened:
			_resolve(entry, "cleared", now)
		_conditions.erase(key)
		return
	if entry.is_empty():
		entry = {"check": check, "subject": subject, "since": now, "opened": false, "terrain": terrain}
		_conditions[key] = entry
	entry["seen_cycle"] = cycle
	if entry.opened or now - float(entry.since) < float(THRESHOLDS.get(check, 0.0)):
		return
	entry["opened"] = true
	entry["opened_at"] = now
	open_count += 1
	var record := details.duplicate()
	record["held_sec"] = snappedf(now - float(entry.since), 0.01)
	if worker != null:
		record["worker"] = Decision.worker_snapshot(worker)
	if task != null:
		record["task"] = Decision.task_snapshot(task)
	elif worker != null and worker.current_task_id >= 0:
		var current = world.task_queue.get_task(worker.current_task_id)
		if current != null:
			record["task"] = Decision.task_snapshot(current)
	_write("opened", check, subject, record)


func _resolve(entry: Dictionary, reason: String, now: float) -> void:
	open_count = maxi(0, open_count - 1)
	_write("resolved", entry.check, entry.subject, {"reason": reason,
		"open_sec": snappedf(now - float(entry.get("opened_at", now)), 0.01)})


## Conditions whose entity was not visited during a whole cycle no longer exist.
func _expire_unseen(cycle: int, terrain: bool) -> void:
	for key in _conditions.keys():
		var entry: Dictionary = _conditions[key]
		if bool(entry.terrain) != terrain or int(entry.get("seen_cycle", cycle)) >= cycle - 1:
			continue
		if entry.opened:
			_resolve(entry, "entity_gone", wall_time if terrain else sim_time)
		_conditions.erase(key)


func _reset_for_epoch() -> void:
	if _epoch >= 0:
		for key in _conditions:
			var entry: Dictionary = _conditions[key]
			if entry.opened:
				_resolve(entry, "world_reset", wall_time if entry.terrain else sim_time)
	_epoch = world.runtime_epoch
	_conditions.clear()
	_task_history.clear()
	_known_workers.clear()
	_terrain_keys.clear()
	_terrain_index = 0
	_write("session", "world_epoch", "world", {"seed": world.get("world_seed"), "playtest": playtest})
#endregion


#region Output
func _write(kind: String, check: String, subject: String, data: Dictionary) -> void:
	if records_written >= MAX_RECORDS or bytes_written >= MAX_FILE_BYTES:
		suppressed += 1
		return
	var record := {"v": FORMAT_VERSION, "kind": kind, "check": check, "subject": subject,
		"sim_time": snappedf(sim_time, 0.01), "wall_time": snappedf(wall_time, 0.01),
		"world_epoch": _epoch, "frame": Engine.get_process_frames(),
		"datetime": Time.get_datetime_string_from_system(), "data": Data.plain(data)}
	if suppressed > 0:
		record["suppressed_before"] = suppressed
		suppressed = 0
	var line := JSON.stringify(record) + "\n"
	bytes_written += line.to_utf8_buffer().size()
	records_written += 1
	if keep_records:
		records.append(record)
	if _open_file():
		_file.store_string(line)
		_file.flush()
	var service = world.get("live_diagnostics")
	if service != null and service.enabled and kind != "session":
		service.mark_event("anomaly", {"kind": kind, "check": check, "subject": subject})


func _open_file() -> bool:
	if _file != null:
		return true
	if _file_failed or output_root.is_empty():
		return false
	var stamp := Time.get_datetime_string_from_system().replace(":", "-")
	var dir := "%s/%s-%d" % [output_root, stamp, OS.get_process_id()]
	if DirAccess.make_dir_recursive_absolute(dir) != OK:
		_file_failed = true
		push_warning("Anomaly watchdog could not create %s" % dir)
		return false
	output_path = dir + "/anomalies.jsonl"
	_file = FileAccess.open(output_path, FileAccess.WRITE)
	if _file == null:
		_file_failed = true
		push_warning("Anomaly watchdog could not open %s" % output_path)
		return false
	return true


func close() -> void:
	if _file != null:
		_file.close()
		_file = null
#endregion
