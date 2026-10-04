class_name BezierPatch
extends RefCounted
## Tessellates Q3/RBSP patch surfaces (MST_PATCH). The control grid is
## width x height (both odd); every 3x3 block sharing edges is a biquadratic
## Bezier patch. The original subdivides adaptively (tr_curve.cpp); a fixed
## level per sub-patch is simpler and looks at least as smooth.

## Output arrays, in Quake space, appended to by tessellate().
var xyz := PackedVector3Array()
var st := PackedVector2Array()
var lm := PackedVector2Array()
var normal := PackedVector3Array()
var color := PackedColorArray()
var tris := PackedInt32Array()    # indices into the arrays above


func tessellate(bsp: RBSPFile, surf: RBSPFile.Surface, level: int = 8) -> void:
	var w := surf.patch_width
	var h := surf.patch_height
	if w < 3 or h < 3 or w % 2 == 0 or h % 2 == 0 or w * h != surf.num_verts:
		push_warning("BezierPatch: bad patch size %dx%d" % [w, h])
		return
	var cols := (w - 1) / 2 * level + 1
	var rows := (h - 1) / 2 * level + 1
	var base := xyz.size()
	var fv := surf.first_vert
	for row in rows:
		var py := mini(row / level, (h - 1) / 2 - 1)
		var ty := float(row - py * level) / level
		for col in cols:
			var px := mini(col / level, (w - 1) / 2 - 1)
			var tx := float(col - px * level) / level
			var v := _eval(bsp, fv, w, px * 2, py * 2, tx, ty)
			xyz.append(v[0])
			st.append(v[1])
			lm.append(v[2])
			normal.append((v[3] as Vector3).normalized())
			color.append(v[4])
	# Winding: same orientation as the control grid quads in the BSP.
	for row in rows - 1:
		for col in cols - 1:
			var a := base + row * cols + col
			var b := a + 1
			var c := a + cols
			var d := c + 1
			tris.append_array([a, c, b, b, c, d])


static func _b(t: float) -> Vector3:
	var it := 1.0 - t
	return Vector3(it * it, 2.0 * it * t, t * t)


func _eval(bsp: RBSPFile, fv: int, w: int, x0: int, y0: int, tx: float, ty: float) -> Array:
	var bx := _b(tx)
	var by := _b(ty)
	var p := Vector3.ZERO
	var s := Vector2.ZERO
	var l := Vector2.ZERO
	var n := Vector3.ZERO
	var c := Color(0, 0, 0, 0)
	for j in 3:
		for i in 3:
			var k := bx[i] * by[j]
			var idx := fv + (y0 + j) * w + (x0 + i)
			p += bsp.vert_xyz[idx] * k
			s += bsp.vert_st[idx] * k
			l += bsp.vert_lm[idx] * k
			n += bsp.vert_normal[idx] * k
			c += bsp.vert_color[idx] * k
	return [p, s, l, n, c]
