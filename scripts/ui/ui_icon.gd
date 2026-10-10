extends Control
class_name UiIcon

const NAMES := [
	"inspect", "dig", "build", "stairs", "stairs_up", "stairs_down", "erase", "stockpile",
	"busy", "moving", "idle", "reserve", "pending", "blocked", "stored",
	"colony", "workers", "jobs", "tasks", "stockpiles", "resources", "more", "menu", "world", "game",
	"up", "down", "warning", "close", "locate", "block", "worker", "item", "rotate",
	"left", "right", "plus", "minus", "speed", "search", "check"
]

@export var icon_name: String = "":
	set(value):
		icon_name = value
		queue_redraw()

@export var icon_color: Color = Color("e7c48a"):
	set(value):
		icon_color = value
		queue_redraw()

var accent_color: Color = Color("b88b4e"):
	set(value):
		accent_color = value
		queue_redraw()

var line_width: float = 2.0:
	set(value):
		line_width = maxf(value, 0.1)
		queue_redraw()


func _init() -> void:
	custom_minimum_size = Vector2(24, 24)
	mouse_filter = Control.MOUSE_FILTER_IGNORE


static func make(name: String, pixel_size: int = 24, color: Color = Color("e7c48a")) -> Control:
	var icon := load("res://scripts/ui/ui_icon.gd").new() as Control
	icon.icon_name = name
	icon.icon_color = color
	icon.custom_minimum_size = Vector2(pixel_size, pixel_size)
	icon.size = Vector2(pixel_size, pixel_size)
	return icon


static func has_icon(name: String) -> bool:
	return name in NAMES


func _draw() -> void:
	var side := minf(size.x, size.y)
	if side <= 0.0:
		return
	var scale_factor := side / 24.0
	var offset := (size - Vector2.ONE * side) * 0.5
	draw_set_transform(offset, 0.0, Vector2.ONE * scale_factor)
	match icon_name:
		"inspect": _draw_inspect()
		"dig", "busy": _draw_pickaxe()
		"build": _draw_build()
		"stairs": _draw_stairs()
		"stairs_up": _draw_stairs_up()
		"stairs_down": _draw_stairs_down()
		"erase": _draw_erase()
		"stockpile", "stored": _draw_crate()
		"moving": _draw_moving()
		"idle": _draw_idle()
		"reserve": _draw_reserve()
		"pending": _draw_pending()
		"blocked": _draw_blocked()
		"colony": _draw_colony()
		"workers": _draw_workers()
		"jobs": _draw_jobs()
		"tasks": _draw_tasks()
		"stockpiles": _draw_stockpiles()
		"resources", "item": _draw_resources()
		"more": _draw_more()
		"menu": _draw_menu()
		"world": _draw_world()
		"game": _draw_game()
		"up": _draw_up()
		"down": _draw_down()
		"warning": _draw_warning()
		"close": _draw_close()
		"locate": _draw_locate()
		"block": _draw_block()
		"worker": _draw_worker()
		"rotate": _draw_rotate()
		"left": _draw_left()
		"right": _draw_right()
		"plus": _draw_plus()
		"minus": _draw_minus()
		"speed": _draw_speed()
		"search": _draw_inspect()
		"check": _draw_check()
		_: _draw_placeholder()
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


func _stroke() -> float:
	return line_width * 24.0 / maxf(minf(size.x, size.y), 1.0)


func _line(a: Vector2, b: Vector2, color: Color = icon_color, width: float = -1.0) -> void:
	draw_line(a, b, color, _stroke() if width < 0.0 else width, true)


func _path(points: PackedVector2Array, color: Color = icon_color, width: float = -1.0, close_path: bool = false) -> void:
	if close_path and points.size() > 2:
		points.append(points[0])
	draw_polyline(points, color, _stroke() if width < 0.0 else width, true)


func _draw_inspect() -> void:
	draw_arc(Vector2(10, 10), 6.5, 0.0, TAU, 32, icon_color, _stroke(), true)
	_line(Vector2(15, 15), Vector2(21, 21))


func _draw_pickaxe() -> void:
	_line(Vector2(7, 21), Vector2(18, 6), icon_color, _stroke() * 1.25)
	_path(PackedVector2Array([Vector2(4, 8), Vector2(9, 4), Vector2(19, 5), Vector2(21, 8)]), icon_color, _stroke() * 1.25)


func _draw_build() -> void:
	draw_rect(Rect2(3, 13, 8, 7), accent_color, true)
	draw_rect(Rect2(13, 13, 8, 7), icon_color, true)
	draw_rect(Rect2(8, 4, 8, 7), icon_color, true)
	_line(Vector2(3, 13), Vector2(21, 13), Color("332a20"), 0.7)


