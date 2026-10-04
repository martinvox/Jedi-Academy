class_name JAPmove
extends RefCounted
## Player movement, ported from code/game/bg_pmove.cpp and bg_slidemove.cpp.
## Works in Quake space (units, Z up) on a JACollisionWorld, one usercmd at a
## time, exactly like Pmove(). Function names match the original so the two
## can be compared side by side.
##
## Ported so far: walking, air, water and ladder movement, friction,
## acceleration, slide/step moves (with g_stepSlideFix 1, the default),
## ground trace, ducking, the normal jump and landing timers.
## Not yet: force jumps/flips/wall runs/rolls, knockback, vehicles, falling
## damage, animations and events (see the comments marked TODO).

# bg_pmove.cpp movement parameters
const pm_stopspeed := 100.0
const pm_duckScale := 0.50
const pm_swimScale := 0.50
const pm_ladderScale := 0.7
const pm_accelerate := 12.0
const pm_airaccelerate := 4.0
const pm_wateraccelerate := 4.0
const pm_flyaccelerate := 8.0
const pm_friction := 6.0
const pm_waterfriction := 1.0
const pm_airDecelRate := 1.35
# bg_public.h / bg_local.h
const MIN_WALK_NORMAL := 0.7
const JUMP_VELOCITY := 225.0
const STEPSIZE := 18.0
const OVERCLIP := 1.001
const MAX_CLIP_PLANES := 5
const DEFAULT_MINS_2 := -24.0
const DEFAULT_MAXS_2 := 40.0
const CROUCH_MAXS_2 := 16.0
const STANDARD_VIEWHEIGHT_OFFSET := -4.0
# pm_flags
const PMF_DUCKED := 1
const PMF_JUMP_HELD := 2
const PMF_JUMPING := 4
const PMF_BACKWARDS_RUN := 8
const PMF_TIME_LAND := 32
const PMF_TIME_KNOCKBACK := 64
const PMF_TIME_WATERJUMP := 256
const PMF_TIME_NOFRICTION := 0x1000
const PMF_TIMEMASK := PMF_TIME_LAND | PMF_TIME_KNOCKBACK | PMF_TIME_WATERJUMP | PMF_TIME_NOFRICTION

const SURF_SLICK := 0x4000

class UserCmd:
	var forwardmove := 0    # -127..127
	var rightmove := 0
	var upmove := 0         # >0 jump, <0 crouch
	var viewangles := Vector3.ZERO   # pitch, yaw, roll (degrees)
	var msec := 16

## playerState_t subset
var origin := Vector3.ZERO
var velocity := Vector3.ZERO
var viewangles := Vector3.ZERO
var mins := Vector3(-16, -16, DEFAULT_MINS_2)
var maxs := Vector3(16, 16, DEFAULT_MAXS_2)
var viewheight := DEFAULT_MAXS_2 + STANDARD_VIEWHEIGHT_OFFSET
var pm_flags := 0
var pm_time := 0
var on_ground := false          # groundEntityNum != ENTITYNUM_NONE
var gravity := 800.0            # g_gravity
var speed := 250.0              # g_speed
var standheight := DEFAULT_MAXS_2
var crouchheight := CROUCH_MAXS_2
var waterlevel := 0
var watertype := 0
var tracemask := JACollisionWorld.MASK_PLAYERSOLID
var noclip := false
## events from the last move, for sounds/animation later
var events := PackedStringArray()
## bsp model the player stands on (-1: none), like groundEntityNum
var ground_model := -1
## bsp models bumped during the last move (PM_AddTouchEnt)
var touched_models: Array[int] = []
var buttons := 0
const BUTTON_USE := 4

var world: JACollisionWorld

# pml_t
var _forward := Vector3.ZERO
var _right := Vector3.ZERO
var _frametime := 0.0
var _walking := false
var _ground_plane := false
var _ground: JACollisionWorld.Trace
var _previous_origin := Vector3.ZERO
var _previous_velocity := Vector3.ZERO
var _impact_speed := 0.0
var _cmd: UserCmd


func _init(p_world: JACollisionWorld) -> void:
	world = p_world


func _trace(start: Vector3, end: Vector3) -> JACollisionWorld.Trace:
	return world.trace(start, end, mins, maxs, tracemask)


func PM_AddTouchEnt(tr: JACollisionWorld.Trace) -> void:
	if tr.brush < 0:
		return
	var m := world.brush_model[tr.brush]
	if not touched_models.has(m):
		touched_models.append(m)


