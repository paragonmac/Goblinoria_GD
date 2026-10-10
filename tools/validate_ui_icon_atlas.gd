extends SceneTree

const UiIconAtlas = preload("res://scripts/ui/ui_icon_atlas.gd")

var checks := 0
var failures := 0


func _init() -> void:
	_run.call_deferred()


func _run() -> void:
	var first := UiIconAtlas.texture("inspect") as AtlasTexture
	var second := UiIconAtlas.texture("dig") as AtlasTexture
	var third := UiIconAtlas.texture("build", Color("ff0000")) as AtlasTexture
	var fourth := UiIconAtlas.texture("inspect", Color("00ff00")) as AtlasTexture
	_check(first != null and second != null and third != null and fourth != null, "requests return AtlasTextures")
	# The viewport attaches deferred so requests from _ready() are safe.
	await process_frame
	var atlas_viewport := root.get_node_or_null("UiIconAtlas") as SubViewport
	_check(atlas_viewport != null, "viewport is attached to SceneTree root")
	if atlas_viewport != null and first != null and second != null and third != null and fourth != null:
		var textures: Array[AtlasTexture] = [first, second, third, fourth]
		var regions: Array[Rect2] = []
		for atlas_texture: AtlasTexture in textures:
			_check(atlas_texture.atlas == atlas_viewport.get_texture(), "texture references atlas viewport")
			_check(Rect2(Vector2.ZERO, Vector2(atlas_viewport.size)).encloses(atlas_texture.region), "region fits viewport")
			for existing_region: Rect2 in regions:
				_check(not existing_region.intersects(atlas_texture.region), "regions do not overlap")
			regions.append(atlas_texture.region)
		_check(UiIconAtlas.texture("inspect") == first, "same request returns cached object")
		_check(UiIconAtlas.texture("inspect", Color("00ff00")) == fourth, "color-specific cache returns same object")
		_check(UiIconAtlas.texture("not_a_real_icon") == UiIconAtlas.texture("__placeholder__"), "unknown names use placeholder region")
	else:
		_check(false, "atlas inspection requires valid textures and viewport")
	UiIconAtlas.clear()
	_check(root.get_node_or_null("UiIconAtlas") == null, "clear frees the viewport")
	print("UI icon atlas: %d checks, %d failures" % [checks, failures])
	quit(1 if failures > 0 else 0)


func _check(condition: bool, _message: String) -> void:
	checks += 1
	if not condition:
		failures += 1
