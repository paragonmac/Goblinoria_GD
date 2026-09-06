extends SceneTree

# Run with --headless --log-file <TEMP>/goblinoria-live-transport.log.
# Descriptors are isolated under TEMP; no default user:// diagnostics are touched.
# Append -- --pwsh to also validate with PowerShell 7 on Windows.

const Transport = preload("res://scripts/diagnostics/live_diagnostics_transport.gd")
var _checks := 0
var _errors: Array[String] = []
var _root := ""
var _transport: RefCounted
var _token := ""
var _now := 0
var _serial := 0
var _calls: Array[Dictionary] = []
var _peers: Array[StreamPeerTCP] = []
var _buffers: Dictionary = {}
var _messages: Dictionary = {}
var _capture_polls := 0
var _capture_outcome := "complete"


func _init() -> void:
	_run.call_deferred()


func _run() -> void:
	var temporary := OS.get_environment("TEMP") if OS.get_name() == "Windows" else OS.get_environment("TMPDIR")
	if temporary.is_empty():
		temporary = "/tmp" if OS.get_name() != "Windows" else OS.get_cache_dir()
	_root = temporary.path_join("goblinoria-live-transport-test-%d-%d" % [OS.get_process_id(), Time.get_ticks_usec()])
	_test_lifecycle()
	_test_protocol()
	_test_invalid_utf8()
	_test_bounds()
	_test_timeouts()
	_test_handler_lifecycle()
	_test_client()
	_reset()
	DirAccess.remove_absolute(_root)
	if _errors.is_empty():
		print("LIVE_DIAGNOSTICS_TRANSPORT_OK: %d checks" % _checks)
		quit(0)
	else:
		for error in _errors:
			push_error(error)
		quit(1)


func _check(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_errors.append(message)


func _reset() -> void:
	if _transport != null:
		_transport.stop()
	for peer in _peers:
		peer.disconnect_from_host()
	_peers.clear()
	_buffers.clear()
	_messages.clear()
	_calls.clear()


func _start() -> void:
	_reset()
	_serial += 1
	_now = 0
	_transport = Transport.new()
	_transport.descriptor_root = _root
	_check(_transport.start("test-%d" % _serial) == OK, "transport starts with injected descriptor root")
	if not _transport.enabled:
		return
	var descriptor: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(_transport.descriptor_path))
	_token = descriptor.token
	_check(descriptor.host == "127.0.0.1" and descriptor.port == _transport.port, "descriptor contains loopback ephemeral port")
	_check(descriptor.pid == OS.get_process_id() and descriptor.session_id == "test-%d" % _serial, "descriptor identifies process and session")
	_check(_token.length() == 64 and _token.is_valid_hex_number(), "descriptor has cryptographic 256-bit token")


func _handler(op: String, args: Dictionary) -> Dictionary:
	_calls.append({"op": op, "args": args})
	if args.has("size"):
		return {"payload": "x".repeat(int(args.size))}
	if op == "capture_bug":
		_capture_polls = 0
		return {"session_id": "service-stamp", "world_epoch": 1, "frame_id": 123,
			"data": {"capture_id": "capture-test", "state": "pending"}}
	if op == "capture_status":
		_capture_polls += 1
		return {"session_id": "service-stamp", "world_epoch": 1, "frame_id": 123,
			"data": {"capture_id": "capture-test", "state": _capture_outcome if _capture_polls >= 2 else "writing"}}
	if op == "status":
		return {"op": op, "args": args, "session_id": "service-stamp", "frame": 123,
			"world_epoch": 7, "data": {"view_id": "view-test"}}
	return {"op": op, "args": args, "session_id": "service-stamp", "frame": 123}


func _connect(expect_accept := true) -> StreamPeerTCP:
	var peer := StreamPeerTCP.new()
	_check(peer.connect_to_host("127.0.0.1", _transport.port) == OK, "real TCP connection starts")
	peer.set_no_delay(true)
	_peers.append(peer)
	_buffers[peer.get_instance_id()] = PackedByteArray()
	_messages[peer.get_instance_id()] = []
	for _index in range(100):
		_tick()
		if not expect_accept:
			return peer
		if peer.get_status() == StreamPeerTCP.STATUS_CONNECTED:
			break
	_check(peer.get_status() == StreamPeerTCP.STATUS_CONNECTED, "real TCP connection completes")
	return peer


