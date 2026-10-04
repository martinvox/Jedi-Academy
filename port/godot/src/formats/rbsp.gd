class_name RBSPFile
extends RefCounted
## Parser for Raven BSP ("RBSP" version 1), the map format of Jedi Academy.
## Layouts follow the PC (non-_XBOX) structs in code/qcommon/qfiles.h.
## All data stays in Quake units / Quake axes; conversion happens in JACoords.

const IDENT := 0x50534252  # "RBSP" little-endian
const VERSION := 1
const MAX_LIGHTMAPS := 4
const LIGHTMAP_SIZE := 128

enum Lump {
	ENTITIES, SHADERS, PLANES, NODES, LEAFS, LEAFSURFACES, LEAFBRUSHES,
	MODELS, BRUSHES, BRUSHSIDES, DRAWVERTS, DRAWINDEXES, FOGS, SURFACES,
	LIGHTMAPS, LIGHTGRID, VISIBILITY, LIGHTARRAY,
}
const HEADER_LUMPS := 18

enum SurfaceType { BAD, PLANAR, PATCH, TRIANGLE_SOUP, FLARE }

# lightmapNum special values (code/renderer/tr_local.h)
const LIGHTMAP_2D := -4
const LIGHTMAP_BY_VERTEX := -3
const LIGHTMAP_WHITEIMAGE := -2
const LIGHTMAP_NONE := -1

# struct sizes in bytes
const SIZE_SHADER := 72      # char[64], int surfaceFlags, int contentFlags
const SIZE_PLANE := 16       # float normal[3], float dist
const SIZE_MODEL := 40       # float mins[3], maxs[3], int firstSurface, numSurfaces, firstBrush, numBrushes
const SIZE_BRUSH := 12       # int firstSide, numSides, shaderNum
const SIZE_BRUSHSIDE := 12   # int planeNum, shaderNum, drawSurfNum
const SIZE_DRAWVERT := 80    # xyz[3], st[2], lightmap[4][2], normal[3], byte color[4][4]
const SIZE_FOG := 72         # char[64], int brushNum, int visibleSide
const SIZE_SURFACE := 148

class ShaderInfo:
	var name: String
	var surface_flags: int
	var content_flags: int

class Model:
	var mins: Vector3
	var maxs: Vector3
	var first_surface: int
	var num_surfaces: int
	var first_brush: int
	var num_brushes: int

class Brush:
	var first_side: int
	var num_sides: int
	var shader_num: int

class Surface:
	var shader_num: int
	var fog_num: int
	var surface_type: int
	var first_vert: int
	var num_verts: int
	var first_index: int
	var num_indexes: int
	var lightmap_styles: PackedByteArray
	var vertex_styles: PackedByteArray
	var lightmap_num: PackedInt32Array
	var lightmap_origin: Vector3
	var lightmap_vecs: Array[Vector3]
	var patch_width: int
	var patch_height: int

var shaders: Array[ShaderInfo] = []
var planes_normal: PackedVector3Array
var planes_dist: PackedFloat32Array
var models: Array[Model] = []
var brushes: Array[Brush] = []
var brushside_plane: PackedInt32Array
var brushside_shader: PackedInt32Array
var surfaces: Array[Surface] = []
var indexes: PackedInt32Array
# draw vertices, structure-of-arrays
var vert_xyz: PackedVector3Array
var vert_st: PackedVector2Array
var vert_lm: PackedVector2Array      # lightmap[0] only; styles 1-3 are rare
var vert_normal: PackedVector3Array
var vert_color: PackedColorArray     # color[0]
var lightmaps: Array[Image] = []     # 128x128 RGB8 pages
var entities: Array[Dictionary] = []
var entity_string: String

var error: String = ""


