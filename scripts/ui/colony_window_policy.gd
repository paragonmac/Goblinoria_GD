extends RefCounted
## Logical UI coordinates scale independently of native-resolution 3D.
const BASE := Vector2i(1920, 1080)
var window: Window
var last_screen := -99
var timer := 0.0

static func fit_size(work_area: Vector2i, decorations: Vector2i) -> Vector2i:
	return Vector2i(mini(BASE.x, maxi(1, work_area.x - maxi(0, decorations.x))),
		mini(BASE.y, maxi(1, work_area.y - maxi(0, decorations.y))))

func setup(target: Window) -> void:
	window = target
	window.content_scale_size = BASE
	window.content_scale_mode = Window.CONTENT_SCALE_MODE_CANVAS_ITEMS
	window.content_scale_aspect = Window.CONTENT_SCALE_ASPECT_EXPAND
	if DisplayServer.get_name() != "headless":
		apply(true)

func tick(dt: float) -> void:
	timer += dt
	if timer < 0.5 or window == null or DisplayServer.get_name() == "headless":
		return
	timer = 0.0
	apply(false)

func apply(initial: bool) -> void:
	var screen := window.current_screen
	var area := DisplayServer.screen_get_usable_rect(screen)
	# Include native decorations and a small desktop safety margin.
	var decorations := DisplayServer.window_get_size_with_decorations() - DisplayServer.window_get_size()
	var minimum := fit_size(area.size, decorations + Vector2i(16, 16))
	var changed := screen != last_screen or window.min_size != minimum
	window.min_size = minimum
	if initial or changed:
		window.size = minimum if initial else Vector2i(clampi(window.size.x, minimum.x, maxi(minimum.x, area.size.x - decorations.x - 16)), clampi(window.size.y, minimum.y, maxi(minimum.y, area.size.y - decorations.y - 16)))
		window.position = Vector2i(clampi(window.position.x, area.position.x, area.end.x - window.size.x - decorations.x), clampi(window.position.y, area.position.y, area.end.y - window.size.y - decorations.y))
	last_screen = screen
