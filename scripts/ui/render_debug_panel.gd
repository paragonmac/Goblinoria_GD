extends PanelContainer
## F7 Rendering debug panel (debug builds only). Non-modal live switches for
## world.renderer plus a readout of cull and void stats. Does not pause the game.

const REFRESH_SEC := 0.25
const MODE_VALUES := ["async", "area", "sync"]
const MODE_LABELS := ["Async cull", "Whole loaded area", "Main-thread cull"]
const DEPTH_VALUES := [0, 1, 2, 4, 8]
const DEPTH_LABELS := ["All layers", "1 layer", "2 layers", "4 layers", "8 layers"]
const UPDATE_LABELS := ["Every frame", "Every 50 ms"]
const DRAW_MODES := [Viewport.DEBUG_DRAW_DISABLED, Viewport.DEBUG_DRAW_UNSHADED,
		Viewport.DEBUG_DRAW_OVERDRAW, Viewport.DEBUG_DRAW_WIREFRAME,
		Viewport.DEBUG_DRAW_DISABLED, Viewport.DEBUG_DRAW_DISABLED]
const DRAW_LABELS := ["Normal", "Unshaded", "Overdraw", "Wireframe (see-through)",
		"Wireframe (visible only)", "Polygons"]
## Terrain material view per draw item ("normal" for the viewport debug modes).
const DRAW_TERRAIN_VIEWS := ["normal", "normal", "normal", "normal", "hidden_line", "polygons"]
const LOOK_AHEAD_MAX := 0.5

var main
var _syncing := false
var _refresh_accum := 0.0
var _wireframe_enabled := false
var _fps_label: Label
var _void_label: Label
var _shown_label: Label
var _updates_label: Label
var _visibility_option: OptionButton
var _depth_option: OptionButton
var _look_ahead_check: CheckBox
var _look_ahead_slider: HSlider
var _look_ahead_value: Label
var _update_option: OptionButton
var _freeze_check: CheckBox
## Darkness switches (SEE-ADR-021), keyed by render_debug setting.
var _light_checks := {}
## Drag handle for the window layout.
var title_handle: Label
## Default floating rect: between the management and details columns at 1920x1080.
const DEFAULT_RECT := Rect2(1032, 90, 360, 600)
var _draw_option: OptionButton
var _wireframe_caption: Label


func setup(main_node) -> void:
	main = main_node
	theme = ColonyUITheme.build()
	theme_type_variation = &"Card"
	mouse_filter = Control.MOUSE_FILTER_STOP
	# Position and size come from the colony UI's WindowLayout (DEFAULT_RECT until
	# the player moves, resizes or docks it).
	size = DEFAULT_RECT.size
	_build()
	visible = false
	set_process(false)


func set_panel_visible(value: bool) -> void:
	visible = value
	set_process(value)
	if value:
		_sync_controls()
		_refresh_readout()
	_refresh_accum = 0.0


func _process(delta: float) -> void:
	_refresh_accum += delta
	if _refresh_accum < REFRESH_SEC:
		return
	_refresh_accum = 0.0
	_refresh_readout()