## Pmove(): one command.
func pmove(cmd: UserCmd) -> void:
	_cmd = cmd
	events.clear()
	touched_models.clear()
	var msec := clampi(cmd.msec, 1, 200)
	_frametime = msec * 0.001
	_previous_origin = origin
	_previous_velocity = velocity
	_walking = false
	_ground_plane = false
	_impact_speed = 0.0

	viewangles = cmd.viewangles
	var v := _angle_vectors(viewangles)
	_forward = v[0]
	_right = v[1]

	if cmd.upmove < 10:
		pm_flags &= ~PMF_JUMP_HELD
	if cmd.forwardmove < 0:
		pm_flags |= PMF_BACKWARDS_RUN
	elif cmd.forwardmove > 0 or (cmd.forwardmove == 0 and cmd.rightmove != 0):
		pm_flags &= ~PMF_BACKWARDS_RUN

	if noclip:
		PM_NoclipMove()
		PM_DropTimers(msec)
		return

	PM_SetWaterLevel()
	if not (watertype & JACollisionWorld.CONTENTS_LADDER):
		PM_CheckDuck()
	PM_GroundTrace()
	PM_DropTimers(msec)

	if waterlevel > 1 or (watertype & JACollisionWorld.CONTENTS_LADDER):
		PM_WaterMove()
	elif _walking:
		PM_WalkMove()
	else:
		PM_AirMove()

	if origin != _previous_origin:
		PM_GroundTrace()
	PM_SetWaterLevel()


## AngleVectors (q_math.cpp): forward, right, up in Quake space.
static func _angle_vectors(angles: Vector3) -> Array:
	var p := deg_to_rad(angles.x)
	var y := deg_to_rad(angles.y)
	var r := deg_to_rad(angles.z)
	var sp := sin(p); var cp := cos(p)
	var sy := sin(y); var cy := cos(y)
	var sr := sin(r); var cr := cos(r)
	var forward := Vector3(cp * cy, cp * sy, -sp)
	var right := Vector3(-1 * sr * sp * cy + -1 * cr * -sy, -1 * sr * sp * sy + -1 * cr * cy, -1 * sr * cp)
	var up := Vector3(cr * sp * cy + -sr * -sy, cr * sp * sy + -sr * cy, cr * cp)
	return [forward, right, up]


func PM_DropTimers(msec: int) -> void:
	if pm_time:
		if msec >= pm_time:
			pm_flags &= ~PMF_TIMEMASK
			pm_time = 0
		else:
			pm_time -= msec


func PM_ClipVelocity(vin: Vector3, normal: Vector3, overbounce: float) -> Vector3:
	var backoff := vin.dot(normal)
	if backoff < 0.0:
		backoff *= overbounce
	else:
		backoff /= overbounce
	var out := vin - normal * backoff
	# g_stepSlideFix: don't slide up slopes too steep to walk on
	if normal.z < MIN_WALK_NORMAL and on_ground:
		out.z = vin.z
	return out


func PM_Friction() -> void:
	var vec := velocity
	if _walking:
		vec.z = 0.0
	var spd := vec.length()
	if spd < 1.0:
		velocity.x = 0.0
		velocity.y = 0.0
		return
	var drop := 0.0
	var ladder := watertype & JACollisionWorld.CONTENTS_LADDER
	if ladder or waterlevel <= 1:
		if ladder or (_walking and not (_ground.surface_flags & SURF_SLICK)):
			if not (pm_flags & (PMF_TIME_KNOCKBACK | PMF_TIME_NOFRICTION)):
				var control := pm_stopspeed if spd < pm_stopspeed else spd
				drop += control * pm_friction * _frametime
	if waterlevel and not ladder:
		drop += spd * pm_waterfriction * waterlevel * _frametime
	var newspeed := maxf(spd - drop, 0.0) / spd
	velocity *= newspeed


func PM_Accelerate(wishdir: Vector3, wishspeed: float, accel: float) -> void:
	var currentspeed := velocity.dot(wishdir)
	var addspeed := wishspeed - currentspeed
	if addspeed <= 0.0:
		return
	var accelspeed := minf(accel * _frametime * wishspeed, addspeed)
	velocity += wishdir * accelspeed


func PM_CmdScale() -> float:
	var mx := maxi(absi(_cmd.forwardmove), maxi(absi(_cmd.rightmove), absi(_cmd.upmove)))
	if mx == 0:
		return 0.0
	var total := sqrt(float(_cmd.forwardmove * _cmd.forwardmove + _cmd.rightmove * _cmd.rightmove + _cmd.upmove * _cmd.upmove))
	return speed * mx / (127.0 * total)