func _draw_stairs() -> void:
	_path(PackedVector2Array([Vector2(3, 20), Vector2(3, 16), Vector2(8, 16), Vector2(8, 12), Vector2(13, 12), Vector2(13, 8), Vector2(18, 8), Vector2(18, 4), Vector2(21, 4)]), icon_color, _stroke() * 1.25)
	_line(Vector2(3, 20), Vector2(21, 20))


func _draw_stairs_up() -> void:
	_draw_stairs()
	_line(Vector2(18, 11), Vector2(18, 3), accent_color)
	_path(PackedVector2Array([Vector2(15, 6), Vector2(18, 3), Vector2(21, 6)]), accent_color)


func _draw_stairs_down() -> void:
	_draw_stairs()
	_line(Vector2(18, 3), Vector2(18, 11), accent_color)
	_path(PackedVector2Array([Vector2(15, 8), Vector2(18, 11), Vector2(21, 8)]), accent_color)


func _draw_erase() -> void:
	var points := PackedVector2Array([Vector2(4, 15), Vector2(13, 5), Vector2(21, 12), Vector2(14, 20), Vector2(8, 20)])
	_path(points, icon_color, _stroke(), true)
	_line(Vector2(8, 16), Vector2(16, 16), accent_color)


func _draw_crate() -> void:
	_path(PackedVector2Array([Vector2(3, 7), Vector2(12, 3), Vector2(21, 7), Vector2(21, 18), Vector2(12, 22), Vector2(3, 18)]), icon_color, _stroke(), true)
	_line(Vector2(3, 7), Vector2(12, 12), accent_color)
	_line(Vector2(21, 7), Vector2(12, 12), accent_color)
	_line(Vector2(12, 12), Vector2(12, 22), accent_color)


func _draw_moving() -> void:
	draw_circle(Vector2(15, 5), 2.5, icon_color)
	_line(Vector2(14, 9), Vector2(10, 14), icon_color, _stroke() * 1.25)
	_line(Vector2(11, 12), Vector2(5, 11), icon_color)
	_line(Vector2(11, 12), Vector2(17, 14), icon_color)
	_line(Vector2(10, 14), Vector2(5, 20), icon_color, _stroke() * 1.25)
	_line(Vector2(10, 14), Vector2(17, 20), icon_color, _stroke() * 1.25)


func _draw_idle() -> void:
	_line(Vector2(3, 18), Vector2(9, 18))
	_path(PackedVector2Array([Vector2(3, 12), Vector2(8, 12), Vector2(3, 7), Vector2(9, 7)]), icon_color)
	_line(Vector2(13, 7), Vector2(18, 7))
	_line(Vector2(13, 7), Vector2(18, 2))
	_line(Vector2(13, 2), Vector2(18, 2))
	_line(Vector2(19, 4), Vector2(22, 4))
	_line(Vector2(19, 4), Vector2(22, 1))
	_line(Vector2(19, 1), Vector2(22, 1))


func _draw_reserve() -> void:
	_path(PackedVector2Array([Vector2(12, 2), Vector2(20, 5), Vector2(19, 14), Vector2(12, 22), Vector2(5, 14), Vector2(4, 5)]), icon_color, _stroke(), true)
	_line(Vector2(8, 12), Vector2(11, 15), accent_color)
	_line(Vector2(11, 15), Vector2(16, 9), accent_color)


func _draw_pending() -> void:
	_path(PackedVector2Array([Vector2(7, 3), Vector2(17, 3), Vector2(20, 6), Vector2(20, 21), Vector2(5, 21), Vector2(5, 3)]), icon_color, _stroke(), true)
	_line(Vector2(15, 3), Vector2(15, 7), accent_color)
	_line(Vector2(15, 7), Vector2(20, 7), accent_color)
	_line(Vector2(8, 11), Vector2(17, 11))
	_line(Vector2(8, 15), Vector2(17, 15))


func _draw_blocked() -> void:
	draw_arc(Vector2(12, 12), 9, 0.0, TAU, 32, icon_color, _stroke(), true)
	_line(Vector2(6, 18), Vector2(18, 6), icon_color, _stroke() * 1.3)


func _draw_colony() -> void:
	_path(PackedVector2Array([Vector2(3, 11), Vector2(12, 3), Vector2(21, 11)]), icon_color, _stroke() * 1.5)
	draw_rect(Rect2(5, 10, 14, 11), icon_color, true)
	draw_rect(Rect2(10, 14, 4, 7), accent_color, true)


func _draw_workers() -> void:
	draw_circle(Vector2(8, 8), 3, icon_color)
	draw_circle(Vector2(17, 8), 3, accent_color)
	_path(PackedVector2Array([Vector2(3, 7), Vector2(5, 4), Vector2(11, 4), Vector2(13, 7)]), icon_color, _stroke())
	_path(PackedVector2Array([Vector2(12, 7), Vector2(14, 4), Vector2(20, 4), Vector2(22, 7)]), accent_color, _stroke())
	draw_arc(Vector2(8, 20), 6, PI, TAU, 16, icon_color, _stroke(), true)
	draw_arc(Vector2(17, 20), 6, PI, TAU, 16, accent_color, _stroke(), true)


