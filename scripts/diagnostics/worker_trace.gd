extends RefCounted
class_name WorkerTrace
## Writes low-frequency worker lifecycle and task events to a diagnostic CSV.

const DiagnosticsCsvWriterScript = preload("res://scripts/diagnostics/csv_writer.gd")

const TRACE_DIR := "user://diagnostics"
const TRACE_FLUSH_INTERVAL_MS := 250
const TRACE_COLUMNS := [
	"elapsed_ms",
	"datetime",
	"worker_id",
	"worker_role",
	"event",
	"state",
	"worker_x",
	"worker_y",
	"worker_z",
	"task_id",
	"task_type",
	"target_x",
	"target_y",
	"target_z",
	"path_index",
	"path_length",
	"details",
]

var enabled := false
var trace_path := ""
var trace_file: FileAccess
var start_ms: int = 0
var last_flush_ms: int = 0


func start(workers: Array) -> bool:
	stop()
	if not DiagnosticsCsvWriterScript.ensure_dir(TRACE_DIR):
		push_warning("Worker trace directory failed: %s" % TRACE_DIR)
		return false
	var stamp := Time.get_datetime_string_from_system().replace(":", "-").replace(" ", "_")
	trace_path = TRACE_DIR.path_join("worker_trace_%s_%d.csv" % [stamp, Time.get_ticks_msec()])
	trace_file = FileAccess.open(trace_path, FileAccess.WRITE)
	if trace_file == null:
		push_warning("Worker trace failed: %s" % trace_path)
		trace_path = ""
		return false
	trace_file.store_line(DiagnosticsCsvWriterScript.row_from_values(TRACE_COLUMNS))
	start_ms = Time.get_ticks_msec()
	last_flush_ms = start_ms
	enabled = true
	for worker in workers:
		record(worker, "trace_snapshot", null, "trace enabled")
	trace_file.flush()
	print("Worker trace enabled: %s" % ProjectSettings.globalize_path(trace_path))
	return true


func stop() -> void:
	if trace_file != null:
		trace_file.flush()
		trace_file = null
	if enabled and not trace_path.is_empty():
		print("Worker trace saved: %s" % ProjectSettings.globalize_path(trace_path))
	enabled = false
	start_ms = 0
	last_flush_ms = 0
	trace_path = ""


func record(worker, event: String, task = null, details: String = "") -> void:
	if not enabled or trace_file == null or worker == null:
		return
	_store_row(worker, event, task, details)


func record_task_event(task, event: String, details: String = "") -> void:
	if not enabled or trace_file == null or task == null:
		return
	_store_row(task.assigned_worker, event, task, details)


func record_system_event(event: String, details: String = "") -> void:
	if not enabled or trace_file == null:
		return
	_store_row(null, event, null, details)


func _store_row(worker, event: String, task, details: String) -> void:
	var worker_pos := Vector3i.ZERO
	if worker != null:
		worker_pos = worker.get_block_coord()
	var target := Vector3i.ZERO
	var task_id := -1
	var task_type := "none"
	if task != null:
		task_id = task.id
		task_type = _task_type_name(task.type)
		target = task.pos
	var row := [
		Time.get_ticks_msec() - start_ms,
		Time.get_datetime_string_from_system(),
		worker.worker_id if worker != null else -1,
		worker.get_role_name() if worker != null else "",
		event,
		_worker_state_name(worker.state) if worker != null else "",
		worker_pos.x if worker != null else "",
		worker_pos.y if worker != null else "",
		worker_pos.z if worker != null else "",
		task_id,
		task_type,
		target.x if task != null else "",
		target.y if task != null else "",
		target.z if task != null else "",
		worker.path_index if worker != null else "",
		worker.path.size() if worker != null else "",
		details,
	]
	trace_file.store_line(DiagnosticsCsvWriterScript.row_from_values(row))
	var now_ms := Time.get_ticks_msec()
	if now_ms - last_flush_ms >= TRACE_FLUSH_INTERVAL_MS:
		trace_file.flush()
		last_flush_ms = now_ms


func _worker_state_name(state: int) -> String:
	var names := Worker.WorkerState.keys()
	if state < 0 or state >= names.size():
		return "UNKNOWN"
	return str(names[state])


func _task_type_name(task_type: int) -> String:
	var names := TaskQueue.TaskType.keys()
	if task_type < 0 or task_type >= names.size():
		return "UNKNOWN"
	return str(names[task_type])
