extends RefCounted
## Bottom command bar (status chips, tool palette, panel buttons), the
## contextual tool-options row above it, the right-edge depth gauge and the
## blocked-jobs alert. The controller owns actions; this only builds and shows.

const H = preload("res://scripts/ui/colony_panel_helpers.gd")
const Icon = preload("res://scripts/ui/ui_icon.gd")
const Tools = preload("res://scripts/main_tool_catalog.gd")
const UITheme = preload("res://scripts/ui/colony_ui_theme.gd")

const BAR_HEIGHT := 96.0
const GAUGE_WIDTH := 84.0
const EDGE := 16.0
const STATUS := [
	{"id": "working", "icon": "busy", "caption": "Busy", "tip": "Workers doing a job. Click to list them."},
	{"id": "travelling", "icon": "moving", "caption": "Moving", "tip": "Workers walking to a job. Click to list them."},
	{"id": "waiting", "icon": "idle", "caption": "Idle", "tip": "Workers waiting for something they can do. Click to list them."},
	{"id": "reserve", "icon": "reserve", "caption": "Reserve", "tip": "Workers with no enabled work (Fighters until combat exists). Click to list them."},
	{"id": "pending", "icon": "pending", "caption": "Pending", "tip": "Jobs waiting for a worker. Click to list them."},
	{"id": "blocked", "icon": "blocked", "caption": "Blocked", "tip": "Jobs no worker can reach right now. Click to list them."},
	{"id": "stored", "icon": "stored", "caption": "Stored", "tip": "Items in stockpiles. Click for resources."},
]
const TOOL_LAYOUT := [
	{"icon": "inspect", "caption": "Inspect", "modes": [World.PlayerMode.INFORMATION]},
	{"icon": "dig", "caption": "Dig", "modes": [World.PlayerMode.DIG]},
	{"icon": "build", "caption": "Build", "modes": [World.PlayerMode.PLACE]},
	{"icon": "stairs", "caption": "Stairs", "modes": [World.PlayerMode.UP_STAIRS, World.PlayerMode.DOWN_STAIRS]},
	{"icon": "erase", "caption": "Erase", "modes": [World.PlayerMode.ERASE]},
	{"icon": "stockpile", "caption": "Stockpile", "modes": [World.PlayerMode.STOCKPILE]},
]
const OPTION_HINTS := {
	World.PlayerMode.INFORMATION: ["inspect", "Click a block to see it and everything on it"],
	World.PlayerMode.DIG: ["dig", "Drag to mark blocks. Workers dig sideways on their own level"],
	World.PlayerMode.PLACE: ["build", "Uses 1 stored iron ore per block"],
	World.PlayerMode.ERASE: ["erase", "Cancels pending jobs and stockpile cells (not demolition)"],
	World.PlayerMode.STOCKPILE: ["stockpile", "Drag to designate a stockpile; select one to edit it"],
}

var ui
var bar: PanelContainer
var summary: Label
var status_chips: Dictionary = {}
var tool_buttons: Dictionary = {}
var stairs_button: Button
var stairs_up: Button
var stairs_down: Button
var last_stairs_mode: int = World.PlayerMode.UP_STAIRS
var options_row: PanelContainer
var options_hint_icon
var options_hint: Label
var stairs_options: HBoxContainer
var gauge: PanelContainer
var level_label: Label
var level_caption: Label
var alert: Button
var alert_text: Label
var _shown_mode := -1


