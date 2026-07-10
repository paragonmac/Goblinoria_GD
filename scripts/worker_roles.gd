extends RefCounted
class_name WorkerRoles
## Static role templates. Workers share one state machine and differ by eligibility.

enum Role {MINER, HAULER, FIGHTER}

const DEFAULT_SPAWN_ROLES := [
	Role.MINER,
	Role.MINER,
	Role.HAULER,
	Role.FIGHTER,
]


static func is_valid(role_id: int) -> bool:
	return role_id >= Role.MINER and role_id <= Role.FIGHTER


static func default_spawn_role(index: int) -> int:
	if index >= 0 and index < DEFAULT_SPAWN_ROLES.size():
		return DEFAULT_SPAWN_ROLES[index]
	return Role.MINER


static func display_name(role_id: int) -> String:
	match role_id:
		Role.MINER:
			return "Miner"
		Role.HAULER:
			return "Hauler"
		Role.FIGHTER:
			return "Fighter"
		_:
			return "Unknown"


static func idle_status(role_id: int) -> String:
	match role_id:
		Role.MINER:
			return "Awaiting excavation"
		Role.HAULER:
			return "Awaiting haul work"
		Role.FIGHTER:
			return "Awaiting threat"
		_:
			return "Unknown role"


static func allows_idle_wander(role_id: int) -> bool:
	return role_id != Role.FIGHTER


static func allowed_task_types(role_id: int) -> Array[int]:
	match role_id:
		Role.MINER:
			return [
				TaskQueue.TaskType.DIG,
				TaskQueue.TaskType.PLACE,
				TaskQueue.TaskType.STAIRS,
			]
		Role.HAULER:
			return [TaskQueue.TaskType.HAUL]
		_:
			return []


static func can_accept_task(role_id: int, task_type: int) -> bool:
	return allowed_task_types(role_id).has(task_type)


static func task_role_name(task_type: int) -> String:
	match task_type:
		TaskQueue.TaskType.DIG, TaskQueue.TaskType.PLACE, TaskQueue.TaskType.STAIRS:
			return display_name(Role.MINER)
		TaskQueue.TaskType.HAUL:
			return display_name(Role.HAULER)
		_:
			return "Worker"
