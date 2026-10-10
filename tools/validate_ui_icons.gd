extends SceneTree

const UiIcon = preload("res://scripts/ui/ui_icon.gd")

const REQUIRED_NAMES := [
	"inspect", "dig", "build", "stairs", "stairs_up", "stairs_down", "erase", "stockpile",
	"busy", "moving", "idle", "reserve", "pending", "blocked", "stored",
	"colony", "workers", "jobs", "tasks", "stockpiles", "resources", "more", "menu", "world", "game",
	"up", "down", "warning", "close", "locate", "block", "worker", "item", "rotate"
]

var checks := 0
var failures := 0


func _initialize() -> void:
	_run_checks.call_deferred()


func _run_checks() -> void:
	var root_node := Node2D.new()
	root.add_child(root_node)
	for required_name in REQUIRED_NAMES:
		_check(required_name in UiIcon.NAMES, "%s listed" % required_name)
		_check(UiIcon.has_icon(required_name), "%s recognized" % required_name)
	for pixel_size in [16, 24, 48]:
		for icon_name in UiIcon.NAMES:
			var icon = UiIcon.make(icon_name, pixel_size, Color("d8b779"))
			root_node.add_child(icon)
			_check(icon.icon_name == icon_name, "%s name configured" % icon_name)
			_check(icon.custom_minimum_size == Vector2(pixel_size, pixel_size), "%s minimum configured" % icon_name)
			_check(icon.icon_color == Color("d8b779"), "%s color configured" % icon_name)
			icon.size = Vector2(pixel_size, pixel_size)
			icon.icon_name = "not_a_real_icon"
			icon.icon_color = Color("c49a57")
			icon.accent_color = Color("8d693e")
			icon.line_width = 2.5
			icon.icon_name = icon_name
		_check(not UiIcon.has_icon("not_a_real_icon"), "unknown name rejected")
		var unknown = UiIcon.make("not_a_real_icon", pixel_size)
		root_node.add_child(unknown)
		unknown.size = Vector2(pixel_size, pixel_size)
	await process_frame
	await process_frame
	_check(true, "draw callbacks completed")
	print("UI icons: %d checks, %d failures" % [checks, failures])
	quit(1 if failures > 0 else 0)


func _check(condition: bool, description: String) -> void:
	checks += 1
	if not condition:
		failures += 1
		push_error("UI icon check failed: %s" % description)