func build(root: Control, owner) -> void:
	ui = owner
	bar = PanelContainer.new()
	bar.name = "CommandBar"
	bar.theme_type_variation = "CommandBar"
	root.add_child(bar)
	bar.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	bar.offset_top = -BAR_HEIGHT
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	bar.add_child(row)
	var status := HBoxContainer.new()
	status.name = "Status"
	status.add_theme_constant_override("separation", 4)
	row.add_child(status)
	for entry: Dictionary in STATUS:
		var chip := _chip(status, entry)
		status_chips[entry.id] = chip
	summary = Label.new()
	summary.theme_type_variation = "Caption"
	summary.text = ""
	summary.custom_minimum_size = Vector2(0, 0)
	summary.mouse_filter = Control.MOUSE_FILTER_IGNORE
	status.add_child(summary)
	row.add_child(_separator())
	var tools := HBoxContainer.new()
	tools.name = "Tools"
	tools.add_theme_constant_override("separation", 6)
	row.add_child(tools)
	for entry: Dictionary in TOOL_LAYOUT:
		var button := H.icon_button(tools, entry.icon, entry.caption, _on_tool_pressed.bind(entry), "ToolButton", 30, Vector2(82, 72))
		button.toggle_mode = true
		button.name = str(entry.caption) + "Tool"
		_add_key_badge(button, entry.modes)
		button.tooltip_text = "%s (%s)" % [entry.caption, _key_text(entry.modes)]
		for mode: int in entry.modes:
			tool_buttons[mode] = button
		if entry.modes.size() > 1:
			stairs_button = button
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(spacer)
	ui.navigation.setup(row, root)
	row.add_child(_separator())
	var menu := H.icon_button(row, "menu", "Menu", ui.main.open_menu, "PanelButton", 26, Vector2(64, 72))
	menu.name = "Menu"
	_build_options_row(root)
	_build_gauge(root)
	_build_alert(root)


func _chip(parent: Control, entry: Dictionary) -> Button:
	var chip := Button.new()
	chip.name = str(entry.caption) + "Chip"
	chip.theme_type_variation = "ChipButton"
	chip.custom_minimum_size = Vector2(68, 72)
	chip.focus_mode = Control.FOCUS_NONE
	chip.tooltip_text = entry.tip
	chip.pressed.connect(_on_chip_pressed.bind(str(entry.id)))
	parent.add_child(chip)
	var stack := VBoxContainer.new()
	stack.mouse_filter = Control.MOUSE_FILTER_IGNORE
	stack.alignment = BoxContainer.ALIGNMENT_CENTER
	stack.add_theme_constant_override("separation", 0)
	chip.add_child(stack)
	stack.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var icon: Control = Icon.make(entry.icon, 22, UITheme.BAD if entry.id == "blocked" else UITheme.BRASS_LIGHT)
	icon.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	stack.add_child(icon)
	var number := Label.new()
	number.theme_type_variation = "Number"
	number.text = "0"
	number.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	number.mouse_filter = Control.MOUSE_FILTER_IGNORE
	stack.add_child(number)
	var caption := Label.new()
	caption.theme_type_variation = "Caption"
	caption.text = entry.caption
	caption.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	caption.mouse_filter = Control.MOUSE_FILTER_IGNORE
	stack.add_child(caption)
	chip.set_meta("number", number)
	return chip


func _separator() -> VSeparator:
	var line := VSeparator.new()
	line.mouse_filter = Control.MOUSE_FILTER_IGNORE
	line.add_theme_color_override("separator", UITheme.BRASS_DIM)
	return line


func _key_text(modes: Array) -> String:
	var keys: PackedStringArray = []
	for tool: Dictionary in Tools.TOOLS:
		if modes.has(int(tool.mode)):
			keys.append(OS.get_keycode_string(tool.key))
	return "/".join(keys)


func _add_key_badge(button: Button, modes: Array) -> void:
	var badge := Label.new()
	badge.theme_type_variation = "KeyBadge"
	badge.text = _key_text(modes)
	badge.mouse_filter = Control.MOUSE_FILTER_IGNORE
	button.add_child(badge)
	badge.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	badge.offset_left = -34
	badge.offset_right = -6
	badge.offset_top = 3
	badge.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT


