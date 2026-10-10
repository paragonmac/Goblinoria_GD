extends SceneTree
## Darkness phase 2 (SEE-ADR-021): LightField layers reach the terrain material
## as Texture2DArray, dirty layers upload within budget nearest the render
## level, and the F7 switches drive the shader. Headless: no pixels inspected.

const DepthFixture = preload("res://tools/validate_assignment_depth_scaling.gd")

var checks := 0
var failures := 0


func _init() -> void:
	_run.call_deferred()


func _check(ok: bool, message: String) -> void:
	checks += 1
	if not ok:
		failures += 1
		push_error(message)


func _run() -> void:
	var world := DepthFixture.TestWorld.new()
	world.world_size_y = 256
	world._init_ramp_lookup()
	world.block_registry.load_from_csv(World.BLOCK_DATA_PATH)
	for x in range(-16, 16):
		for z in range(-16, 16):
			for y in range(216, 227):
				world.set_block_raw(x, y, z, World.BLOCK_ID_GRANITE, false)
	# Missing chunks count as opaque (not yet generated): create the open air above.
	for cx in range(-2, 2):
		for cz in range(-2, 2):
			for cy in range(27, 32):
				world.ensure_chunk_generated(Vector3i(cx, cy, cz))
	for chunk: ChunkData in world.chunks.values():
		chunk.generated = true
	var renderer := WorldRenderer.new()
	renderer.use_async_meshing = false
	world.add_child(renderer)
	world.renderer = renderer
	renderer.initialize(world)
	world.top_render_y = 226
	world.light_field.build(world)
	world.light_field_built = true

	renderer.pump_light()
	var material: ShaderMaterial = renderer.get_block_material()
	_check(material.get_shader_parameter("light_tex") is Texture2DArray
		and material.get_shader_parameter("explored_tex") is Texture2DArray, "Light and explored textures are bound")
	_check(bool(material.get_shader_parameter("darkness_enabled")), "Darkness is enabled once light is bound")
	var light_tex: Texture2DArray = material.get_shader_parameter("light_tex")
	_check(light_tex.get_layers() == world.world_size_y and light_tex.get_width() == 256 and light_tex.get_height() == 256,
		"One 256x256 layer per world Y")
	_check(material.get_shader_parameter("light_origin") == Vector2i(World.WORLD_MIN_BLOCK_X, World.WORLD_MIN_BLOCK_Z),
		"Texture origin matches the world minimum")
	_check(world.light_field.take_dirty_layers(256, 0).is_empty(), "Binding uploads every layer and clears dirty state")

	# Dig a shaft: only changed layers upload, budgeted, nearest the render level.
	for y in range(220, 227):
		world.set_block(0, y, 0, World.BLOCK_ID_AIR)
	while world.light_field.pending_events() > 0:
		world.light_field.process_events(100000)
	var dirty_before: int = world.light_field.dirty_light_layers.size()
	var uploaded: int = renderer.light_sync.pump(world.light_field, world.top_render_y, 4)
	_check(dirty_before > 0 and uploaded == mini(4, dirty_before), "A dig uploads a budget of dirty layers (%d of %d)" % [uploaded, dirty_before])
	var drained := 0
	for i in 64:
		drained += renderer.light_sync.pump(world.light_field, world.top_render_y, 4)
	_check(world.light_field.dirty_light_layers.is_empty(), "Remaining dirty layers drain over later frames")
	_check(material.get_shader_parameter("light_tex") == light_tex, "Incremental uploads reuse the bound texture")

	# F7 switches.
	renderer.set_render_debug("darkness", false)
	_check(not bool(material.get_shader_parameter("darkness_enabled")), "Darkness switch turns shading off")
	renderer.set_render_debug("darkness", true)
	renderer.set_render_debug("fog", false)
	_check(bool(material.get_shader_parameter("darkness_enabled")) and not bool(material.get_shader_parameter("fog_enabled")),
		"Fog switch leaves light on")
	renderer.set_render_debug("light_view", true)
	_check(bool(material.get_shader_parameter("light_view")), "Light view switch reaches the shader")
	renderer.set_render_debug("fog", true)
	renderer.set_render_debug("light_view", false)

	# A rebuilt field (new world / load) rebinds fresh textures.
	world.light_field.build(world)
	renderer.pump_light()
	_check(material.get_shader_parameter("light_tex") != light_tex, "A rebuilt light field rebinds new textures")

	# The terrain shader still parses with the darkness uniforms.
	var names := []
	for uniform in (load("res://scripts/rendering/block_terrain.gdshader") as Shader).get_shader_uniform_list():
		names.append(uniform.name)
	_check(names.has("light_tex") and names.has("darkness_enabled") and names.has("fog_enabled"), "Terrain shader exposes darkness uniforms")

	print("Light render: %d checks, %d failures" % [checks, failures])
	world.free()
	quit(1 if failures > 0 else 0)
