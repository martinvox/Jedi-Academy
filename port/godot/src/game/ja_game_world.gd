class_name JAGameWorld
extends RefCounted
## Server-side entity logic for map entities, ported from code/game:
##   g_mover.cpp   func_door, func_plat, func_button, func_bobbing, func_rotating
##   g_trigger.cpp trigger_multiple/once, trigger_push, trigger_teleport
##   g_target.cpp  target_relay, target_delay, target_push, target_teleporter, target_print
##   g_utils.cpp   G_UseTargets, target_activate/deactivate
##   g_misc.cpp    TeleportPlayer, misc_teleporter_dest
## Entities are driven by run_frame() at the player's command rate, before
## the player's Pmove, and touch_triggers() right after it (as ClientThink does).
## Not ported yet: ICARUS scripts (usescript/spawnscript), func_train,
## func_breakable damage, sounds, goodie keys, NPC-only triggers.

const MOVER_START_OPEN := 1
const MOVER_FORCE_ACTIVATE := 2
const MOVER_CRUSHER := 4
const MOVER_TOGGLE := 8
const MOVER_LOCKED := 16
const MOVER_GOODIE := 32
const MOVER_PLAYER_USE := 64
const MOVER_INACTIVE := 128

enum MoverState { POS1, POS2, ONE_TO_TWO, TWO_TO_ONE }

class GEnt:
	var index := -1
	var classname := ""
	var spawn: Dictionary
	var targetname := ""
	var target := ""
	var target2 := ""
	var opentarget := ""
	var closetarget := ""
	var spawnflags := 0
	var model := -1                # bsp inline model, -1 for point entities
	var origin := Vector3.ZERO     # current origin (Quake space)
	var angles := Vector3.ZERO
	var node: Node3D
	var inactive := false
	var wait := 0.0                # ms unless noted
	var delay := 0.0               # ms
	var random := 0.0
	var speed := 0.0
	var next_think := 0
	var think := ""                # name of the method to call at next_think
	var wait_until := 0            # trigger re-fire gate
	var activator = null
	# movers
	var pos1 := Vector3.ZERO
	var pos2 := Vector3.ZERO
	var state: int = MoverState.POS1
	var tr_time := 0
	var tr_duration := 1
	var linear := false
	var team: Array = []           # all members, master first (empty: no team)
	var master: GEnt = null
	var usable := true
	var is_mover := false
	var bob_axis := Vector3.ZERO
	var bob_height := 0.0
	var bob_phase := 0.0
	var rot_axis := Vector3.ZERO
	var rotating := false
	# triggers
	var box := AABB()              # spawned box triggers (door/plat), Quake space
	var owner: GEnt = null
	var push_velocity := Vector3.ZERO

	func key(k: String, default: String = "") -> String:
		return spawn.get(k, default)

	func fkey(k: String, default: float = 0.0) -> float:
		return float(spawn[k]) if spawn.has(k) else default


var level_time := 0
var ents: Array[GEnt] = []
var _by_name: Dictionary = {}       # targetname -> Array[GEnt]
var _by_model: Dictionary = {}      # bsp model -> GEnt
var world: JACollisionWorld         # solid brushes (movers included)
var triggers: JACollisionWorld      # trigger brushes
var pm: JAPmove
## called with (origin: Vector3, angles: Vector3) when the player teleports
var teleport_callback: Callable
## latest target_print text and when it was shown
var message := ""
var message_time := -100000
var event_log := PackedStringArray()