func _build_options_row(root: Control) -> void:
	options_row = PanelContainer.new()
	options_row.name = "ToolOptions"
	options_row.theme_type_variation = "Card"
	options_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(options_row)
	options_row.anchor_left = 0.5
	options_row.anchor_right = 0.5
	options_row.anchor_top = 1.0
	options_row.anchor_bottom = 1.0
	options_row.grow_horizontal = Control.GROW_DIRECTION_BOTH
	options_row.grow_vertical = Control.GROW_DIRECTION_BEGIN
	options_row.offset_bottom = -BAR_HEIGHT - 10.0
	var line := HBoxContainer.new()
	line.add_theme_constant_override("separation", 10)
	options_row.add_child(line)
	stairs_options = HBoxContainer.new()
	stairs_options.add_theme_constant_override("separation", 6)
	line.add_child(stairs_options)
	stairs_up = _option_toggle(stairs_options, "stairs_up", "Up", World.PlayerMode.UP_STAIRS)
	stairs_down = _option_toggle(stairs_options, "stairs_down", "Down", World.PlayerMode.DOWN_STAIRS)
	stairs_options.add_child(_separator())
	options_hint_icon = Icon.make("inspect", 20)
	options_hint_icon.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	line.add_child(options_hint_icon)
	options_hint = Label.new()
	options_hint.theme_type_variation = "Body"
	options_hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	options_hint.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	line.add_child(options_hint)
	options_row.hide()


func _option_toggle(parent: Control, icon_name: String, caption: String, mode: int) -> Button:
	var button := Button.new()
	button.theme_type_variation = "ToolButton"
	button.toggle_mode = true
	button.focus_mode = Control.FOCUS_NONE
	button.custom_minimum_size = Vector2(96, 40)
	button.tooltip_text = "%s stairs (%s)" % [caption, _key_text([mode])]
	button.pressed.connect(func(): ui.choose_tool(mode))
	parent.add_child(button)
	var line := HBoxContainer.new()
	line.mouse_filter = Control.MOUSE_FILTER_IGNORE
	line.alignment = BoxContainer.ALIGNMENT_CENTER
	button.add_child(line)
	line.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	line.add_child(Icon.make(icon_name, 20))
	var text := Label.new()
	text.theme_type_variation = "Body"
	text.text = caption
	text.mouse_filter = Control.MOUSE_FILTER_IGNORE
	line.add_child(text)
	return button


func _build_gauge(root: Control) -> void:
	gauge = PanelContainer.new()
	gauge.name = "DepthGauge"
	gauge.theme_type_variation = "Card"
	gauge.mouse_filter = Control.MOUSE_FILTER_STOP
	root.add_child(gauge)
	gauge.anchor_left = 1.0
	gauge.anchor_right = 1.0
	gauge.anchor_top = 0.5
	gauge.anchor_bottom = 0.5
	gauge.offset_left = -EDGE - GAUGE_WIDTH
	gauge.offset_right = -EDGE
	gauge.offset_top = -170.0
	gauge.offset_bottom = 110.0
	var stack := VBoxContainer.new()
	stack.alignment = BoxContainer.ALIGNMENT_CENTER
	stack.add_theme_constant_override("separation", 6)
	gauge.add_child(stack)
	var up := H.icon_button(stack, "up", "Up", ui.change_level.bind(1), "IconButton", 22, Vector2(60, 56))
	up.name = "LevelUp"
	up.tooltip_text = "Show the level above ( ] )"
	var ruler := VBoxContainer.new()
	ruler.size_flags_vertical = Control.SIZE_EXPAND_FILL
	ruler.alignment = BoxContainer.ALIGNMENT_CENTER
	stack.add_child(ruler)
	var caption := Label.new()
	caption.theme_type_variation = "Caption"
	caption.text = "Level"
	caption.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	ruler.add_child(caption)
	level_label = Label.new()
	level_label.theme_type_variation = "Heading"
	level_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	level_label.text = "0"
	ruler.add_child(level_label)
	level_caption = Label.new()
	level_caption.theme_type_variation = "Caption"
	level_caption.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	ruler.add_child(level_caption)
	var down := H.icon_button(stack, "down", "Down", ui.change_level.bind(-1), "IconButton", 22, Vector2(60, 56))
	down.name = "LevelDown"
	down.tooltip_text = "Show the level below ( [ )"