## Parses `data`. Returns OK, or an error code with `error` set.
func parse(data: PackedByteArray) -> int:
	if data.size() < 8 + HEADER_LUMPS * 8:
		return _fail("file too small")
	if data.decode_u32(0) != IDENT:
		return _fail("not an RBSP file (ident 0x%08x)" % data.decode_u32(0))
	if data.decode_s32(4) != VERSION:
		return _fail("unsupported RBSP version %d" % data.decode_s32(4))
	var ofs := PackedInt32Array()
	var lens := PackedInt32Array()
	for i in HEADER_LUMPS:
		var o := data.decode_s32(8 + i * 8)
		var l := data.decode_s32(12 + i * 8)
		if o < 0 or l < 0 or o + l > data.size():
			return _fail("lump %d out of range" % i)
		ofs.append(o)
		lens.append(l)

	_parse_entities(data, ofs[Lump.ENTITIES], lens[Lump.ENTITIES])
	_parse_shaders(data, ofs[Lump.SHADERS], lens[Lump.SHADERS])
	_parse_planes(data, ofs[Lump.PLANES], lens[Lump.PLANES])
	_parse_models(data, ofs[Lump.MODELS], lens[Lump.MODELS])
	_parse_brushes(data, ofs[Lump.BRUSHES], lens[Lump.BRUSHES])
	_parse_brushsides(data, ofs[Lump.BRUSHSIDES], lens[Lump.BRUSHSIDES])
	_parse_drawverts(data, ofs[Lump.DRAWVERTS], lens[Lump.DRAWVERTS])
	_parse_indexes(data, ofs[Lump.DRAWINDEXES], lens[Lump.DRAWINDEXES])
	_parse_surfaces(data, ofs[Lump.SURFACES], lens[Lump.SURFACES])
	_parse_lightmaps(data, ofs[Lump.LIGHTMAPS], lens[Lump.LIGHTMAPS])
	return _validate()


func _fail(msg: String) -> int:
	error = msg
	return ERR_PARSE_ERROR


func _validate() -> int:
	var nv := vert_xyz.size()
	for i in surfaces.size():
		var s := surfaces[i]
		if s.first_vert < 0 or s.first_vert + s.num_verts > nv:
			return _fail("surface %d vertex range out of bounds" % i)
		if s.first_index < 0 or s.first_index + s.num_indexes > indexes.size():
			return _fail("surface %d index range out of bounds" % i)
		if s.shader_num < 0 or s.shader_num >= shaders.size():
			return _fail("surface %d bad shader %d" % [i, s.shader_num])
	for i in brushes.size():
		var b := brushes[i]
		if b.first_side < 0 or b.first_side + b.num_sides > brushside_plane.size():
			return _fail("brush %d side range out of bounds" % i)
	for p in brushside_plane:
		if p < 0 or p >= planes_normal.size():
			return _fail("brushside references bad plane %d" % p)
	return OK


static func _vec3(d: PackedByteArray, o: int) -> Vector3:
	return Vector3(d.decode_float(o), d.decode_float(o + 4), d.decode_float(o + 8))


static func _cstr(d: PackedByteArray, o: int, n: int) -> String:
	var end := o
	while end < o + n and d[end] != 0:
		end += 1
	return d.slice(o, end).get_string_from_ascii()


func _parse_shaders(d: PackedByteArray, o: int, l: int) -> void:
	for i in l / SIZE_SHADER:
		var b := o + i * SIZE_SHADER
		var s := ShaderInfo.new()
		s.name = _cstr(d, b, 64)
		s.surface_flags = d.decode_s32(b + 64)
		s.content_flags = d.decode_s32(b + 68)
		shaders.append(s)


func _parse_planes(d: PackedByteArray, o: int, l: int) -> void:
	var n := l / SIZE_PLANE
	planes_normal.resize(n)
	planes_dist.resize(n)
	for i in n:
		var b := o + i * SIZE_PLANE
		planes_normal[i] = _vec3(d, b)
		planes_dist[i] = d.decode_float(b + 12)


func _parse_models(d: PackedByteArray, o: int, l: int) -> void:
	for i in l / SIZE_MODEL:
		var b := o + i * SIZE_MODEL
		var m := Model.new()
		m.mins = _vec3(d, b)
		m.maxs = _vec3(d, b + 12)
		m.first_surface = d.decode_s32(b + 24)
		m.num_surfaces = d.decode_s32(b + 28)
		m.first_brush = d.decode_s32(b + 32)
		m.num_brushes = d.decode_s32(b + 36)
		models.append(m)


func _parse_brushes(d: PackedByteArray, o: int, l: int) -> void:
	for i in l / SIZE_BRUSH:
		var b := o + i * SIZE_BRUSH
		var br := Brush.new()
		br.first_side = d.decode_s32(b)
		br.num_sides = d.decode_s32(b + 4)
		br.shader_num = d.decode_s32(b + 8)
		brushes.append(br)


