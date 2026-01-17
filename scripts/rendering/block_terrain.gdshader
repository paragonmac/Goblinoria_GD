shader_type spatial;
render_mode cull_back, depth_prepass_alpha;

uniform float top_render_y = 0.0;
uniform sampler2D atlas_texture;
const float HEIGHT_SHADE_FACTOR = 0.15;
const float HEIGHT_SHADE_MIN = 0.3;

void fragment() {
	if (UV2.x > top_render_y) {
		discard;
	}
	if (UV2.y > 0.5 && top_render_y >= UV2.x + 1.0) {
		discard;
	}
	float height_shade = clamp(1.0 - (top_render_y - UV2.x) * HEIGHT_SHADE_FACTOR, HEIGHT_SHADE_MIN, 1.0);
	vec3 tex = texture(atlas_texture, UV).rgb;
	ALBEDO = tex * COLOR.rgb * height_shade;
	ALPHA = COLOR.a;
}