func _build_alert(root: Control) -> void:
	alert = Button.new()
	alert.name = "BlockedAlert"
	alert.theme_type_variation = "IconButton"
	alert.focus_mode = Control.FOCUS_NONE
	alert.tooltip_text = "Open blocked jobs"
	alert.pressed.connect(func(): ui.show_tasks("Blocked"))
	root.add_child(alert)
	alert.anchor_left = 1.0
	alert.anchor_right = 1.0
	alert.anchor_top = 1.0
	alert.anchor_bottom = 1.0
	alert.offset_left = -EDGE - 340.0
	alert.offset_right = -EDGE
	alert.offset_bottom = -BAR_HEIGHT - 10.0
	alert.offset_top = -BAR_HEIGHT - 10.0 - 48.0
	alert.add_theme_stylebox_override("normal", _toast_box())
	alert.add_theme_stylebox_override("hover", _toast_box(UITheme.BRASS_LIGHT))
	var line := HBoxContainer.new()
	line.mouse_filter = Control.MOUSE_FILTER_IGNORE
	line.add_theme_constant_override("separation", 10)
	alert.add_child(line)
	line.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	line.offset_left = 12
	line.offset_right = -12
	var icon: Control = Icon.make("warning", 22, UITheme.WARNING)
	icon.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	line.add_child(icon)
	alert_text = Label.new()
	alert_text.theme_type_variation = "Body"
	alert_text.add_theme_color_override("font_color", UITheme.WARNING)
	alert_text.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	alert_text.mouse_filter = Control.MOUSE_FILTER_IGNORE
	line.add_child(alert_text)
	alert.hide()


func _toast_box(edge: Color = UITheme.WARNING) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.16, 0.1, 0.07, 0.94)
	style.border_color = edge
	style.set_border_width_all(1)
	style.set_corner_radius_all(8)
	return style


func _on_tool_pressed(entry: Dictionary) -> void:
	var modes: Array = entry.modes
	var mode: int = int(modes[0])
	if modes.size() > 1:
		mode = last_stairs_mode
	ui.choose_tool(mode)


func _on_chip_pressed(id: String) -> void:
	match id:
		"pending":
			ui.show_tasks("Pending")
		"blocked":
			ui.show_tasks("Blocked")
		"stored":
			ui.toggle_category("resources")
		_:
			ui.toggle_workers(id)


## Called every UI tick: tool highlight and the contextual options row.
func update_tools(mode: int) -> void:
	if mode == World.PlayerMode.UP_STAIRS or mode == World.PlayerMode.DOWN_STAIRS:
		last_stairs_mode = mode
	for button: Button in tool_buttons.values():
		button.set_pressed_no_signal(false)
	if tool_buttons.has(mode):
		tool_buttons[mode].set_pressed_no_signal(true)
	stairs_up.set_pressed_no_signal(mode == World.PlayerMode.UP_STAIRS)
	stairs_down.set_pressed_no_signal(mode == World.PlayerMode.DOWN_STAIRS)
	if mode == _shown_mode:
		return
	_shown_mode = mode
	var stairs := mode == World.PlayerMode.UP_STAIRS or mode == World.PlayerMode.DOWN_STAIRS
	stairs_options.visible = stairs
	if stairs:
		options_hint_icon.icon_name = "rotate"
		options_hint.text = "Mouse wheel rotates. Red means the flight can't go there"
	elif OPTION_HINTS.has(mode):
		options_hint_icon.icon_name = OPTION_HINTS[mode][0]
		options_hint.text = OPTION_HINTS[mode][1]
	options_row.visible = stairs or OPTION_HINTS.has(mode)
	options_row.reset_size()


## Called on the summary refresh cadence.
func update_counts(counts: Dictionary, updating: bool) -> void:
	for id: String in status_chips:
		var number: Label = status_chips[id].get_meta("number")
		number.text = _compact(int(counts.get(id, 0)))
	summary.text = "Updating..." if updating else ""
	var blocked := int(counts.get("blocked", 0))
	var more_open: bool = is_instance_valid(ui.navigation.more_panel) and ui.navigation.more_panel.visible
	alert.visible = blocked > 0 and not more_open
	alert_text.text = "%d %s can't be reached" % [blocked, "job" if blocked == 1 else "jobs"]


func update_level(level: int, y: int) -> void:
	level_label.text = "%d" % level
	level_caption.text = "Y %d" % y


static func _compact(value: int) -> String:
	if value >= 10000:
		return "%dk" % (value / 1000)
	return str(value)
