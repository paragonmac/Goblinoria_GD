extends RefCounted
class_name WorldRendererMaterials

const BlockTerrainShader = preload("res://scripts/rendering/block_terrain.gdshader")
const BlockTerrainDebugShader = preload("res://scripts/rendering/block_terrain_debug.gdshader")
const BLOCK_ATLAS_PATH := "res://assets/textures/atlas.png"

var world: World
var block_material: Material
var block_atlas_texture: Texture2D
var debug_normals_enabled: bool = false


func initialize(world_ref: World) -> void:
	world = world_ref


func update_world(world_ref: World) -> void:
	world = world_ref


func get_block_material() -> Material:
	if block_material == null:
		var shader_material := ShaderMaterial.new()
		shader_material.shader = BlockTerrainDebugShader if debug_normals_enabled else BlockTerrainShader
		shader_material.set_shader_parameter("atlas_texture", _get_block_atlas_texture())
		if world != null:
			shader_material.set_shader_parameter("top_render_y", float(world.top_render_y))
			shader_material.set_shader_parameter("min_render_y", float(world.get_min_render_y()))
		block_material = shader_material
	return block_material


func set_top_render_y(value: int) -> void:
	var mat := get_block_material()
	if mat is ShaderMaterial:
		var shader_material := mat as ShaderMaterial
		shader_material.set_shader_parameter("top_render_y", float(value))
		if world != null:
			shader_material.set_shader_parameter("min_render_y", float(world.get_min_render_y()))


func set_min_render_y(value: int) -> void:
	var mat := get_block_material()
	if mat is ShaderMaterial:
		var shader_material := mat as ShaderMaterial
		shader_material.set_shader_parameter("min_render_y", float(value))


func toggle_debug_normals() -> void:
	debug_normals_enabled = not debug_normals_enabled
	var mat := get_block_material()
	if mat is ShaderMaterial:
		var shader_material := mat as ShaderMaterial
		shader_material.shader = BlockTerrainDebugShader if debug_normals_enabled else BlockTerrainShader
		if world != null:
			shader_material.set_shader_parameter("top_render_y", float(world.top_render_y))
			shader_material.set_shader_parameter("min_render_y", float(world.get_min_render_y()))


func _get_block_atlas_texture() -> Texture2D:
	if block_atlas_texture != null:
		return block_atlas_texture
	var image := Image.new()
	var err := image.load(BLOCK_ATLAS_PATH)
	if err != OK:
		push_warning("Block atlas load failed: %s (%d)" % [BLOCK_ATLAS_PATH, err])
		return null
	block_atlas_texture = ImageTexture.create_from_image(image)
	return block_atlas_texture
