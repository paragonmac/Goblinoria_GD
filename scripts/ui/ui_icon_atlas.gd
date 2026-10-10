extends RefCounted
class_name UiIconAtlas

const UiIcon = preload("res://scripts/ui/ui_icon.gd")
const CELL_SIZE := 48
const COLUMN_COUNT := 8
const ICON_SIZE := 32
const DEFAULT_COLOR := Color("e7c48a")

static var _viewport: SubViewport
static var _regions: Array[Rect2i] = []
static var _textures: Dictionary = {}


static func texture(icon_name: String, color: Color = DEFAULT_COLOR) -> Texture2D:
	var scene_tree := Engine.get_main_loop() as SceneTree
	if scene_tree == null:
		return null
	if not is_instance_valid(_viewport):
		_create_viewport(scene_tree)
	var resolved_name := icon_name if UiIcon.has_icon(icon_name) else "__placeholder__"
	if not _textures.has(resolved_name):
		_textures[resolved_name] = {}
	var color_textures: Dictionary = _textures[resolved_name]
	if color_textures.has(color):
		return color_textures[color]
	var cell_index := _regions.size()
	var cell := Vector2i(cell_index % COLUMN_COUNT, cell_index / COLUMN_COUNT)
	var required_rows := int(cell_index / COLUMN_COUNT) + 1
	if _viewport.size.y < required_rows * CELL_SIZE:
		_viewport.size = Vector2i(COLUMN_COUNT * CELL_SIZE, required_rows * CELL_SIZE)
	var icon := UiIcon.make(resolved_name, ICON_SIZE, color)
	icon.position = Vector2(cell * CELL_SIZE) + Vector2.ONE * ((CELL_SIZE - ICON_SIZE) * 0.5)
	_viewport.add_child(icon)
	# Region hugs the icon so menus do not show the cell padding.
	var region := Rect2i(cell * CELL_SIZE + Vector2i.ONE * ((CELL_SIZE - ICON_SIZE) / 2), Vector2i.ONE * ICON_SIZE)
	_regions.append(region)
	_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	var atlas_texture := AtlasTexture.new()
	atlas_texture.atlas = _viewport.get_texture()
	atlas_texture.region = region
	color_textures[color] = atlas_texture
	return atlas_texture


static func clear() -> void:
	if is_instance_valid(_viewport):
		if _viewport.is_inside_tree():
			_viewport.free()
		else:
			_viewport.queue_free()
	_viewport = null
	_regions.clear()
	_textures.clear()


static func _create_viewport(scene_tree: SceneTree) -> void:
	_viewport = SubViewport.new()
	_viewport.name = "UiIconAtlas"
	_viewport.transparent_bg = true
	_viewport.size = Vector2i(COLUMN_COUNT * CELL_SIZE, CELL_SIZE)
	_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	# Deferred: the first request can come from a _ready() while root is still
	# adding children, where a direct add_child() fails.
	scene_tree.root.add_child.call_deferred(_viewport)