func _parse_brushsides(d: PackedByteArray, o: int, l: int) -> void:
	var n := l / SIZE_BRUSHSIDE
	brushside_plane.resize(n)
	brushside_shader.resize(n)
	for i in n:
		var b := o + i * SIZE_BRUSHSIDE
		brushside_plane[i] = d.decode_s32(b)
		brushside_shader[i] = d.decode_s32(b + 4)


func _parse_drawverts(d: PackedByteArray, o: int, l: int) -> void:
	var n := l / SIZE_DRAWVERT
	vert_xyz.resize(n)
	vert_st.resize(n)
	vert_lm.resize(n)
	vert_normal.resize(n)
	vert_color.resize(n)
	for i in n:
		var b := o + i * SIZE_DRAWVERT
		vert_xyz[i] = _vec3(d, b)
		vert_st[i] = Vector2(d.decode_float(b + 12), d.decode_float(b + 16))
		vert_lm[i] = Vector2(d.decode_float(b + 20), d.decode_float(b + 24))
		vert_normal[i] = _vec3(d, b + 52)
		vert_color[i] = Color8(d[b + 64], d[b + 65], d[b + 66], d[b + 67])


func _parse_indexes(d: PackedByteArray, o: int, l: int) -> void:
	indexes = d.slice(o, o + (l / 4) * 4).to_int32_array()


func _parse_surfaces(d: PackedByteArray, o: int, l: int) -> void:
	for i in l / SIZE_SURFACE:
		var b := o + i * SIZE_SURFACE
		var s := Surface.new()
		s.shader_num = d.decode_s32(b)
		s.fog_num = d.decode_s32(b + 4)
		s.surface_type = d.decode_s32(b + 8)
		s.first_vert = d.decode_s32(b + 12)
		s.num_verts = d.decode_s32(b + 16)
		s.first_index = d.decode_s32(b + 20)
		s.num_indexes = d.decode_s32(b + 24)
		s.lightmap_styles = d.slice(b + 28, b + 32)
		s.vertex_styles = d.slice(b + 32, b + 36)
		s.lightmap_num = d.slice(b + 36, b + 52).to_int32_array()
		# lightmapX[4], lightmapY[4], lightmapWidth, lightmapHeight: b+52..b+92
		s.lightmap_origin = _vec3(d, b + 92)
		s.lightmap_vecs = [_vec3(d, b + 104), _vec3(d, b + 116), _vec3(d, b + 128)]
		s.patch_width = d.decode_s32(b + 140)
		s.patch_height = d.decode_s32(b + 144)
		surfaces.append(s)


func _parse_lightmaps(d: PackedByteArray, o: int, l: int) -> void:
	var page := LIGHTMAP_SIZE * LIGHTMAP_SIZE * 3
	for i in l / page:
		var px := d.slice(o + i * page, o + (i + 1) * page)
		lightmaps.append(Image.create_from_data(LIGHTMAP_SIZE, LIGHTMAP_SIZE, false, Image.FORMAT_RGB8, px))


func _parse_entities(d: PackedByteArray, o: int, l: int) -> void:
	entity_string = _cstr(d, o, l)
	entities = parse_entity_string(entity_string)


## Parses the entity lump: { "key" "value" ... } blocks. Later duplicate keys
## win, as in G_ParseSpawnVars/G_SpawnString lookups.
static func parse_entity_string(text: String) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var tokens := _tokenize(text)
	var i := 0
	while i < tokens.size():
		if tokens[i] != "{":
			i += 1
			continue
		i += 1
		var ent := {}
		while i + 1 < tokens.size() and tokens[i] != "}":
			ent[tokens[i]] = tokens[i + 1]
			i += 2
		i += 1
		out.append(ent)
	return out


static func _tokenize(text: String) -> PackedStringArray:
	var out := PackedStringArray()
	var i := 0
	var n := text.length()
	while i < n:
		var c := text[i]
		if c == '"':
			var j := text.find('"', i + 1)
			if j < 0:
				j = n
			out.append(text.substr(i + 1, j - i - 1))
			i = j + 1
		elif c == "{" or c == "}":
			out.append(c)
			i += 1
		else:
			i += 1
	return out
