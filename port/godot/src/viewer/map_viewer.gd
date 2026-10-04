extends Node3D
## Map viewer / walk test (milestones 1-2).
## After loading, you walk the map with the ported player movement; F toggles
## the free-fly camera, T first/third person, V noclip, Tab the map list.
##
## Command line (after "--"):
##   --gamedata=<path to GameData>   folder that contains "base"
##   --game=<mod dir>                optional mod folder mounted over base
##   --map=<name>                    e.g. "mp/ffa_bespin" or "t1_sour"
##   --quit-after-load               load, print stats, exit (smoke test)
##   --view="x y z pitch yaw"        start camera here (Quake coordinates)
##   --screenshot=<file.png>         load, render a few frames, save, exit
## Without --gamedata the last path is taken from user://ja_port.cfg, or a
## setup panel asks for it.

const CONFIG_PATH := "user://ja_port.cfg"

@onready var camera: FreeFlyCamera = $Camera
@onready var world_env: WorldEnvironment = $WorldEnvironment
@onready var hud: Label = $UI/Hud

var vfs: JAVfs
var shaders: Q3ShaderLibrary
var map_root: Node3D
var player: JAPlayer
var collision: JACollisionWorld
var _status_text := ""
var _setup: Control
var _args := {}


func _ready() -> void:
	_args = _parse_args(OS.get_cmdline_user_args())
	var cfg := ConfigFile.new()
	cfg.load(CONFIG_PATH)
	var gamedata: String = _args.get("gamedata", cfg.get_value("paths", "gamedata", ""))
	var mod: String = _args.get("game", cfg.get_value("paths", "game", ""))
	if not gamedata.is_empty() and _mount(gamedata, mod):
		if _args.has("map"):
			_load_map.call_deferred(_args["map"])
			return
		_show_setup(gamedata)
	else:
		_show_setup(gamedata)


func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey and event.pressed and not event.echo):
		return
	if event.keycode == KEY_TAB and vfs != null:
		_show_setup(_current_gamedata())
	elif event.keycode == KEY_F and player != null:
		_set_fly_mode(not camera.current)


func _set_fly_mode(fly: bool) -> void:
	if fly:
		camera.global_transform = player.camera.global_transform
		var e := camera.global_basis.get_euler()
		camera.set_view(camera.global_position, rad_to_deg(e.y) + 90.0, -rad_to_deg(e.x))
		camera.make_current()
	else:
		player.make_current()


func _process(_delta: float) -> void:
	if player != null and _setup == null:
		var mode := "fly camera (F to walk)" if camera.current else ("walking" + ("  noclip" if player.pm.noclip else ""))
		hud.text = _status_text + "\n" + mode + "  |  " + player.debug_text()


func _parse_args(args: PackedStringArray) -> Dictionary:
	var out := {}
	for a in args:
		if a.begins_with("--"):
			var kv := a.substr(2).split("=", true, 1)
			out[kv[0]] = kv[1] if kv.size() > 1 else "1"
	return out


func _mount(gamedata: String, mod: String) -> bool:
	var v := JAVfs.new()
	if v.mount_game_dir(gamedata, "base") != OK:
		return false
	if not mod.is_empty():
		v.mount_game_dir(gamedata, mod)
	vfs = v
	vfs.set_meta("gamedata", gamedata)
	shaders = Q3ShaderLibrary.new()
	var t := Time.get_ticks_msec()
	shaders.load_from_vfs(vfs)
	print("Mounted %s: %d files, %d shaders (%d ms)" % [gamedata, vfs.file_count(), shaders.defs.size(), Time.get_ticks_msec() - t])
	var cfg := ConfigFile.new()
	cfg.load(CONFIG_PATH)
	cfg.set_value("paths", "gamedata", gamedata)
	cfg.set_value("paths", "game", mod)
	cfg.save(CONFIG_PATH)
	return true


func _current_gamedata() -> String:
	return vfs.get_meta("gamedata", "") if vfs != null else ""


func _load_map(name: String) -> void:
	if _setup != null:
		_setup.queue_free()
		_setup = null
	var path := name if name.begins_with("maps/") else "maps/" + name
	if not path.ends_with(".bsp"):
		path += ".bsp"
	hud.text = "Loading %s ..." % path
	await get_tree().process_frame

	var t0 := Time.get_ticks_msec()
	var bsp := RBSPFile.new()
	var err := bsp.parse(vfs.read_file(path))
	if err != OK:
		hud.text = "Failed to load %s: %s" % [path, bsp.error]
		push_error(hud.text)
		if _args.has("quit-after-load"):
			get_tree().quit(1)
		return
	var t1 := Time.get_ticks_msec()
	var builder := JAMapBuilder.new(vfs, shaders)
	var root := builder.build(bsp, path)
	var t2 := Time.get_ticks_msec()

	if map_root != null:
		map_root.queue_free()
	map_root = root
	add_child(map_root)
	world_env.environment = JAEnvironment.create(vfs, shaders, builder.stats["sky_shaders"])
	_place_camera(bsp)
	var t3 := Time.get_ticks_msec()
	collision = JACollisionWorld.from_bsp(bsp, shaders, solid_models(bsp))
	print("collision world: %d brushes (%d ms)" % [collision.brush_count(), Time.get_ticks_msec() - t3])
	_spawn_player(bsp)
	if _args.has("view"):
		_set_fly_mode(true)

	var s := builder.stats
	_status_text = "%s  |  %d tris, %d materials, %d brushes, %d entities, %d missing textures, parse %d ms, build %d ms\nWASD move, Space jump, C crouch, Shift walk, T 1st/3rd person, V noclip, F fly camera, Tab maps, Esc mouse" % [
		path, s["triangles"], s["materials"], s["brushes"], s["entities"], s["missing_textures"], t1 - t0, t2 - t1]
	hud.text = _status_text
	print(_status_text)
	print("stats: ", s)
	if builder.materials.missing_textures.size() > 0:
		print("missing textures (first 20): ", builder.materials.missing_textures.slice(0, 20))
	if _args.has("screenshot"):
		for i in 10:
			await get_tree().process_frame
		await RenderingServer.frame_post_draw
		var img := get_viewport().get_texture().get_image()
		img.save_png(_args["screenshot"])
		print("screenshot saved to ", _args["screenshot"])
	if _args.has("quit-after-load") or _args.has("screenshot"):
		get_tree().quit(0)


