extends RefCounted
class_name BlockDropTable

var drops_by_source: Dictionary = {}


func load_from_csv(path: String) -> void:
	drops_by_source.clear()
	if not FileAccess.file_exists(path):
		push_warning("BlockDropTable: missing csv at %s" % path)
		return
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		push_warning("BlockDropTable: unable to open %s" % path)
		return
	var header: Array[String] = []
	var column_index := {}
	while not file.eof_reached():
		var line := file.get_line().strip_edges()
		if line.is_empty() or line.begins_with("#"):
			continue
		var cells := line.split(",")
		if header.is_empty():
			header.resize(cells.size())
			for i in range(cells.size()):
				var key := cells[i].strip_edges().to_lower()
				header[i] = key
				column_index[key] = i
			continue
		_parse_row(cells, column_index)


func resolve_drops(source_block_id: int, rng: RandomNumberGenerator, legacy_drop_id: int = 0) -> Array[Dictionary]:
	var entries: Array = drops_by_source.get(source_block_id, [])
	var resolved: Array[Dictionary] = []
	if entries.is_empty() and legacy_drop_id > 0:
		resolved.append({"material_id": legacy_drop_id, "count": 1})
		return resolved
	for entry: Dictionary in entries:
		var chance := float(entry.get("chance", 1.0))
		if chance < 1.0 and rng.randf() > chance:
			continue
		var min_count := int(entry.get("count_min", 1))
		var max_count := int(entry.get("count_max", min_count))
		var count := min_count
		if max_count > min_count:
			count = rng.randi_range(min_count, max_count)
		if count <= 0:
			continue
		resolved.append({
			"material_id": int(entry.get("drop_material_id", 0)),
			"count": count,
		})
	return resolved


func _parse_row(cells: Array, column_index: Dictionary) -> void:
	var source_text := _get_cell(cells, column_index, "source_block_id", "")
	var drop_text := _get_cell(cells, column_index, "drop_material_id", "")
	if source_text.is_empty() or drop_text.is_empty():
		return
	var source_block_id := int(source_text)
	var drop_material_id := int(drop_text)
	if source_block_id <= 0 or drop_material_id <= 0:
		return
	var entry := {
		"drop_material_id": drop_material_id,
		"count_min": maxi(1, int(_get_cell(cells, column_index, "count_min", "1"))),
		"count_max": maxi(1, int(_get_cell(cells, column_index, "count_max", "1"))),
		"chance": clampf(float(_get_cell(cells, column_index, "chance", "1.0")), 0.0, 1.0),
	}
	if not drops_by_source.has(source_block_id):
		drops_by_source[source_block_id] = []
	drops_by_source[source_block_id].append(entry)


func _get_cell(cells: Array, column_index: Dictionary, key: String, default_value: String) -> String:
	if not column_index.has(key):
		return default_value
	var idx: int = int(column_index[key])
	if idx < 0 or idx >= cells.size():
		return default_value
	return String(cells[idx]).strip_edges()
