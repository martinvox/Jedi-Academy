class_name Q3ShaderLibrary
extends RefCounted
## Parses shaders/*.shader scripts (code/renderer/tr_shader.cpp) into a
## simplified description that is enough to build Godot materials.
## Only the commonly used keywords are interpreted; everything else is kept
## as raw text in `Def.source` for later, more complete translation.

enum Blend { OPAQUE, ALPHA, ADD, MULTIPLY }
enum AlphaTest { NONE, GT0, LT128, GE128, GE192 }

class Stage:
	var map: String = ""            # texture path, "$lightmap", "$whiteimage"
	var anim_maps: PackedStringArray
	var anim_freq: float = 0.0
	var clamp: bool = false
	var blend_src: String = ""
	var blend_dst: String = ""
	var rgb_gen: String = ""
	var alpha_func: int = AlphaTest.NONE
	var tc_gen: String = ""
	var tc_mods: Array[PackedStringArray] = []
	var glow: bool = false

class Def:
	var name: String
	var cull: String = "front"      # front | back | none
	var surfaceparms: PackedStringArray
	var sky_env: String = ""
	var deforms: Array[PackedStringArray] = []
	var stages: Array[Stage] = []
	var source: String = ""

	func has_parm(p: String) -> bool:
		return surfaceparms.has(p)

	## First stage carrying a real texture (not lightmap/white/env).
	func diffuse_stage() -> Stage:
		for s in stages:
			if s.map.is_empty() or (s.map.begins_with("$") and s.anim_maps.is_empty()):
				continue
			if s.tc_gen == "environment":
				continue
			return s
		return null

	func has_lightmap_stage() -> bool:
		for s in stages:
			if s.map == "$lightmap":
				return true
		return false

	func uses_vertex_color() -> bool:
		for s in stages:
			if s.rgb_gen in ["vertex", "exactvertex", "lightingdiffuse"]:
				return true
		return false

	## Blend mode of the first (base) stage, mapped to a Godot transparency mode.
	func base_blend() -> int:
		var s := diffuse_stage()
		if s == null:
			return Blend.OPAQUE
		return blend_from(s.blend_src, s.blend_dst)

	func alpha_test() -> int:
		var s := diffuse_stage()
		return s.alpha_func if s != null else AlphaTest.NONE


var defs: Dictionary = {}   # lowercase name -> Def (first definition wins, like the original)


func load_from_vfs(vfs: JAVfs) -> void:
	for path in vfs.list_files("shaders", "shader"):
		parse_text(vfs.read_text(path))


func get_def(name: String) -> Def:
	# R_FindShader strips the extension before looking a name up
	var n := name.to_lower().replace("\\", "/")
	if n.get_extension() in ["tga", "jpg", "png"]:
		n = n.get_basename()
	return defs.get(n)


static func blend_from(src: String, dst: String) -> int:
	if src.is_empty():
		return Blend.OPAQUE
	var s := src.to_lower()
	var d := dst.to_lower()
	if s == "blend" or (s == "gl_src_alpha" and d == "gl_one_minus_src_alpha"):
		return Blend.ALPHA
	if s == "add" or (s == "gl_one" and d == "gl_one") or (s == "gl_src_alpha" and d == "gl_one"):
		return Blend.ADD
	if s == "filter" or (s == "gl_dst_color" and d == "gl_zero") or (s == "gl_zero" and d == "gl_src_color"):
		return Blend.MULTIPLY
	if s == "gl_one" and d == "gl_zero":
		return Blend.OPAQUE
	return Blend.ALPHA


func parse_text(text: String) -> void:
	var lines := _lines_of_tokens(text)
	var i := 0
	while i < lines.size():
		var line: PackedStringArray = lines[i]
		if line.size() == 1 and line[0] != "{" and line[0] != "}" and i + 1 < lines.size() and lines[i + 1][0] == "{":
			var def := Def.new()
			def.name = line[0].to_lower().replace("\\", "/")
			i = _parse_body(lines, i + 2, def)
			if not defs.has(def.name):
				defs[def.name] = def
		else:
			i += 1