## Builds the entity list. `entity_nodes` maps entity index -> Node3D created
## by JAMapBuilder (may be empty in tests).
func setup(bsp: RBSPFile, shaders: Q3ShaderLibrary, entity_nodes: Dictionary) -> void:
	var solid_models := [0]
	var trigger_models := []
	for i in bsp.entities.size():
		var spawn: Dictionary = bsp.entities[i]
		var e := GEnt.new()
		e.index = i
		e.spawn = spawn
		e.classname = spawn.get("classname", "")
		e.targetname = spawn.get("targetname", "")
		e.target = spawn.get("target", "")
		e.target2 = spawn.get("target2", "")
		e.opentarget = spawn.get("opentarget", "")
		e.closetarget = spawn.get("closetarget", "")
		e.spawnflags = int(spawn.get("spawnflags", "0"))
		e.origin = JACoords.parse_vec3(spawn.get("origin", "0 0 0"))
		e.angles = JACoords.entity_angles(spawn)
		e.speed = e.fkey("speed")
		e.wait = e.fkey("wait")
		e.delay = e.fkey("delay")
		e.random = e.fkey("random")
		e.node = entity_nodes.get(i)
		var m: String = spawn.get("model", "")
		if i > 0 and m.begins_with("*"):
			e.model = m.substr(1).to_int()
			_by_model[e.model] = e
			if e.classname.begins_with("trigger_"):
				trigger_models.append(e.model)
			else:
				solid_models.append(e.model)
		ents.append(e)
		if not e.targetname.is_empty():
			if not _by_name.has(e.targetname):
				_by_name[e.targetname] = []
			_by_name[e.targetname].append(e)
	world = JACollisionWorld.from_bsp(bsp, shaders, solid_models)
	triggers = JACollisionWorld.from_bsp(bsp, shaders, trigger_models if not trigger_models.is_empty() else [-1])
	for e in ents:
		if e.model > 0:
			world.model_offset[e.model] = e.origin
			triggers.model_offset[e.model] = e.origin
	for e in ents:
		_spawn(e)
	# second pass, like the think at START_TIME_LINK_ENTS
	_link_teams()
	for e in ents:
		if e.classname == "func_door" and e.master == e:
			_door_spawn_trigger(e)
		elif e.classname in ["trigger_push", "target_push"] and not e.target.is_empty():
			_aim_at_target(e)


func _log(s: String) -> void:
	event_log.append("%d: %s" % [level_time, s])


# ---------------------------------------------------------------- spawning

func _spawn(e: GEnt) -> void:
	match e.classname:
		"func_door": _sp_func_door(e)
		"func_plat": _sp_func_plat(e)
		"func_button": _sp_func_button(e)
		"func_bobbing": _sp_func_bobbing(e)
		"func_rotating": _sp_func_rotating(e)
		"func_usable": _sp_func_usable(e)
		"trigger_multiple":
			e.wait = e.fkey("wait", 0.0)
			e.delay *= 1000.0
			e.inactive = e.spawnflags & 128 != 0
		"trigger_once":
			e.wait = -1.0
			e.delay *= 1000.0
			e.inactive = e.spawnflags & 128 != 0
		"trigger_push":
			if e.wait > 0.0:
				e.wait *= 1000.0
			if e.spawnflags & 4:
				e.speed = 1000.0
			e.inactive = e.spawnflags & 128 != 0
		"trigger_teleport":
			e.inactive = e.spawnflags & 128 != 0
		"target_relay":
			e.wait *= 1000.0
			e.delay *= 1000.0
			e.inactive = e.spawnflags & 128 != 0
		"target_delay":
			if not e.spawn.has("delay"):
				e.wait = e.fkey("wait", 1.0)
			else:
				e.wait = e.fkey("delay")
			if e.wait == 0.0:
				e.wait = 1.0
		"target_push":
			if e.speed == 0.0:
				e.speed = 1000.0
			e.push_velocity = _movedir(e.angles) * e.speed


func _movedir(angles: Vector3) -> Vector3:
	# G_SetMovedir: angle -1 / -2 mean up / down
	if angles == Vector3(-90, 0, 0):
		return Vector3(0, 0, 1)
	if angles == Vector3(90, 0, 0):
		return Vector3(0, 0, -1)
	return JAPmove._angle_vectors(angles)[0]


func _model_size(e: GEnt) -> Vector3:
	return world.model_bounds(e.model).size


