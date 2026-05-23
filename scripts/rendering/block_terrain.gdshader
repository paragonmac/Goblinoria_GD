shader_type spatial;
render_mode cull_back, depth_draw_opaque;

uniform float top_render_y = 0.0;
uniform float min_render_y = -1e20;
uniform sampler2D atlas_texture;
const float HEIGHT_SHADE_FACTOR = 0.15;
const float HEIGHT_SHADE_MIN = 0.3;
const float ATLAS_COLUMNS = 4.0;
const float ATLAS_ROWS = 4.0;
const float GREEDY_UV2_FLAG = 2.0;

void fragment() {
	if (UV2.x < min_render_y) {
		discard;
	}
	if (UV2.x > top_render_y) {
		discard;
	}
	bool greedy_uv = UV2.y >= GREEDY_UV2_FLAG;
	float top_flag = UV2.y;
	float tile_index = 0.0;
	if (greedy_uv) {
		float encoded = UV2.y - GREEDY_UV2_FLAG;
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
}
