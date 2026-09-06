class_name LiveDiagnosticsTransport
extends RefCounted

## Local, main-thread NDJSON bridge. Call poll once per frame; the handler owns
## service validation/stamps. No socket operation waits for a complete message.
const MAX_CLIENTS := 2
const MAX_REQUEST_BYTES := 8 * 1024
const MAX_RESPONSE_BYTES := 256 * 1024
const MAX_QUEUED := 8
const MAX_QUERIES_PER_SECOND := 10
const MAX_DRAIN_BYTES := 64 * 1024
const TIMEOUT_USEC := 5_000_000
const OPERATIONS := [
	"status", "inspect_screen", "inspect_cell", "inspect_chunk", "list_workers",
	"list_tasks", "inspect_worker", "inspect_task", "inspect_item",
	"inspect_stockpile", "recent_events", "capture_bug", "capture_status",
]

var descriptor_path := ""
var port := 0
var enabled := false
var last_error := ""
# Override before start for isolated tests or a custom application user directory.
var descriptor_root := "user://diagnostics/bridge"

var _server := TCPServer.new()
var _crypto := Crypto.new()
var _token := ""
var _clients: Array[Dictionary] = []
var _queue: Array[Dictionary] = []
var _query_times: Array[int] = []


func start(session_id: String) -> Error:
	if enabled:
		last_error = "Diagnostics transport is already enabled"
		return ERR_ALREADY_IN_USE
	last_error = ""
	if session_id.is_empty() or session_id.length() > 96:
		last_error = "Invalid diagnostics session ID"
		return ERR_INVALID_PARAMETER
	for character in session_id:
		if not character in "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-":
			last_error = "Invalid diagnostics session ID"
			return ERR_INVALID_PARAMETER
	var secret := _crypto.generate_random_bytes(32)
	if secret.size() != 32:
		last_error = "Cannot generate diagnostics credentials"
		return ERR_CANT_CREATE
	_token = secret.hex_encode()
	var error := _server.listen(0, "127.0.0.1")
	if error != OK:
		return _fail_start(error, "Cannot listen on diagnostics loopback socket")
	port = _server.get_local_port()
	var root := ProjectSettings.globalize_path(descriptor_root)
	if FileAccess.file_exists(root):
		return _fail_start(ERR_FILE_BAD_PATH, "Diagnostics descriptor root is not a directory")
	error = DirAccess.make_dir_recursive_absolute(root)
	if error != OK:
		return _fail_start(error, "Cannot create diagnostics descriptor directory")
	var path := root.path_join("%s-%d.json" % [session_id, OS.get_process_id()])
	# Do not replace another bridge's descriptor, even in an injected test root.
	if FileAccess.file_exists(path):
		return _fail_start(ERR_ALREADY_EXISTS, "Diagnostics descriptor already exists")
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return _fail_start(FileAccess.get_open_error(), "Cannot create diagnostics descriptor")
	descriptor_path = path
	file.store_string(JSON.stringify({
		"protocol_version": 1, "session_id": session_id, "pid": OS.get_process_id(),
		"host": "127.0.0.1", "port": port, "token": _token,
	}))
	file.flush()
	error = file.get_error()
	file.close()
	if error != OK:
		return _fail_start(error, "Cannot write diagnostics descriptor")
	enabled = true
	return OK


func _fail_start(error: Error, message: String) -> Error:
	stop()
	last_error = message
	return error


func stop() -> void:
	enabled = false
	_server.stop()
	for client in _clients:
		client.peer.disconnect_from_host()
	_clients.clear()
	_queue.clear()
	_query_times.clear()
	_token = ""
	port = 0
	if not descriptor_path.is_empty():
		var error := DirAccess.remove_absolute(descriptor_path)
		if error != OK and FileAccess.file_exists(descriptor_path):
			last_error = "Cannot remove diagnostics descriptor"
		else:
			descriptor_path = ""


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		# A dying RefCounted cannot call another GDScript method on itself.
		_server.stop()
		for client in _clients:
			client.peer.disconnect_from_host()
		if not descriptor_path.is_empty():
			DirAccess.remove_absolute(descriptor_path)


