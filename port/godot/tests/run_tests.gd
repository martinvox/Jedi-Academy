extends SceneTree
## Headless test runner:
##   godot --headless --path port/godot -s res://tests/run_tests.gd
## Uses the synthetic install in tests/fixtures/gamedata (regenerate with
## port/tools/make_test_map.py). Exits non-zero on failure.

const FIXTURE := "res://tests/fixtures/gamedata"

var _failures := 0
var _checks := 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var gamedata := ProjectSettings.globalize_path(FIXTURE)
	var vfs := JAVfs.new()
	_check(vfs.mount_game_dir(gamedata, "base") == OK, "mount base")
	test_vfs(vfs)
	var bsp := test_rbsp(vfs)
	var lib := test_shaders(vfs)
	_check(bsp != null and lib != null, "parsers completed without script errors")
	test_winding_convention()
	test_angles()
	if bsp != null:
		await test_builder(vfs, lib, bsp)
		test_collision(lib, bsp)
		test_pmove(lib, bsp)
		test_game(lib, bsp)
	print("\n%d checks, %d failures" % [_checks, _failures])
	quit(1 if _failures > 0 else 0)


func _check(cond: bool, what: String) -> void:
	_checks += 1
	if not cond:
		_failures += 1
		printerr("FAIL: " + what)
	else:
		print("ok   " + what)


func _near(a: float, b: float, eps: float = 1e-3) -> bool:
	return absf(a - b) <= eps


func test_vfs(vfs: JAVfs) -> void:
	_check(vfs.exists("maps/test.bsp"), "vfs finds map")
	_check(vfs.exists("MAPS\\Test.BSP"), "vfs is case-insensitive")
	_check(vfs.find_image("textures/test/wall") == "textures/test/wall.png", "find_image tries extensions")
	_check(vfs.find_image("textures/test/floor.jpg") == "textures/test/floor.tga", "find_image swaps extension")
	_check(vfs.list_files("shaders", "shader").size() == 1, "list_files")
	var img := Image.new()
	img.load_tga_from_buffer(vfs.read_file("textures/test/floor.tga"))
	_check(img.get_pixel(0, 0).g > 0.9 and img.get_pixel(0, 0).r < 0.1, "later pk3 overrides earlier pk3")


func test_rbsp(vfs: JAVfs) -> RBSPFile:
	var bsp := RBSPFile.new()
	var err := bsp.parse(vfs.read_file("maps/test.bsp"))
	_check(err == OK, "rbsp parses (%s)" % bsp.error)
	if err != OK:
		return null
	_check(bsp.shaders.size() == 7, "shader lump")
	_check(bsp.models.size() == 6, "models lump")
	_check(bsp.brushes.size() == 15, "brush lump")
	_check(bsp.lightmaps.size() == 1, "lightmap lump")
	_check(bsp.entities.size() == 11, "entity lump")
	_check(bsp.entities[0].get("message") == "Test map", "worldspawn keys")
	_check(bsp.surfaces[6].surface_type == RBSPFile.SurfaceType.PATCH and bsp.surfaces[6].patch_width == 3, "patch surface")
	_check(bsp.surfaces[7].lightmap_num[0] == RBSPFile.LIGHTMAP_BY_VERTEX, "vertex-lit soup")
	var bad := RBSPFile.new()
	_check(bad.parse(PackedByteArray([1, 2, 3])) != OK, "rejects garbage")
	return bsp


func test_shaders(vfs: JAVfs) -> Q3ShaderLibrary:
	var lib := Q3ShaderLibrary.new()
	lib.load_from_vfs(vfs)
	var glass := lib.get_def("textures/test/glass")
	_check(glass != null, "shader defined")
	if glass != null:
		_check(glass.cull == "none", "cull none")
		_check(glass.base_blend() == Q3ShaderLibrary.Blend.ALPHA, "blendFunc alpha")
		_check(glass.diffuse_stage().map == "textures/test/wall", "stage map")
		_check(glass.diffuse_stage().tc_mods.size() == 1, "tcMod kept")
	_check(lib.get_def("textures/test/ignored") == null, "block comments skipped")
	_check(lib.get_def("textures/test/sky").has_parm("sky"), "surfaceparm")
	_check(lib.get_def("TEXTURES/TEST/SKY.tga") != null, "lookup ignores case and extension")
	return lib


