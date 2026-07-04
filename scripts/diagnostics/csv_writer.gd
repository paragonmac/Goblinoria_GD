extends RefCounted
class_name DiagnosticsCsvWriter
## Small CSV/file helper for runtime diagnostics.


static func escape(value: Variant, force_quote: bool = false) -> String:
	var text := str(value)
	if force_quote or text.contains("\"") or text.contains(",") or text.contains("\n"):
		return "\"%s\"" % text.replace("\"", "\"\"")
	return text


static func row_from_values(values: Array) -> String:
	var escaped: Array[String] = []
	for value in values:
		escaped.append(escape(value))
	return ",".join(escaped)


static func row_from_columns(row: Dictionary, columns: Array) -> String:
	var values: Array = []
	for column in columns:
		values.append(row.get(column, ""))
	return row_from_values(values)


static func open_new_file(dir_path: String, prefix: String, columns: Array) -> FileAccess:
	if not ensure_dir(dir_path):
		return null
	var stamp := Time.get_datetime_string_from_system().replace(":", "-").replace(" ", "_")
	var path := dir_path.path_join("%s%s.csv" % [prefix, stamp])
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return null
	if not columns.is_empty():
		file.store_line(row_from_values(columns))
		file.flush()
	return file


static func append_line(path: String, line: String) -> bool:
	var file: FileAccess
	if FileAccess.file_exists(path):
		file = FileAccess.open(path, FileAccess.READ_WRITE)
		if file != null:
			file.seek_end()
	else:
		file = FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return false
	file.store_line(line)
	return true


static func append_values(path: String, values: Array) -> bool:
	return append_line(path, row_from_values(values))


static func ensure_dir(dir_path: String) -> bool:
	var result := DirAccess.make_dir_recursive_absolute(dir_path)
	if result == OK:
		return true
	var absolute_path := ProjectSettings.globalize_path(dir_path)
	if absolute_path == dir_path:
		return false
	return DirAccess.make_dir_recursive_absolute(absolute_path) == OK