func _tick(count := 1, step := 1000) -> void:
	for _index in range(count):
		_now += step
		_transport.poll(_handler, _now)
		for peer in _peers:
			peer.poll()
			if peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
				continue
			var available := peer.get_available_bytes()
			if available <= 0:
				continue
			var received := peer.get_partial_data(available)
			if received[0] != OK:
				continue
			var key := peer.get_instance_id()
			var buffer: PackedByteArray = _buffers[key]
			buffer.append_array(received[1])
			var newline := buffer.find(10)
			while newline >= 0:
				var text := buffer.slice(0, newline).get_string_from_utf8()
				_check(not text.contains(_token), "responses never contain the descriptor token")
				var parsed: Variant = JSON.parse_string(text)
				_check(parsed is Dictionary, "wire response is a complete JSON object")
				if parsed is Dictionary:
					_messages[key].append(parsed)
				buffer = buffer.slice(newline + 1)
				newline = buffer.find(10)
			_buffers[key] = buffer
		OS.delay_usec(1000)


func _wire(id: Variant = "request", op := "status", args: Dictionary = {}) -> String:
	return JSON.stringify({"id": id, "token": _token, "op": op, "args": args}) + "\n"


func _test_invalid_utf8() -> void:
	_start()
	var logger = preload("res://scripts/diagnostics/live_diagnostics_logger.gd").new()
	OS.add_logger(logger)
	var peer := _connect()
	for invalid in [PackedByteArray([255]), PackedByteArray([192, 175]), PackedByteArray([224, 128, 128]), PackedByteArray([237, 160, 128]), PackedByteArray([244, 144, 128, 128]), PackedByteArray([226, 130])]:
		_check(not Transport._valid_utf8(invalid), "invalid UTF-8 rejected before decoder")
		var wire: PackedByteArray = invalid.duplicate()
		wire.append(10)
		_check(peer.put_data(wire) == OK, "malformed UTF-8 request sent")
		_error(_take(peer), "invalid_request")
	_check(logger.drain().rows.is_empty(), "malformed UTF-8 causes no engine log spam")
	OS.remove_logger(logger)


func _send(peer: StreamPeerTCP, wire: String) -> void:
	_check(peer.put_data(wire.to_utf8_buffer()) == OK, "test request sent")


func _take(peer: StreamPeerTCP, attempts := 100) -> Dictionary:
	var queue: Array = _messages[peer.get_instance_id()]
	for _index in range(attempts):
		if not queue.is_empty():
			return queue.pop_front()
		_tick()
	_check(false, "received a response before test deadline")
	return {}


func _error(reply: Dictionary, code: String) -> void:
	_check(reply.get("error", {}).get("code", "") == code and not reply.has("result"), "expected protocol error: " + code)


func _test_lifecycle() -> void:
	_start()
	var path: String = _transport.descriptor_path
	_check(path.get_file() == "test-%d-%d.json" % [_serial, OS.get_process_id()], "descriptor filename is session-pid.json")
	_check(_transport.start("other") == ERR_ALREADY_IN_USE, "double start preserves active listener")
	_check(_transport.descriptor_path == path and FileAccess.file_exists(path), "double start preserves descriptor")
	var old_token := _token
	_transport.stop()
	_check(not _transport.enabled and _transport.port == 0 and not FileAccess.file_exists(path), "stop disables listener and removes descriptor")
	_transport.stop()
	_check(_transport.start("../escape") == ERR_INVALID_PARAMETER, "session path traversal rejected")
	_check(_transport.start("restart") == OK, "transport restarts after stop")
	var descriptor: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(_transport.descriptor_path))
	_check(descriptor.token != old_token, "restart rotates authentication token")
	path = _transport.descriptor_path
	_transport.enabled = false
	_transport.poll(_handler, _now)
	_check(not FileAccess.file_exists(path) and _transport.port == 0, "direct disable cleans up on next poll")
	var blocker_path := _root.path_join("blocked")
	var blocker := FileAccess.open(blocker_path, FileAccess.WRITE)
	blocker.store_string("not a directory")
	blocker.close()
	_transport.descriptor_root = blocker_path
	_check(_transport.start("fail") != OK and not _transport.enabled and _transport.port == 0, "descriptor failure rolls back listener")
	_check(not _transport.last_error.is_empty() and not _transport.last_error.contains(old_token), "startup failure gives credential-free error")
	DirAccess.remove_absolute(blocker_path)
	_transport.descriptor_root = _root
	var collision := _root.path_join("collision-%d.json" % OS.get_process_id())
	blocker = FileAccess.open(collision, FileAccess.WRITE)
	blocker.store_string("existing descriptor")
	blocker.close()
	_check(_transport.start("collision") == ERR_ALREADY_EXISTS, "existing descriptor is not overwritten")
	_check(FileAccess.get_file_as_string(collision) == "existing descriptor", "failed start preserves foreign descriptor")
	DirAccess.remove_absolute(collision)
	var released = Transport.new()
	released.descriptor_root = _root
	_check(released.start("released") == OK, "temporary transport starts")
	path = released.descriptor_path
	released = null
	_check(not FileAccess.file_exists(path), "releasing transport removes descriptor")


