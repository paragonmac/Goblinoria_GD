extends RefCounted
## Read-only colony view. Main calls refresh_workers() on its 200 ms timer.
## SEE-ADR-008 / SEE-ADR-009: store signals dirty the economy; idle pumps are O(1).
## Published arrays and rows are immutable, cached values from completed builds.
## Resources partition stored/loose/carried; reservation counts overlap them.

const Roles = preload("res://scripts/worker_roles.gd")
const MAX_OVERRIDES := 64
const MAX_REFERENCES := 32
const KINDS := ["worker", "job", "stockpile", "resource"]


static func cell_details(world, pos: Vector3i, level_base_y: int) -> Dictionary:
	var block_id: int = world.get_block_no_generate(pos.x, pos.y, pos.z)
	var block_name: String = world.block_registry.get_name(block_id)
	if block_name.is_empty():
		block_name = "Block %d" % block_id
	else:
		block_name = block_name.capitalize()
	var solid: bool = world.is_block_solid_id(block_id)
	var is_ramp_or_stair: bool = World.RAMP_BLOCK_IDS.has(block_id)
	var occupant_cell := pos + Vector3i.UP if solid and not is_ramp_or_stair else pos
	var cells: Array[Vector3i] = [pos]
	if not cells.has(occupant_cell):
		cells.append(occupant_cell)
	var protection_reason: String = world.stair_dig_reject_reason(pos)
	var result := {
		"kind": "cell",
		"id": block_id,
		"pos": pos,
		"block_id": block_id,
		"block_name": block_name,
		"level": pos.y - level_base_y,
		"solid": solid,
		"diggable": _cell_is_diggable(world, pos),
		"shape": "Player stairs" if World.PLAYER_STAIR_BLOCK_IDS.has(block_id) else ("Terrain slope" if World.is_terrain_slope_block_id(block_id) else "None"),
		"protection_reason": protection_reason,
		"occupant_cell": occupant_cell,
		"workers": [],
		"items": [],
		"stockpile": {},
		"jobs": [],
	}
	var cell_set := {}
	for cell: Vector3i in cells:
		cell_set[cell] = true
	for worker in world.workers:
		if not is_instance_valid(worker) or not cell_set.has(worker.get_block_coord()):
			continue
		var role := Roles.display_name(worker.role_id)
		var state: String = Worker.WorkerState.keys()[clampi(worker.state, 0, Worker.WorkerState.size() - 1)].capitalize().replace("_", " ")
		result.workers.append({"id": int(worker.worker_id), "label": "Worker %d - %s - %s" % [worker.worker_id, role, state]})
	var seen_items := {}
	for cell: Vector3i in cells:
		for item: Dictionary in world.item_store.stored_items_at(cell):
			_add_cell_item(result.items, seen_items, item, true, world)
	for item_id in world.item_store.items:
		var item: Dictionary = world.item_store.items[item_id]
		if bool(item.get("is_carried", false)) or int(item.get("stored_stockpile_id", -1)) >= 0:
			continue
		if not cell_set.has(item.get("pos", Vector3i.ZERO)):
			continue
		_add_cell_item(result.items, seen_items, item, false, world)
	var stockpile_id: int = world.stockpile_store.stockpile_at(occupant_cell)
	if stockpile_id >= 0:
		result.stockpile = {"id": stockpile_id, "label": world.stockpile_store.display_name(stockpile_id)}
	var seen_tasks := {}
	for cell: Vector3i in cells:
		for task in world.task_queue.get_active_tasks_at(cell):
			if seen_tasks.has(task.id):
				continue
			seen_tasks[task.id] = true
			var type_name: String = ["Dig", "Place", "Stairs", "Haul"][clampi(task.type, 0, 3)]
			var status_name := "assigned" if task.status == TaskQueue.TaskStatus.IN_PROGRESS or is_instance_valid(task.assigned_worker) else "pending"
			var access_name := "unknown"
			if task.accessibility == TaskQueue.TaskAccessibility.REACHABLE:
				access_name = "reachable"
			elif task.accessibility == TaskQueue.TaskAccessibility.UNREACHABLE:
				access_name = "blocked"
			result.jobs.append({"id": int(task.id), "label": "%s - %s - %s" % [type_name, status_name, access_name]})
	result["empty"] = result.workers.is_empty() and result.items.is_empty() \
		and result.stockpile.is_empty() and result.jobs.is_empty()
	return result


