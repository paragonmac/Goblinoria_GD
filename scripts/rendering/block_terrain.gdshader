shader_type spatial;
render_mode cull_back, depth_draw_opaque;

#include "terrain_excavation_preview.gdshaderinc"

uniform float top_render_y = 0.0;
uniform float min_render_y = -1e20;
uniform sampler2D atlas_texture;
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
	// A surviving top face with top_flag set is a synthetic cut through solid ground.
	if (top_flag > 0.5) {
		ALBEDO *= CUT_FACE_SHADE * mix(1.0, CUT_HATCH_SHADE, cut_hatch_line());
	}
}