func poll(handler: Callable, now_usec: int) -> void:
	if not enabled:
		# Also clean up when the owning controller directly disables the bridge.
		if _server.is_listening():
			stop()
		return
	# Bound accepts as well as byte processing under a connection flood.
	for _index in range(MAX_CLIENTS + 1):
		if not _server.is_connection_available():
			break
		var peer := _server.take_connection()
		if peer == null:
			break
		if _clients.size() >= MAX_CLIENTS:
			peer.disconnect_from_host()
			continue
		peer.set_no_delay(true)
		_clients.append({
			"peer": peer, "input": PackedByteArray(), "input_since": -1,
			"output": PackedByteArray(), "offset": 0, "output_since": -1,
			"activity": now_usec, "closing": false,
		})
	var read_budget := MAX_DRAIN_BYTES
	for client in _clients.duplicate():
		var peer: StreamPeerTCP = client.peer
		peer.poll()
		if peer.get_status() != StreamPeerTCP.STATUS_CONNECTED or _expired(client, now_usec):
			_drop(client)
			continue
		if not client.closing:
			read_budget -= _read(client, read_budget, now_usec)
	# Skip clients with pending output; each gets at most one response buffer.
	for index in range(_queue.size()):
		var request := _queue[index]
		var client: Dictionary = request.client
		if not client.output.is_empty():
			continue
		_queue.remove_at(index)
		_dispatch(client, request.line, handler, now_usec)
		if not enabled:
			stop()
			return
		break
	var write_budget := MAX_DRAIN_BYTES
	for client in _clients.duplicate():
		write_budget -= _drain(client, write_budget, now_usec)


func _expired(client: Dictionary, now: int) -> bool:
	if now - int(client.activity) >= TIMEOUT_USEC:
		return true
	for field in ["input_since", "output_since"]:
		if int(client[field]) >= 0 and now - int(client[field]) >= TIMEOUT_USEC:
			return true
	for request in _queue:
		if is_same(request.client, client) and now - int(request.since) >= TIMEOUT_USEC:
			return true
	return false


func _read(client: Dictionary, budget: int, now: int) -> int:
	var consumed := 0
	var peer: StreamPeerTCP = client.peer
	while consumed < budget and peer.get_available_bytes() > 0:
		var count := mini(peer.get_available_bytes(), budget - consumed)
		count = mini(count, MAX_REQUEST_BYTES + 1 - client.input.size())
		var received := peer.get_partial_data(count)
		if received[0] != OK:
			_drop(client)
			break
		var bytes: PackedByteArray = received[1]
		if bytes.is_empty():
			break
		consumed += bytes.size()
		client.activity = now
		if int(client.input_since) < 0:
			client.input_since = now
		client.input.append_array(bytes)
		var newline: int = client.input.find(10)
		while newline >= 0:
			if newline + 1 > MAX_REQUEST_BYTES:
				_reject_and_close(client, "request_too_large", "Request exceeds 8 KiB", now)
				return consumed
			if _queue.size() >= MAX_QUEUED:
				_reject_and_close(client, "queue_full", "Diagnostics request queue is full", now)
				return consumed
			_queue.append({"client": client, "line": client.input.slice(0, newline), "since": now})
			client.input = client.input.slice(newline + 1)
			client.input_since = -1 if client.input.is_empty() else now
			newline = client.input.find(10)
		if client.input.size() >= MAX_REQUEST_BYTES:
			_reject_and_close(client, "request_too_large", "Request exceeds 8 KiB", now)
			break
	return consumed


