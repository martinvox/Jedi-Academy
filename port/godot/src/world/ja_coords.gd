class_name JACoords
extends RefCounted
## The single place where Quake space turns into Godot space.
##
## Quake: X forward, Y left, Z up, 1 unit = 1 inch (by convention).
## Godot: X right, Y up, -Z forward, metres.
## Mapping (a proper rotation, so triangle winding is preserved):
##   godot = (q.x, q.z, -q.y) * SCALE
## With this mapping a Quake yaw (CCW about +Z, from +X) is the same angle
## as a Godot rotation about +Y, so yaw values carry over unchanged.

const SCALE := 0.0254


static func pos(q: Vector3) -> Vector3:
	return Vector3(q.x, q.z, -q.y) * SCALE


static func dir(q: Vector3) -> Vector3:
	return Vector3(q.x, q.z, -q.y)


## Q3 plane: dot(normal, p) = dist, solid side is dot <= dist.
## Godot Plane has the same convention (points "over" the plane are outside).
static func plane(normal: Vector3, dist: float) -> Plane:
	return Plane(dir(normal), dist * SCALE)


## Quake "angles" key is "pitch yaw roll" in degrees (see G_SpawnVector /
## AngleVectors in q_math). Pitch is positive looking down.
static func basis_from_angles(pitch_yaw_roll: Vector3) -> Basis:
	var pitch := deg_to_rad(pitch_yaw_roll.x)
	var yaw := deg_to_rad(pitch_yaw_roll.y)
	var roll := deg_to_rad(pitch_yaw_roll.z)
	# Entity forward is local +X (Quake forward). The result maps +X to
	# AngleVectors' forward = (cp*cy, cp*sy, -sp), converted to Godot axes.
	# Pitch turns about Quake +Y, which is Godot -Z, hence BACK with -pitch.
	var b := Basis(Vector3.UP, yaw)
	b = b * Basis(Vector3.BACK, -pitch)
	b = b * Basis(Vector3.RIGHT, roll)
	return b


## Parses "x y z" strings from entity keys.
static func parse_vec3(s: String) -> Vector3:
	var p := s.split_floats(" ", false)
	if p.size() < 3:
		return Vector3.ZERO
	return Vector3(p[0], p[1], p[2])


## Entity orientation following G_SetAngles / spawn conventions:
## "angles" wins over "angle" (yaw only).
static func entity_angles(ent: Dictionary) -> Vector3:
	if ent.has("angles"):
		return parse_vec3(ent["angles"])
	if ent.has("angle"):
		var a := float(ent["angle"])
		# ANGLE_UP / ANGLE_DOWN are pitch overrides (qfiles.h)
		if a == -1.0:
			return Vector3(-90, 0, 0)
		if a == -2.0:
			return Vector3(90, 0, 0)
		return Vector3(0, a, 0)
	return Vector3.ZERO