func PM_CheckJump() -> bool:
	if _cmd.upmove < 10:
		return false
	if pm_flags & PMF_JUMP_HELD:
		_cmd.upmove = 0
		return false
	if not on_ground:
		return false
	# TODO: force jumps, flips, wall runs, rolls (PM_CheckJump is ~1300 lines)
	velocity.z = JUMP_VELOCITY
	pm_flags |= PMF_JUMPING | PMF_JUMP_HELD
	_ground_plane = false
	_walking = false
	on_ground = false
	ground_model = -1
	events.append("jump")
	return true


func PM_WalkMove() -> void:
	if waterlevel > 2 and _forward.dot(_ground.normal) > 0.0:
		PM_WaterMove()
		return
	if PM_CheckJump():
		if waterlevel > 1:
			PM_WaterMove()
		else:
			PM_AirMove()
		return
	if on_ground and velocity.z <= 0.0 and (pm_flags & PMF_TIME_KNOCKBACK):
		pm_flags &= ~PMF_TIME_KNOCKBACK

	PM_Friction()
	var fmove := float(_cmd.forwardmove)
	var smove := float(_cmd.rightmove)
	var scale := PM_CmdScale()

	_forward.z = 0.0
	_right.z = 0.0
	_forward = PM_ClipVelocity(_forward, _ground.normal, OVERCLIP).normalized()
	_right = PM_ClipVelocity(_right, _ground.normal, OVERCLIP).normalized()

	var wishvel := _forward * fmove + _right * smove
	var wishdir := wishvel.normalized()
	var wishspeed := wishvel.length() * scale

	if (pm_flags & PMF_DUCKED) and wishspeed > speed * pm_duckScale:
		wishspeed = speed * pm_duckScale
	if waterlevel:
		var water_scale := 1.0 - (1.0 - pm_swimScale) * (waterlevel / 3.0)
		wishspeed = minf(wishspeed, speed * water_scale)

	var accelerate := pm_accelerate
	var slick := (_ground.surface_flags & SURF_SLICK) or (pm_flags & (PMF_TIME_KNOCKBACK | PMF_TIME_NOFRICTION))
	if slick:
		accelerate = pm_airaccelerate
	PM_Accelerate(wishdir, wishspeed, accelerate)

	if slick:
		if not (on_ground and velocity.length_squared() == 0.0 and _ground.normal.z == 1.0):
			velocity.z -= gravity * _frametime

	var vel := velocity.length()
	velocity = PM_ClipVelocity(velocity, _ground.normal, OVERCLIP)
	# don't decrease velocity when going up or down a slope
	velocity = velocity.normalized() * vel

	if velocity.x == 0.0 and velocity.y == 0.0:
		return
	PM_StepSlideMove(0.0)


func PM_AirMove() -> void:
	PM_Friction()
	var fmove := float(_cmd.forwardmove)
	var smove := float(_cmd.rightmove)
	var scale := PM_CmdScale()

	_forward.z = 0.0
	_right.z = 0.0
	_forward = _forward.normalized()
	_right = _right.normalized()

	var wishvel := _forward * fmove + _right * smove
	wishvel.z = 0.0
	var wishdir := wishvel.normalized()
	var wishspeed := wishvel.length() * scale
	if velocity.dot(wishdir) < 0.0:
		wishspeed *= pm_airDecelRate
	PM_Accelerate(wishdir, wishspeed, pm_airaccelerate)

	if _ground_plane:
		velocity = PM_ClipVelocity(velocity, _ground.normal, OVERCLIP)
	PM_StepSlideMove(1.0)


func PM_WaterMove() -> void:
	# TODO: PM_CheckWaterJump / PM_WaterJumpMove, waterheight-based sinking
	PM_Friction()
	var scale := PM_CmdScale()
	var ladder := watertype & JACollisionWorld.CONTENTS_LADDER
	var wishvel: Vector3
	if scale == 0.0:
		wishvel = Vector3(0, 0, 0 if ladder else -60)
	else:
		wishvel = _forward * (scale * _cmd.forwardmove) + _right * (scale * _cmd.rightmove)
		wishvel.z += scale * _cmd.upmove
	var wishdir := wishvel.normalized()
	var wishspeed := wishvel.length()
	if ladder:
		wishspeed = minf(wishspeed, speed * pm_ladderScale)
		PM_Accelerate(wishdir, wishspeed, pm_flyaccelerate)
	else:
		wishspeed = minf(wishspeed, speed * pm_swimScale)
		PM_Accelerate(wishdir, wishspeed, pm_wateraccelerate)
	if _ground_plane and velocity.dot(_ground.normal) < 0.0:
		var vel := velocity.length()
		velocity = PM_ClipVelocity(velocity, _ground.normal, OVERCLIP).normalized() * vel
	PM_SlideMove(0.0)


