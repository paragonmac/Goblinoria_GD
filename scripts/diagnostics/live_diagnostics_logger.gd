extends Logger
## Logger can be called on engine threads. Never touch scene state or log here.
const MAX_ROWS := 256
const MAX_BYTES := 256 * 1024
var _mutex := Mutex.new()
var _rows: Array = []
var _bytes := 0
var _dropped := 0

func _log_error(function: String, file: String, line: int, code: String, rationale: String, _editor_notify: bool, error_type: int, _script_backtraces: Array[ScriptBacktrace]) -> void:
	var row := {"monotonic_usec": Time.get_ticks_usec(), "function": function.left(128),
		"file": file.left(256), "line": line, "code": code.left(512),
		"message": rationale.left(1024), "type": error_type}
	var bytes := JSON.stringify(row).to_utf8_buffer().size()
	_mutex.lock()
	if _rows.size() < MAX_ROWS and _bytes + bytes <= MAX_BYTES:
		_rows.append(row)
		_bytes += bytes
	else:
		_dropped += 1
	_mutex.unlock()

func drain() -> Dictionary:
	_mutex.lock()
	var result := {"rows": _rows, "dropped": _dropped}
	_rows = []
	_bytes = 0
	_dropped = 0
	_mutex.unlock()
	return result
