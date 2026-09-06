extends RefCounted
## Owns only copied data. The single writer thread never reads the scene tree.
const SNAPSHOT_LIMIT := 2 * 1024 * 1024
const BUNDLE_LIMIT := 64 * 1024 * 1024
const QUOTA := 512 * 1024 * 1024
var root_path := "user://diagnostics/bugs"
var quota_bytes := QUOTA
var bundle_limit_bytes := BUNDLE_LIMIT
var thread: Thread
var status: Dictionary = {"state": "idle"}

func start(capture_id: String, snapshot: Dictionary, history: Dictionary, errors: Dictionary, screenshot: Image = null) -> bool:
	if thread != null:
		return false
	status = {"state": "writing", "capture_id": capture_id}
	thread = Thread.new()
	var err := thread.start(_write.bind(capture_id, snapshot, history, errors, screenshot, root_path, quota_bytes, bundle_limit_bytes))
	if err != OK:
		thread = null
		status = {"state": "failed", "error": "writer_start_failed", "capture_id": capture_id}
		return false
	return true

func poll() -> void:
	if thread != null and not thread.is_alive():
		status = thread.wait_to_finish()
		thread = null

func shutdown() -> void:
	if thread != null:
		status = thread.wait_to_finish()
		thread = null

static func _write(id: String, snapshot: Dictionary, history: Dictionary, errors: Dictionary, screenshot: Image, destination: String, quota: int, limit: int) -> Dictionary:
	var started := Time.get_ticks_usec()
	var path := destination.path_join(id)
	var result := {"state": "failed", "capture_id": id, "path": path, "error": ""}
	if DirAccess.make_dir_recursive_absolute(destination) != OK:
		result.error = "capture_root_unwritable"
		return result
	var usage := _disk_usage(destination)
	if usage < 0 or usage + limit > quota:
		result.error = "capture_quota_or_directory_limit"
		return result
	if DirAccess.dir_exists_absolute(path) or DirAccess.make_dir_absolute(path) != OK:
		result.error = "capture_directory_failed"
		return result
	# This manifest is deliberately left incomplete if termination interrupts output.
	var incomplete := JSON.stringify({"format_version": 1, "complete": false, "capture_id": id})
	if not _store(path.path_join("manifest.json"), incomplete.to_utf8_buffer()):
		result.error = "manifest_write_failed"
		return result
	var body := JSON.stringify(snapshot, "\t").to_utf8_buffer()
	if body.size() > SNAPSHOT_LIMIT:
		result.error = "snapshot_limit"
		return result
	var files := {"snapshot.json": body,
		"events.jsonl": _jsonl(history.get("events", [])), "errors.jsonl": _jsonl(errors.get("rows", []))}
	var report := "# Bug capture\n\nProblem: %s\n\nExpected: [fill in]\n\nSteps: [fill in]\n\nFrequency: [fill in]\n\n" % str(snapshot.get("note", "[fill in]"))
	report += "Capture: %s\n\nWorld epoch: %s; frame: %s; monotonic time: %s us.\n\n" % [id, snapshot.get("world_epoch"), snapshot.get("frame_id"), snapshot.get("monotonic_usec")]
	report += "History available: %s. Dropped events: %s; dropped decisions: %s; dropped errors: %s.\n\n" % [history.get("history_available", false), history.get("dropped_events", 0), history.get("dropped_decisions", 0), errors.get("dropped", 0)]
	report += "Screenshot: %s.\n\n" % str(snapshot.get("screenshot", {}))
	report += "Rendering eligibility is not proof of visible pixels. Decisions describe the last actual evaluation, not a fresh simulation. History begins when diagnostics are enabled. Capture itself may hitch.\n\n"
	report += "See snapshot.json for camera, seed, render level, diagnostics, omissions, and performance recording reference. This bundle is evidence; GitHub remains the active bug tracker.\n"
	files["report.md"] = report.to_utf8_buffer()
	if screenshot != null:
		var png := screenshot.save_png_to_buffer()
		if png.is_empty():
			result.error = "png_encoding_failed"
			return result
		files["screenshot.png"] = png
	var size := incomplete.length()
	for name in files:
		size += files[name].size()
	if size + 4096 > limit:
		result.error = "bundle_limit"
		return result
	for name in files:
		if not _store(path.path_join(name), files[name]):
			result.error = "write_failed:" + name
			return result
	result.state = "complete"
	result.erase("error")
	result["bytes"] = size
	result["write_usec"] = Time.get_ticks_usec() - started
	var manifest := result.duplicate(true)
	manifest["complete"] = true
	manifest["format_version"] = 1
	if not _store(path.path_join("manifest.json"), JSON.stringify(manifest, "\t").to_utf8_buffer()):
		result.state = "failed"
		result.error = "final_manifest_failed"
	return result

static func _store(path: String, bytes: PackedByteArray) -> bool:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return false
	file.store_buffer(bytes)
	file.flush()
	var ok := file.get_error() == OK
	file.close()
	var check := FileAccess.open(path, FileAccess.READ)
	return ok and check != null and check.get_length() == bytes.size()

static func _jsonl(rows: Array) -> PackedByteArray:
	var lines := PackedStringArray()
	for row in rows:
		lines.append(JSON.stringify(row))
	return ("\n".join(lines) + ("\n" if not rows.is_empty() else "")).to_utf8_buffer()

static func _disk_usage(path: String) -> int:
	# Only one level of owned bundle directories; never follow links or recurse.
	var dir := DirAccess.open(path)
	if dir == null:
		return -1
	var total := 0
	var entries := 0
	dir.list_dir_begin()
	var name := dir.get_next()
	while not name.is_empty():
		entries += 1
		if entries > 4096 or dir.is_link(name):
			return -1
		if dir.current_is_dir():
			var child := DirAccess.open(path.path_join(name))
			if child == null:
				return -1
			child.list_dir_begin()
			var file_name := child.get_next()
			while not file_name.is_empty():
				entries += 1
				if entries > 32768 or child.is_link(file_name) or child.current_is_dir():
					return -1
				var file := FileAccess.open(path.path_join(name).path_join(file_name), FileAccess.READ)
				if file == null:
					return -1
				total += file.get_length()
				file_name = child.get_next()
		else:
			var file := FileAccess.open(path.path_join(name), FileAccess.READ)
			if file == null:
				return -1
			total += file.get_length()
		name = dir.get_next()
	return total