static func _cell_is_diggable(world, pos: Vector3i) -> bool:
	if not world.is_block_coord_valid(pos.x, pos.y, pos.z):
		return false
	if not world.stair_dig_reject_reason(pos).is_empty():
		return false
	# Match is_diggable_at() using its current loaded block without requesting generation.
	var block_id: int = world.get_block_no_generate(pos.x, pos.y, pos.z)
	return world.block_registry.get_hardness(block_id) > 0.0


static func _add_cell_item(output: Array, seen: Dictionary, item: Dictionary, stored: bool, world) -> void:
	var item_id: int = int(item.get("id", -1))
	if bool(item.get("is_carried", false)) or seen.has(item_id):
		return
	seen[item_id] = true
	var material_id: int = int(item.get("material_id", 0))
	var material_name: String = world.block_registry.get_name(material_id)
	if material_name.is_empty():
		material_name = "Material %d" % material_id
	else:
		material_name = material_name.capitalize()
	var count: int = int(item.get("count", 0))
	output.append({"id": material_id, "item_id": item_id, "count": count,
		"stored": stored, "label": "%s x%d - %s" % [material_name, count, "stored" if stored else "loose"]})

# A suspended native iterator retains its cursor without keys()/values() copies.
# On invalidation close() returns BEFORE advancing a mutated dictionary iterator.
class DictionaryCursor extends RefCounted:
	signal advance
	var key = null
	var done := false

	func start(source: Dictionary) -> void:
		for entry in source:
			key = entry
			await advance
			if done:
				return
		done = true

	func next() -> void:
		advance.emit()

	func close() -> void:
		done = true
		advance.emit()

var revision: int = 0
var epoch: int = 0
var updating: bool:
	get:
		return _dirty or _phase >= 0 or _workers_dirty or _worker_cursor >= 0

var _world: WeakRef
var _connections: Array = []
var _rows: Dictionary = {}
var _indexes: Dictionary = {}
var _counts: Dictionary = {}
var _sampled_msec := 0
var _dirty := false
var _phase := -1
var _cursor := 0
var _dictionary_cursor: DictionaryCursor
var _pending_rows: Dictionary = {}
var _pending_indexes: Dictionary = {}
var _pending_counts: Dictionary = {}
var _occupied: Dictionary = {}
var _workers_dirty := false
var _worker_cursor := -1
var _worker_rows: Array = []
var _worker_index: Dictionary = {}
var _worker_counts: Dictionary = {}
var _worker_turn := true
var _empty_rows: Array = []
var _empty_row: Dictionary = {}
# Useful for budget validation; counts record/phase steps, including finalization.
var last_pump_steps := 0


func _init() -> void:
	_empty_rows.make_read_only()
	_empty_row.make_read_only()
	_reset_values()


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE and _dictionary_cursor != null:
		_dictionary_cursor.close()


func bind_world(world) -> void:
	# Explicit bind always starts a new epoch, including same-World load/reset.
	clear()
	if not is_instance_valid(world):
		return
	_world = weakref(world)
	_connect(world.task_queue.task_added)
	_connect(world.task_queue.task_removed)
	_connect(world.task_queue.task_visual_state_changed)
	_connect(world.task_queue.active_count_changed)
	_connect(world.item_store.visual_state_changed)
	_connect(world.item_store.haul_state_changed)
	_connect(world.stockpile_store.visual_state_changed)
	_connect(world.stockpile_store.haul_state_changed)
	_dirty = true
	refresh_workers()


func clear() -> void:
	for connection: Signal in _connections:
		if not connection.is_null() and is_instance_valid(connection.get_object()) \
				and connection.is_connected(_on_dirty):
			connection.disconnect(_on_dirty)
	_connections.clear()
	_close_cursor()
	_world = null
	_dirty = false
	_phase = -1
	_workers_dirty = false
	_worker_cursor = -1
	_pending_rows = {}
	_pending_indexes = {}
	_pending_counts = {}
	_occupied = {}
	_worker_rows = []
	_worker_index = {}
	_worker_counts = {}
	_worker_turn = true
	_reset_values()
	epoch += 1
	revision += 1


