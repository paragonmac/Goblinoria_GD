extends SceneTree
## Headless catalog, theme, navigation, and GUI input contract. No world generation.

const Catalog = preload("res://scripts/ui/colony_capability_catalog.gd")
const MainTools = preload("res://scripts/main_tool_catalog.gd")
const UITheme = preload("res://scripts/ui/colony_ui_theme.gd")
const Navigation = preload("res://scripts/ui/colony_navigation.gd")
const EXPECTED_CATEGORIES := ["colony", "workers", "assignments", "jobs", "stockpiles", "resources", "build", "zones", "production", "needs", "defense", "world", "game"]
const FULL_LABELS := {"assignments": "Jobs", "jobs": "Tasks", "build": "Dig & Build", "zones": "Zones & Rooms", "needs": "Needs & Health", "world": "World & Environment", "game": "Game & Diagnostics"}
const FEATURE_LABELS := {"worker_roles": "Jobs", "work_priorities": "Per-worker priorities", "job_list": "Task list and blocked reasons", "job_priorities": "Individual task priorities", "defense_jobs": "Defense tasks", "world_overlays": "Access, tasks, resources, danger, fluids"}
# GDD groups are explicit so dropping a whole future system fails this contract.
const REQUIRED_GROUPS := {
	"colony": ["colony_overview", "alerts", "policies"],
	"workers": ["worker_roster", "worker_skills", "worker_equipment", "worker_schedules", "worker_personality"],
	"assignments": ["worker_roles", "work_priorities"],
	"jobs": ["job_list", "job_priorities", "hauling", "operate_jobs", "maintenance_jobs", "defense_jobs"],
	"stockpiles": ["stockpile_filters", "stockpile_capacity", "stockpile_links", "stockpile_containers"],
	"resources": ["resource_inventory", "physical_items", "raw_materials", "resource_accounting"],
	"build": ["information", "dig", "place", "up_stairs", "down_stairs", "erase", "stockpile", "construction_materials", "walls_floors", "ramps_bridges", "doors_access", "furniture", "workshop_buildings", "supports", "build_traps", "lighting"],
	"zones": ["rooms", "bedrooms", "dining_meeting", "farm_zones", "workshop_storage_zones", "barracks", "medical_rooms", "restricted_zones"],
	"production": ["extraction", "refinement", "crafting", "recipes_orders", "production_logistics"],
	"needs": ["food_drink", "sleep_shelter", "safety", "morale_social", "health"],
	"defense": ["threats", "combat", "squads", "combat_roles", "advanced_abilities", "defense_alerts"],
	"world": ["level_up", "level_down", "rotate_left", "rotate_right", "world_generation", "world_overlays", "fog", "water_flooding", "lava", "cave_ins", "poison_gas", "fire_smoke", "temperature_pressure"],
	"game": ["game_menu", "new_world", "resume", "save", "load", "session_persistence", "settings", "live_diagnostics", "capture_bug", "performance", "profiler", "draw_burden", "debug_timings", "streaming_stats", "streaming_capture", "ramp_counts", "debug_normals", "map_snapshot", "timings_log", "worker_trace", "quit"],
}
const ROUTES := ["open:colony", "open:workers", "open:jobs", "open:stockpiles", "open:resources", "camera:left", "camera:right", "level:up", "level:down", "game:menu", "game:new", "game:save", "game:load", "diagnostics:live", "diagnostics:capture", "diagnostics:performance", "debug:profiler", "debug:burden", "debug:timings", "debug:streaming", "debug:streaming_capture", "debug:ramps", "debug:render_panel", "debug:normals", "debug:map", "debug:timings_log", "debug:workers"]

var failures: Array[String] = []
var checks := 0
var selections: Array[String] = []


func _init() -> void:
	_run.call_deferred()


func _run() -> void:
	_test_catalog()
	_test_theme()
	await _test_navigation()
	if failures.is_empty():
		print("Colony capabilities contract OK (%d checks)" % checks)
		quit(0)
	else:
		for failure: String in failures:
			push_error(failure)
		quit(1)