func _test_protocol() -> void:
	_start()
	var peer := _connect()
	var wire := _wire("fragment", "inspect_cell", {"x": 7})
	_send(peer, wire.substr(0, 11))
	_tick(3)
	_check(_calls.is_empty(), "partial request is not dispatched")
	_send(peer, wire.substr(11))
	var reply := _take(peer)
	_check(reply.get("id") == "fragment" and reply.get("result", {}).get("frame") == 123, "ID and service stamps survive transport")
	_check(_calls.size() == 1 and _calls[0].op == "inspect_cell" and _calls[0].args.get("x") == 7, "handler receives operation and dictionary arguments")
	_send(peer, _wire(1) + _wire(2) + _wire(3))
	for _index in range(3):
		var before := _calls.size()
		_tick()
		_check(_calls.size() - before <= 1, "at most one request is dispatched per frame")
	for id in [1, 2, 3]:
		_check(_take(peer).get("id") == id, "pipelined responses remain ordered")
	for invalid in ["{\n", "[]\n", "null\n", "\n"]:
		_send(peer, invalid)
		_error(_take(peer), "invalid_request")
	var unicode_text := String.chr(0x1f600)
	var unicode_wire := _wire("utf8", "status", {"text": unicode_text}).to_utf8_buffer()
	var split := unicode_wire.find(0xf0) + 1
	_check(peer.put_data(unicode_wire.slice(0, split)) == OK, "request can split within a UTF-8 sequence")
	_tick(2)
	_check(peer.put_data(unicode_wire.slice(split)) == OK, "UTF-8 sequence tail sent")
	_check(_take(peer).get("result", {}).get("args", {}).get("text") == unicode_text, "fragmented UTF-8 roundtrips")
	_send(peer, _wire("crlf").trim_suffix("\n") + "\r\n")
	_check(_take(peer).get("id") == "crlf", "CRLF framing accepted")
	for change in [{"args": []}, {"id": {}}, {"op": 3}, {"extra": true}, {"id": null}, {"id": 1.5}]:
		var request: Dictionary = JSON.parse_string(_wire())
		request.merge(change, true)
		_send(peer, JSON.stringify(request) + "\n")
		_error(_take(peer), "invalid_request")
	_send(peer, _wire("mutation", "delete_world"))
	_error(_take(peer), "unknown_operation")
	_send(peer, _wire(_token, "status", {"echo": _token}))
	reply = _take(peer)
	_check(reply.get("id") == "[redacted]" and reply.get("result", {}).get("args", {}).get("echo") == "[redacted]", "credentials are redacted even in IDs and handler results")
	for op in Transport.OPERATIONS:
		_now += 1_000_000
		_send(peer, _wire(op, op))
		_check(_take(peer).has("result"), "allowlisted operation dispatches: " + op)
	var call_count := _calls.size()
	var bad_auth := _connect()
	_send(bad_auth, _wire(_token).replace('"token":"' + _token + '"', '"token":"wrong"'))
	reply = _take(bad_auth)
	_error(reply, "unauthorized")
	_check(reply.get("id") == null and _calls.size() == call_count, "authentication failure does not reflect ID or invoke service")
	_tick(3)
	_check(_transport._clients.size() == 1, "unauthenticated client is closed")
	peer.disconnect_from_host()
	_tick(3)
	_check(_transport._clients.is_empty(), "disconnected client is reclaimed")