func _parse_body(lines: Array, i: int, def: Def) -> int:
	var src := PackedStringArray()
	while i < lines.size():
		var t: PackedStringArray = lines[i]
		if t[0] == "}":
			def.source = "\n".join(src)
			return i + 1
		if t[0] == "{":
			var st := Stage.new()
			i = _parse_stage(lines, i + 1, st, src)
			def.stages.append(st)
			continue
		src.append(" ".join(t))
		var k := t[0].to_lower()
		match k:
			"cull":
				var v := t[1].to_lower() if t.size() > 1 else "front"
				if v in ["none", "twosided", "disable"]:
					def.cull = "none"
				elif v in ["back", "backside", "backsided"]:
					def.cull = "back"
				else:
					def.cull = "front"
			"surfaceparm":
				if t.size() > 1:
					def.surfaceparms.append(t[1].to_lower())
			"skyparms":
				if t.size() > 1:
					def.sky_env = t[1]
			"deformvertexes":
				def.deforms.append(t.slice(1))
		i += 1
	return i


func _parse_stage(lines: Array, i: int, st: Stage, src: PackedStringArray) -> int:
	while i < lines.size():
		var t: PackedStringArray = lines[i]
		if t[0] == "}":
			return i + 1
		src.append("  " + " ".join(t))
		var k := t[0].to_lower()
		var a1 := t[1] if t.size() > 1 else ""
		match k:
			"map":
				st.map = a1
			"clampmap":
				st.map = a1
				st.clamp = true
			"animmap", "clampanimmap", "oneshotanimmap":
				st.anim_freq = float(a1)
				st.anim_maps = t.slice(2)
				if not st.anim_maps.is_empty():
					st.map = st.anim_maps[0]
				st.clamp = k != "animmap"
			"blendfunc":
				st.blend_src = a1
				st.blend_dst = t[2] if t.size() > 2 else ""
			"rgbgen":
				st.rgb_gen = a1.to_lower()
			"alphafunc":
				match a1.to_upper():
					"GT0": st.alpha_func = AlphaTest.GT0
					"LT128": st.alpha_func = AlphaTest.LT128
					"GE128": st.alpha_func = AlphaTest.GE128
					"GE192": st.alpha_func = AlphaTest.GE192
			"tcgen":
				st.tc_gen = a1.to_lower()
			"tcmod":
				st.tc_mods.append(t.slice(1))
			"glow":
				st.glow = true
		i += 1
	return i


## Splits text into lines of tokens, dropping // and /* */ comments and
## splitting braces into their own lines.
static func _lines_of_tokens(text: String) -> Array:
	var out: Array = []
	var in_block_comment := false
	for raw in text.split("\n"):
		var line := raw
		if in_block_comment:
			var e := line.find("*/")
			if e < 0:
				continue
			line = line.substr(e + 2)
			in_block_comment = false
		var b := line.find("/*")
		while b >= 0:
			var e2 := line.find("*/", b + 2)
			if e2 < 0:
				line = line.substr(0, b)
				in_block_comment = true
				break
			line = line.substr(0, b) + " " + line.substr(e2 + 2)
			b = line.find("/*")
		var c := line.find("//")
		if c >= 0:
			line = line.substr(0, c)
		line = line.replace("{", " { ").replace("}", " } ").replace("\t", " ").replace("\r", " ")
		var cur := PackedStringArray()
		for tok in line.split(" ", false):
			if tok == "{" or tok == "}":
				if not cur.is_empty():
					out.append(cur)
					cur = PackedStringArray()
				out.append(PackedStringArray([tok]))
			else:
				cur.append(tok)
		if not cur.is_empty():
			out.append(cur)
	return out