func pump(max_steps: int = 128, max_ms: float = 1.0) -> void:
	last_pump_steps = 0
	if not updating:
		return
	var world = _world.get_ref() if _world != null else null
	if not is_instance_valid(world):
		clear()
		return
	if max_steps <= 0 or max_ms <= 0.0:
		return
	var deadline := Time.get_ticks_usec() + int(max_ms * 1000.0)
	while updating and last_pump_steps < max_steps and Time.get_ticks_usec() < deadline:
		# Alternate workstreams so a large economy never starves the worker timer.
		if (_workers_dirty or _worker_cursor >= 0) \
				and (_worker_turn or not (_dirty or _phase >= 0)):
			_worker_step(world)
			_worker_turn = false
		else:
			_economy_step(world)
			_worker_turn = true
		last_pump_steps += 1


func refresh_workers() -> void:
	if _world != null and is_instance_valid(_world.get_ref()):
		_workers_dirty = true


func snapshot() -> Dictionary:
	var result := {
		"workers": list_rows("worker"), "jobs": list_rows("job"),
		"stockpiles": list_rows("stockpile"), "resources": list_rows("resource"),
		"counts": _counts, "suggestion": _suggestion(),
		"suggestion_category": _suggestion_category(),
		"revision": revision, "epoch": epoch, "updating": updating,
		"sampled_msec": _sampled_msec,
	}
	result.make_read_only()
	return result


func list_rows(kind: String) -> Array:
	return _rows.get(kind, _empty_rows)


func get_row(kind: String, id: int) -> Dictionary:
	return _indexes.get(kind, _empty_row).get(id, _empty_row)


func _connect(source: Signal) -> void:
	source.connect(_on_dirty)
	_connections.append(source)


func _on_dirty(_value = null) -> void:
	_dirty = true


func _reset_values() -> void:
	_rows = {}
	_indexes = {}
	for kind in KINDS:
		_rows[kind] = _empty_rows
		_indexes[kind] = _empty_row
	_counts = _new_counts()
	_counts.make_read_only()
	_sampled_msec = 0


func _new_counts() -> Dictionary:
	return {"workers": 0, "working": 0, "travelling": 0, "waiting": 0,
		"reserve": 0, "jobs": 0, "pending": 0, "pending_haul": 0, "blocked": 0,
		"stockpiles": 0, "stored": 0, "loose": 0, "carried": 0, "reserved": 0}


func _close_cursor() -> void:
	if _dictionary_cursor != null:
		_dictionary_cursor.close()
		_dictionary_cursor = null


func _begin_dictionary(source: Dictionary) -> void:
	_close_cursor()
	_dictionary_cursor = DictionaryCursor.new()
	_dictionary_cursor.start(source)


func _begin_economy() -> void:
	_close_cursor()
	_pending_rows = {"job": [], "stockpile": [], "resource": []}
	_pending_indexes = {"job": {}, "stockpile": {}, "resource": {}}
	_pending_counts = _new_counts()
	_occupied = {}
	_cursor = 0
	_phase = 0
	_dirty = false