func _test_catalog() -> void:
	var category_ids: Array[String] = []
	var feature_ids: Dictionary = {}
	var tool_entries: Dictionary = {}
	var routes: Dictionary = {}
	for category: Dictionary in Catalog.categories():
		category_ids.append(category.id)
		_check(category.label is String and not category.label.is_empty(), "Category label: " + category.id)
		if FULL_LABELS.has(category.id):
			_check(category.label == FULL_LABELS[category.id], "Full category label: " + category.id)
		var ids: Array[String] = []
		for feature: Dictionary in Catalog.entries(category.id):
			for field: String in ["id", "label", "status", "description", "action"]:
				_check(feature.get(field) is String, "String field %s in %s" % [field, feature.get("id", "?")])
			_check(not feature.id.is_empty() and not feature.label.is_empty() and not feature.description.is_empty(), "Nonempty feature: " + feature.id)
			if FEATURE_LABELS.has(feature.id):
				_check(feature.label == FEATURE_LABELS[feature.id], "Player-facing feature label: " + feature.id)
			_check(not feature_ids.has(feature.id), "Unique feature: " + feature.id)
			feature_ids[feature.id] = true
			ids.append(feature.id)
			_check(feature.status in ["available", "partial", "planned", "tentative"], "Valid status: " + feature.id)
			if feature.status in ["planned", "tentative"]:
				_check(feature.action.is_empty(), "Unavailable feature is disabled: " + feature.id)
			if feature.status == "available":
				_check(not feature.action.is_empty(), "Available feature has route: " + feature.id)
			_check(Catalog.find_feature(feature.id) == feature, "Lookup matches: " + feature.id)
			var action: String = feature.action
			if action.begins_with("tool:"):
				_check(category.id == "build", "All shared tools belong to Dig & Build")
				_check(not tool_entries.has(action), "One entry per shared tool: " + action)
				tool_entries[action] = feature
			elif not action.is_empty():
				_check(action in ROUTES or action == "open:assignments", "Known Main action: " + action)
				routes[action] = true
		for required: String in REQUIRED_GROUPS.get(category.id, []):
			_check(required in ids, "GDD coverage: %s/%s" % [category.id, required])
	_check(category_ids == EXPECTED_CATEGORIES, "Stable category IDs and navigation order for Work Priorities and Tasks")
	_check(Catalog.entries("missing").is_empty(), "Unknown category returns empty array")
	_check(Catalog.find_feature("missing").is_empty(), "Unknown feature returns empty dictionary")
	_check(Catalog.find_feature("rotate_left").action == "camera:left", "Rotate left dispatches camera action")
	_check(Catalog.find_feature("rotate_right").action == "camera:right", "Rotate right dispatches camera action")
	_check(tool_entries.size() == MainTools.TOOLS.size(), "Shared tool count parity")
	for tool: Dictionary in MainTools.TOOLS:
		var action := "tool:%d" % int(tool.mode)
		_check(tool_entries.has(action), "Shared tool route: " + action)
		_check(tool_entries.get(action, {}).get("label") == tool.label, "Shared tool label: " + str(tool.label))
	for action: String in ROUTES:
		_check(routes.has(action), "Existing entry route: " + action)
	_check(routes.has("open:assignments"), "Stable Work Priorities navigation route")
	for id: String in ["worker_roles", "work_priorities"]:
		_check(Catalog.find_feature(id).action == "open:assignments", "Stable Work Priorities feature route: " + id)
	for id: String in ["job_list", "hauling"]:
		_check(Catalog.find_feature(id).action == "open:jobs", "Stable Tasks feature route: " + id)
	for id: String in ["worker_roles", "job_list", "place", "save", "load"]:
		_check(Catalog.find_feature(id).status == "partial", "Prototype limit disclosed: " + id)
	var changed := Catalog.find_feature("save")
	changed.action = "bad"
	_check(Catalog.find_feature("save").action == "game:save", "Lookups do not expose mutable shared entries")
	var categories := Catalog.categories()
	categories[0].id = "bad"
	_check(Catalog.categories()[0].id == "colony", "Category results are independent")


func _test_theme() -> void:
	var theme := UITheme.build()
	_check(theme.default_font_size == 20, "Default font is 20 logical pixels")
	_check(UITheme.CONTROL_HEIGHT == 36, "Minimum control height contract")
	_check(theme.get_color("font_color", "Button") == UITheme.WARM_TEXT, "Warm control text")
	_check(theme.get_color("default_color", "RichTextLabel") == UITheme.WARM_TEXT, "Warm rich text")
	_check((theme.get_stylebox("panel", "Panel") as StyleBoxFlat).bg_color == UITheme.CHARCOAL, "Charcoal background")
	_check((theme.get_stylebox("panel", "PanelContainer") as StyleBoxFlat).border_color == UITheme.BRONZE, "Bronze panel border")
	_check(theme.get_stylebox("normal", "Button") != theme.get_stylebox("pressed", "Button"), "Selection has its own style")
	_check(theme.has_stylebox("focus", "Button") and theme.has_stylebox("disabled", "Button"), "Focus and disabled styles")
	_check(theme != UITheme.build(), "Theme builds are independent")


