extends RefCounted
class_name StockpileStore

const CATEGORY_SOIL := "soil"
const CATEGORY_STONE := "stone"
const CATEGORY_ORE := "ore"
const CATEGORY_ORGANIC := "organic"
const CATEGORY_LIQUID := "liquid"
const CATEGORY_CONSTRUCTION := "construction"
const CATEGORY_GEMS := "gems"
const BASE_CELL_CAPACITY := 16
const CATEGORIES := [
	CATEGORY_SOIL,
	CATEGORY_STONE,
	CATEGORY_ORE,
	CATEGORY_ORGANIC,
	CATEGORY_LIQUID,
	CATEGORY_CONSTRUCTION,
	CATEGORY_GEMS,
]

var stockpiles: Dictionary = {}
var cells: Dictionary = {}
var next_id := 1


func clear() -> void:
	stockpiles.clear()
	cells.clear()
	next_id = 1


func create_stockpile(cell_list: Array[Vector3i]) -> int:
	var stockpile_id := next_id
	next_id += 1
	var allowed := {}
	for category in CATEGORIES:
		allowed[category] = true
	stockpiles[stockpile_id] = {
		"id": stockpile_id,
		"cells": [],
		"allowed_categories": allowed,
		"material_overrides": {},
	}
	add_cells(stockpile_id, cell_list)
	return stockpile_id


func restore_stockpile(stockpile: Dictionary) -> void:
	var stockpile_id := int(stockpile.get("id", -1))
	if stockpile_id <= 0:
		return
	var restored := {
		"id": stockpile_id,
		"cells": [],
		"allowed_categories": _normalize_categories(stockpile.get("allowed_categories", {})),
		"material_overrides": stockpile.get("material_overrides", {}).duplicate(true),
	}
	stockpiles[stockpile_id] = restored
	next_id = maxi(next_id, stockpile_id + 1)
	var restored_cells: Array[Vector3i] = []
	for cell in stockpile.get("cells", []):
		if typeof(cell) == TYPE_VECTOR3I:
			restored_cells.append(cell)
	add_cells(stockpile_id, restored_cells)


func add_cells(stockpile_id: int, cell_list: Array[Vector3i]) -> void:
	if not stockpiles.has(stockpile_id):
		return
	var stockpile: Dictionary = stockpiles[stockpile_id]
	var stockpile_cells: Array = stockpile.get("cells", [])
	for cell: Vector3i in cell_list:
		if cells.has(cell):
			continue
		cells[cell] = stockpile_id
		stockpile_cells.append(cell)
	stockpile["cells"] = stockpile_cells
	stockpiles[stockpile_id] = stockpile


func remove_cells(cell_list: Array[Vector3i]) -> Array[int]:
	var touched: Dictionary = {}
	for cell: Vector3i in cell_list:
		if not cells.has(cell):
			continue
		var stockpile_id: int = int(cells[cell])
		touched[stockpile_id] = true
		cells.erase(cell)
		var stockpile: Dictionary = stockpiles.get(stockpile_id, {})
		var stockpile_cells: Array = stockpile.get("cells", [])
		stockpile_cells.erase(cell)
		stockpile["cells"] = stockpile_cells
		if stockpile_cells.is_empty():
			stockpiles.erase(stockpile_id)
		else:
			stockpiles[stockpile_id] = stockpile
	var ids: Array[int] = []
	for stockpile_id in touched.keys():
		ids.append(int(stockpile_id))
	return ids


func stockpile_at(pos: Vector3i) -> int:
	return int(cells.get(pos, -1))


func accepts_material(stockpile_id: int, material_id: int) -> bool:
	if not stockpiles.has(stockpile_id):
		return false
	var stockpile: Dictionary = stockpiles[stockpile_id]
	var overrides: Dictionary = stockpile.get("material_overrides", {})
	if overrides.has(material_id):
		return bool(overrides[material_id])
	if overrides.has(str(material_id)):
		return bool(overrides[str(material_id)])
	var category := category_for_material(material_id)
	var allowed: Dictionary = stockpile.get("allowed_categories", {})
	return bool(allowed.get(category, false))


func candidate_cells_for_material(material_id: int) -> Array[Dictionary]:
	var candidates: Array[Dictionary] = []
	for stockpile_id in stockpiles.keys():
		var id := int(stockpile_id)
		if not accepts_material(id, material_id):
			continue
		var stockpile: Dictionary = stockpiles[id]
		for cell in stockpile.get("cells", []):
			if typeof(cell) != TYPE_VECTOR3I:
				continue
			candidates.append({"stockpile_id": id, "pos": cell})
	return candidates


func cell_capacity(_pos: Vector3i) -> int:
	return BASE_CELL_CAPACITY


func set_category_allowed(stockpile_id: int, category: String, allowed_value: bool) -> void:
	if not stockpiles.has(stockpile_id):
		return
	if not CATEGORIES.has(category):
		return
	var stockpile: Dictionary = stockpiles[stockpile_id]
	var allowed: Dictionary = stockpile.get("allowed_categories", {})
	allowed[category] = allowed_value
	stockpile["allowed_categories"] = allowed
	stockpiles[stockpile_id] = stockpile


func set_material_override(stockpile_id: int, material_id: int, allowed_value: bool) -> void:
	if not stockpiles.has(stockpile_id) or material_id <= 0:
		return
	var stockpile: Dictionary = stockpiles[stockpile_id]
	var overrides: Dictionary = stockpile.get("material_overrides", {})
	overrides[material_id] = allowed_value
	stockpile["material_overrides"] = overrides
	stockpiles[stockpile_id] = stockpile


func category_for_material(material_id: int) -> String:
	match material_id:
		2, 3, 10, 15, 16:
			return CATEGORY_SOIL
		1, 4, 5, 6, 7:
			return CATEGORY_STONE
		8, 9:
			return CATEGORY_ORE
		12, 13, 14:
			return CATEGORY_ORGANIC
		11:
			return CATEGORY_LIQUID
		100, 101, 102, 103, 104, 105, 106, 107, 108, 109, 110, 111:
			return CATEGORY_CONSTRUCTION
		_:
			return CATEGORY_GEMS


func as_save_array() -> Array:
	var saved: Array = []
	for stockpile: Dictionary in stockpiles.values():
		saved.append(stockpile.duplicate(true))
	return saved


func _normalize_categories(value) -> Dictionary:
	var allowed := {}
	for category in CATEGORIES:
		allowed[category] = true
	if typeof(value) != TYPE_DICTIONARY:
		return allowed
	var source: Dictionary = value
	for category in CATEGORIES:
		if source.has(category):
			allowed[category] = bool(source[category])
	return allowed
