class_name JAMapBuilder
extends RefCounted
## Turns a parsed RBSPFile into a Godot scene tree:
##   <map>/World        MeshInstance3D per material, from bsp model 0
##   <map>/Collision    StaticBody3D per contents mask, one convex shape per brush
##   <map>/Entities     one Node3D per entity (spawn vars kept as metadata);
##                      brush entities ("model" "*N") get their own meshes and
##                      collision as children
## Everything is converted with JACoords (Quake units -> metres, Z-up -> Y-up).

# contents flags (code/game/surfaceflags.h)
const CONTENTS_SOLID := 0x1
const CONTENTS_LAVA := 0x2
const CONTENTS_WATER := 0x4
const CONTENTS_FOG := 0x8
const CONTENTS_PLAYERCLIP := 0x10
const CONTENTS_MONSTERCLIP := 0x20
const CONTENTS_SHOTCLIP := 0x80
const CONTENTS_TRIGGER := 0x400
const CONTENTS_LADDER := 0x2000
const CONTENTS_SLIME := 0x20000
# surface flags
const SURF_SKY := 0x2000
const SURF_NODRAW := 0x200000

# Godot physics layers used by the port (see port/README.md)
const LAYER_SOLID := 1          # blocks everything
const LAYER_PLAYERCLIP := 2     # blocks players only
const LAYER_MONSTERCLIP := 4    # blocks NPCs only
const LAYER_SHOTCLIP := 8       # blocks shots only
const LAYER_LADDER := 16

## Godot treats clockwise triangles (seen from the front) as front faces, so
## for a front face cross(b - a, c - a) points away from the normal.
const FRONT_SIGN := -1.0

var vfs: JAVfs
var shaders: Q3ShaderLibrary
var materials: JAMaterials
var patch_level := 8
var stats := {}


func _init(p_vfs: JAVfs, p_shaders: Q3ShaderLibrary) -> void:
	vfs = p_vfs
	shaders = p_shaders


func build(bsp: RBSPFile, map_name: String = "map") -> Node3D:
	stats = {"surfaces_drawn": 0, "surfaces_skipped": 0, "triangles": 0,
		"brushes": 0, "entities": 0, "flipped_surfaces": 0, "sky_shaders": PackedStringArray()}
	var root := Node3D.new()
	root.name = map_name.get_file().get_basename()

	var atlas := _build_lightmap_atlas(bsp)
	materials = JAMaterials.new(vfs, shaders)
	materials.lightmap_atlas = atlas[0]

	if bsp.models.is_empty():
		return root
	var world := _build_model_meshes(bsp, 0, atlas[1])
	world.name = "World"
	root.add_child(world)

	var collision := Node3D.new()
	collision.name = "Collision"
	root.add_child(collision)
	_build_brush_collision(bsp, bsp.models[0], collision, false)
	_build_patch_collision(bsp, bsp.models[0], collision, false)

	var ents := Node3D.new()
	ents.name = "Entities"
	root.add_child(ents)
	for i in bsp.entities.size():
		ents.add_child(_build_entity(bsp, i, atlas[1]))
	stats["entities"] = bsp.entities.size()
	stats["materials"] = materials.material_count()
	stats["missing_textures"] = materials.missing_textures.size()
	_set_owner_recursive(root, root)
	return root


## Packs the 128x128 lightmap pages into one square-ish grid texture.
## Returns [Texture2D, grid_columns].
func _build_lightmap_atlas(bsp: RBSPFile) -> Array:
	var n := bsp.lightmaps.size()
	if n == 0:
		var white := Image.create(4, 4, false, Image.FORMAT_RGB8)
		white.fill(Color.WHITE)
		return [ImageTexture.create_from_image(white), 1]
	var cols := int(ceil(sqrt(float(n))))
	var rows := int(ceil(float(n) / cols))
	var sz := RBSPFile.LIGHTMAP_SIZE
	var img := Image.create(cols * sz, rows * sz, false, Image.FORMAT_RGB8)
	for i in n:
		img.blit_rect(bsp.lightmaps[i], Rect2i(0, 0, sz, sz), Vector2i((i % cols) * sz, (i / cols) * sz))
	stats["lightmap_pages"] = n
	return [ImageTexture.create_from_image(img), Vector2i(cols, rows)]


