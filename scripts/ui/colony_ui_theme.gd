extends RefCounted
class_name ColonyUITheme
## Logical pixel sizes. Main applies this theme to its code-created shell.

const FONT_SIZE := 20
const CONTROL_HEIGHT := 36
const CHARCOAL := Color("242321")
const PANEL := Color("302e2a")
const BRONZE := Color("a78050")
const WARM_TEXT := Color("eee3ce")
const MUTED_TEXT := Color("b8ae9c")


static func build() -> Theme:
	var theme := Theme.new()
	theme.default_font_size = FONT_SIZE
	for type_name: String in ["Label", "Button", "CheckBox", "CheckButton", "OptionButton", "LineEdit", "TextEdit", "ItemList", "PopupMenu", "Tree"]:
		theme.set_color("font_color", type_name, WARM_TEXT)
		theme.set_color("font_disabled_color", type_name, MUTED_TEXT)
		theme.set_color("font_hover_color", type_name, WARM_TEXT)
		theme.set_color("font_pressed_color", type_name, WARM_TEXT)
		theme.set_color("font_hover_pressed_color", type_name, WARM_TEXT)
		theme.set_color("font_focus_color", type_name, WARM_TEXT)
	theme.set_color("default_color", "RichTextLabel", WARM_TEXT)
	theme.set_stylebox("panel", "Panel", _box(CHARCOAL, BRONZE))
	theme.set_stylebox("panel", "PanelContainer", _box(PANEL, BRONZE))
	theme.set_stylebox("panel", "PopupMenu", _box(CHARCOAL, BRONZE))
	theme.set_stylebox("panel", "TooltipPanel", _box(CHARCOAL, BRONZE))
	theme.set_color("font_color", "TooltipLabel", WARM_TEXT)
	for type_name: String in ["Button", "OptionButton", "CheckBox", "CheckButton"]:
		theme.set_stylebox("normal", type_name, _box(PANEL, Color("5c5142")))
		theme.set_stylebox("hover", type_name, _box(Color("41392e"), BRONZE))
		theme.set_stylebox("pressed", type_name, _box(Color("59432d"), BRONZE))
		theme.set_stylebox("hover_pressed", type_name, _box(Color("654d33"), BRONZE))
		theme.set_stylebox("disabled", type_name, _box(CHARCOAL, Color("49443b")))
		theme.set_stylebox("focus", type_name, _box(Color.TRANSPARENT, WARM_TEXT, 2))
	for type_name: String in ["LineEdit", "TextEdit"]:
		theme.set_stylebox("normal", type_name, _box(CHARCOAL, BRONZE))
		theme.set_stylebox("focus", type_name, _box(Color.TRANSPARENT, WARM_TEXT, 2))
		theme.set_color("caret_color", type_name, WARM_TEXT)
		theme.set_color("selection_color", type_name, Color("654d33"))
	theme.set_constant("separation", "VBoxContainer", 8)
	theme.set_constant("separation", "HBoxContainer", 8)
	theme.set_stylebox("scroll", "VScrollBar", _box(CHARCOAL, CHARCOAL))
	theme.set_stylebox("grabber", "VScrollBar", _box(Color("68553d"), BRONZE))
	theme.set_stylebox("grabber_highlight", "VScrollBar", _box(BRONZE, BRONZE))
	theme.set_stylebox("grabber_pressed", "VScrollBar", _box(BRONZE, WARM_TEXT))
	return theme


static func _box(background: Color, border: Color, width: int = 1) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = background
	style.border_color = border
	style.set_border_width_all(width)
	style.set_corner_radius_all(4)
	style.content_margin_left = 8.0
	style.content_margin_right = 8.0
	style.content_margin_top = 6.0
	style.content_margin_bottom = 6.0
	return style