func _economy_step(world) -> void:
	if _dirty:
		_begin_economy()
		return
	match _phase:
		0:
			if _cursor < world.task_queue.tasks.size():
				var row := _job_row(world.task_queue.tasks[_cursor])
				_append_pending("job", row)
				_pending_counts.jobs += 1
				_pending_counts.pending += int(row.pending)
				_pending_counts.pending_haul += int(row.pending and row.task_type == TaskQueue.TaskType.HAUL)
				_pending_counts.blocked += int(row.blocked)
				_cursor += 1
			else:
				_phase = 1
				_begin_dictionary(world.stockpile_store.stockpiles)
		1:
			if not _dictionary_cursor.done:
				var stockpile: Dictionary = world.stockpile_store.stockpiles[_dictionary_cursor.key]
				_append_pending("stockpile", _stockpile_row(stockpile,
					world.stockpile_store.display_name(int(stockpile.id))))
				_pending_counts.stockpiles += 1
				_dictionary_cursor.next()
			else:
				_phase = 2
				_begin_dictionary(world.item_store.items)
		2:
			if not _dictionary_cursor.done:
				_accumulate_item(world, world.item_store.items[_dictionary_cursor.key])
				_dictionary_cursor.next()
			else:
				_close_cursor()
				_phase = 3
				_cursor = 0
		3:
			if _cursor < world.workers.size():
				var worker = world.workers[_cursor]
				_cursor += 1
				if is_instance_valid(worker) and worker.carried_count > 0 \
						and _pending_indexes.resource.has(worker.carried_material_id):
					_append_reference(_pending_indexes.resource[worker.carried_material_id], "worker_ids", worker.worker_id)
			else:
				_phase = 4
				_cursor = 0
		4, 5:
			var kind := "stockpile" if _phase == 4 else "resource"
			var rows: Array = _pending_rows[kind]
			if _cursor < rows.size():
				var row: Dictionary = rows[_cursor]
				if kind == "stockpile":
					row.free_capacity = maxi(0, int(row.capacity) - int(row.stored_count))
					row.description = "%d/%d cells occupied; %d/%d items stored" % [
						row.occupied_cells, row.cell_count, row.stored_count, row.capacity]
				else:
					for field in ["item_ids", "stockpile_ids", "worker_ids"]:
						row[field].make_read_only()
					row.description = "%d stored, %d loose, %d carried; %d reserved (overlapping)" % [
						row.stored, row.loose, row.carried, row.reserved]
				row.make_read_only()
				_cursor += 1
			else:
				_phase += 1
				_cursor = 0
		6:
			for kind in ["job", "stockpile", "resource"]:
				_pending_rows[kind].make_read_only()
				_rows[kind] = _pending_rows[kind]
				_indexes[kind] = _pending_indexes[kind]
			var counts := _counts.duplicate()
			for key in ["jobs", "pending", "pending_haul", "blocked", "stockpiles", "stored", "loose", "carried", "reserved"]:
				counts[key] = _pending_counts[key]
			_publish_counts(counts)
			_phase = -1


func _append_pending(kind: String, row: Dictionary) -> void:
	_pending_rows[kind].append(row)
	_pending_indexes[kind][row.id] = row


func _worker_step(world) -> void:
	if _workers_dirty:
		_worker_cursor = 0
		_worker_rows = []
		_worker_index = {}
		_worker_counts = {"workers": 0, "working": 0, "travelling": 0, "waiting": 0, "reserve": 0}
		_workers_dirty = false
		return
	if _worker_cursor < world.workers.size():
		var worker = world.workers[_worker_cursor]
		_worker_cursor += 1
		if not is_instance_valid(worker):
			return
		var row := _worker_row(world, worker)
		_worker_rows.append(row)
		_worker_index[row.id] = row
		_worker_counts.workers += 1
		_worker_counts[row.activity] += 1
		return
	_worker_rows.make_read_only()
	_rows.worker = _worker_rows
	_indexes.worker = _worker_index
	var counts := _counts.duplicate()
	for key in _worker_counts:
		counts[key] = _worker_counts[key]
	_publish_counts(counts)
	_worker_cursor = -1


func _publish_counts(counts: Dictionary) -> void:
	counts.make_read_only()
	_counts = counts
	_sampled_msec = Time.get_ticks_msec()
	revision += 1