func _surface_drawable(bsp: RBSPFile, s: RBSPFile.Surface) -> bool:
	if s.surface_type == RBSPFile.SurfaceType.FLARE or s.surface_type == RBSPFile.SurfaceType.BAD:
		return false
	var sh := bsp.shaders[s.shader_num]
	if sh.surface_flags & SURF_NODRAW:
		return false
	var def: Q3ShaderLibrary.Def = shaders.get_def(sh.name) if shaders != null else null
	if def != null and (def.has_parm("nodraw") or def.has_parm("fog")):
		return false
	if sh.surface_flags & SURF_SKY or (def != null and def.has_parm("sky")):
		if not stats["sky_shaders"].has(sh.name):
			stats["sky_shaders"].append(sh.name)
		return false
	if sh.content_flags & CONTENTS_FOG:
		return false
	return true


func _build_model_meshes(bsp: RBSPFile, model_index: int, grid: Vector2i) -> Node3D:
	var node := Node3D.new()
	var model := bsp.models[model_index]
	# group key "shader|lightmode" -> {arrays}
	var groups := {}
	for si in range(model.first_surface, model.first_surface + model.num_surfaces):
		var s := bsp.surfaces[si]
		if not _surface_drawable(bsp, s):
			stats["surfaces_skipped"] += 1
			continue
		var lm_page := s.lightmap_num[0]
		var mode := JAMaterials.LightMode.LIGHTMAP if lm_page >= 0 else JAMaterials.LightMode.VERTEX
		var key := "%d|%d" % [s.shader_num, mode]
		if not groups.has(key):
			groups[key] = {"shader": bsp.shaders[s.shader_num].name, "mode": mode,
				"pos": PackedVector3Array(), "nrm": PackedVector3Array(), "uv": PackedVector2Array(),
				"uv2": PackedVector2Array(), "col": PackedColorArray(), "idx": PackedInt32Array()}
		_append_surface(bsp, s, groups[key], grid)
		stats["surfaces_drawn"] += 1

	for key in groups:
		var g: Dictionary = groups[key]
		if g["idx"].is_empty():
			continue
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = g["pos"]
		arrays[Mesh.ARRAY_NORMAL] = g["nrm"]
		arrays[Mesh.ARRAY_TEX_UV] = g["uv"]
		arrays[Mesh.ARRAY_TEX_UV2] = g["uv2"]
		arrays[Mesh.ARRAY_COLOR] = g["col"]
		arrays[Mesh.ARRAY_INDEX] = g["idx"]
		var mesh := ArrayMesh.new()
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		var mat := materials.get_material(g["shader"], g["mode"])
		mesh.surface_set_material(0, mat)
		var mi := MeshInstance3D.new()
		mi.name = _safe_name(g["shader"])
		mi.mesh = mesh
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		node.add_child(mi)
		stats["triangles"] += g["idx"].size() / 3
	return node