## Pins down Godot's front-face convention that JAMapBuilder.FRONT_SIGN
## relies on: SurfaceTool generates normals pointing out of front faces.
func test_winding_convention() -> void:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var a := Vector3(0, 0, 0)
	var b := Vector3(1, 0, 0)
	var c := Vector3(0, 0, 1)
	st.add_vertex(a)
	st.add_vertex(b)
	st.add_vertex(c)
	st.generate_normals()
	var arrays := st.commit_to_arrays()
	var n: Vector3 = arrays[Mesh.ARRAY_NORMAL][0]
	var geometric := (b - a).cross(c - a)
	_check(signf(geometric.dot(n)) == JAMapBuilder.FRONT_SIGN, "Godot front-face winding matches FRONT_SIGN")


func test_angles() -> void:
	var b := JACoords.basis_from_angles(Vector3(0, 90, 0))
	_check(b.x.is_equal_approx(Vector3(0, 0, -1)), "yaw 90 faces Quake +Y (Godot -Z)")
	b = JACoords.basis_from_angles(Vector3(45, 0, 0))
	var f := b.x
	_check(_near(f.y, -sin(deg_to_rad(45))), "positive pitch looks down")
	_check(JACoords.pos(Vector3(0, 0, 100)).is_equal_approx(Vector3(0, 2.54, 0)), "Z-up to Y-up, inches to metres")


func test_builder(vfs: JAVfs, lib: Q3ShaderLibrary, bsp: RBSPFile) -> void:
	var builder := JAMapBuilder.new(vfs, lib)
	var map := builder.build(bsp, "maps/test.bsp")
	print("     stats: ", builder.stats)
	var world := map.get_node("World")
	_check(world.get_child_count() >= 3, "world meshes grouped by material")
	_check(not world.has_node("textures_test_sky"), "sky surface not drawn")
	_check(builder.stats["sky_shaders"].has("textures/test/sky"), "sky shader recorded")
	_check(builder.stats["brushes"] == 15, "all brushes converted")

	# triangle winding of every output mesh agrees with its normals
	var wrong := 0
	for mi in world.get_children():
		var arr: Array = (mi as MeshInstance3D).mesh.surface_get_arrays(0)
		var p: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
		var nn: PackedVector3Array = arr[Mesh.ARRAY_NORMAL]
		var idx: PackedInt32Array = arr[Mesh.ARRAY_INDEX]
		for t in range(0, idx.size(), 3):
			var g := (p[idx[t + 1]] - p[idx[t]]).cross(p[idx[t + 2]] - p[idx[t]])
			if signf(g.dot(nn[idx[t]])) != JAMapBuilder.FRONT_SIGN:
				wrong += 1
	_check(wrong == 0, "output winding is front-facing (%d wrong)" % wrong)

	var glass := world.get_node_or_null("textures_test_glass") as MeshInstance3D
	_check(glass != null, "glass mesh exists")
	if glass != null:
		var mat := glass.mesh.surface_get_material(0) as ShaderMaterial
		_check(mat.shader.code.contains("cull_disabled") and mat.shader.code.contains("blend_mix"), "glass material is two-sided and blended")
		_check(mat.get_shader_parameter("light_mode") == JAMaterials.LightMode.VERTEX, "vertex-lit surface uses vertex light")
	var floor_mi := world.get_node_or_null("textures_test_floor") as MeshInstance3D
	_check(floor_mi != null, "floor mesh exists")
	if floor_mi != null:
		var tex := (floor_mi.mesh.surface_get_material(0) as ShaderMaterial).get_shader_parameter("albedo_tex") as Texture2D
		_check(tex != null and tex.get_image().get_pixel(0, 0).g > 0.9, "floor texture from overriding pk3")
		var uv2: PackedVector2Array = floor_mi.mesh.surface_get_arrays(0)[Mesh.ARRAY_TEX_UV2]
		var inside := true
		for v in uv2:
			inside = inside and v.x >= 0.0 and v.x <= 1.0 and v.y >= 0.0 and v.y <= 1.0
		_check(inside, "lightmap UVs inside atlas")

	var ents := map.get_node("Entities")
	var start := ents.get_node_or_null("info_player_start_1") as Node3D
	_check(start != null and start.position.is_equal_approx(JACoords.pos(Vector3(0, -128, 24))), "entity origin converted")
	var door := ents.get_node_or_null("func_door_2")
	_check(door != null and door.get_node_or_null("Model") != null, "brush entity has its own mesh")
	_check(door != null and door.get_children().any(func(c): return c is AnimatableBody3D), "door collision is movable")
	var trig := ents.get_node_or_null("trigger_multiple_3")
	_check(trig != null and trig.get_children().any(func(c): return c is Area3D), "trigger becomes Area3D")
	var coll := map.get_node("Collision")
	_check(coll.get_children().any(func(c): return c is Area3D and c.get_meta("volume") == "water"), "water volume")
	_check(coll.get_children().any(func(c): return c is StaticBody3D and c.collision_layer == JAMapBuilder.LAYER_PLAYERCLIP), "player clip layer")

	# physics: drop rays onto the converted world
	root.add_child(map)
	await physics_frame
	await physics_frame
	var space := map.get_world_3d().direct_space_state
	var hit := _ray(space, JACoords.pos(Vector3(0, -128, 100)), JACoords.pos(Vector3(0, -128, -100)), JAMapBuilder.LAYER_SOLID)
	_check(not hit.is_empty() and _near(hit.position.y, 0.0), "ray hits brush floor at z=0")
	hit = _ray(space, JACoords.pos(Vector3(0, 128, 100)), JACoords.pos(Vector3(0, 128, -100)), JAMapBuilder.LAYER_SOLID)
	_check(not hit.is_empty() and _near(hit.position.y, 16 * JACoords.SCALE, 0.01), "ray hits patch hump at z=16")
	hit = _ray(space, JACoords.pos(Vector3(-175, -175, 200)), JACoords.pos(Vector3(-175, -175, -100)), JAMapBuilder.LAYER_PLAYERCLIP)
	_check(not hit.is_empty() and _near(hit.position.y, 128 * JACoords.SCALE), "player clip blocks players")
	map.queue_free()


