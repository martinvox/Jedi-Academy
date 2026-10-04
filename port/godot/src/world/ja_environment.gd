class_name JAEnvironment
extends RefCounted
## Builds a WorldEnvironment for a loaded map: the skybox from the first sky
## shader with "skyparms env/<name>", otherwise a flat colour. Tonemapping is
## linear so the baked lightmaps look like the original.

const SKY_SUFFIXES := ["rt", "lf", "bk", "ft", "up", "dn"]  # tr_shader.cpp ParseSkyParms


static func create(vfs: JAVfs, shaders: Q3ShaderLibrary, sky_shaders: PackedStringArray) -> Environment:
	var env := Environment.new()
	env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	env.ambient_light_source = Environment.AMBIENT_SOURCE_DISABLED
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.05, 0.05, 0.08)
	for name in sky_shaders:
		var def := shaders.get_def(name)
		if def == null or def.sky_env.is_empty() or def.sky_env == "-":
			continue
		var mat := sky_material(vfs, def.sky_env)
		if mat != null:
			var sky := Sky.new()
			sky.sky_material = mat
			env.sky = sky
			env.background_mode = Environment.BG_SKY
			break
	return env


static func sky_material(vfs: JAVfs, env_name: String) -> ShaderMaterial:
	var mat := ShaderMaterial.new()
	mat.shader = load("res://src/world/q3_sky.gdshader")
	var found := 0
	for suf in SKY_SUFFIXES:
		var tex := JAMaterials.load_texture(vfs, "%s_%s" % [env_name, suf])
		if tex != null:
			found += 1
		mat.set_shader_parameter("sky_" + suf, tex)
	return mat if found > 0 else null
