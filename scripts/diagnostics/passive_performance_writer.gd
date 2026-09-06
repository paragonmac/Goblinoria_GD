extends RefCounted

## Main-thread-only bounded report writer. Detailed rows are expendable; aggregate
## rows and lifecycle events are not. No filesystem work is done by worker jobs.

var output_path := ""
var last_error := ""
var bytes_written := 0
var pending_bytes := 0
var dropped_detail_records := 0
var limit_reached := false
var fail_after_bytes := -1
var fail_open := false
var pending_limit := 4 * 1024 * 1024
var pump_limit := 64 * 1024
var capture_limit := 128 * 1024 * 1024
var summary_reserve := 1024 * 1024
var _files: Dictionary = {}
var _essential: Array = []
var _details: Array = []


func open_reports(root: String) -> bool:
	if fail_open:
		last_error = "Injected report creation failure"
		return false
	var base := ProjectSettings.globalize_path(root)
	if DirAccess.make_dir_recursive_absolute(base) != OK:
		last_error = "Cannot create recording root: " + root
		return false
	var unique := "%s-%s-%s" % [Time.get_datetime_string_from_system().replace(":", "-"), OS.get_process_id(), Time.get_ticks_usec()]
	output_path = base.path_join(unique)
	var suffix := 0
	while DirAccess.dir_exists_absolute(output_path):
		suffix += 1
		output_path = base.path_join(unique + "-" + str(suffix))
	if DirAccess.make_dir_absolute(output_path) != OK:
		last_error = "Cannot create unique recording directory"
		return false
	for name in ["samples.csv", "events.jsonl", "spike_frames.csv"]:
		var file := FileAccess.open(output_path.path_join(name), FileAccess.WRITE)
		if file == null:
			last_error = "Cannot create " + name
			close()
			return false
		_files[name] = file
	return true


func enqueue(name: String, line: String, detail := false) -> bool:
	if not last_error.is_empty() or limit_reached:
		return false
	var data := line.to_utf8_buffer()
	if bytes_written + pending_bytes + data.size() > maxi(0, capture_limit - summary_reserve):
		limit_reached = true
		return false
	if pending_bytes + data.size() > pending_limit:
		if detail:
			dropped_detail_records += 1
			return true
		# Keep a partially written record: dropping its tail would corrupt CSV.
		for i in range(_details.size() - 1, -1, -1):
			var record: Dictionary = _details[i]
			if int(record.offset) == 0:
				pending_bytes -= record.data.size()
				_details.remove_at(i)
				dropped_detail_records += 1
		if pending_bytes + data.size() > pending_limit:
			last_error = "Recording output backlog exceeded its bounded buffer"
			return false
	var entry := {"name": name, "data": data, "offset": 0}
	if detail:
		_details.append(entry)
	else:
		_essential.append(entry)
	pending_bytes += data.size()
	return true


func pump(budget: int = -1) -> void:
	var remaining := pump_limit if budget < 0 else budget
	while remaining > 0 and pending_bytes > 0 and last_error.is_empty():
		var queue: Array = _essential if not _essential.is_empty() else _details
		var entry: Dictionary = queue[0]
		var offset := int(entry.offset)
		var count := mini(remaining, entry.data.size() - offset)
		if fail_after_bytes >= 0 and bytes_written + count > fail_after_bytes:
			last_error = "Injected report write failure"
			break
		var file: FileAccess = _files.get(entry.name)
		if file == null:
			last_error = "Recording stream is unavailable: " + str(entry.name)
			break
		file.store_buffer(entry.data.slice(offset, offset + count))
		if file.get_error() != OK:
			last_error = "Recording write failed: " + str(entry.name)
			break
		entry.offset = offset + count
		bytes_written += count
		pending_bytes -= count
		remaining -= count
		if int(entry.offset) == entry.data.size():
			queue.pop_front()


func flush() -> void:
	for file: FileAccess in _files.values():
		file.flush()
		if file.get_error() != OK:
			last_error = "Recording flush failed"


func write_summary(summary: Dictionary, markdown: String) -> bool:
	if output_path.is_empty():
		return false
	var json_data := (JSON.stringify(summary, "\t") + "\n").to_utf8_buffer()
	var md_data := markdown.to_utf8_buffer()
	if json_data.size() + md_data.size() > summary_reserve:
		last_error = "Recording summary exceeded its reserved space"
		return false
	for pair in [["summary.md", md_data], ["summary.json", json_data]]:
		if fail_after_bytes >= 0 and bytes_written + pair[1].size() > fail_after_bytes:
			last_error = "Injected summary write failure"
			return false
		var file := FileAccess.open(output_path.path_join(pair[0]), FileAccess.WRITE)
		if file == null:
			last_error = "Cannot write " + str(pair[0])
			return false
		file.store_buffer(pair[1])
		file.flush()
		var error := file.get_error()
		file.close()
		if error != OK:
			last_error = "Cannot finish " + str(pair[0])
			return false
	return true


func close() -> void:
	for file: FileAccess in _files.values():
		file.close()
	_files.clear()
