extends RefCounted
class_name MainLoadingController

var owner_node: Node
var world: World
var hud_layer: CanvasLayer
var menu_layer: CanvasLayer
var loading_layer: CanvasLayer
var loading_status_label: Label
var loading_progress_bar: ProgressBar


func initialize(owner_ref: Node, world_ref: World, hud_layer_ref: CanvasLayer, menu_layer_ref: CanvasLayer) -> void:
	owner_node = owner_ref
	world = world_ref
	hud_layer = hud_layer_ref
	menu_layer = menu_layer_ref


func setup_loading_screen() -> void:
	if owner_node == null:
		return
	if loading_layer != null:
		return
	loading_layer = CanvasLayer.new()
	loading_layer.name = "LoadingScreen"
	loading_layer.layer = 100
	if menu_layer != null:
		loading_layer.layer = menu_layer.layer + 10
	loading_layer.visible = false
	owner_node.add_child(loading_layer)

	var backdrop := ColorRect.new()
	backdrop.name = "Backdrop"
	backdrop.color = Color(0.0, 0.0, 0.0, 0.92)
	backdrop.anchor_right = 1.0
	backdrop.anchor_bottom = 1.0
	loading_layer.add_child(backdrop)

	var panel := PanelContainer.new()
	panel.name = "StatusWindow"
	panel.anchor_left = 0.5
	panel.anchor_top = 0.5
	panel.anchor_right = 0.5
	panel.anchor_bottom = 0.5
	panel.offset_left = -220.0
	panel.offset_top = -80.0
	panel.offset_right = 220.0
	panel.offset_bottom = 80.0
	loading_layer.add_child(panel)

	var box := VBoxContainer.new()
	box.name = "Content"
	box.add_theme_constant_override("separation", 10)
	panel.add_child(box)

	var title := Label.new()
	title.name = "Title"
	title.text = "Loading"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(title)

	loading_status_label = Label.new()
	loading_status_label.name = "StatusLabel"
	loading_status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	loading_status_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	loading_status_label.text = "Loading..."
	box.add_child(loading_status_label)

	loading_progress_bar = ProgressBar.new()
	loading_progress_bar.name = "ProgressBar"
	loading_progress_bar.min_value = 0.0
	loading_progress_bar.max_value = 1.0
	loading_progress_bar.value = 0.0
	box.add_child(loading_progress_bar)


func show(text: String) -> void:
	set_world_draw_enabled(false)
	set_status(text)
	if loading_layer != null:
		loading_layer.visible = true


func hide() -> void:
	if loading_layer != null:
		loading_layer.visible = false


func set_status(text: String) -> void:
	if loading_status_label != null:
		loading_status_label.text = text


func set_progress(ready: int, total: int) -> void:
	if loading_progress_bar == null:
		return
	loading_progress_bar.max_value = maxf(float(total), 1.0)
	loading_progress_bar.value = clampf(float(ready), 0.0, loading_progress_bar.max_value)


func set_world_draw_enabled(enabled: bool) -> void:
	if world != null:
		world.visible = enabled
	if hud_layer != null:
		hud_layer.visible = enabled