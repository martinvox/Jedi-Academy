// Q3 / Jedi Academy skybox ("skyparms env/name"), six images name_rt/lf/bk/ft/up/dn.
// Face orientation is the inverse of MakeSkyVec in code/renderer/tr_sky.cpp:
// for each face, world = signed permutation of (s, t, 1), and the image is
// sampled at ((s + 1) / 2, 1 - (t + 1) / 2).
shader_type sky;

uniform sampler2D sky_rt : source_color, filter_linear, repeat_disable;
uniform sampler2D sky_lf : source_color, filter_linear, repeat_disable;
uniform sampler2D sky_bk : source_color, filter_linear, repeat_disable;
uniform sampler2D sky_ft : source_color, filter_linear, repeat_disable;
uniform sampler2D sky_up : source_color, filter_linear, repeat_disable;
uniform sampler2D sky_dn : source_color, filter_linear, repeat_disable;

vec2 face_uv(float s, float t) {
	return vec2(0.5 + 0.5 * s, 0.5 - 0.5 * t);
}

void sky() {
	// Godot (x, y, z) -> Quake (x, -z, y)
	vec3 q = vec3(EYEDIR.x, -EYEDIR.z, EYEDIR.y);
	vec3 a = abs(q);
	vec3 c;
	if (a.x >= a.y && a.x >= a.z) {
		if (q.x > 0.0) { // rt: (x, y, z) = (1, -s, t)
			c = texture(sky_rt, face_uv(-q.y / q.x, q.z / q.x)).rgb;
		} else {         // lf: (-1, s, t)
			c = texture(sky_lf, face_uv(q.y / -q.x, q.z / -q.x)).rgb;
		}
	} else if (a.y >= a.z) {
		if (q.y > 0.0) { // bk: (s, 1, t)
			c = texture(sky_bk, face_uv(q.x / q.y, q.z / q.y)).rgb;
		} else {         // ft: (-s, -1, t)
			c = texture(sky_ft, face_uv(q.x / q.y, -q.z / q.y)).rgb;
		}
	} else {
		if (q.z > 0.0) { // up: (-t, -s, 1)
			c = texture(sky_up, face_uv(-q.y / q.z, -q.x / q.z)).rgb;
		} else {         // dn: (t, -s, -1)
			c = texture(sky_dn, face_uv(q.y / q.z, -q.x / q.z)).rgb;
		}
	}
	COLOR = c;
}