func _init_mover(e: GEnt) -> void:
	e.is_mover = true
	e.linear = int(e.spawn.get("linear", "0")) != 0
	e.state = MoverState.POS1
	e.origin = e.pos1
	if e.speed == 0.0:
		e.speed = 100.0
	e.tr_duration = maxi(int((e.pos2 - e.pos1).length() * 1000.0 / e.speed), 1)
	e.inactive = e.spawnflags & MOVER_INACTIVE != 0
	_apply_origin(e)


func _sp_func_door(e: GEnt) -> void:
	if e.speed == 0.0:
		e.speed = 400.0
	if e.wait == 0.0:
		e.wait = 2.0
	e.wait *= 1000.0
	e.delay *= 1000.0
	var lip := e.fkey("lip", 8.0)
	e.pos1 = e.origin
	var dir := _movedir(e.angles)
	var size := _model_size(e)
	var distance := dir.abs().dot(size) - lip
	e.pos2 = e.pos1 + dir * distance
	if e.spawnflags & MOVER_START_OPEN:
		var t := e.pos2
		e.pos2 = e.origin
		e.pos1 = t
	_init_mover(e)


func _sp_func_plat(e: GEnt) -> void:
	e.speed = e.fkey("speed", 200.0)
	e.wait = 1000.0
	var lip := e.fkey("lip", 8.0)
	var height := e.fkey("height", _model_size(e).z - lip)
	e.pos2 = e.origin
	e.pos1 = e.origin - Vector3(0, 0, height)
	_init_mover(e)
	if e.targetname.is_empty():
		# SpawnPlatTrigger: thin trigger just above the low position
		var b := world.model_bounds(e.model)
		var tmin := e.pos1 + b.position + Vector3(33, 33, 0)
		var tmax := e.pos1 + b.end + Vector3(-33, -33, 8)
		if tmax.x <= tmin.x:
			tmin.x = e.pos1.x + b.get_center().x
			tmax.x = tmin.x + 1
		if tmax.y <= tmin.y:
			tmin.y = e.pos1.y + b.get_center().y
			tmax.y = tmin.y + 1
		var t := GEnt.new()
		t.classname = "trigger_plat"
		t.owner = e
		t.box = AABB(tmin, tmax - tmin)
		ents.append(t)


func _sp_func_button(e: GEnt) -> void:
	if e.speed == 0.0:
		e.speed = 40.0
	if e.wait == 0.0:
		e.wait = 1.0
	e.wait *= 1000.0
	e.pos1 = e.origin
	var lip := e.fkey("lip", 4.0)
	var dir := _movedir(e.angles)
	e.pos2 = e.pos1 + dir * (dir.abs().dot(_model_size(e)) - lip)
	_init_mover(e)


func _sp_func_bobbing(e: GEnt) -> void:
	e.bob_height = e.fkey("height", 32.0)
	e.speed = e.fkey("speed", 4.0)
	e.bob_phase = e.fkey("phase", 0.0)
	e.bob_axis = Vector3(1, 0, 0) if e.spawnflags & 1 else (Vector3(0, 1, 0) if e.spawnflags & 2 else Vector3(0, 0, 1))
	e.pos1 = e.origin


func _sp_func_rotating(e: GEnt) -> void:
	if e.speed == 0.0:
		e.speed = 100.0
	# X_AXIS rolls, Y_AXIS pitches, default yaws (apos.trDelta in SP_func_rotating)
	e.rot_axis = Vector3(1, 0, 0) if e.spawnflags & 4 else (Vector3(0, 1, 0) if e.spawnflags & 8 else Vector3(0, 0, 1))
	e.rotating = e.spawnflags & 1 != 0   # START_ON
	# TODO: collision still uses the unrotated brushes


func _sp_func_usable(e: GEnt) -> void:
	if e.spawnflags & 1:   # START_OFF
		_set_solid(e, false)


func _set_solid(e: GEnt, on: bool) -> void:
	if on:
		world.disabled_models.erase(e.model)
	else:
		world.disabled_models[e.model] = true
	if e.node:
		e.node.visible = on


