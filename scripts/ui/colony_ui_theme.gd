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
const BAR_BG := Color(0.105, 0.096, 0.086, 0.94)
const CARD_BG := Color(0.14, 0.126, 0.112, 0.95)
const ROW_BG := Color(0.2, 0.178, 0.152, 0.85)
const TAG_BG := Color("3a3228")
const BUTTON_BG := Color(0.17, 0.152, 0.13, 0.95)
const BUTTON_EDGE := Color("4a3f31")
const BRASS := Color("c9a063")
const BRASS_LIGHT := Color("e7c48a")
const BRASS_DIM := Color("7a6040")
const WARNING := Color("e0a24a")
const GOOD := Color("8fbf6a")
const BAD := Color("d0674e")


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
	_add_command_variations(theme)
	return theme


## Icon-first command bar, cards and labels (approved concept style: dark
## translucent charcoal-brown with warm brass accents).
static func _add_command_variations(theme: Theme) -> void:
	theme.set_type_variation("CommandBar", "PanelContainer")
	var bar := _box(BAR_BG, BRASS, 0, 0)
	bar.border_width_top = 2
	bar.set_content_margin_all(8.0)
	theme.set_stylebox("panel", "CommandBar", bar)
	theme.set_type_variation("Card", "PanelContainer")
	var card := _box(CARD_BG, BRASS_DIM, 1, 8)
	card.set_content_margin_all(12.0)
	card.shadow_color = Color(0, 0, 0, 0.35)
	card.shadow_size = 6
	theme.set_stylebox("panel", "Card", card)
	theme.set_type_variation("Row", "PanelContainer")
	var row := _box(ROW_BG, Color(0, 0, 0, 0), 0, 6)
	row.set_content_margin_all(6.0)
	theme.set_stylebox("panel", "Row", row)
	theme.set_type_variation("Tag", "PanelContainer")
	var tag := _box(TAG_BG, BRASS_DIM, 1, 10)
	tag.content_margin_left = 10.0
	tag.content_margin_right = 10.0
	tag.content_margin_top = 2.0
	tag.content_margin_bottom = 2.0
	theme.set_stylebox("panel", "Tag", tag)
	theme.set_type_variation("Toast", "PanelContainer")
	theme.set_stylebox("panel", "Toast", _box(Color(0.16, 0.1, 0.07, 0.94), WARNING, 1, 8))
	for variation: String in ["ToolButton", "PanelButton", "ChipButton", "IconButton"]:
		theme.set_type_variation(variation, "Button")
		theme.set_stylebox("normal", variation, _box(BUTTON_BG, BUTTON_EDGE, 1, 6))
		theme.set_stylebox("hover", variation, _box(Color("3a3129"), BRASS, 1, 6))
		theme.set_stylebox("pressed", variation, _box(Color("5a4329"), BRASS, 2, 6))
		theme.set_stylebox("hover_pressed", variation, _box(Color("644a2e"), BRASS_LIGHT, 2, 6))
		theme.set_stylebox("disabled", variation, _box(Color(0.13, 0.12, 0.11, 0.8), Color("3b352d"), 1, 6))
		theme.set_stylebox("focus", variation, _box(Color.TRANSPARENT, BRASS_LIGHT, 1, 6))
	for entry: Array in [["Caption", 14, MUTED_TEXT], ["Number", 21, WARM_TEXT], ["Heading", 24, WARM_TEXT],
			["Subheading", 16, BRASS], ["KeyBadge", 12, MUTED_TEXT], ["Body", 17, WARM_TEXT]]:
		theme.set_type_variation(entry[0], "Label")
		theme.set_font_size("font_size", entry[0], entry[1])
		theme.set_color("font_color", entry[0], entry[2])


static func _box(background: Color, border: Color, width: int = 1, radius: int = 4) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = background
	style.border_color = border
	style.set_border_width_all(width)
	style.set_corner_radius_all(radius)
	style.anti_aliasing = true
	style.content_margin_left = 8.0
	style.content_margin_right = 8.0
	style.content_margin_top = 6.0
	style.content_margin_bottom = 6.0
	return style
