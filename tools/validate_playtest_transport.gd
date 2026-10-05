extends SceneTree

const Transport = preload("res://scripts/playtest/playtest_transport.gd")

var _checks := 0
var _errors: Array[String] = []
var _root := ""
var _transport
var _peer: StreamPeerTCP
var _buffer := PackedByteArray()
var _now := 0
var _token := ""


func _init() -> void:
	_run.call_deferred()


func _run() -> void:
	var temporary := OS.get_environment("TEMP") if OS.get_name() == "Windows" else OS.get_environment("TMPDIR")
	if temporary.is_empty():
		temporary = OS.get_cache_dir()
	_root = temporary.path_join("goblinoria-playtest-transport-%d-%d" % [OS.get_process_id(), Time.get_ticks_usec()])
	_transport = Transport.new()
	_transport.descriptor_root = _root.path_join("control")
	_check(_transport.get_allowed_operations().size() == 9, "playtest allowlist has nine operations")
	_check(_transport.get_allowed_operations().has("act") and _transport.get_allowed_operations().has("observe"), "playtest allowlist includes control and observation")
	_check(not _transport.get_allowed_operations().has("inspect_cell") and not _transport.get_allowed_operations().has("capture_bug"), "playtest allowlist excludes diagnostics queries")
	_check(_transport.start("playtest-test", {"run_id": "run-test", "scenario": "stair_preview"}) == OK, "playtest transport starts")
	if _transport.enabled:
		var descriptor: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(_transport.descriptor_path))
		_token = descriptor.token
		_check(descriptor.transport == "playtest" and descriptor.control_version == 1, "descriptor identifies playtest protocol")
		_check(descriptor.run_id == "run-test" and descriptor.scenario == "stair_preview", "descriptor preserves launcher metadata")
		_check(descriptor.host == "127.0.0.1" and descriptor.port == _transport.port, "descriptor is loopback and ephemeral")
		_check(descriptor.token.length() == 64 and descriptor.token.is_valid_hex_number(), "descriptor has a 256-bit token")
		_test_request("status", {"ready": true}, true)
		_test_request("inspect_cell", {}, false)
		_test_request("act", {"accepted": true}, true)
		_transport.stop()
		_check(not FileAccess.file_exists(descriptor_path()), "stop removes playtest descriptor")
	else:
		_errors.append("playtest transport did not start")
	_cleanup()
	if _errors.is_empty():
		print("PLAYTEST_TRANSPORT_OK: %d checks" % _checks)
		quit(0)
	else:
		for error in _errors:
			push_error(error)
		quit(1)


func descriptor_path() -> String:
	return _root.path_join("control").path_join("playtest-test-%d.json" % OS.get_process_id())


func _test_request(operation: String, expected: Dictionary, accepted: bool) -> void:
	_peer = StreamPeerTCP.new()
	_check(_peer.connect_to_host("127.0.0.1", _transport.port) == OK, "TCP connection starts for " + operation)
	for _index in range(100):
		_peer.poll()
		_transport.poll(_handler, _now)
		if _peer.get_status() == StreamPeerTCP.STATUS_CONNECTED:
			break
		OS.delay_usec(1000)
	_check(_peer.get_status() == StreamPeerTCP.STATUS_CONNECTED, "TCP connection completes for " + operation)
	var request := {"id": operation, "token": _token, "op": operation, "args": {}}
	_peer.put_data((JSON.stringify(request) + "\n").to_utf8_buffer())
	var response: Variant = null
	for _index in range(100):
		_now += 1000
		_transport.poll(_handler, _now)
		_peer.poll()
		if _peer.get_available_bytes() > 0:
			_buffer.append_array(_peer.get_data(_peer.get_available_bytes())[1])
		var newline := _buffer.find(10)
		if newline >= 0:
			response = JSON.parse_string(_buffer.slice(0, newline).get_string_from_utf8())
			_buffer = _buffer.slice(newline + 1)
			break
		OS.delay_usec(1000)
	_check(response is Dictionary, "response is JSON for " + operation)
	if response is Dictionary:
		var has_error: bool = response.has("error")
		_check(has_error != accepted, "operation allowlist result for " + operation)
		if accepted:
			_check(response.get("result", {}).get("accepted", false) == expected.get("accepted", false) or operation == "status", "handler result survives transport for " + operation)
		else:
			_check(response.get("error", {}).get("code", "") == "unknown_operation", "rejected operation uses unknown_operation for " + operation)
	_peer.disconnect_from_host()


func _handler(operation: String, _args: Dictionary) -> Dictionary:
	if operation == "status":
		return {"run_id": "run-test", "world_epoch": 1, "view_id": "view-test", "ready": true}
	return {"accepted": true}


func _cleanup() -> void:
	if _peer != null:
		_peer.disconnect_from_host()
	if _transport != null:
		_transport.stop()
	DirAccess.remove_absolute(_root)


func _check(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_errors.append(message)