func _test_bounds() -> void:
	_start()
	var peer := _connect()
	var second := _connect()
	var excess := _connect(false)
	_tick(5)
	excess.poll()
	_check(_transport._clients.size() == 2 and excess.get_status() != StreamPeerTCP.STATUS_CONNECTED, "third TCP client is rejected")
	for index in range(10):
		var target := peer if index % 2 == 0 else second
		_send(target, _wire(index))
		_check(_take(target).has("result"), "first ten queries in rolling second succeed")
	_send(second, _wire(11))
	_error(_take(second), "rate_limited")
	_check(_calls.size() == 10, "rate limit is shared across clients")
	_now += 1_000_000
	_send(peer, _wire(12))
	_check(_take(peer).has("result"), "rolling rate limit expires")
	_start()
	peer = _connect()
	var exact := _wire("exact", "status", {"padding": ""})
	exact = _wire("exact", "status", {"padding": "x".repeat(Transport.MAX_REQUEST_BYTES - exact.to_utf8_buffer().size())})
	_check(exact.to_utf8_buffer().size() == Transport.MAX_REQUEST_BYTES, "test request is exactly 8 KiB including delimiter")
	_send(peer, exact)
	_check(_take(peer).has("result"), "8 KiB request accepted")
	_send(peer, "x".repeat(Transport.MAX_REQUEST_BYTES))
	_error(_take(peer), "request_too_large")
	_tick(3)
	_check(_transport._clients.is_empty(), "oversized unterminated request closes client")
	_start()
	peer = _connect()
	_send(peer, _wire("oversized", "status", {"size": Transport.MAX_RESPONSE_BYTES}))
	_error(_take(peer), "response_too_large")
	_send(peer, _wire("large", "status", {"size": 200_000}))
	var dispatched := false
	for _index in range(20):
		_tick()
		if _calls.size() == 2:
			dispatched = true
			break
	_check(dispatched, "large response dispatched")
	var sent: int = _buffers[peer.get_instance_id()].size()
	_check(sent <= Transport.MAX_DRAIN_BYTES and _messages[peer.get_instance_id()].is_empty(), "large response is limited to 64 KiB in first frame")
	_check(not _transport._clients[0].output.is_empty(), "partially written response retained")
	_send(peer, _wire("after-large"))
	var reply := _take(peer)
	_check(reply.get("result", {}).get("payload", "").length() == 200_000, "partial writes reassemble complete 200 KiB response")
	_check(_take(peer).get("id") == "after-large", "next response cannot overwrite partial response")
	_start()
	peer = _connect()
	var batch := ""
	for index in range(8):
		batch += _wire(index)
	_send(peer, batch)
	for index in range(8):
		_check(_take(peer).get("id") == index, "eight queued requests are accepted")
	_start()
	peer = _connect()
	_send(peer, batch + _wire(9))
	_error(_take(peer), "queue_full")
	_check(_calls.is_empty() and _transport._queue.is_empty(), "queue overflow drops offending backlog without service work")


func _test_timeouts() -> void:
	_start()
	var peer := _connect()
	_now += Transport.TIMEOUT_USEC
	_tick()
	_check(_transport._clients.is_empty(), "idle client expires after five seconds")
	peer = _connect()
	_send(peer, "{")
	_tick(2)
	_now += 3_000_000
	_send(peer, " ")
	_tick(2)
	_now += 2_000_000
	_tick()
	_check(_transport._clients.is_empty(), "slow partial request cannot extend absolute five-second deadline")
	peer = _connect()
	_send(peer, _wire("pending", "status", {"size": 200_000}) + _wire("queued"))
	for _index in range(20):
		_tick()
		if not _calls.is_empty():
			break
	_now += Transport.TIMEOUT_USEC
	_tick()
	_check(_transport._clients.is_empty() and _transport._queue.is_empty(), "response and queued work expire without dispatching stale work")