func PM_NoclipMove() -> void:
	var spd := velocity.length()
	if spd < 1.0:
		velocity = Vector3.ZERO
	else:
		var drop := (pm_stopspeed if spd < pm_stopspeed else spd) * pm_friction * 1.5 * _frametime
		velocity *= maxf(spd - drop, 0.0) / spd
	var scale := PM_CmdScale()
	var wishvel := _forward * (scale * _cmd.forwardmove) + _right * (scale * _cmd.rightmove)
	wishvel.z += scale * _cmd.upmove
	PM_Accelerate(wishvel.normalized(), wishvel.length(), pm_accelerate)
	origin += velocity * _frametime


func PM_SetWaterLevel() -> void:
	waterlevel = 0
	watertype = 0
	var mask := JACollisionWorld.MASK_WATER | JACollisionWorld.CONTENTS_LADDER
	var p := origin + Vector3(0, 0, DEFAULT_MINS_2 + 1)
	var cont := world.point_contents(p, mask)
	if cont & mask:
		var sample2 := viewheight - DEFAULT_MINS_2
		var sample1 := sample2 / 2.0
		watertype = cont
		waterlevel = 1
		cont = world.point_contents(origin + Vector3(0, 0, DEFAULT_MINS_2 + sample1), mask)
		if cont & mask:
			waterlevel = 2
			cont = world.point_contents(origin + Vector3(0, 0, DEFAULT_MINS_2 + sample2), mask)
			if cont & mask:
				waterlevel = 3


func PM_CheckDuck() -> void:
	var old_height := maxs.z
	if _cmd.upmove < 0:
		maxs.z = crouchheight
		viewheight = crouchheight + STANDARD_VIEWHEIGHT_OFFSET
		if not on_ground and not (pm_flags & PMF_DUCKED):
			# ducking in mid-air raises the feet
			origin.z += old_height - maxs.z
		pm_flags |= PMF_DUCKED
	else:
		if pm_flags & PMF_DUCKED:
			maxs.z = standheight
			if not on_ground:
				origin.z += old_height - maxs.z
				var tr := _trace(origin, origin)
				if not tr.allsolid:
					pm_flags &= ~PMF_DUCKED
				else:
					origin.z -= old_height - maxs.z
			else:
				var tr := _trace(origin, origin)
				if not tr.allsolid:
					pm_flags &= ~PMF_DUCKED
		if pm_flags & PMF_DUCKED:
			maxs.z = crouchheight
			viewheight = crouchheight + STANDARD_VIEWHEIGHT_OFFSET
		else:
			maxs.z = standheight
			viewheight = standheight + STANDARD_VIEWHEIGHT_OFFSET


func PM_GroundTrace() -> void:
	var point := origin - Vector3(0, 0, 0.25)
	var tr := _trace(origin, point)
	_ground = tr
	if tr.allsolid:
		# PM_CorrectAllSolid
		on_ground = false
		ground_model = -1
		_ground_plane = false
		_walking = false
		return
	if tr.fraction == 1.0 or gravity <= 0.0:
		# PM_GroundTraceMissed (fall-to-death prediction is NPC-only)
		on_ground = false
		ground_model = -1
		_ground_plane = false
		_walking = false
		return
	# thrown off the ground or leaving it fast
	if velocity.z > 100.0 and velocity.dot(tr.normal) > 10.0:
		on_ground = false
		ground_model = -1
		_ground_plane = false
		_walking = false
		return
	if tr.normal.z < MIN_WALK_NORMAL:
		on_ground = false
		ground_model = -1
		_ground_plane = true
		_walking = false
		return
	_ground_plane = true
	_walking = true
	if pm_flags & PMF_TIME_WATERJUMP:
		pm_flags &= ~(PMF_TIME_WATERJUMP | PMF_TIME_LAND)
		pm_time = 0
	if not on_ground:
		# PM_CrashLand (TODO: landing animations, falling damage, footstep events)
		events.append("land")
		if _previous_velocity.z < -200.0:
			pm_flags |= PMF_TIME_LAND
			pm_time = 250
		if _cmd.forwardmove == 0 and _cmd.rightmove == 0:
			velocity.z = 0.0
	on_ground = true
	ground_model = world.brush_model[tr.brush] if tr.brush >= 0 else 0
	pm_flags &= ~PMF_JUMPING
	PM_AddTouchEnt(tr)


