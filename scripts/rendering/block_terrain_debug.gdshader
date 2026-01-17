shader_type spatial;
render_mode unshaded, cull_disabled, depth_prepass_alpha;

uniform float top_render_y = 0.0;
uniform sampler2D atlas_texture;

void fragment() {
	if (UV2.x > top_render_y) {
		discard;
	}
	if (UV2.y > 0.5 && top_render_y >= UV2.x + 1.0) {
		discard;
	}
	ALBEDO = NORMAL * 0.5 + vec3(0.5);
	ALPHA = 1.0;
}