func _build() -> void:
	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 8)
	add_child(root)
	title_handle = _label("Rendering  [F7]", "Heading")
	root.add_child(title_handle)

	var readout := VBoxContainer.new()
	readout.add_theme_constant_override("separation", 4)
	root.add_child(readout)
	_fps_label = _label("", "Body")
	_void_label = _label("", "Body")
	_shown_label = _label("", "Body")
	_updates_label = _label("", "Body")
	for line in [_fps_label, _void_label, _shown_label, _updates_label]:
		readout.add_child(line)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	root.add_child(scroll)

	var body := VBoxContainer.new()
	body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	body.add_theme_constant_override("separation", 8)
	scroll.add_child(body)

	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 10)
	grid.add_theme_constant_override("v_separation", 8)
	body.add_child(grid)

	_visibility_option = _option(MODE_LABELS)
	_visibility_option.item_selected.connect(_on_visibility_selected)
	_row(grid, "Show chunks", _visibility_option)

	_depth_option = _option(DEPTH_LABELS)
	_depth_option.item_selected.connect(_on_depth_selected)
	_row(grid, "Depth", _depth_option)

	var look_ahead_row := HBoxContainer.new()
	look_ahead_row.add_theme_constant_override("separation", 6)
	_look_ahead_check = CheckBox.new()
	_look_ahead_check.text = "Look-ahead"
	_look_ahead_check.toggled.connect(_on_look_ahead_toggled)
	look_ahead_row.add_child(_look_ahead_check)
	_look_ahead_slider = HSlider.new()
	_look_ahead_slider.min_value = 0.0
	_look_ahead_slider.max_value = LOOK_AHEAD_MAX
	_look_ahead_slider.step = 0.01
	_look_ahead_slider.custom_minimum_size.x = 90.0
	_look_ahead_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_look_ahead_slider.value_changed.connect(_on_look_ahead_value_changed)
	look_ahead_row.add_child(_look_ahead_slider)
	_look_ahead_value = _label("", "Caption")
	_look_ahead_value.custom_minimum_size.x = 48.0
	look_ahead_row.add_child(_look_ahead_value)
	body.add_child(look_ahead_row)

	_update_option = _option(UPDATE_LABELS)
	_update_option.item_selected.connect(_on_update_selected)
	_row(grid, "Update while moving", _update_option)

	_freeze_check = CheckBox.new()
	_freeze_check.text = "Freeze culling"
	_freeze_check.toggled.connect(_on_freeze_toggled)
	body.add_child(_freeze_check)
	for entry: Array in [["darkness", "Darkness"], ["fog", "Fog of war"], ["light_view", "Light view (levels)"]]:
		var check := CheckBox.new()
		check.text = entry[1]
		var key: String = entry[0]
		check.toggled.connect(func(pressed: bool) -> void: _set_render(key, pressed))
		body.add_child(check)
		_light_checks[entry[0]] = check

	_draw_option = _option(DRAW_LABELS)
	_draw_option.item_selected.connect(_on_draw_selected)
	_row(grid, "Draw mode", _draw_option)
	_wireframe_caption = _label("Wireframe applies to meshes built after enabling", "Caption")
	_wireframe_caption.visible = false
	body.add_child(_wireframe_caption)

	var dump := Button.new()
	dump.text = "Dump ramp counts"
	dump.theme_type_variation = &"PanelButton"
	dump.pressed.connect(_on_dump_pressed)
	body.add_child(dump)


func _option(items: Array) -> OptionButton:
	var option := OptionButton.new()
	option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	# Clip instead of growing: the longest item must not widen the panel past its 360 px budget.
	option.clip_text = true
	for item_text in items:
		option.add_item(str(item_text))
	if main != null and main.colony_ui != null:
		main.colony_ui.watch_popup(option.get_popup())
	return option


func _row(grid: GridContainer, caption: String, control: Control) -> void:
	var name_label := _label(caption, "Body")
	name_label.custom_minimum_size.x = 84.0
	name_label.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	grid.add_child(name_label)
	control.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grid.add_child(control)


func _label(text: String, variation: String) -> Label:
	var label := Label.new()
	label.text = text
	label.theme_type_variation = variation
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	return label


func _renderer():
	if main == null or main.world == null:
		return null
	return main.world.renderer


func _set_render(key: String, value: Variant) -> void:
	if _syncing:
		return
	var renderer = _renderer()
	if renderer != null:
		renderer.set_render_debug(key, value)


