extends RefCounted
class_name BlockRegistry

const TABLE_SIZE := 256
const DEFAULT_COLOR := Color(0.5, 0.5, 0.5)

var solid := PackedByteArray()
var hardness := PackedFloat32Array()
var replaceable := PackedByteArray()
var drop := PackedByteArray()
var color := PackedColorArray()
var names := PackedStringArray()

func _init() -> void:
	_init_tables()


func _init_tables() -> void:
	solid.resize(TABLE_SIZE)
	solid.fill(0)
	hardness.resize(TABLE_SIZE)
	for i in range(TABLE_SIZE):
		hardness[i] = 0.0
	replaceable.resize(TABLE_SIZE)
	replaceable.fill(0)
	drop.resize(TABLE_SIZE)
	drop.fill(0)
	color.resize(TABLE_SIZE)
	for i in range(TABLE_SIZE):
		color[i] = DEFAULT_COLOR
	names.resize(TABLE_SIZE)
	for i in range(TABLE_SIZE):
		names[i] = ""


func load_from_csv(path: String) -> void:
	_init_tables()
	if not FileAccess.file_exists(path):
		push_warning("BlockRegistry: missing csv at %s" % path)
		return
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		push_warning("BlockRegistry: unable to open %s" % path)
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


func is_solid(block_id: int) -> bool:
	if block_id < 0 or block_id >= TABLE_SIZE:
		return false
	return solid[block_id] != 0


func is_replaceable(block_id: int) -> bool:
	if block_id < 0 or block_id >= TABLE_SIZE:
		return false
	return replaceable[block_id] != 0


func get_hardness(block_id: int) -> float:
	if block_id < 0 or block_id >= TABLE_SIZE:
		return 0.0
	return hardness[block_id]


func get_drop(block_id: int) -> int:
	if block_id < 0 or block_id >= TABLE_SIZE:
		return 0
	return drop[block_id]


func get_color(block_id: int) -> Color:
	if block_id < 0 or block_id >= TABLE_SIZE:
		return DEFAULT_COLOR
	return color[block_id]


func get_name(block_id: int) -> String:
	if block_id < 0 or block_id >= TABLE_SIZE:
		return "Unknown"
	var name := names[block_id]
	if name.is_empty():
		return "Unknown"
	return name


func _parse_row(cells: Array, column_index: Dictionary) -> void:
	var id_text := _get_cell(cells, column_index, "id", "")
	if id_text.is_empty():
		return
	var block_id := int(id_text)
	if block_id < 0 or block_id >= TABLE_SIZE:
		return

	var solid_text := _get_cell(cells, column_index, "solid", "0")
	var hardness_text := _get_cell(cells, column_index, "hardness", "0")
	var replace_text := _get_cell(cells, column_index, "replaceable", "0")
	var drop_text := _get_cell(cells, column_index, "drop", "0")
	var name_text := _get_cell(cells, column_index, "name", "")
	var r_text := _get_cell(cells, column_index, "color_r", "")
	var g_text := _get_cell(cells, column_index, "color_g", "")
	var b_text := _get_cell(cells, column_index, "color_b", "")
	var a_text := _get_cell(cells, column_index, "color_a", "1")

	solid[block_id] = 1 if _parse_bool(solid_text) else 0
	replaceable[block_id] = 1 if _parse_bool(replace_text) else 0
	hardness[block_id] = float(hardness_text)
	drop[block_id] = int(drop_text)
	if not name_text.is_empty():
		names[block_id] = name_text

	if not r_text.is_empty() and not g_text.is_empty() and not b_text.is_empty():
		var r: float = clamp(float(r_text), 0.0, 1.0)
		var g: float = clamp(float(g_text), 0.0, 1.0)
		var b: float = clamp(float(b_text), 0.0, 1.0)
		var a: float = clamp(float(a_text), 0.0, 1.0)
		color[block_id] = Color(r, g, b, a)


func _get_cell(cells: Array, column_index: Dictionary, key: String, default_value: String) -> String:
	if not column_index.has(key):
		return default_value
	var idx: int = int(column_index[key])
	if idx < 0 or idx >= cells.size():
		return default_value
	return String(cells[idx]).strip_edges()


func _parse_bool(value: String) -> bool:
	var lowered := value.strip_edges().to_lower()
	if lowered == "1" or lowered == "true" or lowered == "yes":
		return true
	return false
