class_name JAMaterials
extends RefCounted
## Builds Godot materials for map surfaces from Q3 shader definitions.
## "Classic" look: unshaded, texture x (lightmap | vertex light), which is
## what the original fixed-function renderer produced. A PBR/lit path can be
## added beside it later without touching the BSP builder.

enum LightMode { FULLBRIGHT, LIGHTMAP, VERTEX }

const MISSING_TEXTURE_SIZE := 64

var vfs: JAVfs
var shaders: Q3ShaderLibrary
var lightmap_atlas: Texture2D
## Multiplier on baked light. 1.0 matches r_overBrightBits 0 (the default).
var light_scale := 1.0

var _textures: Dictionary = {}   # path -> Texture2D (null if missing)
var _shader_code: Dictionary = {} # variant key -> Shader
var _materials: Dictionary = {}  # "shader|mode" -> Material
var _missing: Texture2D
var missing_textures := PackedStringArray()


func _init(p_vfs: JAVfs, p_shaders: Q3ShaderLibrary) -> void:
	vfs = p_vfs
	shaders = p_shaders


## Returns null when the surface should not be drawn at all.
func get_material(shader_name: String, mode: int) -> Material:
	var key := "%s|%d" % [shader_name.to_lower(), mode]
	if _materials.has(key):
		return _materials[key]
	var mat := _build(shader_name, mode)
	_materials[key] = mat
	return mat


func material_count() -> int:
	return _materials.size()


func _build(shader_name: String, mode: int) -> Material:
	var def: Q3ShaderLibrary.Def = shaders.get_def(shader_name) if shaders != null else null
	var tex_path := ""
	var cull := "front"
	var blend := Q3ShaderLibrary.Blend.OPAQUE
	var alpha_test := Q3ShaderLibrary.AlphaTest.NONE
	var clamp := false
	var scroll := Vector2.ZERO
	var light := mode
	if def != null:
		var st := def.diffuse_stage()
		if st != null:
			tex_path = st.map
			clamp = st.clamp
			for m in st.tc_mods:
				if m.size() >= 3 and m[0].to_lower() == "scroll":
					scroll = Vector2(float(m[1]), float(m[2]))
		cull = def.cull
		blend = def.base_blend()
		alpha_test = def.alpha_test()
		# An explicit shader without a $lightmap stage is not lightmapped
		# (e.g. glowing panels); vertex-lit surfaces keep vertex light.
		if mode == LightMode.LIGHTMAP and not def.has_lightmap_stage():
			light = LightMode.VERTEX if def.uses_vertex_color() else LightMode.FULLBRIGHT
		if blend == Q3ShaderLibrary.Blend.ADD:
			light = LightMode.FULLBRIGHT
	else:
		tex_path = shader_name   # implicit shader: texture named like the shader

	var mat := ShaderMaterial.new()
	mat.resource_name = shader_name
	mat.shader = _get_shader(cull, blend, alpha_test, clamp)
	mat.set_shader_parameter("albedo_tex", _texture(tex_path))
	mat.set_shader_parameter("lightmap_tex", lightmap_atlas)
	mat.set_shader_parameter("light_mode", light)
	mat.set_shader_parameter("light_scale", light_scale)
	mat.set_shader_parameter("tc_scroll", scroll)
	if blend != Q3ShaderLibrary.Blend.OPAQUE:
		mat.render_priority = 1
	return mat