func _worker_row(world, worker) -> Dictionary:
	var activity := "waiting"
	var description := "Waiting"
	var work_priorities := {}
	var enabled_work: Array[String] = []
	for work_id in ["hauling", "mining", "building"]:
		var priority: int = worker.get_work_priority(work_id)
		work_priorities[work_id] = priority
		if priority > 0:
			enabled_work.append("%s (%d)" % [work_id, priority])
	work_priorities.make_read_only()
	var custom_assignments: bool = not worker.work_priorities.is_empty()
	var default_fighter: bool = worker.role_id == Roles.Role.FIGHTER and not custom_assignments
	var task = world.task_queue.get_task(worker.current_task_id) if worker.current_task_id >= 0 else null
	match worker.state:
		Worker.WorkerState.WORKING:
			activity = "working"
			description = "Working"
		Worker.WorkerState.MOVING:
			activity = "travelling"
			description = "Travelling"
		Worker.WorkerState.FALLING:
			activity = "travelling"
			description = "Falling"
		Worker.WorkerState.WAITING_FOR_PATH:
			description = "Waiting for path"
		Worker.WorkerState.WAITING:
			# The production WAITING transition follows an invalid work position;
			# a blocked path itself interrupts/releases work instead.
			description = "Work position invalid; route retry pending" if task != null else "Waiting for task"
		Worker.WorkerState.IDLE:
			if enabled_work.is_empty():
				activity = "reserve"
				description = "Reserve" if default_fighter else "Reserve; no work enabled"
			elif custom_assignments:
				description = "Awaiting assigned work: %s" % ", ".join(enabled_work)
			elif worker.role_id == Roles.Role.MINER:
				description = "Miner awaiting excavation"
			elif worker.role_id == Roles.Role.HAULER:
				description = "Hauler awaiting haul"
	var role := Roles.display_name(worker.role_id)
	if default_fighter:
		description += "; combat not implemented yet"
	if worker.current_task_id >= 0:
		description += "; Task %d: %s" % [worker.current_task_id, _task_display_name(task)]
	if worker.carried_count > 0:
		description += "; Carrying %d %s" % [worker.carried_count, _material_name(world, worker.carried_material_id)]
	var row := {"kind": "worker", "id": int(worker.worker_id),
		"title": "Worker %d - %s" % [worker.worker_id, "Custom work priorities" if custom_assignments else role],
		"description": description, "work_priorities": work_priorities,
		"has_custom_assignments": custom_assignments,
		"pos": worker.get_block_coord(), "role_id": int(worker.role_id), "role": role,
		"activity": activity, "task_id": int(worker.current_task_id),
		"carried_count": int(worker.carried_count), "carried_material_id": int(worker.carried_material_id),
		"carried_source_item_id": int(worker.carried_source_item_id), "state": int(worker.state)}
	row.make_read_only()
	return row


func _job_row(task) -> Dictionary:
	var now := Time.get_ticks_msec()
	var unknown: bool = task.accessibility == TaskQueue.TaskAccessibility.UNKNOWN
	var blocked: bool = task.accessibility == TaskQueue.TaskAccessibility.UNREACHABLE
	var stale: bool = not unknown and task.retry_due_msec > 0 and now >= task.retry_due_msec
	var type_name := _task_display_name(task)
	var status_name: String = ["Pending", "In progress", "Completed"][clampi(task.status, 0, 2)]
	var reason := "Not evaluated" if unknown else "Reachable"
	if blocked:
		reason = ["Unreachable", "No work position", "No worker path", "No eligible worker"][clampi(task.block_reason, 0, 3)]
	if stale:
		reason += " (retry due; last known state)"
	var row := {"kind": "job", "id": int(task.id), "title": "%s %d" % [type_name, task.id],
		"description": "%s - %s" % [status_name, reason], "pos": task.pos,
		"task_type": int(task.type), "status": int(task.status),
		"pending": task.status == TaskQueue.TaskStatus.PENDING, "blocked": blocked,
		"block_reason": int(task.block_reason), "accessibility": int(task.accessibility),
		"assigned_worker_id": int(task.assigned_worker.worker_id) if is_instance_valid(task.assigned_worker) else -1,
		"accessibility_updated_msec": int(task.accessibility_updated_msec),
		"accessibility_age_msec": -1 if unknown else maxi(0, now - int(task.accessibility_updated_msec)),
		"accessibility_stale": stale, "retry_due_msec": int(task.retry_due_msec)}
	row.make_read_only()
	return row


