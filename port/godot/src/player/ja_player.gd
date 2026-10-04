class_name JAPlayer
extends Node3D
## Local player: builds usercmds from input, runs JAPmove at a fixed tick,
## and draws first/third-person views. Positions are interpolated between
## ticks for smooth display, like cgame prediction does.
##
## Controls: WASD move, Space jump, C crouch, Shift walk, mouse look,
## T toggle 1st/3rd person, V noclip.

## cg_thirdPersonRange / cg_thirdPersonVertOffset defaults (cg_main.cpp)
@export var third_person_range := 80.0
@export var third_person_vert_offset := 16.0
@export var mouse_sensitivity := 0.022 * 5.0  # m_yaw * sensitivity, degrees per pixel
@export var third_person := true

var pm: JAPmove
var camera: Camera3D
var body: MeshInstance3D

var _yaw := 0.0
var _pitch := 0.0
var _time_ms := 0.0
var _last_cmd_ms := 0
var _prev_origin := Vector3.ZERO
var _curr_origin := Vector3.ZERO
var _prev_view := 0.0
var _curr_view := 0.0


func setup(world: JACollisionWorld, origin_q: Vector3, yaw_deg: float) -> void:
	pm = JAPmove.new(world)
	pm.origin = origin_q
	_yaw = yaw_deg
	_prev_origin = origin_q
	_curr_origin = origin_q
	_curr_view = pm.viewheight
	_prev_view = pm.viewheight
	if camera == null:
		camera = Camera3D.new()
		camera.fov = 80.0
		camera.keep_aspect = Camera3D.KEEP_WIDTH
		camera.near = 0.05
		camera.far = 1000.0
		add_child(camera)
		body = MeshInstance3D.new()
		var box := BoxMesh.new()
		box.size = Vector3(32, 64, 32) * JACoords.SCALE
		var mat := StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.albedo_color = Color(0.85, 0.75, 0.55)
		box.material = mat
		body.mesh = box
		add_child(body)
	_update_visuals(1.0)


func make_current() -> void:
	camera.make_current()
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _unhandled_input(event: InputEvent) -> void:
	if pm == null or not camera.current:
		return
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		_yaw -= event.relative.x * mouse_sensitivity
		_pitch = clampf(_pitch + event.relative.y * mouse_sensitivity, -89.0, 89.0)
	elif event is InputEventMouseButton and event.pressed:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	elif event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_T: third_person = not third_person
			KEY_V: pm.noclip = not pm.noclip
			KEY_ESCAPE: Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func _physics_process(delta: float) -> void:
	if pm == null:
		return
	# integer msec per command, like cmd.serverTime deltas
	_time_ms += delta * 1000.0
	var now := int(_time_ms)
	var cmd := JAPmove.UserCmd.new()
	cmd.msec = now - _last_cmd_ms
	_last_cmd_ms = now
	if camera.current:
		var run := 64 if Input.is_key_pressed(KEY_SHIFT) else 127
		cmd.forwardmove = int(Input.get_axis("move_back", "move_forward") * run)
		cmd.rightmove = int(Input.get_axis("move_left", "move_right") * run)
		cmd.upmove = int(Input.get_axis("move_down", "move_up") * 127)
	cmd.viewangles = Vector3(_pitch, _yaw, 0)
	_prev_origin = _curr_origin
	_prev_view = _curr_view
	pm.pmove(cmd)
	_curr_origin = pm.origin
	_curr_view = pm.viewheight


func _process(_delta: float) -> void:
	if pm != null:
		_update_visuals(Engine.get_physics_interpolation_fraction())


func _update_visuals(frac: float) -> void:
	var o := _prev_origin.lerp(_curr_origin, frac)
	var vh := lerpf(_prev_view, _curr_view, frac)
	position = JACoords.pos(o)
	# body box spans mins..maxs
	var h := pm.maxs.z - pm.mins.z
	(body.mesh as BoxMesh).size = Vector3(32, h, 32) * JACoords.SCALE
	body.position = Vector3(0, (pm.mins.z + h * 0.5) * JACoords.SCALE, 0)
	body.rotation = Vector3(0, deg_to_rad(_yaw), 0)
	body.visible = third_person

	var eye := o + Vector3(0, 0, vh)
	var cam_q := eye
	if third_person:
		# CG_OffsetThirdPersonView: back off from the eye, stopped by walls
		var fwd: Vector3 = JAPmove._angle_vectors(Vector3(_pitch, _yaw, 0))[0]
		var focus := eye + Vector3(0, 0, third_person_vert_offset)
		var want := focus - fwd * third_person_range
		var tr := pm.world.trace(focus, want, Vector3(-4, -4, -4), Vector3(4, 4, 4), JACollisionWorld.CONTENTS_SOLID)
		cam_q = tr.endpos
	camera.global_position = JACoords.pos(cam_q)
	# camera looks along -Z; Quake yaw 0 is +X
	camera.global_basis = Basis(Vector3.UP, deg_to_rad(_yaw - 90.0)) * Basis(Vector3.RIGHT, deg_to_rad(-_pitch))


## Quake-space state for the HUD.
func debug_text() -> String:
	var hv := Vector2(pm.velocity.x, pm.velocity.y).length()
	return "pos %.0f %.0f %.0f  speed %.0f  %s%s%s" % [pm.origin.x, pm.origin.y, pm.origin.z, hv,
		"ground" if pm.on_ground else "air",
		"  crouch" if pm.pm_flags & JAPmove.PMF_DUCKED else "",
		"  water %d" % pm.waterlevel if pm.waterlevel else ""]
