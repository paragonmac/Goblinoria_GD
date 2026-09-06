extends RefCounted
## SEE-ADR-014: main-thread observation only; never invoke gameplay to explain it.

const FORMAT_VERSION := 1
const MAX_ENTRIES := 4096
const MAX_BYTES := 2 * 1024 * 1024
const HISTORY_USEC := 30000000
const MAX_RECORD_BYTES := 16 * 1024
var enabled := false
var session_id := Crypto.new().generate_random_bytes(16).hex_encode()
var world_epoch := 1
var frame_id := 0
var now_usec := 0
var _synthetic_clock := false
var history_started_usec := -1
var dropped_events := 0
var dropped_decisions := 0
var events: Array = []
var decisions: Dictionary = {}
var _event_bytes := 0
var _decision_bytes := 0
var snapshot_provider: Callable
var capture_provider: Callable
var capture_status_provider: Callable


func tick(timestamp_usec: int = -1) -> void:
	_synthetic_clock = timestamp_usec >= 0
	now_usec = Time.get_ticks_usec() if timestamp_usec < 0 else timestamp_usec
	frame_id += 1
	_expire()


func set_enabled(value: bool, timestamp_usec: int = -1) -> void:
	if enabled == value:
		return
	_synthetic_clock = timestamp_usec >= 0
	now_usec = Time.get_ticks_usec() if timestamp_usec < 0 else timestamp_usec
	enabled = value
	events.clear()
	decisions.clear()
	_event_bytes = 0
	_decision_bytes = 0
	dropped_events = 0
	dropped_decisions = 0
	history_started_usec = now_usec if value else -1
	if enabled:
		mark_event("diagnostics_enabled")


func stamp() -> Dictionary:
	return {"format_version": FORMAT_VERSION, "session_id": session_id,
		"world_epoch": world_epoch, "frame_id": frame_id, "monotonic_usec": _time()}

func _time() -> int:
	return now_usec if _synthetic_clock else Time.get_ticks_usec()


func begin_world(reason: String) -> void:
	world_epoch += 1
	decisions.clear()
	_decision_bytes = 0
	mark_event("world_replaced", {"reason": reason})


func observe(subject: String, subject_id: Variant, reason: String, data: Dictionary = {}) -> void:
	if not enabled:
		return
	subject = subject.left(128)
	reason = reason.left(128)
	var identity := str(subject_id).left(128)
	var key := subject + ":" + identity
	var clean: Dictionary = plain(data)
	if JSON.stringify(clean).to_utf8_buffer().size() > MAX_RECORD_BYTES:
		clean = {"unavailable": "payload_limit", "truncated": true}
	var previous: Dictionary = decisions.get(key, {})
	# Identical evaluations update freshness without flooding the event journal.
	if previous.get("reason") == reason and previous.get("data") == clean and previous.get("valid", false):
		_decision_bytes -= int(previous._bytes)
		previous["monotonic_usec"] = _time()
		previous["frame_id"] = frame_id
		previous["_bytes"] = JSON.stringify(previous).to_utf8_buffer().size()
		_decision_bytes += int(previous._bytes)
		if _decision_bytes > MAX_BYTES:
			_decision_bytes -= int(previous._bytes)
			decisions.erase(key)
			dropped_decisions += 1
		return
	if not previous.is_empty():
		_decision_bytes -= int(previous.get("_bytes", 0))
		decisions.erase(key)
	var record := stamp()
	record.merge({"subject": subject, "subject_id": identity, "reason": reason,
		"data": clean, "valid": true})
	record["_bytes"] = JSON.stringify(record).to_utf8_buffer().size()
	while not decisions.is_empty() and (decisions.size() >= MAX_ENTRIES or _decision_bytes + int(record._bytes) > MAX_BYTES):
		for oldest in decisions:
			_decision_bytes -= int(decisions[oldest]._bytes)
			decisions.erase(oldest)
			break
		dropped_decisions += 1
	decisions[key] = record
	_decision_bytes += int(record._bytes)
	mark_event("decision", record)


func invalidate(subject: String, subject_id: Variant, reason: String = "state_changed") -> void:
	if not enabled:
		return
	var key := subject.left(128) + ":" + str(subject_id).left(128)
	if decisions.has(key):
		if not decisions[key].valid and decisions[key].get("invalidated_reason") == reason.left(128):
			return
		_decision_bytes -= int(decisions[key]._bytes)
		decisions[key]["valid"] = false
		decisions[key]["invalidated_reason"] = reason.left(128)
		decisions[key]["_bytes"] = JSON.stringify(decisions[key]).to_utf8_buffer().size()
		_decision_bytes += int(decisions[key]._bytes)
		if _decision_bytes > MAX_BYTES:
			_decision_bytes -= int(decisions[key]._bytes)
			decisions.erase(key)
			dropped_decisions += 1
	mark_event("decision_invalidated", {"subject": subject, "subject_id": str(subject_id), "reason": reason})


