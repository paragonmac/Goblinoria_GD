extends RefCounted
class_name MainHudController
## HUD label setup and per-frame HUD updates.

#region State
var y_level_label: Label
var gen_status_label: Label
var render_level_base_y: int = 0
#endregion


func setup(hud_layer: CanvasLayer) -> void:
	if hud_layer == null:
		return

	y_level_label = Label.new()
	y_level_label.name = "YLevelLabel"
	y_level_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	y_level_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	y_level_label.anchor_left = 1.0
	y_level_label.anchor_right = 1.0
	y_level_label.anchor_top = 1.0
	y_level_label.anchor_bottom = 1.0
	y_level_label.offset_left = -160.0
	y_level_label.offset_top = -30.0
	y_level_label.offset_right = -10.0
	y_level_label.offset_bottom = -10.0
	y_level_label.text = ""
	hud_layer.add_child(y_level_label)

	gen_status_label = Label.new()
	gen_status_label.name = "GenStatusLabel"
	gen_status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	gen_status_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	gen_status_label.anchor_left = 1.0
	gen_status_label.anchor_right = 1.0
	gen_status_label.anchor_top = 1.0
	gen_status_label.anchor_bottom = 1.0
	gen_status_label.offset_left = -240.0
	gen_status_label.offset_top = -50.0
	gen_status_label.offset_right = -10.0
	gen_status_label.offset_bottom = -30.0
	gen_status_label.text = ""
	hud_layer.add_child(gen_status_label)


func set_render_level_base(world: World) -> void:
	if world == null:
		return
	render_level_base_y = world.top_render_y


func update_hud(world: World, hud_label: Label, info_block_id: int, info_block_pos: Vector3i) -> void:
	if world == null or hud_label == null:
		return
	var mode_name := _get_mode_display_name(world)
	var info_text := _get_info_display_text(world, info_block_id, info_block_pos)
	var task_count := world.task_queue.active_count()
	hud_label.text = "Mode: %s%s | Tasks: %d" % [mode_name, info_text, task_count]

	if y_level_label != null:
		y_level_label.text = "Level: %d" % (world.top_render_y - render_level_base_y)

	if gen_status_label != null:
		var stats := world.get_generation_stats()
		var queued: int = int(stats.get("queued", 0))
		var active: int = int(stats.get("active", 0))
		var results: int = int(stats.get("results", 0))
		gen_status_label.text = "Gen q:%d act:%d res:%d" % [queued, active, results]


func _get_mode_display_name(world: World) -> String:
	match world.player_mode:
		World.PlayerMode.INFORMATION:
			return "Info"
		World.PlayerMode.DIG:
			return "Dig"
		World.PlayerMode.PLACE:
			return "Place"
		World.PlayerMode.STAIRS:
			return "Stairs"
		_:
			return "?"


func _get_info_display_text(world: World, info_block_id: int, info_block_pos: Vector3i) -> String:
	if world.player_mode != World.PlayerMode.INFORMATION or info_block_id < 0:
		return ""

	var block_name := world.get_block_name(info_block_id)
	return " | %s (%d) @ %d,%d,%d" % [
		block_name,
		info_block_id,
		info_block_pos.x,
		info_block_pos.y,
		info_block_pos.z,
	]