func _ray(space: PhysicsDirectSpaceState3D, from: Vector3, to: Vector3, mask: int) -> Dictionary:
	var q := PhysicsRayQueryParameters3D.create(from, to, mask)
	return space.intersect_ray(q)


func test_collision(lib: Q3ShaderLibrary, bsp: RBSPFile) -> void:
	var w := JACollisionWorld.from_bsp(bsp, lib)
	var box_min := Vector3(-16, -16, -24)
	var box_max := Vector3(16, 16, 40)
	var tr := w.trace(Vector3(0, -128, 100), Vector3(0, -128, -100), box_min, box_max, JACollisionWorld.MASK_PLAYERSOLID)
	_check(tr.fraction < 1.0 and _near(tr.endpos.z, 24.0, 0.2) and tr.normal.is_equal_approx(Vector3(0, 0, 1)), "box trace lands on floor (z=%.3f)" % tr.endpos.z)
	_check(tr.endpos.z > 24.0, "SURFACE_CLIP_EPSILON gap kept")
	tr = w.trace(Vector3(0, -128, 30), Vector3(1000, -128, 30), box_min, box_max, JACollisionWorld.MASK_PLAYERSOLID)
	_check(_near(tr.endpos.x, 256 - 16, 0.2) and tr.normal.is_equal_approx(Vector3(-1, 0, 0)), "box trace stops at wall")
	tr = w.trace(Vector3(0, -128, 10), Vector3(0, -128, 10), box_min, box_max, JACollisionWorld.MASK_PLAYERSOLID)
	_check(tr.startsolid and tr.allsolid, "box inside floor is allsolid")
	tr = w.trace(Vector3(0, 128, 100), Vector3(0, 128, -100), Vector3.ZERO, Vector3.ZERO, JACollisionWorld.MASK_PLAYERSOLID)
	_check(tr.fraction < 1.0 and _near(tr.endpos.z, 16.0, 1.0), "point trace hits patch hump (z=%.2f)" % tr.endpos.z)
	_check(w.point_contents(Vector3(200, 200, 10)) & JACollisionWorld.CONTENTS_WATER, "point contents: water")
	tr = w.trace(Vector3(-175, -175, 200), Vector3(-175, -175, 0), box_min, box_max, JACollisionWorld.MASK_PLAYERSOLID)
	_check(_near(tr.endpos.z, 128 + 24, 0.2), "player clip blocks player box")
	tr = w.trace(Vector3(-175, -175, 200), Vector3(-175, -175, 0), box_min, box_max, JACollisionWorld.CONTENTS_SOLID)
	_check(tr.endpos.z < 30, "player clip ignored by solid-only mask")


