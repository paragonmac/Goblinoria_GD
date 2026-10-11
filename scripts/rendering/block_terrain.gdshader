shader_type spatial;
render_mode cull_back, depth_draw_opaque;

#include "terrain_excavation_preview.gdshaderinc"

uniform float top_render_y = 0.0;
uniform float min_render_y = -1e20;
uniform sampler2D atlas_texture;
// SEE-ADR-021 darkness: one R8 layer per world Y (light 0..15 scaled to 0..1,
// explored 0/1), indexed by cell x/z offset from the world minimum.
uniform sampler2DArray light_tex : filter_nearest;
uniform sampler2DArray explored_tex : filter_nearest;
uniform bool darkness_enabled = false;
uniform bool fog_enabled = true;
uniform bool light_view = false;
uniform ivec2 light_origin = ivec2(-128, -128);
uniform ivec2 light_size = ivec2(256, 256);
uniform int light_layers = 256;
// Goblin light (SEE-ADR-021 phase 3): per goblin an 11x11x11 wall-aware light
// grid in an atlas (row = dz + 5 + 11 * i, column = dx + 5 + 11 * (dy + 5)).
uniform sampler2D goblin_atlas : filter_nearest;
uniform vec4 goblin_cells[64];
uniform int goblin_count = 0;
// Darkness brightness: explored-but-unlit memory sits below every lit level,
// and lit cells rise from LIT_MIN (level 1) to full colour (level 15), so any
// light, even a goblin's weak level 6, reads brighter than remembered dark.
const float UNLIT_DIM = 0.10;
const float LIT_MIN = 0.18;
const float LIT_GAMMA = 1.3;
const float HEIGHT_SHADE_FACTOR = 0.15;
const float HEIGHT_SHADE_MIN = 0.3;
const float ATLAS_COLUMNS = 4.0;
const float ATLAS_ROWS = 4.0;
const float GREEDY_UV2_FLAG = 2.0;
const float COVERED_FROM_ABOVE_FLAG = 256.0;
// Cut faces through solid ground are darkened and hatched so they read as
// "inside the ground", not walkable floor.
const float CUT_FACE_SHADE = 0.6;
const float CUT_HATCH_SHADE = 0.4;
const float CUT_HATCH_STRIPES_PER_BLOCK = 3.0;
const float CUT_HATCH_LINE_WIDTH = 0.35;

float cut_hatch_line() {
	// preview_world_position comes from the shared vertex() in the include.
	float coord = (preview_world_position.x + preview_world_position.z) * CUT_HATCH_STRIPES_PER_BLOCK;
	float dist = abs(fract(coord) - 0.5) * 2.0;
	float aa = fwidth(coord) * 2.0;
	return 1.0 - smoothstep(CUT_HATCH_LINE_WIDTH - aa, CUT_HATCH_LINE_WIDTH + aa, dist);
}

void fragment() {
	if (inside_excavation_preview()) { discard; }
	float encoded_uv2_y = UV2.y;
	bool covered_from_above = encoded_uv2_y >= COVERED_FROM_ABOVE_FLAG;
	if (covered_from_above) {
		encoded_uv2_y -= COVERED_FROM_ABOVE_FLAG;
	}
	if (UV2.x < min_render_y) {
		discard;
	}
	if (UV2.x > top_render_y) {
		discard;
	}
	bool greedy_uv = encoded_uv2_y >= GREEDY_UV2_FLAG;
	float top_flag = encoded_uv2_y;
	float tile_index = 0.0;
	if (greedy_uv) {
		float encoded = encoded_uv2_y - GREEDY_UV2_FLAG;
		tile_index = floor(encoded / 2.0);
		top_flag = mod(encoded, 2.0);
	}
	if (top_flag > 0.5 && top_render_y >= UV2.x + 1.0) {
		discard;
	}
	float height_shade = clamp(1.0 - (top_render_y - UV2.x) * HEIGHT_SHADE_FACTOR, HEIGHT_SHADE_MIN, 1.0);
	vec2 texture_uv = UV;
	if (greedy_uv) {
		vec2 tile = vec2(mod(tile_index, ATLAS_COLUMNS), floor(tile_index / ATLAS_COLUMNS));
		texture_uv = (tile + fract(UV)) / vec2(ATLAS_COLUMNS, ATLAS_ROWS);
	}
	vec3 tex = texture(atlas_texture, texture_uv).rgb;
	ALBEDO = tex * COLOR.rgb * height_shade;
	if (darkness_enabled) {
		// The cell in front of the face carries its light; a slice cap (cut top
		// inside solid ground) samples its own cell.
		bool cap = top_flag > 0.5;
		vec3 probe = preview_world_position + preview_world_normal * (cap ? -0.5 : 0.5);
		ivec3 cell = ivec3(round(probe));
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
			ALBEDO = vec3(level / 15.0);
		} else if (fog_enabled && explored < 0.5) {
			ALBEDO = vec3(0.0);
		} else if (level < 0.5) {
			float grey = dot(ALBEDO, vec3(0.299, 0.587, 0.114));
			ALBEDO = mix(vec3(grey), ALBEDO, 0.25) * UNLIT_DIM;
		} else {
			ALBEDO *= mix(LIT_MIN, 1.0, pow(clamp((level - 1.0) / 14.0, 0.0, 1.0), LIT_GAMMA));
		}
	}
	// A surviving top face with top_flag set is a synthetic cut through solid ground.
	if (top_flag > 0.5) {
		ALBEDO *= CUT_FACE_SHADE * mix(1.0, CUT_HATCH_SHADE, cut_hatch_line());
	}
}
