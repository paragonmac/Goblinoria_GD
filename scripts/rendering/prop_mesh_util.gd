extends RefCounted
## Shared helpers for blocky prop meshes (trees, item piles): axis-aligned or
## transformed boxes with per-box vertex colour and two UV channels that prop
## shaders use as per-vertex parameters.


## Appends a box of `size` centred at `center` (in `xform` space). Bottom faces
## are darkened a little so stacked boxes read without extra lighting.
static func add_box(st: SurfaceTool, xform: Transform3D, center: Vector3, size: Vector3, color: Color,
		uv: Vector2 = Vector2.ZERO, uv2: Vector2 = Vector2.ZERO) -> void:
	var h := size * 0.5
	var faces := [
		[Vector3.UP, [Vector3(-h.x, h.y, -h.z), Vector3(h.x, h.y, -h.z), Vector3(h.x, h.y, h.z), Vector3(-h.x, h.y, h.z)]],
		[Vector3.DOWN, [Vector3(-h.x, -h.y, h.z), Vector3(h.x, -h.y, h.z), Vector3(h.x, -h.y, -h.z), Vector3(-h.x, -h.y, -h.z)]],
		[Vector3.RIGHT, [Vector3(h.x, -h.y, h.z), Vector3(h.x, h.y, h.z), Vector3(h.x, h.y, -h.z), Vector3(h.x, -h.y, -h.z)]],
		[Vector3.LEFT, [Vector3(-h.x, -h.y, -h.z), Vector3(-h.x, h.y, -h.z), Vector3(-h.x, h.y, h.z), Vector3(-h.x, -h.y, h.z)]],
		[Vector3.BACK, [Vector3(-h.x, -h.y, h.z), Vector3(-h.x, h.y, h.z), Vector3(h.x, h.y, h.z), Vector3(h.x, -h.y, h.z)]],
		[Vector3.FORWARD, [Vector3(h.x, -h.y, -h.z), Vector3(h.x, h.y, -h.z), Vector3(-h.x, h.y, -h.z), Vector3(-h.x, -h.y, -h.z)]],
	]
	for face: Array in faces:
		var normal: Vector3 = face[0]
		var corners: Array = face[1]
		var face_color := color.darkened(0.25) if normal == Vector3.DOWN else color
		var world_normal := (xform.basis * normal).normalized()
		for index: int in [0, 1, 2, 0, 2, 3]:
			st.set_color(face_color)
			st.set_normal(world_normal)
			st.set_uv(uv)
			st.set_uv2(uv2)
			st.add_vertex(xform * (center + corners[index]))


## Lit, vertex-coloured prop material with an optional sway: vertices with
## UV.x > 0 move sideways by UV.x * sway_amount (canopies), per instance.
static func make_prop_material(sway_amount: float = 0.0, use_fade: bool = false) -> ShaderMaterial:
	var shader := Shader.new()
	shader.code = """
shader_type spatial;
render_mode cull_back, diffuse_lambert, specular_disabled;
#include "res://scripts/rendering/prop_darkness.gdshaderinc"

uniform float sway_amount = 0.0;
// Trees: INSTANCE_CUSTOM.r = fade (0..1) when the tree covers something the
// player needs to see; faded instances are drawn with a stipple pattern.
uniform bool use_fade = false;

// Light is sampled at the instance origin cell (item cell, tree base cell).
varying flat ivec3 prop_cell;
varying flat float prop_fade;

void vertex() {
	prop_cell = ivec3(round((MODEL_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xyz));
	prop_fade = use_fade ? INSTANCE_CUSTOM.r : 0.0;
	if (sway_amount > 0.0 && UV.x > 0.0) {
		float seed = float(INSTANCE_ID) * 2.399;
		float t = TIME * 0.9 + seed;
		VERTEX.x += sin(t) * sway_amount * UV.x;
		VERTEX.z += sin(t * 0.77 + 1.3) * sway_amount * 0.6 * UV.x;
	}
}

void fragment() {
	if (prop_fade > 0.0) {
		// 4x4 ordered dither: keep about a quarter of the pixels when faded.
		ivec2 p = ivec2(FRAGCOORD.xy) % 4;
		int bayer[16] = int[](0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5);
		if (float(bayer[p.y * 4 + p.x]) / 16.0 < prop_fade * 0.75) {
			discard;
		}
	}
	// Vertex colours are authored in sRGB.
	ALBEDO = prop_darkness(pow(COLOR.rgb, vec3(2.2)), prop_cell);
	ROUGHNESS = 1.0;
}
"""
	var material := ShaderMaterial.new()
	material.shader = shader
	material.set_shader_parameter("sway_amount", sway_amount)
	material.set_shader_parameter("use_fade", use_fade)
	return material
