extends RefCounted
class_name ColonyNavigation
## Owns navigation only; Main owns pages, shell visibility, and action dispatch.
## Primary categories are icon buttons in the command bar; the remaining catalog
## categories (roadmap areas, game and diagnostics) stay reachable through a
## "More" popover so unavailable features remain discoverable (ADR-016).

signal category_selected(id: String)

const Catalog = preload("res://scripts/ui/colony_capability_catalog.gd")
const H = preload("res://scripts/ui/colony_panel_helpers.gd")
const PRIMARY := ["colony", "workers", "assignments", "jobs", "stockpiles", "resources"]
const ICONS := {
	"colony": "colony", "workers": "workers", "assignments": "jobs", "jobs": "tasks",
	"stockpiles": "stockpiles", "resources": "resources", "build": "build", "zones": "stockpile",
	"production": "build", "needs": "worker", "defense": "reserve", "world": "world", "game": "game",
}
const SHORT_LABELS := {"assignments": "Jobs", "jobs": "Tasks"}

var bar: HBoxContainer
var more_button: Button
var more_panel: PanelContainer
var buttons: Dictionary = {}
var selected_id := ""


func setup(bar_parent: Control, overlay_parent: Control) -> void:
	if not is_instance_valid(bar_parent) or not is_instance_valid(overlay_parent):
		return
	for old in [bar, more_panel]:
		if is_instance_valid(old):
			old.get_parent().remove_child(old)
			old.queue_free()
	buttons.clear()
	bar = HBoxContainer.new()
	bar.name = "ColonyNavigation"
	bar.add_theme_constant_override("separation", 6)
	bar_parent.add_child(bar)
	for category: Dictionary in Catalog.categories():
		if PRIMARY.has(category.id):
			_add_bar_button(category)
	more_button = H.icon_button(bar, "more", "More", toggle_more, "PanelButton", 26, Vector2(64, 72))
	more_button.name = "More"
	more_button.toggle_mode = true
	more_button.focus_mode = Control.FOCUS_ALL
	more_panel = PanelContainer.new()
	more_panel.name = "MoreCategories"
	more_panel.theme_type_variation = "Card"
	more_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	overlay_parent.add_child(more_panel)
	more_panel.anchor_left = 1.0
	more_panel.anchor_right = 1.0
	more_panel.anchor_top = 1.0
	more_panel.anchor_bottom = 1.0
	more_panel.offset_left = -560.0
	more_panel.offset_right = -232.0
	more_panel.offset_bottom = -108.0
	more_panel.offset_top = -108.0 - 380.0
	var list := VBoxContainer.new()
	list.add_theme_constant_override("separation", 4)
	more_panel.add_child(list)
	H.styled_label(list, "More", "Subheading")
	for category: Dictionary in Catalog.categories():
		if not PRIMARY.has(category.id):
			var row := H.icon_row(list, ICONS.get(category.id, "more"), str(category.label), _on_category_pressed.bind(str(category.id)))
			row.name = str(category.id).to_pascal_case()
			row.focus_mode = Control.FOCUS_ALL
			buttons[category.id] = row
	more_panel.hide()
	set_selected(selected_id)


func _add_bar_button(category: Dictionary) -> void:
	var id: String = category.id
	var caption: String = SHORT_LABELS.get(id, category.label)
	var button := H.icon_button(bar, ICONS.get(id, "more"), caption, _on_category_pressed.bind(id), "PanelButton", 26, Vector2(76, 72))
	button.name = id.to_pascal_case()
	button.tooltip_text = category.label
	button.toggle_mode = true
	# Category buttons stay keyboard-reachable; tools and chips do not take focus.
	button.focus_mode = Control.FOCUS_ALL
	buttons[id] = button


func is_primary(id: String) -> bool:
	return PRIMARY.has(id)


func open_more() -> void:
	if is_instance_valid(more_panel):
		more_panel.show()
		more_button.set_pressed_no_signal(true)


func close_more() -> void:
	if is_instance_valid(more_panel):
		more_panel.hide()
		more_button.set_pressed_no_signal(false)


func toggle_more() -> void:
	if is_instance_valid(more_panel) and more_panel.visible:
		close_more()
	else:
		open_more()


func set_selected(id: String) -> void:
	# Main clears selection when the management panel closes.
	if not id.is_empty() and Catalog.categories().all(func(category: Dictionary) -> bool: return category.id != id):
		return
	selected_id = id
	for key: String in buttons:
		var control = buttons[key]
		if is_instance_valid(control) and control is Button and control.toggle_mode:
			control.set_pressed_no_signal(key == id)


func _on_category_pressed(id: String) -> void:
	close_more()
	set_selected(id)
	category_selected.emit(id)
