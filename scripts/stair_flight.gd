extends RefCounted
class_name StairFlight
## Pure geometry and ID helpers for player-built two-cell stair flights.

const LOWER_BASE_ID := 124
const UPPER_BASE_ID := 128
const ROTATION_COUNT := 4

const NORTH := Vector3i(0, 0, -1)
const EAST := Vector3i(1, 0, 0)
const SOUTH := Vector3i(0, 0, 1)
const WEST := Vector3i(-1, 0, 0)


static func is_flight(block_id: int) -> bool:
	return (block_id >= LOWER_BASE_ID and block_id < LOWER_BASE_ID + ROTATION_COUNT) \
		or (block_id >= UPPER_BASE_ID and block_id < UPPER_BASE_ID + ROTATION_COUNT)


static func is_lower(block_id: int) -> bool:
	return block_id >= LOWER_BASE_ID and block_id < LOWER_BASE_ID + ROTATION_COUNT


static func is_upper(block_id: int) -> bool:
	return block_id >= UPPER_BASE_ID and block_id < UPPER_BASE_ID + ROTATION_COUNT


static func rotation_for(block_id: int) -> int:
	if is_lower(block_id):
		return block_id - LOWER_BASE_ID
	if is_upper(block_id):
		return block_id - UPPER_BASE_ID
	return -1


static func direction(rotation: int) -> Vector3i:
	match posmod(rotation, ROTATION_COUNT):
		0: return NORTH
		1: return EAST
		2: return SOUTH
		3: return WEST
	return NORTH


static func lower_id(rotation: int) -> int:
	return LOWER_BASE_ID + posmod(rotation, ROTATION_COUNT)


static func upper_id(rotation: int) -> int:
	return UPPER_BASE_ID + posmod(rotation, ROTATION_COUNT)


static func cells(anchor: Vector3i, rotation: int) -> Array[Vector3i]:
	return [anchor, anchor + direction(rotation)]


static func corner_heights(block_id: int, h: float = 0.5) -> Dictionary:
	var rotation := rotation_for(block_id)
	if rotation < 0:
		return {"nw": -h, "ne": -h, "se": -h, "sw": -h}
	var low := -h if is_lower(block_id) else 0.0
	var high := 0.0 if is_lower(block_id) else h
	match rotation:
		0: return {"nw": high, "ne": high, "se": low, "sw": low}
		1: return {"nw": low, "ne": high, "se": high, "sw": low}
		2: return {"nw": low, "ne": low, "se": high, "sw": high}
		3: return {"nw": high, "ne": low, "se": low, "sw": high}
	return {"nw": -h, "ne": -h, "se": -h, "sw": -h}


static func center_offset(block_id: int) -> float:
	if is_lower(block_id):
		return -0.25
	if is_upper(block_id):
		return 0.25
	return 0.0