func _link_teams() -> void:
	var teams := {}
	for e in ents:
		var t := e.key("team")
		if t.is_empty() or not e.is_mover:
			continue
		var k := e.classname + "|" + t
		if not teams.has(k):
			teams[k] = []
		teams[k].append(e)
	for k in teams:
		var members: Array = teams[k]
		for m in members:
			m.team = members
			m.master = members[0]
	for e in ents:
		if e.is_mover and e.master == null:
			e.master = e


func _team(e: GEnt) -> Array:
	return e.team if not e.team.is_empty() else [e]


## Think_SpawnNewDoorTrigger, for touch-opened doors.
func _door_spawn_trigger(e: GEnt) -> void:
	var health := int(e.key("health", "0"))
	if not (e.spawnflags & MOVER_LOCKED) and (not e.targetname.is_empty() or health or e.spawnflags & (MOVER_PLAYER_USE | MOVER_FORCE_ACTIVATE)):
		return
	var box := AABB()
	var first := true
	for m in _team(e):
		var b := world.model_bounds(m.model)
		b.position += m.origin
		box = b if first else box.merge(b)
		first = false
	var size := box.size
	var best := 0
	for i in [1, 2]:
		if size[i] < size[best]:
			best = i
	box.position[best] -= 120.0
	box.size[best] += 240.0
	var t := GEnt.new()
	t.classname = "trigger_door"
	t.owner = e
	t.box = box
	ents.append(t)


## AimAtTarget: velocity that lands the activator on the target's apex.
func _aim_at_target(e: GEnt) -> void:
	var dest := _pick_target(e.target)
	if dest == null:
		return
	var origin := e.origin
	if e.model > 0:
		origin = triggers.model_bounds(e.model).get_center() + e.origin
	if e.classname == "trigger_push":
		if e.spawnflags & 16:
			e.push_velocity = dest.origin    # relative: stored target position
			return
		elif e.spawnflags & 4:
			e.push_velocity = (dest.origin - origin).normalized()
			return
	if e.classname == "target_push" and e.spawnflags & 2:
		e.push_velocity = (dest.origin - e.origin).normalized() * e.speed
		return
	var height := maxf(dest.origin.z - origin.z, 0.0)
	var gravity := maxf(pm.gravity if pm else 800.0, 0.0)
	var time := sqrt(height / (0.5 * gravity)) if gravity > 0.0 else 0.0
	if time == 0.0:
		return
	var flat := dest.origin - origin
	flat.z = 0.0
	var dist := flat.length()
	e.push_velocity = flat.normalized() * (dist / time)
	e.push_velocity.z = time * gravity


# ---------------------------------------------------------------- using

func _pick_target(name: String) -> GEnt:
	var list: Array = _by_name.get(name, [])
	return list[randi() % list.size()] if not list.is_empty() else null


## G_UseTargets2
func use_targets(e: GEnt, activator, name: String) -> void:
	if name.is_empty():
		return
	if name == "self":
		use(e, e, activator)
		return
	for t in _by_name.get(name, []):
		use(t, e, activator)


func use(e: GEnt, other, activator) -> void:
	_log("use %s (%s)" % [e.classname, e.targetname])
	if e.is_mover:
		_use_binary_mover(e, other, activator)
		return
	match e.classname:
		"trigger_multiple", "trigger_once":
			_multi_trigger(e, activator)
		"target_relay":
			if e.inactive:
				return
			if e.delay > 0.0:
				e.activator = activator
				e.think = "_relay_fire"
				e.next_think = level_time + int(e.delay)
			else:
				_relay_fire(e, activator)
		"target_delay":
			e.activator = activator
			e.think = "_delay_fire"
			e.next_think = level_time + int((e.wait + e.random * randf_range(-1, 1)) * 1000.0)
		"target_push":
			if pm:
				pm.velocity = e.push_velocity
		"target_teleporter":
			var dest := _pick_target(e.target)
			if dest and pm:
				teleport_player(dest.origin, dest.angles)
		"target_print":
			message = e.key("message")
			message_time = level_time
		"target_activate":
			for t in _by_name.get(e.target, []):
				t.inactive = false
		"target_deactivate":
			for t in _by_name.get(e.target, []):
				t.inactive = true
		"func_usable":
			_set_solid(e, world.disabled_models.has(e.model))
			use_targets(e, activator, e.target)
		"func_rotating":
			e.rotating = not e.rotating