func _sim(pm: JAPmove, ms: int, fwd: int = 0, right: int = 0, up: int = 0, yaw: float = 0.0) -> void:
	var t := 0
	while t < ms:
		var cmd := JAPmove.UserCmd.new()
		cmd.msec = 16 if t % 50 != 48 else 18
		cmd.forwardmove = fwd
		cmd.rightmove = right
		cmd.upmove = up
		cmd.viewangles = Vector3(0, yaw, 0)
		pm.pmove(cmd)
		t += cmd.msec


func test_pmove(lib: Q3ShaderLibrary, bsp: RBSPFile) -> void:
	var w := JACollisionWorld.from_bsp(bsp, lib, [0])
	var pm := JAPmove.new(w)
	pm.origin = Vector3(0, -128, 60)
	_sim(pm, 1500)
	_check(pm.on_ground and _near(pm.origin.z, 24.125, 0.1), "falls and lands on floor (z=%.3f)" % pm.origin.z)

	pm.origin = Vector3(-200, -60, 24.125)
	pm.velocity = Vector3.ZERO
	_sim(pm, 1000, 127)
	var hv := Vector2(pm.velocity.x, pm.velocity.y).length()
	_check(_near(hv, 250.0, 2.0), "runs at g_speed 250 (%.1f)" % hv)
	_check(absf(pm.origin.y + 60) < 0.01 and pm.origin.x > -200 + 150, "runs along yaw 0 = +X")

	_sim(pm, 1000)
	_check(Vector2(pm.velocity.x, pm.velocity.y).length() < 1.0, "friction stops the player")

	pm.origin = Vector3(-100, -60, 24.125)
	pm.velocity = Vector3.ZERO
	_sim(pm, 50)
	var top := pm.origin.z
	var t := 0
	while t < 1500:
		var cmd := JAPmove.UserCmd.new()
		cmd.msec = 10
		cmd.upmove = 127
		pm.pmove(cmd)
		top = maxf(top, pm.origin.z)
		t += 10
	var expected := JAPmove.JUMP_VELOCITY * JAPmove.JUMP_VELOCITY / (2.0 * pm.gravity)
	_check(_near(top - 24.125, expected, 2.0), "jump height %.1f ~ v^2/2g %.1f" % [top - 24.125, expected])
	_check(pm.on_ground, "lands after jump and does not re-jump while held")

	pm.origin = Vector3(0, -128, 24.125)
	pm.velocity = Vector3.ZERO
	_sim(pm, 2000, 127)
	_check(_near(pm.origin.x, 256 - 16 - 0.125, 0.2), "stops at wall (x=%.2f)" % pm.origin.x)

	pm.origin = Vector3(60, -200, 24.125)
	pm.velocity = Vector3.ZERO
	_sim(pm, 400, 127)
	_check(pm.origin.z > 16 + 24 - 0.5 and pm.origin.x > 100, "steps up a 16-unit step (z=%.2f)" % pm.origin.z)

	pm.origin = Vector3(-200, 0, 24.125)
	pm.velocity = Vector3.ZERO
	_sim(pm, 1500, 0, 0, 0, 0.0)
	_sim(pm, 1500, 127, 0, 0, 90.0)
	_check(pm.origin.z < 30 and pm.origin.y < 50 - 16 + 0.5, "cannot step a 32-unit block (y=%.2f z=%.2f)" % [pm.origin.y, pm.origin.z])

	pm.origin = Vector3(0, -128, 24.125)
	_sim(pm, 200, 0, 0, -127)
	_check(pm.pm_flags & JAPmove.PMF_DUCKED and pm.maxs.z == JAPmove.CROUCH_MAXS_2, "crouch shrinks the box")
	pm.velocity = Vector3.ZERO
	_sim(pm, 1000, 127, 0, -127, 180.0)
	var chv := Vector2(pm.velocity.x, pm.velocity.y).length()
	_check(_near(chv, 125.0, 2.0), "crouch speed is half (%.1f)" % chv)
	_sim(pm, 200)
	_check(not (pm.pm_flags & JAPmove.PMF_DUCKED), "stands up again")

	pm.origin = Vector3(200, 200, 24.125)
	pm.velocity = Vector3.ZERO
	_sim(pm, 100)
	_check(pm.waterlevel >= 1, "water level detected (%d)" % pm.waterlevel)

	pm.origin = Vector3(-60, 128, 80)
	pm.velocity = Vector3.ZERO
	_sim(pm, 1500)
	_check(pm.on_ground and pm.origin.z > 24.125 + 10.0, "stands on the curved patch (z=%.2f)" % pm.origin.z)


