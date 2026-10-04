class_name JACollisionWorld
extends RefCounted
## Quake-space box tracing against map brushes, ported from
## code/qcommon/cm_trace.cpp (CM_TraceThroughBrush / CM_TestBoxInBrush).
## Player movement uses this instead of Godot physics so stepping, sliding
## and the SURFACE_CLIP_EPSILON gap behave exactly like the original.
##
## Curved surfaces (patches) have no brushes in the BSP; the original builds
## "facets" from the patch grid (cm_patch.cpp). Here every tessellated patch
## triangle becomes a thin brush with edge and axial bevel planes, which the
## same brush trace then handles.

const SURFACE_CLIP_EPSILON := 0.125
const CELL := 256.0               # broadphase grid cell size (Quake units, XY)
const PATCH_THICKNESS := 1.0
const PATCH_COLLISION_LEVEL := 4

# contents (code/game/surfaceflags.h) and masks (bg_public.h)
const CONTENTS_SOLID := 0x1
const CONTENTS_LAVA := 0x2
const CONTENTS_WATER := 0x4
const CONTENTS_PLAYERCLIP := 0x10
const CONTENTS_MONSTERCLIP := 0x20
const CONTENTS_TRIGGER := 0x400
const CONTENTS_LADDER := 0x2000
const CONTENTS_SLIME := 0x20000
const MASK_PLAYERSOLID := CONTENTS_SOLID | CONTENTS_PLAYERCLIP | 0x100 | 0x1000
const MASK_WATER := CONTENTS_WATER | CONTENTS_LAVA | CONTENTS_SLIME

class Trace:
	var allsolid := false
	var startsolid := false
	var fraction := 1.0
	var endpos := Vector3.ZERO
	var normal := Vector3.ZERO
	var plane_dist := 0.0
	var surface_flags := 0
	var contents := 0
	var brush := -1               # index of the brush hit (-1: none)

# brushes, structure-of-arrays
var brush_contents := PackedInt32Array()
var brush_mins := PackedVector3Array()
var brush_maxs := PackedVector3Array()
var brush_first_plane := PackedInt32Array()
var brush_num_planes := PackedInt32Array()
var brush_model := PackedInt32Array()     # bsp model index (0 = world)
var plane_normal := PackedVector3Array()
var plane_dist := PackedFloat32Array()
var plane_surface_flags := PackedInt32Array()

var _grid: Dictionary = {}     # Vector2i -> PackedInt32Array of brush indices
var _stamp := PackedInt32Array()
var _stamp_id := 0
## brushes of these bsp models are skipped (e.g. an open door, a trigger)
var disabled_models: Dictionary = {}


## Builds from all brushes of the given bsp models (default: every model).
static func from_bsp(bsp: RBSPFile, shaders: Q3ShaderLibrary, models: Array = []) -> JACollisionWorld:
	var w := JACollisionWorld.new()
	var model_list := models if not models.is_empty() else range(bsp.models.size())
	for mi in model_list:
		var m := bsp.models[mi]
		for bi in range(m.first_brush, m.first_brush + m.num_brushes):
			w._add_bsp_brush(bsp, bi, mi)
		w._add_patches(bsp, shaders, m, mi)
	w._build_grid()
	return w


func brush_count() -> int:
	return brush_contents.size()


func _add_bsp_brush(bsp: RBSPFile, bi: int, model: int) -> void:
	var br := bsp.brushes[bi]
	if br.shader_num < 0 or br.shader_num >= bsp.shaders.size():
		return
	var contents := bsp.shaders[br.shader_num].content_flags
	if contents == 0:
		return
	var normals := PackedVector3Array()
	var dists := PackedFloat32Array()
	var flags := PackedInt32Array()
	var gplanes: Array[Plane] = []
	for s in range(br.first_side, br.first_side + br.num_sides):
		var pi := bsp.brushside_plane[s]
		normals.append(bsp.planes_normal[pi])
		dists.append(bsp.planes_dist[pi])
		var sh := bsp.brushside_shader[s]
		flags.append(bsp.shaders[sh].surface_flags if sh >= 0 and sh < bsp.shaders.size() else 0)
		gplanes.append(Plane(bsp.planes_normal[pi], bsp.planes_dist[pi]))
	var pts := Geometry3D.compute_convex_mesh_points(gplanes)
	if pts.size() < 4:
		return
	_add_brush(contents, normals, dists, flags, pts, model)