func _relay_fire(e: GEnt, activator = null) -> void:
	var act = activator if activator != null else e.activator
	if e.spawnflags & 4:   # RANDOM
		var t := _pick_target(e.target)
		if t:
			use(t, e, act)
	else:
		use_targets(e, act, e.target)


func _delay_fire(e: GEnt) -> void:
	use_targets(e, e.activator, e.target)


func _use_binary_mover(e: GEnt, other, activator) -> void:
	if not e.usable:
		return
	if e.master != null and e.master != e:
		_use_binary_mover(e.master, other, activator)
		return
	if e.inactive:
		return
	if e.spawnflags & MOVER_LOCKED:
		for m in _team(e):
			m.spawnflags &= ~MOVER_LOCKED
			if not (m.spawnflags & MOVER_TOGGLE):
				m.targetname = ""
		return
	e.activator = activator
	if e.delay > 0.0:
		e.think = "_use_binary_mover_go"
		e.next_think = level_time + int(e.delay)
	else:
		_use_binary_mover_go(e)


func _use_binary_mover_go(e: GEnt) -> void:
	match e.state:
		MoverState.POS1:
			_match_team(e, MoverState.ONE_TO_TWO, level_time + 50)
			use_targets(e, e.activator, e.target)
		MoverState.POS2:
			e.think = "_return_to_pos1"
			e.next_think = level_time + (50 if e.spawnflags & MOVER_TOGGLE else int(e.wait))
			use_targets(e, e.activator, e.target2)
		MoverState.TWO_TO_ONE:
			_reverse(e, MoverState.ONE_TO_TWO)
		MoverState.ONE_TO_TWO:
			_reverse(e, MoverState.TWO_TO_ONE)


## Turns a moving team around mid-way, continuing from the current position.
func _reverse(e: GEnt, new_state: int) -> void:
	var total := (e.pos2 - e.pos1).length()
	var x := 0.0 if total == 0.0 else clampf((e.origin - e.pos1).length() / total, 0.0, 1.0)
	# progress p along the new direction that yields the same position
	var frac := x if new_state == MoverState.ONE_TO_TWO else 1.0 - x
	var p := frac if e.linear else asin(frac) * 2.0 / PI
	_match_team(e, new_state, level_time - int(p * e.tr_duration))


func _return_to_pos1(e: GEnt) -> void:
	e.think = ""
	_match_team(e, MoverState.TWO_TO_ONE, level_time)


func _match_team(e: GEnt, state: int, time: int) -> void:
	for m in _team(e):
		m.state = state
		m.tr_time = time


func _mover_position(e: GEnt, t: int) -> Vector3:
	match e.state:
		MoverState.POS1: return e.pos1
		MoverState.POS2: return e.pos2
	var x := clampf(float(t - e.tr_time) / e.tr_duration, 0.0, 1.0)
	var f := x if e.linear else sin(x * PI * 0.5)   # TR_NONLINEAR_STOP
	if e.state == MoverState.ONE_TO_TWO:
		return e.pos1.lerp(e.pos2, f)
	return e.pos2.lerp(e.pos1, f)


func _reached(e: GEnt) -> void:
	if e.state == MoverState.ONE_TO_TWO:
		e.state = MoverState.POS2
		if e.master == e or e.master == null:
			if e.wait < 0.0:
				e.usable = false
				e.think = ""
			elif e.spawnflags & MOVER_TOGGLE:
				e.think = ""
			else:
				e.think = "_return_to_pos1"
				e.next_think = level_time + int(e.wait)
			use_targets(e, e.activator if e.activator != null else e, e.opentarget)
	elif e.state == MoverState.TWO_TO_ONE:
		e.state = MoverState.POS1
		if e.master == e or e.master == null:
			use_targets(e, e.activator, e.closetarget)


