// Darkness for props (trees, item piles), SEE-ADR-021. Mirrors the terrain
// shader's darkness block (block_terrain.gdshader): keep the curve constants in
// sync. The material helper binds these uniforms on every registered material.
uniform sampler2DArray light_tex : filter_nearest;
uniform sampler2DArray explored_tex : filter_nearest;
uniform bool darkness_enabled = false;
uniform bool fog_enabled = true;
uniform bool light_view = false;
uniform ivec2 light_origin = ivec2(-128, -128);
uniform ivec2 light_size = ivec2(256, 256);
uniform int light_layers = 256;
uniform sampler2D goblin_atlas : filter_nearest;
uniform vec4 goblin_cells[64];
uniform int goblin_count = 0;

const float PROP_UNLIT_DIM = 0.10;
const float PROP_LIT_MIN = 0.18;
const float PROP_LIT_GAMMA = 1.3;

vec3 prop_darkness(vec3 albedo, ivec3 cell) {
	if (!darkness_enabled) {
		return albedo;
	}
	ivec3 texel = ivec3(cell.x - light_origin.x, cell.z - light_origin.y, cell.y);
	float level = 0.0;
	float explored = 1.0;
	if (texel.x >= 0 && texel.x < light_size.x && texel.y >= 0 && texel.y < light_size.y && texel.z >= 0 && texel.z < light_layers) {
		level = texelFetch(light_tex, texel, 0).r * 15.0;
		explored = texelFetch(explored_tex, texel, 0).r;
	}
	for (int i = 0; i < goblin_count; i++) {
		ivec3 d = cell - ivec3(goblin_cells[i].xyz);
		if (abs(d.x) <= 5 && abs(d.y) <= 5 && abs(d.z) <= 5) {
			float g = texelFetch(goblin_atlas, ivec2(d.x + 5 + 11 * (d.y + 5), d.z + 5 + 11 * i), 0).r * 15.0;
			level = max(level, g);
		}
	}
	if (light_view) {
		return vec3(level / 15.0);
	}
	if (fog_enabled && explored < 0.5) {
		return vec3(0.0);
	}
	if (level < 0.5) {
		float grey = dot(albedo, vec3(0.299, 0.587, 0.114));
		return mix(vec3(grey), albedo, 0.25) * PROP_UNLIT_DIM;
	}
	return albedo * mix(PROP_LIT_MIN, 1.0, pow(clamp((level - 1.0) / 14.0, 0.0, 1.0), PROP_LIT_GAMMA));
}