func _draw_jobs() -> void:
	_draw_pending()
	_line(Vector2(8, 11), Vector2(10, 11), accent_color, 1.0)
	_line(Vector2(8, 15), Vector2(13, 15), accent_color, 1.0)
	_line(Vector2(8, 18), Vector2(16, 18), accent_color, 1.0)


func _draw_tasks() -> void:
	_path(PackedVector2Array([Vector2(8, 3), Vector2(16, 3), Vector2(18, 5), Vector2(18, 21), Vector2(5, 21), Vector2(5, 5), Vector2(8, 5)]), icon_color, _stroke(), true)
	for y in [9.0, 14.0, 19.0]:
		_line(Vector2(7, y), Vector2(9, y + 2), accent_color, 1.2)
		_line(Vector2(9, y + 2), Vector2(12, y - 1), accent_color, 1.2)
		_line(Vector2(14, y), Vector2(17, y))


func _draw_stockpiles() -> void:
	_path(PackedVector2Array([Vector2(2, 8), Vector2(8, 4), Vector2(14, 8), Vector2(14, 16), Vector2(8, 19), Vector2(2, 16)]), accent_color, _stroke(), true)
	_line(Vector2(2, 8), Vector2(8, 11), accent_color)
	_line(Vector2(14, 8), Vector2(8, 11), accent_color)
	_path(PackedVector2Array([Vector2(10, 12), Vector2(16, 9), Vector2(22, 12), Vector2(22, 20), Vector2(16, 23), Vector2(10, 20)]), icon_color, _stroke(), true)
	_line(Vector2(10, 12), Vector2(16, 15), icon_color)
	_line(Vector2(22, 12), Vector2(16, 15), icon_color)


func _draw_resources() -> void:
	_path(PackedVector2Array([Vector2(3, 16), Vector2(7, 10), Vector2(11, 13), Vector2(15, 6), Vector2(21, 11), Vector2(20, 19), Vector2(5, 20)]), icon_color, _stroke(), true)
	_line(Vector2(7, 10), Vector2(9, 17), accent_color)
	_line(Vector2(15, 6), Vector2(15, 17), accent_color)
	_line(Vector2(15, 17), Vector2(20, 11), accent_color)


func _draw_more() -> void:
	for x in [5.0, 12.0, 19.0]:
		draw_circle(Vector2(x, 12), 2.0, icon_color)


func _draw_menu() -> void:
	for y in [6.0, 12.0, 18.0]:
		_line(Vector2(4, y), Vector2(20, y), icon_color, _stroke() * 1.4)


func _draw_world() -> void:
	draw_arc(Vector2(12, 12), 9, 0.0, TAU, 32, icon_color, _stroke(), true)
	draw_arc(Vector2(12, 12), 4.5, -PI / 2.0, PI / 2.0, 20, accent_color, _stroke(), true)
	draw_arc(Vector2(12, 12), 4.5, PI / 2.0, 3.0 * PI / 2.0, 20, accent_color, _stroke(), true)
	_line(Vector2(4, 9), Vector2(20, 9), accent_color)
	_line(Vector2(4, 15), Vector2(20, 15), accent_color)


func _draw_game() -> void:
	draw_arc(Vector2(12, 12), 6, 0.0, TAU, 24, icon_color, _stroke() * 1.4, true)
	for i in range(8):
		var angle := TAU * float(i) / 8.0
		var start := Vector2(12, 12) + Vector2(cos(angle), sin(angle)) * 7.0
		var finish := Vector2(12, 12) + Vector2(cos(angle), sin(angle)) * 9.0
		_line(start, finish, icon_color, _stroke() * 1.3)
	draw_circle(Vector2(12, 12), 2, accent_color)


func _draw_up() -> void:
	draw_polygon(PackedVector2Array([Vector2(12, 3), Vector2(21, 19), Vector2(3, 19)]), PackedColorArray([icon_color, icon_color, icon_color]))


func _draw_left() -> void:
	draw_polygon(PackedVector2Array([Vector2(5, 12), Vector2(19, 3), Vector2(19, 21)]), PackedColorArray([icon_color, icon_color, icon_color]))


func _draw_right() -> void:
	draw_polygon(PackedVector2Array([Vector2(19, 12), Vector2(5, 3), Vector2(5, 21)]), PackedColorArray([icon_color, icon_color, icon_color]))


func _draw_plus() -> void:
	_line(Vector2(12, 4), Vector2(12, 20), icon_color, _stroke() * 1.4)
	_line(Vector2(4, 12), Vector2(20, 12), icon_color, _stroke() * 1.4)