func _client(arguments: PackedStringArray, pump := true) -> Dictionary:
	var executable := "powershell.exe" if OS.get_name() == "Windows" else "pwsh"
	if "--pwsh" in OS.get_cmdline_user_args():
		executable = "pwsh"
	# Encode a PowerShell invocation so Windows native quoting cannot strip JSON
	# string quotes from test arguments. Every value is a PowerShell literal.
	var invocation := "& '" + ProjectSettings.globalize_path("res://tools/diagnostics_client.ps1").replace("'", "''") + "'"
	for argument in arguments:
		invocation += " " + (argument if argument.begins_with("-") else "'" + argument.replace("'", "''") + "'")
	var command := PackedStringArray(["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-EncodedCommand", Marshalls.raw_to_base64(invocation.to_utf16_buffer())])
	var process := OS.execute_with_pipe(executable, command, false)
	_check(not process.is_empty(), "PowerShell client process starts")
	if process.is_empty():
		return {"code": -1, "stdout": "", "stderr": ""}
	var stdout := PackedByteArray()
	var stderr := PackedByteArray()
	var started := Time.get_ticks_msec()
	while OS.is_process_running(process.pid) and Time.get_ticks_msec() - started < 15_000:
		stdout.append_array(process.stdio.get_buffer(4096))
		stderr.append_array(process.stderr.get_buffer(4096))
		if pump:
			_transport.poll(_handler, Time.get_ticks_usec())
		OS.delay_msec(2)
	if OS.is_process_running(process.pid):
		OS.kill(process.pid)
		_check(false, "PowerShell client exits before test deadline")
	stdout.append_array(process.stdio.get_buffer(65536))
	stderr.append_array(process.stderr.get_buffer(65536))
	var code := OS.get_process_exit_code(process.pid)
	process.stdio.close()
	process.stderr.close()
	var result := {"code": code, "stdout": stdout.get_string_from_utf8(), "stderr": stderr.get_string_from_utf8()}
	_check(not result.stdout.contains(_token) and not result.stderr.contains(_token), "PowerShell output does not disclose token")
	return result


func _test_handler_lifecycle() -> void:
	_start()
	var peer := _connect()
	_send(peer, _wire())
	for _index in range(20):
		_now += 1000
		_transport.poll(Callable(), _now)
		OS.delay_usec(1000)
	_tick()
	_error(_take(peer), "unavailable")
	_send(peer, _wire("bad-handler"))
	for _index in range(20):
		_now += 1000
		_transport.poll(func(_op: String, _args: Dictionary) -> Variant: return null, _now)
		OS.delay_usec(1000)
	_tick()
	_error(_take(peer), "invalid_result")
	_send(peer, _wire("stop-during-handler"))
	for _index in range(20):
		_now += 1000
		_transport.poll(func(_op: String, _args: Dictionary) -> Dictionary:
			_transport.stop()
			return {}, _now)
		OS.delay_usec(1000)
	_check(not _transport.enabled and _transport._clients.is_empty(), "handler can stop transport safely")