func _append_surface(bsp: RBSPFile, s: RBSPFile.Surface, g: Dictionary, grid: Vector2i) -> void:
	var page := s.lightmap_num[0]
	var page_ofs := Vector2.ZERO
	if page >= 0:
		page_ofs = Vector2(page % grid.x, page / grid.x)
	var inv_grid := Vector2(1.0 / grid.x, 1.0 / grid.y)
	var base: int = g["pos"].size()

	var xyz: PackedVector3Array
	var st: PackedVector2Array
	var lm: PackedVector2Array
	var nrm: PackedVector3Array
	var col: PackedColorArray
	var tris: PackedInt32Array
	if s.surface_type == RBSPFile.SurfaceType.PATCH:
		var p := BezierPatch.new()
		p.tessellate(bsp, s, patch_level)
		xyz = p.xyz; st = p.st; lm = p.lm; nrm = p.normal; col = p.color; tris = p.tris
	else:
		xyz = bsp.vert_xyz.slice(s.first_vert, s.first_vert + s.num_verts)
		st = bsp.vert_st.slice(s.first_vert, s.first_vert + s.num_verts)
		lm = bsp.vert_lm.slice(s.first_vert, s.first_vert + s.num_verts)
		nrm = bsp.vert_normal.slice(s.first_vert, s.first_vert + s.num_verts)
		col = bsp.vert_color.slice(s.first_vert, s.first_vert + s.num_verts)
		tris = bsp.indexes.slice(s.first_index, s.first_index + s.num_indexes)

	var flip := _needs_flip(xyz, nrm, tris)
	if flip:
		stats["flipped_surfaces"] += 1
	for i in xyz.size():
		g["pos"].append(JACoords.pos(xyz[i]))
		g["nrm"].append(JACoords.dir(nrm[i]))
		g["uv"].append(st[i])
		g["uv2"].append((page_ofs + lm[i]) * inv_grid)
		g["col"].append(col[i])
	var t := 0
	while t + 2 < tris.size():
		if flip:
			g["idx"].append_array([base + tris[t], base + tris[t + 2], base + tris[t + 1]])
		else:
			g["idx"].append_array([base + tris[t], base + tris[t + 1], base + tris[t + 2]])
		t += 3


## Decides by majority whether a surface's winding disagrees with Godot's
## front-face convention, using the stored vertex normals as reference.
## (Mapping to Godot space is a proper rotation, so it can be decided in
## Quake space.)
static func _needs_flip(xyz: PackedVector3Array, nrm: PackedVector3Array, tris: PackedInt32Array) -> bool:
	var score := 0.0
	var t := 0
	while t + 2 < tris.size():
		var a := xyz[tris[t]]
		var c := (xyz[tris[t + 1]] - a).cross(xyz[tris[t + 2]] - a)
		var n := nrm[tris[t]] + nrm[tris[t + 1]] + nrm[tris[t + 2]]
		score += signf(c.dot(n))
		t += 3
	return score * FRONT_SIGN < 0.0


func _brush_layer(content_flags: int) -> int:
	var layer := 0
	if content_flags & CONTENTS_SOLID:
		layer |= LAYER_SOLID
	if content_flags & CONTENTS_PLAYERCLIP:
		layer |= LAYER_PLAYERCLIP
	if content_flags & CONTENTS_MONSTERCLIP:
		layer |= LAYER_MONSTERCLIP
	if content_flags & CONTENTS_SHOTCLIP:
		layer |= LAYER_SHOTCLIP
	if content_flags & CONTENTS_LADDER:
		layer |= LAYER_LADDER
	return layer


## One CollisionObject per contents mask, one ConvexPolygonShape3D per brush.
## Liquids and triggers become Area3D nodes. If `as_area` is set (trigger
## entities), every brush becomes part of an Area3D.
func _build_brush_collision(bsp: RBSPFile, model: RBSPFile.Model, parent: Node3D, as_area: bool, movable: bool = false) -> void:
	var bodies := {}
	for bi in range(model.first_brush, model.first_brush + model.num_brushes):
		var br := bsp.brushes[bi]
		var contents: int = bsp.shaders[br.shader_num].content_flags if br.shader_num >= 0 and br.shader_num < bsp.shaders.size() else CONTENTS_SOLID
		var kind := ""
		var layer := 0
		if as_area or contents & CONTENTS_TRIGGER:
			kind = "trigger"
		elif contents & (CONTENTS_WATER | CONTENTS_LAVA | CONTENTS_SLIME):
			kind = "lava" if contents & CONTENTS_LAVA else ("slime" if contents & CONTENTS_SLIME else "water")
		else:
			layer = _brush_layer(contents)
			if layer == 0:
				continue
			kind = "solid_%d" % layer
		var points := _brush_points(bsp, br)
		if points.size() < 4:
			continue
		if not bodies.has(kind):
			var body: CollisionObject3D
			if kind.begins_with("solid_"):
				body = AnimatableBody3D.new() if movable else StaticBody3D.new()
				body.collision_layer = layer
				body.collision_mask = 0
			else:
				body = Area3D.new()
				body.collision_layer = 0
				body.collision_mask = LAYER_SOLID | LAYER_PLAYERCLIP
				body.set_meta("volume", kind)
			body.name = kind.capitalize().replace(" ", "")
			body.set_meta("contents", contents)
			parent.add_child(body)
			bodies[kind] = body
		var cs := CollisionShape3D.new()
		var shape := ConvexPolygonShape3D.new()
		shape.points = points
		cs.shape = shape
		cs.name = "Brush%d" % bi
		bodies[kind].add_child(cs)
		stats["brushes"] += 1