func _frames(g: JAGameWorld, ms: int, fwd: int = 0, yaw: float = 0.0) -> void:
	var t := 0
	while t < ms:
		var cmd := JAPmove.UserCmd.new()
		cmd.msec = 16
		cmd.forwardmove = fwd
		cmd.viewangles = Vector3(0, yaw, 0)
		g.run_frame(cmd.msec)
		g.pm.pmove(cmd)
		g.touch_triggers()
		t += 16


func test_game(lib: Q3ShaderLibrary, bsp: RBSPFile) -> void:
	var g := JAGameWorld.new()
	g.setup(bsp, lib, {})
	var pm := JAPmove.new(g.world)
	g.pm = pm
	var door := g.entity_by_name("door1")
	_check(door != null and door.is_mover and door.pos2.is_equal_approx(Vector3(0, 8, 0)), "func_door pos2 = movedir * (size - lip)")
	_check(g.ents.any(func(e): return e.classname == "trigger_door"), "touch door spawned its trigger")

	# stand clear of everything and let the world settle
	pm.origin = Vector3(-200, -60, 24.125)
	_frames(g, 300)
	_check(door.state == JAGameWorld.MoverState.POS1, "targeted door stays closed")

	# trigger_multiple *2 targets door1
	pm.origin = Vector3(-40, -40, 24.125)
	_frames(g, 32)
	_check(door.state == JAGameWorld.MoverState.ONE_TO_TWO, "trigger_multiple opens the door")
	pm.origin = Vector3(-200, -60, 24.125)
	_frames(g, 1000)
	_check(door.state == JAGameWorld.MoverState.POS2 and door.origin.is_equal_approx(door.pos2), "door reaches open position")
	_check(g.world.model_offset[door.model].is_equal_approx(door.pos2), "door collision moved with it")
	_frames(g, 2500)
	_check(door.state == JAGameWorld.MoverState.POS1, "door returns after wait")

	# door pushes the player standing in its way
	pm.origin = Vector3(4, 8 + 16 + 0.5, 24.125)
	pm.velocity = Vector3.ZERO
	g.use(door, null, pm)
	_frames(g, 1000)
	_check(pm.origin.y > 8 + 8 + 16 - 0.1, "opening door pushes the player (y=%.2f)" % pm.origin.y)

	# touch door opens when approached
	var tdoor: JAGameWorld.GEnt = g.ents.filter(func(e): return e.classname == "func_door" and e.targetname.is_empty())[0]
	pm.origin = Vector3(-120, 228, 24.125)
	pm.velocity = Vector3.ZERO
	_frames(g, 48)
	_check(tdoor.state == JAGameWorld.MoverState.ONE_TO_TWO or tdoor.state == JAGameWorld.MoverState.POS2, "touch door opens on approach")

	# teleporter
	pm.origin = Vector3(210, -70, 24.125)
	pm.velocity = Vector3(100, 0, 0)
	var teleported := []
	g.teleport_callback = func(o, a): teleported.append(a)
	_frames(g, 16)
	_check(pm.origin.distance_to(Vector3(-100, 100, 31)) < 1.0 or (teleported.size() == 1 and absf(pm.origin.x + 100) < 2.0), "trigger_teleport moves the player (%s)" % pm.origin)
	_check(teleported.size() == 1 and teleported[0].y == 180.0, "teleport sets view angles")

	# jump pad
	pm.origin = Vector3(-90, -225, 24.125)
	pm.velocity = Vector3.ZERO
	var apex := 0.0
	var t := 0
	while t < 1500:
		var cmd := JAPmove.UserCmd.new()
		cmd.msec = 16
		g.run_frame(16)
		pm.pmove(cmd)
		g.touch_triggers()
		apex = maxf(apex, pm.origin.z)
		t += 16
	_check(apex > 190.0 and apex < 230.0, "trigger_push throws the player to the target apex (%.1f)" % apex)