func explain(subject: String, subject_id: Variant) -> Dictionary:
	if not enabled:
		return {"availability": "history_disabled"}
	var record: Dictionary = decisions.get(subject.left(128) + ":" + str(subject_id).left(128), {})
	if record.is_empty():
		return {"availability": "not_observed_or_evicted", "history_started_usec": history_started_usec}
	var result := record.duplicate(true)
	result.erase("_bytes")
	result["age_usec"] = maxi(0, _time() - int(record.monotonic_usec))
	result["meaning"] = "last_actual_evaluation_not_a_fresh_query"
	return result


func mark_event(kind: String, data: Dictionary = {}) -> void:
	if not enabled:
		return
	var row := stamp()
	row["kind"] = kind.left(128)
	row["data"] = plain(data)
	if JSON.stringify(row.data).to_utf8_buffer().size() > MAX_RECORD_BYTES:
		row["data"] = {"unavailable": "payload_limit", "truncated": true}
	row["_bytes"] = JSON.stringify(row).to_utf8_buffer().size()
	events.append(row)
	_event_bytes += int(row._bytes)
	_expire()


func recent_events(limit: int = 128, byte_limit: int = MAX_BYTES) -> Dictionary:
	_expire()
	var rows: Array = []
	var bytes := 0
	for i in range(events.size() - 1, maxi(-1, events.size() - clampi(limit, 1, MAX_ENTRIES) - 1), -1):
		bytes += int(events[i]._bytes)
		if bytes > byte_limit:
			break
		var row: Dictionary = events[i].duplicate(true)
		row.erase("_bytes")
		rows.push_front(row)
	return {"history_available": enabled, "history_started_usec": history_started_usec,
		"events": rows, "truncated": rows.size() < events.size(),
		"dropped_events": dropped_events, "dropped_decisions": dropped_decisions}


func dispatch(operation: String, args: Dictionary) -> Dictionary:
	var result := stamp()
	if args.has("world_epoch") and args.world_epoch != world_epoch:
		result["error"] = "stale_world"
		return result
	# World-owned requests must name the epoch obtained from status.
	if operation.begins_with("inspect_") or operation.begins_with("list_"):
		if not args.has("world_epoch"):
			result["error"] = "world_epoch_required"
			return result
	match operation:
		"recent_events":
			result["data"] = recent_events(128, 192 * 1024)
		"capture_bug":
			result["data"] = capture_provider.call(args) if capture_provider.is_valid() else {"error": "unavailable"}
		"capture_status":
			result["data"] = capture_status_provider.call() if capture_status_provider.is_valid() else {"error": "unavailable"}
		_:
			result["data"] = snapshot_provider.call(operation, args) if snapshot_provider.is_valid() else {"error": "unavailable"}
	return result


func _expire() -> void:
	while not events.is_empty() and (events.size() > MAX_ENTRIES or _event_bytes > MAX_BYTES or _time() - int(events[0].monotonic_usec) > HISTORY_USEC):
		_event_bytes -= int(events.pop_front()._bytes)
		dropped_events += 1


static func plain(value: Variant, depth: int = 0) -> Variant:
	# Bound every producer payload, including future hooks and error text.
	if depth > 6:
		return {"unavailable": "depth_limit"}
	match typeof(value):
		TYPE_NIL, TYPE_BOOL, TYPE_INT:
			return value
		TYPE_FLOAT:
			return value if is_finite(value) else null
		TYPE_STRING, TYPE_STRING_NAME:
			return str(value).left(1024)
		TYPE_VECTOR3, TYPE_VECTOR3I:
			return [value.x, value.y, value.z]
		TYPE_VECTOR2, TYPE_VECTOR2I:
			return [value.x, value.y]
		TYPE_DICTIONARY:
			var out := {}
			for key in value:
				if out.size() >= 64:
					out["_truncated"] = true
					break
				out[str(key).left(128)] = plain(value[key], depth + 1)
			return out
		TYPE_ARRAY, TYPE_PACKED_BYTE_ARRAY, TYPE_PACKED_VECTOR3_ARRAY:
			var out: Array = []
			for i in range(mini(value.size(), 128)):
				out.append(plain(value[i], depth + 1))
			if value.size() > 128:
				out.append({"_omitted": value.size() - 128})
			return out
	return {"unavailable": "unsupported_type"}