func _test_navigation() -> void:
	# Command-bar navigation: primary categories are icon buttons in the bar;
	# every other catalog category stays reachable through the "More" popover.
	root.size = Vector2i(1920, 1080)
	var overlay := Control.new()
	overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(overlay)
	overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var bar := HBoxContainer.new()
	overlay.add_child(bar)
	bar.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	bar.offset_top = -96
	var nav := Navigation.new()
	nav.category_selected.connect(func(id: String) -> void: selections.append(id))
	nav.setup(bar, overlay)
	await _settle()
	_check(nav.buttons.size() == EXPECTED_CATEGORIES.size(), "Navigation includes every category")
	_check(selections.is_empty(), "Setup does not emit a selection")
	_check(not nav.more_panel.visible, "More popover starts closed")
	_check(nav.more_panel.mouse_filter == Control.MOUSE_FILTER_STOP, "More popover blocks world input under an ignored parent")
	for id: String in nav.buttons:
		var control: Control = nav.buttons[id]
		_check(control.custom_minimum_size.y >= 36.0, "Accessible control height: " + id)
		_check(control.mouse_filter == Control.MOUSE_FILTER_STOP, "Control owns mouse input: " + id)
		_check(control.focus_mode == Control.FOCUS_ALL, "Keyboard-focusable category: " + id)
		_check(nav.is_primary(id) == (control.get_parent().get_parent() == bar or control.get_parent() == nav.bar), "Primary categories live in the bar: " + id)
		if FULL_LABELS.has(id):
			_check(control.tooltip_text == FULL_LABELS[id], "Navigation retains full label: " + id)
	nav.set_selected("workers")
	await _settle()
	_check(nav.selected_id == "workers" and nav.buttons.workers.button_pressed, "Programmatic selection")
	_check(selections.is_empty(), "Programmatic selection does not dispatch")
	nav.set_selected("missing")
	_check(nav.selected_id == "workers", "Invalid selection preserves current category")
	var button: Button = nav.buttons.workers
	await _click(button.get_global_rect().get_center())
	_check(root.gui_get_hovered_control() == button, "Hover resolves to navigation under ignored parent")
	_check(selections == ["workers"], "GUI click emits exactly one category ID")
	button.grab_focus()
	for pressed: bool in [true, false]:
		var key := InputEventKey.new()
		key.keycode = KEY_ENTER
		key.pressed = pressed
		root.push_input(key, true)
	_check(selections == ["workers", "workers"], "Keyboard activation emits one category ID")
	var pressed_count := 0
	for id: String in nav.buttons:
		if nav.buttons[id] is Button and nav.buttons[id].toggle_mode:
			pressed_count += int(nav.buttons[id].button_pressed)
	_check(pressed_count == 1, "Exactly one selected category")
	await _click(nav.more_button.get_global_rect().get_center())
	_check(nav.more_panel.visible and selections.size() == 2, "More opens the secondary list without dispatching")
	await _click(nav.buttons.game.get_global_rect().get_center())
	_check(selections.back() == "game" and not nav.more_panel.visible, "Secondary category dispatches once and closes More")
	nav.set_selected("")
	_check(nav.selected_id.is_empty(), "Closing management clears selected ID")
	for id: String in nav.buttons:
		if nav.buttons[id] is Button and nav.buttons[id].toggle_mode:
			_check(not nav.buttons[id].button_pressed, "Closing management clears pressed buttons: " + id)
	nav.set_selected("workers")
	nav.setup(bar, overlay)
	await _settle()
	_check(bar.get_child_count() == 1 and nav.buttons.size() == EXPECTED_CATEGORIES.size(), "Repeated setup replaces navigation")
	_check(nav.buttons.workers.button_pressed, "Repeated setup preserves selection")
	overlay.queue_free()


func _click(position: Vector2) -> void:
	var motion := InputEventMouseMotion.new()
	motion.position = position
	root.push_input(motion, true)
	await _settle()
	for pressed: bool in [true, false]:
		var click := InputEventMouseButton.new()
		click.button_index = MOUSE_BUTTON_LEFT
		click.position = position
		click.pressed = pressed
		root.push_input(click, true)
	await _settle()


func _settle() -> void:
	await process_frame
	await process_frame
	await process_frame


func _check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)