func _add_brush(contents: int, normals: PackedVector3Array, dists: PackedFloat32Array,
		flags: PackedInt32Array, points: PackedVector3Array, model: int) -> void:
	var mn := points[0]
	var mx := points[0]
	for p in points:
		mn = mn.min(p)
		mx = mx.max(p)
	brush_contents.append(contents)
	brush_mins.append(mn)
	brush_maxs.append(mx)
	brush_first_plane.append(plane_normal.size())
	brush_num_planes.append(normals.size())
	brush_model.append(model)
	plane_normal.append_array(normals)
	plane_dist.append_array(dists)
	plane_surface_flags.append_array(flags)


func _add_patches(bsp: RBSPFile, shaders: Q3ShaderLibrary, m: RBSPFile.Model, mi: int) -> void:
	for si in range(m.first_surface, m.first_surface + m.num_surfaces):
		var s := bsp.surfaces[si]
		if s.surface_type != RBSPFile.SurfaceType.PATCH:
			continue
		var sh := bsp.shaders[s.shader_num]
		var contents := sh.content_flags
		if contents & (CONTENTS_SOLID | CONTENTS_PLAYERCLIP) == 0:
			continue
		var def: Q3ShaderLibrary.Def = shaders.get_def(sh.name) if shaders != null else null
		if def != null and def.has_parm("nonsolid"):
			continue
		var p := BezierPatch.new()
		p.tessellate(bsp, s, PATCH_COLLISION_LEVEL)
		for t in range(0, p.tris.size(), 3):
			_add_facet(p.xyz[p.tris[t]], p.xyz[p.tris[t + 1]], p.xyz[p.tris[t + 2]],
				(p.normal[p.tris[t]] + p.normal[p.tris[t + 1]] + p.normal[p.tris[t + 2]]),
				contents, sh.surface_flags, mi)


## A thin brush for one patch triangle: front face (towards `hint` normal),
## back face, three edge planes and six axial bevels.
func _add_facet(a: Vector3, b: Vector3, c: Vector3, hint: Vector3, contents: int, sflags: int, model: int) -> void:
	var n := (b - a).cross(c - a)
	if n.length_squared() < 1e-8:
		return
	n = n.normalized()
	if n.dot(hint) < 0.0:
		n = -n
	var d := n.dot(a)
	var normals := PackedVector3Array([n, -n])
	var dists := PackedFloat32Array([d, -(d - PATCH_THICKNESS)])
	var tri := [a, b, c]
	for i in 3:
		var p0: Vector3 = tri[i]
		var p1: Vector3 = tri[(i + 1) % 3]
		var p2: Vector3 = tri[(i + 2) % 3]
		var en := n.cross(p1 - p0).normalized()
		if en.dot(p2 - p0) > 0.0:
			en = -en
		normals.append(en)
		dists.append(en.dot(p0))
	var back := n * PATCH_THICKNESS
	var pts := PackedVector3Array([a, b, c, a - back, b - back, c - back])
	var mn := pts[0]
	var mx := pts[0]
	for p in pts:
		mn = mn.min(p)
		mx = mx.max(p)
	for axis in 3:
		var e := Vector3.ZERO
		e[axis] = 1.0
		normals.append(e)
		dists.append(mx[axis])
		normals.append(-e)
		dists.append(-mn[axis])
	var flags := PackedInt32Array()
	flags.resize(normals.size())
	flags.fill(sflags)
	_add_brush(contents, normals, dists, flags, pts, model)


func _build_grid() -> void:
	_grid.clear()
	for i in brush_contents.size():
		var c0 := _cell(brush_mins[i])
		var c1 := _cell(brush_maxs[i])
		for x in range(c0.x, c1.x + 1):
			for y in range(c0.y, c1.y + 1):
				var k := Vector2i(x, y)
				if not _grid.has(k):
					_grid[k] = PackedInt32Array()
				var arr: PackedInt32Array = _grid[k]
				arr.append(i)
				_grid[k] = arr
	_stamp.resize(brush_contents.size())
	_stamp.fill(0)


static func _cell(p: Vector3) -> Vector2i:
	return Vector2i(floori(p.x / CELL), floori(p.y / CELL))