func _dispatch(client: Dictionary, line: PackedByteArray, handler: Callable, now: int) -> void:
	# Godot's UTF-8 decoder logs malformed bytes. Validate before decoding so an
	# unauthenticated client cannot turn one bounded request into engine log spam.
	if not _valid_utf8(line):
		_reply_error(client, null, "invalid_request", "Expected a UTF-8 JSON object", now)
		return
	var source := line.get_string_from_utf8()
	var json := JSON.new()
	if source.to_utf8_buffer() != line or json.parse(source) != OK or not json.data is Dictionary:
		_reply_error(client, null, "invalid_request", "Expected a JSON object", now)
		return
	var request: Dictionary = json.data
	# Authenticate before reflecting even the request ID. Never echo credentials.
	var token: Variant = request.get("token")
	if not token is String or not _crypto.constant_time_compare(_token.to_utf8_buffer(), token.to_utf8_buffer()):
		_reject_and_close(client, "unauthorized", "Invalid diagnostics credentials", now)
		return
	var id: Variant = request.get("id")
	var valid_id: bool = id is String and id.length() <= 128
	if id is float or id is int:
		valid_id = is_finite(float(id)) and absf(float(id)) <= 9007199254740991.0 and float(id) == floor(float(id))
	if not valid_id or not request.get("op") is String or not request.get("args") is Dictionary:
		_reply_error(client, null, "invalid_request", "Expected id, token, op and object args", now)
		return
	for key in request:
		if not key in ["id", "token", "op", "args"]:
			_reply_error(client, id, "invalid_request", "Unexpected request field", now)
			return
	if not request.op in OPERATIONS:
		_reply_error(client, id, "unknown_operation", "Operation is not allowed", now)
		return
	while not _query_times.is_empty() and now - _query_times[0] >= 1_000_000:
		_query_times.pop_front()
	if _query_times.size() >= MAX_QUERIES_PER_SECOND:
		_reply_error(client, id, "rate_limited", "Diagnostics query rate exceeded", now)
		return
	_query_times.append(now)
	if not handler.is_valid():
		_reply_error(client, id, "unavailable", "Diagnostics handler is unavailable", now)
		return
	var result: Variant = handler.call(request.op, request.args)
	# A handler can disable diagnostics while handling a request.
	if not enabled or not _clients.has(client):
		return
	if not result is Dictionary:
		_reply_error(client, id, "invalid_result", "Diagnostics handler must return an object", now)
		return
	_reply(client, {"id": id, "result": result}, now)


static func _valid_utf8(bytes: PackedByteArray) -> bool:
	var index := 0
	while index < bytes.size():
		var first := int(bytes[index])
		if first < 128:
			index += 1
			continue
		var count := 0
		if first >= 194 and first <= 223:
			count = 1
		elif first >= 224 and first <= 239:
			count = 2
		elif first >= 240 and first <= 244:
			count = 3
		else:
			return false
		if index + count >= bytes.size():
			return false
		for offset in range(1, count + 1):
			if bytes[index + offset] < 128 or bytes[index + offset] > 191:
				return false
		var second := int(bytes[index + 1])
		if (first == 224 and second < 160) or (first == 237 and second >= 160) or (first == 240 and second < 144) or (first == 244 and second >= 144):
			return false
		index += count + 1
	return true


func _reply_error(client: Dictionary, id: Variant, code: String, message: String, now: int) -> void:
	_reply(client, {"id": id, "error": {"code": code, "message": message}}, now)


func _reply(client: Dictionary, envelope: Dictionary, now: int) -> void:
	var text := JSON.stringify(envelope)
	if not _token.is_empty():
		text = text.replace(_token, "[redacted]")
	var bytes := (text + "\n").to_utf8_buffer()
	if bytes.size() > MAX_RESPONSE_BYTES:
		bytes = (JSON.stringify({"id": envelope.id, "error": {
			"code": "response_too_large", "message": "Response exceeds 256 KiB",
		}}).replace(_token, "[redacted]") + "\n").to_utf8_buffer()
	client.output = bytes
	client.offset = 0
	client.output_since = now


func _reject_and_close(client: Dictionary, code: String, message: String, now: int) -> void:
	_remove_queued(client)
	client.input = PackedByteArray()
	client.input_since = -1
	client.closing = true
	# Never replace the tail of an already partially written NDJSON record.
	if client.output.is_empty():
		_reply_error(client, null, code, message, now)


func _drain(client: Dictionary, budget: int, now: int) -> int:
	var consumed := 0
	var peer: StreamPeerTCP = client.peer
	if not client.output.is_empty() and budget > 0:
		var end := mini(client.output.size(), int(client.offset) + budget)
		var sent := peer.put_partial_data(client.output.slice(client.offset, end))
		if sent[0] != OK:
			_drop(client)
			return 0
		consumed = int(sent[1])
		client.offset += consumed
		if consumed > 0:
			client.activity = now
		if int(client.offset) == client.output.size():
			client.output = PackedByteArray()
			client.offset = 0
			client.output_since = -1
	if client.closing and client.output.is_empty():
		_drop(client)
	return consumed


func _remove_queued(client: Dictionary) -> void:
	for index in range(_queue.size() - 1, -1, -1):
		if is_same(_queue[index].client, client):
			_queue.remove_at(index)


func _drop(client: Dictionary) -> void:
	client.peer.disconnect_from_host()
	_remove_queued(client)
	_clients.erase(client)