func _get_shader(cull: String, blend: int, alpha_test: int, clamp: bool) -> Shader:
	var key := "%s|%d|%d|%s" % [cull, blend, alpha_test, clamp]
	if _shader_code.has(key):
		return _shader_code[key]
	var modes := PackedStringArray(["unshaded"])
	match cull:
		"none": modes.append("cull_disabled")
		"back": modes.append("cull_front")
		_: modes.append("cull_back")
	match blend:
		Q3ShaderLibrary.Blend.ADD: modes.append_array(["blend_add", "depth_draw_never"])
		Q3ShaderLibrary.Blend.MULTIPLY: modes.append_array(["blend_mul", "depth_draw_never"])
		Q3ShaderLibrary.Blend.ALPHA: modes.append_array(["blend_mix", "depth_draw_never"])
	var repeat := "repeat_disable" if clamp else "repeat_enable"
	var alpha_code := ""
	match alpha_test:
		Q3ShaderLibrary.AlphaTest.GT0: alpha_code = "if (t.a <= 0.0) discard;"
		Q3ShaderLibrary.AlphaTest.LT128: alpha_code = "if (t.a >= 0.5) discard;"
		Q3ShaderLibrary.AlphaTest.GE128: alpha_code = "if (t.a < 0.5) discard;"
		Q3ShaderLibrary.AlphaTest.GE192: alpha_code = "if (t.a < 0.75) discard;"
	var write_alpha := "ALPHA = t.a;" if blend == Q3ShaderLibrary.Blend.ALPHA else ""
	var code := """shader_type spatial;
render_mode %s;

uniform sampler2D albedo_tex : source_color, filter_linear_mipmap_anisotropic, %s;
uniform sampler2D lightmap_tex : source_color, filter_linear, repeat_disable;
uniform int light_mode = 0; // 0 fullbright, 1 lightmap (UV2), 2 vertex colour
uniform float light_scale = 1.0;
uniform vec2 tc_scroll = vec2(0.0);

void fragment() {
	vec4 t = texture(albedo_tex, UV + tc_scroll * TIME);
	%s
	vec3 light = vec3(1.0);
	if (light_mode == 1) {
		light = texture(lightmap_tex, UV2).rgb * light_scale;
	} else if (light_mode == 2) {
		// vertex colours are stored as raw sRGB bytes
		light = pow(COLOR.rgb, vec3(2.2)) * light_scale;
	}
	ALBEDO = t.rgb * light;
	%s
}
""" % [", ".join(modes), repeat, alpha_code, write_alpha]
	var sh := Shader.new()
	sh.code = code
	_shader_code[key] = sh
	return sh


func _texture(path: String) -> Texture2D:
	if path.is_empty() or path.begins_with("$"):
		return _missing_texture()
	if _textures.has(path):
		var cached = _textures[path]
		return cached if cached != null else _missing_texture()
	var tex := load_texture(vfs, path)
	_textures[path] = tex
	if tex == null:
		missing_textures.append(path)
		return _missing_texture()
	return tex


static func load_texture(p_vfs: JAVfs, path: String) -> Texture2D:
	var real := p_vfs.find_image(path)
	if real.is_empty():
		return null
	var bytes := p_vfs.read_file(real)
	var img := Image.new()
	var err := ERR_FILE_UNRECOGNIZED
	match real.get_extension():
		"tga": err = img.load_tga_from_buffer(bytes)
		"jpg": err = img.load_jpg_from_buffer(bytes)
		"png": err = img.load_png_from_buffer(bytes)
	if err != OK:
		push_warning("JAMaterials: failed to decode %s" % real)
		return null
	img.generate_mipmaps()
	var tex := ImageTexture.create_from_image(img)
	tex.resource_name = real
	return tex


func _missing_texture() -> Texture2D:
	if _missing == null:
		var img := Image.create(MISSING_TEXTURE_SIZE, MISSING_TEXTURE_SIZE, false, Image.FORMAT_RGB8)
		for y in MISSING_TEXTURE_SIZE:
			for x in MISSING_TEXTURE_SIZE:
				var on := ((x / 8) + (y / 8)) % 2 == 0
				img.set_pixel(x, y, Color(0.8, 0.0, 0.8) if on else Color(0.1, 0.1, 0.1))
		img.generate_mipmaps()
		_missing = ImageTexture.create_from_image(img)
	return _missing
