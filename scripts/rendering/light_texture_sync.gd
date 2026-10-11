extends RefCounted
class_name LightTextureSync
## SEE-ADR-021: mirrors LightField layers into two Texture2DArray (one R8 layer
## per world Y: light, explored) for the terrain shader. Only dirty layers are
## uploaded, a budget per frame, nearest the render level first.

const LAYER_BUDGET := 16

var light_tex: Texture2DArray
var explored_tex: Texture2DArray
var layers_uploaded_total := 0
var last_layers_uploaded := 0
var _field_id := 0
var _field_build := -1


## Recreates both textures from every layer when the field instance or its
## build changed. Returns true when new textures were created.
func bind(field) -> bool:
	if field == null:
		return false
	var build := int(field.get("build_count")) if field.get("build_count") != null else 0
	if field.get_instance_id() == _field_id and build == _field_build and light_tex != null:
		return false
	_field_id = field.get_instance_id()
	_field_build = build
	var light_images: Array[Image] = []
	var explored_images: Array[Image] = []
	var layers: int = field.layer_count() if field.has_method("layer_count") else field.NY
	var width: int = field.NX
	var height: int = field.NZ
	for y in range(layers):
		light_images.append(_image(field.layer_slice("light", y), width, height))
		explored_images.append(_image(field.layer_slice("explored", y), width, height))
	light_tex = Texture2DArray.new()
	light_tex.create_from_images(light_images)
	explored_tex = Texture2DArray.new()
	explored_tex.create_from_images(explored_images)
	# A full upload covers everything dirty so far.
	field.take_dirty_layers(layers, 0)
	return true


## Uploads up to budget dirty layers nearest near_y. Returns layers uploaded.
func pump(field, near_y: int, budget: int = LAYER_BUDGET) -> int:
	last_layers_uploaded = 0
	if field == null or light_tex == null:
		return 0
	for y: int in field.take_dirty_layers(budget, near_y):
		light_tex.update_layer(_image(field.layer_slice("light", y), field.NX, field.NZ), y)
		explored_tex.update_layer(_image(field.layer_slice("explored", y), field.NX, field.NZ), y)
		last_layers_uploaded += 1
	layers_uploaded_total += last_layers_uploaded
	return last_layers_uploaded


static func _image(data: PackedByteArray, width: int, height: int) -> Image:
	return Image.create_from_data(width, height, false, Image.FORMAT_R8, data)
