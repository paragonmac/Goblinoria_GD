extends RefCounted
class_name WorldRendererMaterials

const BlockTerrainShader = preload("res://scripts/rendering/block_terrain.gdshader")
const BlockTerrainDebugShader = preload("res://scripts/rendering/block_terrain_debug.gdshader")
const BlockTerrainPolyDebugShader = preload("res://scripts/rendering/block_terrain_poly_debug.gdshader")
const BlockTerrainPolyWireShader = preload("res://scripts/rendering/block_terrain_poly_wire.gdshader")
const BLOCK_ATLAS_PATH := "res://assets/textures/atlas.png"

var world: World
var block_material: Material
var block_atlas_texture: Texture2D
var poly_wire_material: ShaderMaterial
var debug_normals_enabled: bool = false
var poly_debug_enabled: bool = false


func initialize(world_ref: World) -> void:
	world = world_ref


func update_world(world_ref: World) -> void:
	world = world_ref


func get_block_material() -> Material:
	if block_material == null:
		var shader_material := ShaderMaterial.new()
		shader_material.shader = _active_shader()
		shader_material.set_shader_parameter("atlas_texture", _get_block_atlas_texture())
		if world != null:
			shader_material.set_shader_parameter("top_render_y", float(world.top_render_y))
			shader_material.set_shader_parameter("min_render_y", float(world.get_min_render_y()))
		_apply_next_pass(shader_material)
		block_material = shader_material
	return block_material


func set_top_render_y(value: int) -> void:
	var mat := get_block_material()
	if mat is ShaderMaterial:
		var shader_material := mat as ShaderMaterial
		shader_material.set_shader_parameter("top_render_y", float(value))
		if poly_wire_material != null:
			poly_wire_material.set_shader_parameter("top_render_y", float(value))
		if world != null:
			shader_material.set_shader_parameter("min_render_y", float(world.get_min_render_y()))
			if poly_wire_material != null:
				poly_wire_material.set_shader_parameter("min_render_y", float(world.get_min_render_y()))


func set_min_render_y(value: int) -> void:
	var mat := get_block_material()
	if mat is ShaderMaterial:
		var shader_material := mat as ShaderMaterial
		shader_material.set_shader_parameter("min_render_y", float(value))
		if poly_wire_material != null:
			poly_wire_material.set_shader_parameter("min_render_y", float(value))


func toggle_debug_normals() -> void:
	debug_normals_enabled = not debug_normals_enabled
	_apply_active_shader()


func set_poly_debug_enabled(enabled: bool) -> void:
	if poly_debug_enabled == enabled:
		return
	poly_debug_enabled = enabled
	_apply_active_shader()


func _active_shader() -> Shader:
	if debug_normals_enabled:
		return BlockTerrainDebugShader
	if poly_debug_enabled:
		return BlockTerrainPolyDebugShader
	return BlockTerrainShader


func _apply_active_shader() -> void:
	var mat := get_block_material()
	if mat is ShaderMaterial:
		var shader_material := mat as ShaderMaterial
		shader_material.shader = _active_shader()
		shader_material.set_shader_parameter("atlas_texture", _get_block_atlas_texture())
		if world != null:
			shader_material.set_shader_parameter("top_render_y", float(world.top_render_y))
			shader_material.set_shader_parameter("min_render_y", float(world.get_min_render_y()))
		_apply_next_pass(shader_material)


func _apply_next_pass(shader_material: ShaderMaterial) -> void:
	if poly_debug_enabled and not debug_normals_enabled:
		shader_material.next_pass = _get_poly_wire_material()
	else:
		shader_material.next_pass = null


func _get_poly_wire_material() -> ShaderMaterial:
	if poly_wire_material == null:
		poly_wire_material = ShaderMaterial.new()
		poly_wire_material.shader = BlockTerrainPolyWireShader
	if world != null:
		poly_wire_material.set_shader_parameter("top_render_y", float(world.top_render_y))
		poly_wire_material.set_shader_parameter("min_render_y", float(world.get_min_render_y()))
	return poly_wire_material


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
