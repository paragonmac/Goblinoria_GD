extends RefCounted
class_name MainHudController
## HUD label setup and per-frame HUD updates.

#region State
var y_level_label: Label
var gen_status_label: Label
var inventory_label: Label
var stockpile_panel: PanelContainer
var stockpile_summary_label: Label
var stockpile_checkboxes: Dictionary = {}
var current_world: World
var current_stockpile_id := -1
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

	inventory_label = Label.new()
	inventory_label.name = "InventoryLabel"
	inventory_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	inventory_label.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
	inventory_label.anchor_left = 0.0
	inventory_label.anchor_right = 0.0
	inventory_label.anchor_top = 1.0
	inventory_label.anchor_bottom = 1.0
	inventory_label.offset_left = 10.0
	inventory_label.offset_top = -200.0
	inventory_label.offset_right = 200.0
	inventory_label.offset_bottom = -10.0
	inventory_label.text = ""
	hud_layer.add_child(inventory_label)
	_setup_stockpile_panel(hud_layer)


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
		World.PlayerMode.UP_STAIRS:
			return "Up Stairs"
		World.PlayerMode.DOWN_STAIRS:
			return "Down Stairs"
		World.PlayerMode.ERASE:
			return "Erase"
		World.PlayerMode.STOCKPILE:
			return "Stockpile"
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


func update_inventory(world: World) -> void:
	if inventory_label == null or world == null:
		return
	current_world = world
	var inv: Dictionary = world.inventory
	if inv.is_empty():
		inventory_label.text = ""
	else:
		var lines: PackedStringArray = PackedStringArray()
		var keys: Array = inv.keys()
		keys.sort()
		for block_id in keys:
			var count: int = inv[block_id]
			if count <= 0:
				continue
			var block_name: String = world.block_registry.get_name(block_id)
			lines.append("%s: %d" % [block_name, count])
		inventory_label.text = "\n".join(lines)
	_update_stockpile_panel(world)


func _setup_stockpile_panel(hud_layer: CanvasLayer) -> void:
	stockpile_panel = PanelContainer.new()
	stockpile_panel.name = "StockpilePanel"
	stockpile_panel.anchor_left = 1.0
	stockpile_panel.anchor_right = 1.0
	stockpile_panel.anchor_top = 0.0
	stockpile_panel.anchor_bottom = 0.0
	stockpile_panel.offset_left = -230.0
	stockpile_panel.offset_top = 80.0
	stockpile_panel.offset_right = -10.0
	stockpile_panel.offset_bottom = 300.0
	stockpile_panel.visible = false
	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 8)
	margin.add_theme_constant_override("margin_top", 8)
	margin.add_theme_constant_override("margin_right", 8)
	margin.add_theme_constant_override("margin_bottom", 8)
	stockpile_panel.add_child(margin)
	var content := VBoxContainer.new()
	content.add_theme_constant_override("separation", 4)
	margin.add_child(content)
	stockpile_summary_label = Label.new()
	stockpile_summary_label.text = "Stockpiles"
	content.add_child(stockpile_summary_label)
	for category in StockpileStore.CATEGORIES:
		var checkbox := CheckBox.new()
		checkbox.text = category
		checkbox.toggled.connect(_on_stockpile_category_toggled.bind(category))
		stockpile_checkboxes[category] = checkbox
		content.add_child(checkbox)
	hud_layer.add_child(stockpile_panel)


func _update_stockpile_panel(world: World) -> void:
	if stockpile_panel == null or stockpile_summary_label == null:
		return
	if world == null or world.stockpile_store.stockpiles.is_empty():
		current_stockpile_id = -1
		stockpile_panel.visible = false
		return
	var ids: Array = world.stockpile_store.stockpiles.keys()
	ids.sort()
	current_stockpile_id = int(ids[0])
	var stockpile: Dictionary = world.stockpile_store.stockpiles[current_stockpile_id]
	var cell_count: int = stockpile.get("cells", []).size()
	stockpile_summary_label.text = "Stockpile %d | Cells: %d" % [current_stockpile_id, cell_count]
	var allowed: Dictionary = stockpile.get("allowed_categories", {})
	for category in stockpile_checkboxes.keys():
		var checkbox: CheckBox = stockpile_checkboxes[category]
		checkbox.set_pressed_no_signal(bool(allowed.get(category, false)))
	stockpile_panel.visible = true


func _on_stockpile_category_toggled(pressed: bool, category: String) -> void:
	if current_world == null or current_stockpile_id < 0:
		return
	current_world.stockpile_store.set_category_allowed(current_stockpile_id, category, pressed)
	if current_world.task_manager != null:
		current_world.task_manager.rebuild_haul_tasks()