func _apply_origin(e: GEnt) -> void:
	world.model_offset[e.model] = e.origin
	if e.node:
		e.node.position = JACoords.pos(e.origin)


# ---------------------------------------------------------------- frame

func run_frame(msec: int) -> void:
	level_time += msec
	for e in ents:
		if not e.think.is_empty() and e.next_think > 0 and e.next_think <= level_time:
			var fn := e.think
			e.think = ""
			e.next_think = 0
			call(fn, e)
	for e in ents:
		if e.is_mover and (e.master == e or e.master == null) and e.state in [MoverState.ONE_TO_TWO, MoverState.TWO_TO_ONE]:
			_run_mover_team(e)
		elif e.classname == "func_bobbing" and not (e.spawnflags & 4):
			var dur := maxf(e.speed * 1000.0, 1.0)
			var s := sin((level_time / dur + e.bob_phase) * TAU)
			_push_to(e, e.pos1 + e.bob_axis * e.bob_height * s)
		elif e.classname == "func_rotating" and e.rotating and e.node:
			var ax := JACoords.dir(e.rot_axis)
			e.node.rotate(ax, deg_to_rad(e.speed) * msec * 0.001)


func _run_mover_team(e: GEnt) -> void:
	var members := _team(e)
	var old := []
	for m in members:
		old.append(m.origin)
	var blocked := false
	for m in members:
		if not _push_to(m, _mover_position(m, level_time)):
			blocked = true
			break
	if blocked:
		for i in members.size():
			members[i].origin = old[i]
			_apply_origin(members[i])
		# Blocked_Door: crushers keep pushing, others reverse
		if not (e.spawnflags & MOVER_CRUSHER):
			_use_binary_mover(e, e, null)
		return
	if level_time >= e.tr_time + e.tr_duration:
		for m in members:
			_reached(m)


## Moves a brush entity, carrying/pushing the player (G_MoverPush, player
## only). Returns false if the player would end up stuck.
func _push_to(e: GEnt, new_origin: Vector3) -> bool:
	var delta := new_origin - e.origin
	if delta == Vector3.ZERO:
		return true
	e.origin = new_origin
	_apply_origin(e)
	if pm == null or pm.noclip:
		return true
	var riding := pm.ground_model == e.model
	if riding or world.box_touches_model(pm.origin, pm.mins, pm.maxs, e.model):
		var dest := pm.origin + delta
		var tr := world.trace(dest, dest, pm.mins, pm.maxs, JACollisionWorld.MASK_PLAYERSOLID)
		if tr.startsolid:
			if riding and not world.box_touches_model(pm.origin, pm.mins, pm.maxs, e.model):
				return true   # moved away below the player's feet but player can't follow; just drop
			e.origin = new_origin - delta
			_apply_origin(e)
			return false
		pm.origin = dest
	return true


## G_TouchTriggers + mover touches, after the player's Pmove.
func touch_triggers() -> void:
	if pm == null or pm.noclip:
		return
	var absmin := pm.origin + pm.mins
	var absbox := AABB(absmin, pm.maxs - pm.mins)
	for e in ents:
		if e.inactive:
			continue
		var touching := false
		if e.classname in ["trigger_door", "trigger_plat"]:
			touching = absbox.intersects(e.box)
		elif e.model > 0 and e.classname.begins_with("trigger_"):
			touching = triggers.box_touches_model(pm.origin, pm.mins, pm.maxs, e.model)
		elif e.model > 0 and e.is_mover and pm.touched_models.has(e.model):
			touching = true
		if touching:
			_touch(e)