func _test_client() -> void:
	_start()
	var result := _client(["-DescriptorRoot", _root, "-ListSessions"])
	_check(result.code == 0, "PowerShell lists sessions successfully")
	var sessions: Variant = JSON.parse_string(result.stdout)
	_check(sessions is Array and sessions.size() == 1 and not sessions[0].has("token"), "session listing includes metadata without credentials")
	result = _client(["-DescriptorRoot", _root, "-Session", "test-%d" % _serial, "-Operation", "inspect_cell", "-ArgsJson", '{"x":42}'])
	_check(result.code == 0, "PowerShell selects session and executes query")
	var reply: Variant = JSON.parse_string(result.stdout)
	_check(reply is Dictionary and reply.get("result", {}).get("args", {}).get("x") == 42, "PowerShell JSON arguments reach service")
	_check(reply is Dictionary and reply.get("result", {}).get("args", {}).get("world_epoch") == 7, "PowerShell obtains missing inspection epoch from status")
	result = _client(["-DescriptorPath", _transport.descriptor_path, "-Operation", "inspect_screen"])
	reply = JSON.parse_string(result.stdout)
	_check(result.code == 0 and reply is Dictionary and reply.get("result", {}).get("args", {}).get("view_id") == "view-test", "PowerShell obtains missing screen view from status data")
	var calls_before := _calls.size()
	result = _client(["-DescriptorPath", _transport.descriptor_path, "-Operation", "inspect_screen", "-ArgsJson", '{"world_epoch":99,"view_id":"pinned"}'])
	reply = JSON.parse_string(result.stdout)
	_check(result.code == 0 and _calls.size() == calls_before + 1 and reply is Dictionary and reply.get("result", {}).get("args", {}).get("world_epoch") == 99 and reply.get("result", {}).get("args", {}).get("view_id") == "pinned", "explicit epoch and view bypass automatic status and are preserved")
	result = _client(["-DescriptorPath", _transport.descriptor_path, "-Operation", "list_workers", "-ArgsJson", '{"limit":20}'])
	reply = JSON.parse_string(result.stdout)
	_check(result.code == 0 and reply is Dictionary and reply.get("result", {}).get("args", {}).get("world_epoch") == 7 and reply.get("result", {}).get("args", {}).get("limit") == 20, "PowerShell fills first-page list epoch and preserves limit")
	for operation in ["inspect_worker", "inspect_task", "inspect_item", "list_workers", "list_tasks"]:
		calls_before = _calls.size()
		var arguments := '{"cursor":{"offset":1}}' if operation.begins_with("list_") else '{"id":7}'
		result = _client(["-DescriptorPath", _transport.descriptor_path, "-Operation", operation, "-ArgsJson", arguments])
		_check(result.code != 0 and result.stderr.contains("requires explicit world_epoch") and _calls.size() == calls_before, "PowerShell rejects missing epoch without making a query: " + operation)
	calls_before = _calls.size()
	result = _client(["-DescriptorPath", _transport.descriptor_path, "-Operation", "inspect_worker", "-ArgsJson", '{"world_epoch":99,"id":7}'])
	reply = JSON.parse_string(result.stdout)
	_check(result.code == 0 and _calls.size() == calls_before + 1 and reply is Dictionary and reply.get("result", {}).get("args", {}).get("world_epoch") == 99, "entity inspection preserves explicitly observed epoch without status lookup")
	calls_before = _calls.size()
	result = _client(["-DescriptorPath", _transport.descriptor_path, "-Operation", "capture_bug", "-WaitCapture", "-TimeoutSec", "10"])
	_check(result.code == 0 and _capture_polls == 2, "PowerShell polls asynchronous capture until completion")
	_check(_calls.size() > calls_before and _calls[calls_before].args.get("request_key", "").length() == 32, "PowerShell generates capture request key")
	_check(_calls.back().args.is_empty(), "capture status polling sends no arguments")
	reply = JSON.parse_string(result.stdout)
	_check(reply is Dictionary and reply.get("result", {}).get("data", {}).get("state") == "complete", "PowerShell returns terminal capture response with service stamps")
	_capture_outcome = "failed"
	result = _client(["-DescriptorPath", _transport.descriptor_path, "-Operation", "capture_bug", "-WaitCapture"])
	reply = JSON.parse_string(result.stdout)
	_check(result.code != 0 and reply is Dictionary and reply.get("result", {}).get("data", {}).get("state") == "failed", "PowerShell returns failed capture with nonzero exit status")
	_capture_outcome = "writing"
	result = _client(["-DescriptorPath", _transport.descriptor_path, "-Operation", "capture_bug", "-WaitCapture", "-TimeoutSec", "1"])
	_check(result.code != 0 and result.stderr.contains("timed out"), "capture polling shares the overall timeout")
	_capture_outcome = "complete"
	calls_before = _calls.size()
	result = _client(["-DescriptorPath", _transport.descriptor_path, "-Operation", "capture_bug", "-ArgsJson", '{"request_key":"retry-key","note":"test note"}'])
	_check(result.code == 0 and _calls.size() > calls_before and _calls[calls_before].args.get("request_key") == "retry-key" and _calls[calls_before].args.get("note") == "test note", "PowerShell preserves explicit capture key and note")
	result = _client(["-DescriptorPath", _transport.descriptor_path, "-ArgsJson", "[]"])
	_check(result.code != 0 and result.stderr.contains("JSON object"), "PowerShell rejects non-object args")
	result = _client(["-DescriptorPath", _transport.descriptor_path, "-ArgsJson", '{"padding":"' + "x".repeat(8192) + '"}'])
	_check(result.code != 0 and result.stderr.contains("exceeds 8 KiB"), "PowerShell rejects oversized requests before sending")
	var descriptor: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(_transport.descriptor_path))
	var alternate := _root.path_join("alternate.json")
	descriptor.token = "0".repeat(64)
	var file := FileAccess.open(alternate, FileAccess.WRITE)
	file.store_string(JSON.stringify(descriptor))
	file.close()
	result = _client(["-DescriptorRoot", _root])
	_check(result.code != 0 and result.stderr.contains("Multiple diagnostics sessions"), "PowerShell requires selection when sessions are ambiguous")
	result = _client(["-DescriptorPath", alternate])
	_check(result.code != 0 and result.stderr.contains("authentication failed"), "PowerShell reports authentication failure")
	DirAccess.remove_absolute(alternate)
	result = _client(["-DescriptorPath", _transport.descriptor_path, "-TimeoutSec", "1"], false)
	_check(result.code != 0 and result.stderr.contains("timed out"), "PowerShell enforces response deadline")