## Box trace from start to end (CM_BoxTrace). mins/maxs are relative to the
## origin. Only brushes with contents & mask are considered.
func trace(start: Vector3, end: Vector3, mins: Vector3, maxs: Vector3, mask: int) -> Trace:
	var tr := Trace.new()
	# Symmetric box around a shifted origin, as CM_Trace does.
	var offset := (mins + maxs) * 0.5
	var size_min := mins - offset
	var size_max := maxs - offset
	var s := start + offset
	var e := end + offset
	var bmin := s.min(e) + size_min - Vector3.ONE
	var bmax := s.max(e) + size_max + Vector3.ONE
	var point := size_min == Vector3.ZERO and size_max == Vector3.ZERO

	_stamp_id += 1
	var c0 := _cell(bmin)
	var c1 := _cell(bmax)
	for x in range(c0.x, c1.x + 1):
		for y in range(c0.y, c1.y + 1):
			var cell = _grid.get(Vector2i(x, y))
			if cell == null:
				continue
			for bi in cell:
				if _stamp[bi] == _stamp_id:
					continue
				_stamp[bi] = _stamp_id
				if brush_contents[bi] & mask == 0 or disabled_models.has(brush_model[bi]):
					continue
				if bmin.x > brush_maxs[bi].x or bmin.y > brush_maxs[bi].y or bmin.z > brush_maxs[bi].z \
						or bmax.x < brush_mins[bi].x or bmax.y < brush_mins[bi].y or bmax.z < brush_mins[bi].z:
					continue
				if s == e:
					_test_box_in_brush(tr, bi, s, size_min, size_max)
				else:
					_trace_through_brush(tr, bi, s, e, size_min, size_max, point)
				if tr.allsolid:
					break
	if tr.fraction == 1.0:
		tr.endpos = end
	else:
		tr.endpos = start + (end - start) * tr.fraction
	return tr


## Contents of all brushes containing `p` (CM_PointContents).
func point_contents(p: Vector3, mask: int = -1) -> int:
	var contents := 0
	var cell = _grid.get(_cell(p))
	if cell == null:
		return 0
	for bi in cell:
		if brush_contents[bi] & mask == 0 or disabled_models.has(brush_model[bi]):
			continue
		var mn := brush_mins[bi]
		var mx := brush_maxs[bi]
		if p.x < mn.x or p.y < mn.y or p.z < mn.z or p.x > mx.x or p.y > mx.y or p.z > mx.z:
			continue
		var inside := true
		var fp := brush_first_plane[bi]
		for i in range(fp, fp + brush_num_planes[bi]):
			if plane_normal[i].dot(p) - plane_dist[i] > 0.0:
				inside = false
				break
		if inside:
			contents |= brush_contents[bi]
	return contents


static func _offset_for(n: Vector3, size_min: Vector3, size_max: Vector3) -> float:
	# tw->offsets[plane->signbits]: maxs on axes where the normal is negative
	return (size_max.x if n.x < 0.0 else size_min.x) * n.x \
		+ (size_max.y if n.y < 0.0 else size_min.y) * n.y \
		+ (size_max.z if n.z < 0.0 else size_min.z) * n.z


func _test_box_in_brush(tr: Trace, bi: int, s: Vector3, size_min: Vector3, size_max: Vector3) -> void:
	var fp := brush_first_plane[bi]
	for i in range(fp, fp + brush_num_planes[bi]):
		var n := plane_normal[i]
		var dist := plane_dist[i] - _offset_for(n, size_min, size_max)
		if n.dot(s) - dist > 0.0:
			return
	tr.startsolid = true
	tr.allsolid = true
	tr.fraction = 0.0
	tr.contents = brush_contents[bi]
	tr.brush = bi


func _trace_through_brush(tr: Trace, bi: int, s: Vector3, e: Vector3, size_min: Vector3, size_max: Vector3, point: bool) -> void:
	var enter_frac := -1.0
	var leave_frac := 1.0
	var clip := -1
	var getout := false
	var startout := false
	var fp := brush_first_plane[bi]
	for i in range(fp, fp + brush_num_planes[bi]):
		var n := plane_normal[i]
		var dist := plane_dist[i]
		if not point:
			dist -= _offset_for(n, size_min, size_max)
		var d1 := n.dot(s) - dist
		var d2 := n.dot(e) - dist
		if d2 > 0.0:
			getout = true
		if d1 > 0.0:
			startout = true
		if d1 > 0.0 and (d2 >= SURFACE_CLIP_EPSILON or d2 >= d1):
			return
		if d1 <= 0.0 and d2 <= 0.0:
			continue
		if d1 > d2:
			var f := maxf((d1 - SURFACE_CLIP_EPSILON) / (d1 - d2), 0.0)
			if f > enter_frac:
				enter_frac = f
				clip = i
		else:
			var f := minf((d1 + SURFACE_CLIP_EPSILON) / (d1 - d2), 1.0)
			if f < leave_frac:
				leave_frac = f
	if not startout:
		tr.startsolid = true
		tr.contents |= brush_contents[bi]
		if not getout:
			tr.allsolid = true
			tr.fraction = 0.0
			tr.brush = bi
		return
	if enter_frac < leave_frac and enter_frac > -1.0 and enter_frac < tr.fraction:
		tr.fraction = maxf(enter_frac, 0.0)
		tr.normal = plane_normal[clip]
		tr.plane_dist = plane_dist[clip]
		tr.surface_flags = plane_surface_flags[clip]
		tr.contents = brush_contents[bi]
		tr.brush = bi