func _touch(e: GEnt) -> void:
	match e.classname:
		"trigger_door":
			var door := e.owner
			if door.spawnflags & MOVER_LOCKED:
				return
			if door.state != MoverState.ONE_TO_TWO:
				_use_binary_mover(door, e, pm)
		"trigger_plat":
			if e.owner.state == MoverState.POS1:
				_use_binary_mover(e.owner, e, pm)
		"func_plat":
			if e.state == MoverState.POS2 and e.think == "_return_to_pos1":
				e.next_think = level_time + 1000
		"func_button":
			if e.state == MoverState.POS1 and int(e.key("health", "0")) == 0:
				_use_binary_mover(e, pm, pm)
		"trigger_multiple", "trigger_once":
			if e.spawnflags & 4 and not (pm.buttons & JAPmove.BUTTON_USE):
				return   # USE_BUTTON
			if e.spawnflags & 16:
				return   # NPCONLY
			if e.spawnflags & 2:   # FACING: within 45 degrees of the trigger's angles
				var want: Vector3 = JAPmove._angle_vectors(e.angles)[0]
				var look: Vector3 = JAPmove._angle_vectors(pm.viewangles)[0]
				if want.dot(look) < 0.7071:
					return
			_multi_trigger(e, pm)
		"trigger_push":
			if level_time < e.wait_until:
				return
			if e.spawnflags & 32 and not pm.on_ground:
				return   # CONVEYOR
			if e.spawnflags & 8:
				return   # NPCONLY
			if e.spawnflags & 16:
				var d: Vector3 = e.push_velocity - pm.origin
				pm.velocity = d.normalized() * e.speed if e.speed > 0.0 else d
			elif e.spawnflags & 4:
				pm.velocity = e.push_velocity * e.speed
			else:
				pm.velocity = e.push_velocity
			pm.on_ground = false
			pm.ground_model = -1
			e.wait_until = level_time + (int(e.wait) if e.wait > 0.0 else 0) + 1
			if e.wait < 0.0:
				e.inactive = true
			_log("push %s" % pm.velocity)
		"trigger_teleport":
			var dest := _pick_target(e.target)
			if dest:
				teleport_player(dest.origin, dest.angles)


## multi_trigger / multi_trigger_run
func _multi_trigger(e: GEnt, activator) -> void:
	if e.inactive or e.think == "_multi_trigger_run":
		return
	if level_time < e.wait_until:
		return
	e.activator = activator
	if e.delay > 0.0:
		e.think = "_multi_trigger_run"
		e.next_think = level_time + int(e.delay)
	else:
		_multi_trigger_run(e)


func _multi_trigger_run(e: GEnt) -> void:
	use_targets(e, e.activator, e.target)
	if e.wait > 0.0:
		e.wait_until = level_time + int((e.wait + e.random * randf_range(-1, 1)) * 1000.0)
	elif e.wait < 0.0:
		e.inactive = true
	else:
		e.wait_until = level_time + 1


## TeleportPlayer: origin + 1 up, velocity cleared, view angles set.
func teleport_player(origin: Vector3, angles: Vector3) -> void:
	pm.origin = origin + Vector3(0, 0, 1)
	pm.velocity = Vector3.ZERO
	pm.on_ground = false
	pm.ground_model = -1
	_log("teleport to %s" % origin)
	if teleport_callback.is_valid():
		teleport_callback.call(pm.origin, angles)


## Player pressed use: trace 64 units from the eye (USE_DISTANCE) and use a
## PLAYER_USE mover or func_usable that is hit.
func player_use() -> void:
	if pm == null:
		return
	var eye := pm.origin + Vector3(0, 0, pm.viewheight)
	var fwd: Vector3 = JAPmove._angle_vectors(pm.viewangles)[0]
	var tr := world.trace(eye, eye + fwd * 64.0, Vector3.ZERO, Vector3.ZERO, JACollisionWorld.MASK_PLAYERSOLID)
	if tr.brush < 0:
		return
	var e: GEnt = _by_model.get(world.brush_model[tr.brush])
	if e == null:
		return
	if e.is_mover and (e.spawnflags & MOVER_PLAYER_USE or e.classname == "func_button"):
		_use_binary_mover(e, pm, pm)
	elif e.classname == "func_usable" and e.spawnflags & 64:   # PLAYER_USE
		use(e, pm, pm)


func entity_by_name(name: String) -> GEnt:
	var l: Array = _by_name.get(name, [])
	return l[0] if not l.is_empty() else null