## PM_SlideMove (bg_slidemove.cpp). Returns true if the velocity was clipped.
func PM_SlideMove(grav_mod: float) -> bool:
	var numbumps := 4
	var primal_velocity := velocity
	var end_velocity := velocity
	if grav_mod != 0.0:
		end_velocity.z -= gravity * _frametime * grav_mod
		velocity.z = (velocity.z + end_velocity.z) * 0.5
		primal_velocity.z = end_velocity.z
		if _ground_plane:
			velocity = PM_ClipVelocity(velocity, _ground.normal, OVERCLIP)

	var time_left := _frametime
	var planes: Array[Vector3] = []
	if _ground_plane:
		planes.append(_ground.normal)
	planes.append(velocity.normalized())

	var bumpcount := 0
	while bumpcount < numbumps:
		var end := origin + velocity * time_left
		var tr := _trace(origin, end)
		if tr.allsolid:
			velocity.z = 0.0
			return true
		if tr.fraction > 0.0:
			origin = tr.endpos
		if tr.fraction == 1.0:
			break
		PM_AddTouchEnt(tr)
		time_left -= time_left * tr.fraction
		if planes.size() >= MAX_CLIP_PLANES:
			velocity = Vector3.ZERO
			return true
		var normal := tr.normal
		# if this is the same plane we hit before, nudge velocity out along it
		var same := false
		for p in planes:
			if normal.dot(p) > 0.99:
				velocity += normal
				same = true
				break
		if same:
			bumpcount += 1
			continue
		planes.append(normal)

		for i in planes.size():
			var into := velocity.dot(planes[i])
			if into >= 0.1:
				continue
			if -into > _impact_speed:
				_impact_speed = -into
			var clip_velocity := PM_ClipVelocity(velocity, planes[i], OVERCLIP)
			var end_clip_velocity := PM_ClipVelocity(end_velocity, planes[i], OVERCLIP)
			var stop := false
			for j in planes.size():
				if j == i:
					continue
				if clip_velocity.dot(planes[j]) >= 0.1:
					continue
				clip_velocity = PM_ClipVelocity(clip_velocity, planes[j], OVERCLIP)
				end_clip_velocity = PM_ClipVelocity(end_clip_velocity, planes[j], OVERCLIP)
				if clip_velocity.dot(planes[i]) >= 0.0:
					continue
				# slide along the crease
				var dir := planes[i].cross(planes[j]).normalized()
				clip_velocity = dir * dir.dot(velocity)
				end_clip_velocity = dir * dir.dot(end_velocity)
				for k in planes.size():
					if k == i or k == j:
						continue
					if clip_velocity.dot(planes[k]) >= 0.1:
						continue
					stop = true
					break
				if stop:
					break
			if stop:
				velocity = Vector3.ZERO
				return true
			velocity = clip_velocity
			end_velocity = end_clip_velocity
			break
		bumpcount += 1

	if grav_mod != 0.0:
		velocity = end_velocity
	if pm_time:
		velocity = primal_velocity
	return bumpcount != 0


## PM_StepSlideMove with g_stepSlideFix 1.
func PM_StepSlideMove(grav_mod: float) -> void:
	var start_o := origin
	var start_v := velocity
	if not PM_SlideMove(grav_mod):
		return
	var step := STEPSIZE
	var tr := _trace(start_o, start_o - Vector3(0, 0, step))
	if velocity.z > 0.0 and (tr.fraction == 1.0 or tr.normal.z < 0.7):
		return
	if velocity.x == 0.0 and velocity.y == 0.0:
		return
	var down_o := origin
	var down_v := velocity
	tr = _trace(start_o, start_o + Vector3(0, 0, step))
	if tr.allsolid or tr.startsolid or tr.fraction == 0.0:
		return
	var up_end := tr.endpos
	origin = up_end
	velocity = start_v
	PM_SlideMove(grav_mod)

	var slide_move := down_o - start_o
	var step_up_move := up_end - origin
	if absf(step_up_move.x) < 0.1 and absf(step_up_move.y) < 0.1 and slide_move.length_squared() > step_up_move.length_squared():
		origin = down_o
		velocity = down_v
		return
	tr = _trace(origin, origin - Vector3(0, 0, step))
	var skip_step := false
	if tr.normal.z < MIN_WALK_NORMAL:
		var step_vec := (tr.endpos - down_o).normalized()
		if step_vec.z > 1.0 - MIN_WALK_NORMAL:
			skip_step = true
	if not tr.allsolid and not skip_step:
		origin = tr.endpos
		if tr.fraction < 1.0:
			velocity = PM_ClipVelocity(velocity, tr.normal, OVERCLIP)
		if origin.z - start_o.z > 2.0:
			events.append("step")
	else:
		origin = down_o
		velocity = down_v