func _stockpile_row(stockpile: Dictionary, name: String) -> Dictionary:
	var categories := {}
	for category in StockpileStore.CATEGORIES:
		categories[category] = bool(stockpile.get("allowed_categories", {}).get(category, false))
	var overrides := {}
	var source: Dictionary = stockpile.get("material_overrides", {})
	var inspected := 0
	for material in source:
		if inspected >= MAX_OVERRIDES:
			break
		inspected += 1
		# Retain int/string key identity, matching the store's exact-override rules.
		if typeof(material) == TYPE_INT or typeof(material) == TYPE_STRING:
			overrides[material] = bool(source[material])
	categories.make_read_only()
	overrides.make_read_only()
	var cells: Array = stockpile.get("cells", [])
	var capacity := cells.size() * StockpileStore.BASE_CELL_CAPACITY
	return {"kind": "stockpile", "id": int(stockpile.id),
		"title": name, "name": name, "description": "",
		"pos": cells[0] if not cells.is_empty() else Vector3i.ZERO,
		"cell_count": cells.size(), "occupied_cells": 0, "stored_count": 0,
		"capacity": capacity, "free_capacity": capacity,
		"allowed_categories": categories, "material_overrides": overrides,
		"material_overrides_truncated": source.size() > overrides.size()}


func _accumulate_item(world, item: Dictionary) -> void:
	var material := int(item.get("material_id", 0))
	var count := int(item.get("count", 0))
	if material <= 0 or count <= 0:
		return
	var resource: Dictionary = _pending_indexes.resource.get(material, {})
	if resource.is_empty():
		resource = {"kind": "resource", "id": material, "material_id": material,
			"title": _material_name(world, material), "description": "",
			"stored": 0, "loose": 0, "carried": 0, "reserved": 0, "total": 0,
			"item_ids": [], "stockpile_ids": [], "worker_ids": [],
			"item_ids_truncated": false, "stockpile_ids_truncated": false, "worker_ids_truncated": false}
		_append_pending("resource", resource)
	var stockpile_id := int(item.get("stored_stockpile_id", -1))
	_append_reference(resource, "item_ids", int(item.get("id", -1)))
	if stockpile_id >= 0:
		_append_reference(resource, "stockpile_ids", stockpile_id)
	var category := "carried" if bool(item.get("is_carried", false)) else ("stored" if stockpile_id >= 0 else "loose")
	resource[category] += count
	resource.total += count
	_pending_counts[category] += count
	if int(item.get("reserved_by_task_id", -1)) >= 0:
		resource.reserved += count
		_pending_counts.reserved += count
	if category == "stored" and _pending_indexes.stockpile.has(stockpile_id):
		var stockpile: Dictionary = _pending_indexes.stockpile[stockpile_id]
		stockpile.stored_count += count
		var pos: Vector3i = item.get("pos", Vector3i.ZERO)
		if not _occupied.has(pos):
			_occupied[pos] = true
			stockpile.occupied_cells += 1


func _suggestion() -> String:
	if _counts.pending_haul > 0 and _counts.reserve > 0:
		return "%d hauling jobs waiting; %d reserve available." % [_counts.pending_haul, _counts.reserve]
	if _counts.blocked > 0:
		return "Inspect blocked jobs for their last known accessibility reason."
	if _counts.loose > 0 and _counts.stockpiles == 0:
		return "Create a stockpile for loose resources."
	if _counts.loose > 0:
		return "Check hauler availability and stockpile filters and capacity."
	return ""


func _suggestion_category() -> String:
	if _counts.pending_haul > 0 and _counts.reserve > 0:
		return "workers"
	if _counts.blocked > 0:
		return "jobs"
	if _counts.loose > 0:
		return "stockpiles"
	return ""


func _append_reference(row: Dictionary, field: String, id: int) -> void:
	if id < 0:
		return
	var ids: Array = row[field]
	if ids.has(id):
		return
	if ids.size() >= MAX_REFERENCES:
		row[field + "_truncated"] = true
	else:
		ids.append(id)


func _task_type_name(type: int) -> String:
	return ["Dig", "Place", "Stairs", "Haul"][clampi(type, 0, 3)]


func _task_display_name(task) -> String:
	if task == null:
		return "no longer queued"
	if task.type == TaskQueue.TaskType.STAIRS and bool(task.data.get("remove_stairs", false)):
		return "Remove stairs"
	return _task_type_name(task.type)


func _material_name(world, material: int) -> String:
	var label: String = world.block_registry.get_name(material).left(128)
	return label if not label.is_empty() else "Material %d" % material
