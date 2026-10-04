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
	_check(bsp.models.size() == 3, "models lump")
	_check(bsp.brushes.size() == 10, "brush lump")
	_check(bsp.lightmaps.size() == 1, "lightmap lump")
	_check(bsp.entities.size() == 6, "entity lump")
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
	_check(builder.stats["brushes"] == 10, "all brushes converted")

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