func _sync_controls() -> void:
	var renderer = _renderer()
	_syncing = true
	if renderer != null:
		var settings: Dictionary = renderer.get_render_debug()
		_visibility_option.select(maxi(MODE_VALUES.find(settings["visibility_mode"]), 0))
		_depth_option.select(maxi(DEPTH_VALUES.find(int(settings["depth_layers"])), 0))
		_look_ahead_check.button_pressed = bool(settings["look_ahead"])
		_look_ahead_slider.value = float(settings["look_ahead_sec"])
		_look_ahead_slider.editable = bool(settings["look_ahead"])
		_look_ahead_value.text = "%.2f s" % _look_ahead_slider.value
		_update_option.select(0 if bool(settings["refresh_every_frame"]) else 1)
		_freeze_check.button_pressed = bool(settings["freeze"])
		for key: String in _light_checks:
			if settings.has(key):
				_light_checks[key].button_pressed = bool(settings[key])
	var mode: int = main.get_viewport().debug_draw if main != null else Viewport.DEBUG_DRAW_DISABLED
	var view: String = renderer.get_terrain_view() if renderer != null and renderer.has_method("get_terrain_view") else "normal"
	var index: int = DRAW_TERRAIN_VIEWS.find(view) if view != "normal" else maxi(DRAW_MODES.find(mode), 0)
	_draw_option.select(index)
	_wireframe_caption.visible = mode == Viewport.DEBUG_DRAW_WIREFRAME
	_syncing = false


func _refresh_readout() -> void:
	var renderer = _renderer()
	if renderer == null:
		_fps_label.text = "Renderer unavailable"
		return
	# A loaded or new world brings a fresh renderer; keep its meter on while open.
	renderer.void_meter_enabled = visible
	_apply_stats(renderer.get_render_debug_stats())


func _apply_stats(stats: Dictionary) -> void:
	_fps_label.text = "FPS %d  |  frame %.1f ms  |  draws %d" % [
			int(stats["fps"]), float(stats["frame_ms"]), int(stats["draw_calls"])]

	var void_stats: Dictionary = stats["void"]
	var hidden := int(void_stats["hidden"])
	_void_label.text = "Void now %d  |  max (2 s) %d  |  void %.0f ms  |  void time %.0f%%" % [
			hidden, int(void_stats["max_recent"]), float(void_stats["void_ms"]),
			float(void_stats["void_pct_recent"])]
	if hidden > 0:
		_void_label.add_theme_color_override("font_color", ColonyUITheme.BAD)
	else:
		_void_label.remove_theme_color_override("font_color")

	var lag = stats["vis_lag_ms"]
	var lag_text := "n/a" if lag == null else "%d ms" % int(round(float(lag)))
	_shown_label.text = "Shown %d / eligible %d  |  vis lag %s" % [
			int(stats["shown_nodes"]), int(stats["eligible"]), lag_text]

	var last = stats["last_application_mode"]
	var last_text := "n/a" if last == null else str(last)
	_updates_label.text = "Updates/s fast %.1f full %.1f  |  cull job %.1f ms  |  last %s" % [
			float(stats["delta_per_sec"]), float(stats["full_per_sec"]),
			float(stats["cull_job_ms"]), last_text]


func _on_visibility_selected(index: int) -> void:
	_set_render("visibility_mode", MODE_VALUES[index])


func _on_depth_selected(index: int) -> void:
	_set_render("depth_layers", DEPTH_VALUES[index])


func _on_look_ahead_toggled(pressed: bool) -> void:
	_look_ahead_slider.editable = pressed
	_set_render("look_ahead", pressed)


func _on_look_ahead_value_changed(value: float) -> void:
	_look_ahead_value.text = "%.2f s" % value
	_set_render("look_ahead_sec", value)


func _on_update_selected(index: int) -> void:
	_set_render("refresh_every_frame", index == 0)


func _on_freeze_toggled(pressed: bool) -> void:
	_set_render("freeze", pressed)


func _on_draw_selected(index: int) -> void:
	var mode: int = DRAW_MODES[index]
	_wireframe_caption.visible = mode == Viewport.DEBUG_DRAW_WIREFRAME
	if _syncing or main == null:
		return
	if mode == Viewport.DEBUG_DRAW_WIREFRAME and not _wireframe_enabled:
		_wireframe_enabled = true
		RenderingServer.set_debug_generate_wireframes(true)
	main.get_viewport().debug_draw = mode
	var renderer = _renderer()
	if renderer != null and renderer.has_method("set_terrain_view"):
		renderer.set_terrain_view(DRAW_TERRAIN_VIEWS[index])


func _on_dump_pressed() -> void:
	if main != null and main.debug_overlay != null:
		main.debug_overlay.dump_ramp_counts()
