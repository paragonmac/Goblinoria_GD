extends RefCounted
class_name MainToolCatalog
## Shared labels and shortcuts for keyboard, HUD, and context-menu tools.

const TOOLS := [
	{"mode": World.PlayerMode.INFORMATION, "label": "Information", "key": KEY_1},
	{"mode": World.PlayerMode.DIG, "label": "Dig", "key": KEY_2},
	{"mode": World.PlayerMode.PLACE, "label": "Place", "key": KEY_3},
	{"mode": World.PlayerMode.UP_STAIRS, "label": "Up Stairs", "key": KEY_4},
	{"mode": World.PlayerMode.DOWN_STAIRS, "label": "Down Stairs", "key": KEY_5},
	{"mode": World.PlayerMode.ERASE, "label": "Erase", "key": KEY_6},
	{"mode": World.PlayerMode.STOCKPILE, "label": "Stockpile", "key": KEY_7},
	{"mode": World.PlayerMode.TORCH, "label": "Torch", "key": KEY_8},
	{"mode": World.PlayerMode.CHOP, "label": "Chop", "key": KEY_9},
]


static func mode_label(mode: int) -> String:
	for tool: Dictionary in TOOLS:
		if tool.mode == mode:
			return str(tool.label)
	return "?"


static func format_block_info(world: World, block_id: int, pos: Vector3i) -> String:
	return "%s (%d) @ %d,%d,%d" % [
		world.get_block_name(block_id), block_id, pos.x, pos.y, pos.z,
	]