## bsp models the player collides with: the world and every brush entity
## except triggers (doors start closed until movers are ported).
static func solid_models(bsp: RBSPFile) -> Array:
	var models := [0]
	for ent in bsp.entities:
		var m: String = ent.get("model", "")
		var cls: String = ent.get("classname", "")
		if m.begins_with("*") and not cls.begins_with("trigger_"):
			models.append(m.substr(1).to_int())
	return models


func _spawn_point(bsp: RBSPFile) -> Array:
	for cls in ["info_player_start", "info_player_deathmatch", "info_player_duel", "info_player_intermission"]:
		for ent in bsp.entities:
			if ent.get("classname") == cls and ent.has("origin"):
				return [JACoords.parse_vec3(ent["origin"]), JACoords.entity_angles(ent).y]
	var m := bsp.models[0]
	return [(m.mins + m.maxs) * 0.5, 0.0]


func _spawn_player(bsp: RBSPFile) -> void:
	if player != null:
		player.queue_free()
	player = JAPlayer.new()
	player.name = "Player"
	add_child(player)
	var sp := _spawn_point(bsp)
	# SelectSpawnPoint raises the origin 9 units so the box does not start in the floor
	player.setup(collision, sp[0] + Vector3(0, 0, 9), sp[1])
	player.make_current()


func _place_camera(bsp: RBSPFile) -> void:
	if _args.has("view"):
		var v: PackedFloat64Array = (_args["view"] as String).split_floats(" ", false)
		if v.size() >= 5:
			camera.set_view(JACoords.pos(Vector3(v[0], v[1], v[2])), v[4], v[3])
			return
	for cls in ["info_player_start", "info_player_deathmatch", "info_player_duel", "info_player_intermission"]:
		for ent in bsp.entities:
			if ent.get("classname") == cls and ent.has("origin"):
				var o := JACoords.parse_vec3(ent["origin"])
				var ang := JACoords.entity_angles(ent)
				# eye height: DEFAULT_VIEWHEIGHT is 26 above the origin
				camera.set_view(JACoords.pos(o + Vector3(0, 0, 26)), ang.y, ang.x)
				return
	var m := bsp.models[0]
	camera.set_view(JACoords.pos((m.mins + m.maxs) * 0.5), 0.0)


func _show_setup(gamedata: String) -> void:
	if _setup != null:
		_setup.queue_free()
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	var panel := PanelContainer.new()
	panel.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	panel.custom_minimum_size = Vector2(640, 480)
	var box := VBoxContainer.new()
	panel.add_child(box)
	var title := Label.new()
	title.text = "Jedi Academy - Godot map viewer\nPoint this at the GameData folder of your own copy of the game (the folder containing \"base\")."
	title.autowrap_mode = TextServer.AUTOWRAP_WORD
	box.add_child(title)
	var row := HBoxContainer.new()
	box.add_child(row)
	var path_edit := LineEdit.new()
	path_edit.text = gamedata
	path_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	path_edit.placeholder_text = "C:/Program Files (x86)/Steam/steamapps/common/Jedi Academy/GameData"
	row.add_child(path_edit)
	var browse := Button.new()
	browse.text = "Browse..."
	row.add_child(browse)
	var mount_btn := Button.new()
	mount_btn.text = "Load"
	row.add_child(mount_btn)
	var filter := LineEdit.new()
	filter.placeholder_text = "filter maps"
	box.add_child(filter)
	var list := ItemList.new()
	list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	box.add_child(list)
	var status := Label.new()
	box.add_child(status)

	var dialog := FileDialog.new()
	dialog.file_mode = FileDialog.FILE_MODE_OPEN_DIR
	dialog.access = FileDialog.ACCESS_FILESYSTEM
	dialog.use_native_dialog = true
	panel.add_child(dialog)

	var refresh := func() -> void:
		list.clear()
		if vfs == null:
			status.text = "No game data mounted."
			return
		for m in vfs.list_files("maps", "bsp"):
			var short := m.substr(5).get_basename()
			if filter.text.is_empty() or short.contains(filter.text.to_lower()):
				list.add_item(short)
		status.text = "%d files mounted. Double-click a map." % vfs.file_count()
	var do_mount := func() -> void:
		if _mount(path_edit.text.strip_edges(), _args.get("game", "")):
			refresh.call()
		else:
			status.text = "No \"base\" folder found in that path."
	browse.pressed.connect(dialog.popup_centered_ratio.bind(0.6))
	dialog.dir_selected.connect(func(d: String) -> void:
		path_edit.text = d
		do_mount.call())
	mount_btn.pressed.connect(do_mount)
	path_edit.text_submitted.connect(func(_t: String) -> void: do_mount.call())
	filter.text_changed.connect(func(_t: String) -> void: refresh.call())
	list.item_activated.connect(func(i: int) -> void: _load_map(list.get_item_text(i)))
	refresh.call()
	$UI.add_child(panel)
	_setup = panel