## Curved surfaces have no brushes; the original builds collision from the
## patch grid at load time (CM_GeneratePatchCollide). We use the tessellated
## triangles as a concave shape instead.
func _build_patch_collision(bsp: RBSPFile, model: RBSPFile.Model, parent: Node3D, movable: bool) -> void:
	var faces := PackedVector3Array()
	for si in range(model.first_surface, model.first_surface + model.num_surfaces):
		var s := bsp.surfaces[si]
		if s.surface_type != RBSPFile.SurfaceType.PATCH:
			continue
		var sh := bsp.shaders[s.shader_num]
		if not (sh.content_flags & (CONTENTS_SOLID | CONTENTS_PLAYERCLIP)):
			continue
		var def: Q3ShaderLibrary.Def = shaders.get_def(sh.name) if shaders != null else null
		if def != null and def.has_parm("nonsolid"):
			continue
		var p := BezierPatch.new()
		p.tessellate(bsp, s, maxi(2, patch_level / 2))
		for i in p.tris:
			faces.append(JACoords.pos(p.xyz[i]))
	if faces.is_empty():
		return
	var body: CollisionObject3D = AnimatableBody3D.new() if movable else StaticBody3D.new()
	body.name = "Patches"
	body.collision_layer = LAYER_SOLID
	body.collision_mask = 0
	var shape := ConcavePolygonShape3D.new()
	shape.backface_collision = true
	shape.set_faces(faces)
	var cs := CollisionShape3D.new()
	cs.shape = shape
	body.add_child(cs)
	parent.add_child(body)
	stats["patch_collision_triangles"] = stats.get("patch_collision_triangles", 0) + faces.size() / 3


func _brush_points(bsp: RBSPFile, br: RBSPFile.Brush) -> PackedVector3Array:
	var planes: Array[Plane] = []
	for side in range(br.first_side, br.first_side + br.num_sides):
		var pi := bsp.brushside_plane[side]
		planes.append(JACoords.plane(bsp.planes_normal[pi], bsp.planes_dist[pi]))
	return Geometry3D.compute_convex_mesh_points(planes)


func _build_entity(bsp: RBSPFile, index: int, grid: Vector2i) -> Node3D:
	var ent: Dictionary = bsp.entities[index]
	var classname: String = ent.get("classname", "unknown")
	var node := Node3D.new()
	node.name = "%s_%d" % [_safe_name(classname), index]
	node.set_meta("classname", classname)
	node.set_meta("spawn", ent)
	if ent.has("origin"):
		node.position = JACoords.pos(JACoords.parse_vec3(ent["origin"]))
	var model_key: String = ent.get("model", "")
	if index == 0 or not model_key.begins_with("*"):
		node.basis = JACoords.basis_from_angles(JACoords.entity_angles(ent))
		return node
	# Brush entity: geometry in the BSP is already in its local frame.
	var mi := model_key.substr(1).to_int()
	if mi <= 0 or mi >= bsp.models.size():
		return node
	var meshes := _build_model_meshes(bsp, mi, grid)
	meshes.name = "Model"
	node.add_child(meshes)
	var is_trigger := classname.begins_with("trigger_")
	var movable := classname.begins_with("func_") and classname != "func_group" and classname != "func_static"
	_build_brush_collision(bsp, bsp.models[mi], node, is_trigger, movable)
	if not is_trigger:
		_build_patch_collision(bsp, bsp.models[mi], node, movable)
	return node


static func _safe_name(s: String) -> String:
	return s.validate_node_name().replace("/", "_").replace(".", "_")


static func _set_owner_recursive(node: Node, owner: Node) -> void:
	for c in node.get_children():
		c.owner = owner
		_set_owner_recursive(c, owner)