func _draw_minus() -> void:
	_line(Vector2(4, 12), Vector2(20, 12), icon_color, _stroke() * 1.4)


func _draw_speed() -> void:
	draw_polygon(PackedVector2Array([Vector2(3, 5), Vector2(12, 12), Vector2(3, 19)]), PackedColorArray([icon_color, icon_color, icon_color]))
	draw_polygon(PackedVector2Array([Vector2(12, 5), Vector2(21, 12), Vector2(12, 19)]), PackedColorArray([accent_color, accent_color, accent_color]))


func _draw_check() -> void:
	_path(PackedVector2Array([Vector2(4, 13), Vector2(10, 19), Vector2(20, 6)]), icon_color, _stroke() * 1.4)


func _draw_down() -> void:
	draw_polygon(PackedVector2Array([Vector2(3, 5), Vector2(21, 5), Vector2(12, 21)]), PackedColorArray([icon_color, icon_color, icon_color]))


func _draw_warning() -> void:
	_path(PackedVector2Array([Vector2(12, 3), Vector2(22, 20), Vector2(2, 20)]), icon_color, _stroke() * 1.2, true)
	_line(Vector2(12, 9), Vector2(12, 14), icon_color, _stroke() * 1.3)
	draw_circle(Vector2(12, 17), 1.0, icon_color)


func _draw_close() -> void:
	_line(Vector2(5, 5), Vector2(19, 19), icon_color, _stroke() * 1.3)
	_line(Vector2(19, 5), Vector2(5, 19), icon_color, _stroke() * 1.3)


func _draw_locate() -> void:
	draw_arc(Vector2(12, 12), 6, 0.0, TAU, 24, icon_color, _stroke(), true)
	_line(Vector2(12, 2), Vector2(12, 8))
	_line(Vector2(12, 16), Vector2(12, 22))
	_line(Vector2(2, 12), Vector2(8, 12))
	_line(Vector2(16, 12), Vector2(22, 12))


func _draw_block() -> void:
	_path(PackedVector2Array([Vector2(12, 3), Vector2(21, 8), Vector2(12, 13), Vector2(3, 8)]), icon_color, _stroke(), true)
	draw_polygon(PackedVector2Array([Vector2(3, 8), Vector2(12, 13), Vector2(12, 22), Vector2(3, 17)]), PackedColorArray([accent_color, accent_color, accent_color, accent_color]))
	draw_polygon(PackedVector2Array([Vector2(12, 13), Vector2(21, 8), Vector2(21, 17), Vector2(12, 22)]), PackedColorArray([icon_color, icon_color, icon_color, icon_color]))
	_line(Vector2(12, 13), Vector2(12, 22), Color("332a20"), 0.8)


func _draw_worker() -> void:
	_path(PackedVector2Array([Vector2(3, 8), Vector2(6, 4), Vector2(18, 4), Vector2(21, 8)]), icon_color, _stroke() * 1.25, true)
	draw_rect(Rect2(5, 8, 14, 9), accent_color, true)
	draw_polygon(PackedVector2Array([Vector2(5, 15), Vector2(8, 19), Vector2(16, 19), Vector2(19, 15)]), PackedColorArray([accent_color, accent_color, accent_color, accent_color]))
	draw_circle(Vector2(9, 12), 1.2, Color("332a20"))
	draw_circle(Vector2(15, 12), 1.2, Color("332a20"))
	_line(Vector2(10, 16), Vector2(14, 16), Color("332a20"), 0.8)
	draw_circle(Vector2(12, 6), 2, Color("fff0c9"))


func _draw_rotate() -> void:
	draw_arc(Vector2(12, 12), 7.5, -PI * 0.8, PI * 0.65, 24, icon_color, _stroke() * 1.2, true)
	_path(PackedVector2Array([Vector2(18, 3), Vector2(21, 8), Vector2(15, 8)]), icon_color, _stroke() * 1.2)


func _draw_placeholder() -> void:
	var color := Color("9a927f")
	var radius := 4.0
	var width := _stroke()
	_line(Vector2(7, 3), Vector2(17, 3), color, width)
	_line(Vector2(21, 7), Vector2(21, 17), color, width)
	_line(Vector2(17, 21), Vector2(7, 21), color, width)
	_line(Vector2(3, 17), Vector2(3, 7), color, width)
	draw_arc(Vector2(7, 7), radius, PI, 3.0 * PI / 2.0, 8, color, width, true)
	draw_arc(Vector2(17, 7), radius, 3.0 * PI / 2.0, TAU, 8, color, width, true)
	draw_arc(Vector2(17, 17), radius, 0.0, PI / 2.0, 8, color, width, true)
	draw_arc(Vector2(7, 17), radius, PI / 2.0, PI, 8, color, width, true)
