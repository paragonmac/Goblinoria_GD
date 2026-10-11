extends RefCounted
class_name WorkerWorkPriorities
## Pure catalog. Persist overrides or effective_values(); absent keys use role defaults.

const MIN_PRIORITY := 0
const MAX_PRIORITY := 9
const ENTRIES := [
	{"id": "hauling", "label": "Hauling", "group": "Logistics", "implemented": true},
	{"id": "mining", "label": "Mining", "group": "Terrain & construction", "implemented": true},
	{"id": "crafting", "label": "Crafting", "group": "Production", "implemented": false},
	{"id": "building", "label": "Building", "group": "Terrain & construction", "implemented": true},
	{"id": "gathering", "label": "Gathering", "group": "Production", "implemented": false},
	{"id": "farming", "label": "Farming", "group": "Production", "implemented": false},
	{"id": "combat", "label": "Combat", "group": "Defense", "implemented": false},
]


static func entries() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for entry: Dictionary in ENTRIES:
		var row := entry.duplicate()
		row["description"] = "1 is highest; equal priorities choose the cheapest reachable route. 0 is Off." \
			if row["implemented"] else "Not implemented yet; no jobs are available."
		result.append(row)
	return result


static func is_available(work_id: String) -> bool:
	return work_id in ["hauling", "mining", "building"]


static func is_valid_setting(work_id: String, value: int) -> bool:
	return is_available(work_id) and value >= MIN_PRIORITY and value <= MAX_PRIORITY


static func task_work_id(task_type: int) -> String:
	match task_type:
		TaskQueue.TaskType.HAUL: return "hauling"
		TaskQueue.TaskType.DIG: return "mining"
		TaskQueue.TaskType.PLACE, TaskQueue.TaskType.STAIRS, TaskQueue.TaskType.TORCH: return "building"
	return ""


static func default_priority(role_id: int, work_id: String) -> int:
	# Stable WorkerRoles enum IDs; no dependency cycle with the role template catalog.
	if role_id == 0 and work_id in ["mining", "building"]:
		return 2
	if role_id == 1 and work_id == "hauling":
		return 2
	return 0


static func effective_priority(role_id: int, overrides: Dictionary, work_id: String) -> int:
	if not is_available(work_id):
		return 0
	var value = overrides.get(work_id, default_priority(role_id, work_id))
	if typeof(value) != TYPE_INT or not is_valid_setting(work_id, value):
		return default_priority(role_id, work_id)
	return value


static func effective_values(role_id: int, overrides: Dictionary) -> Dictionary:
	var values := {}
	for work_id in ["hauling", "mining", "building"]:
		values[work_id] = effective_priority(role_id, overrides, work_id)
	return values


static func route_length_lower_bound(start: Vector3i, target: Vector3i, task_type: int) -> int:
	# Paths include the starting node. Each current movement edge advances one XZ
	# cardinal step and at most one Y level. Work can occur beside the target;
	# stairs additionally permit the target/adjacent cells one level above it.
	var horizontal := absi(start.x - target.x) + absi(start.z - target.z)
	var vertical := absi(start.y - target.y)
	if task_type != TaskQueue.TaskType.HAUL:
		horizontal = maxi(0, horizontal - 1)
	if task_type == TaskQueue.TaskType.STAIRS:
		vertical = mini(vertical, absi(start.y - target.y - 1))
	return maxi(horizontal, vertical) + 1
