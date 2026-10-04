class_name FreeFlyCamera
extends Camera3D
## Noclip-style camera: click to capture the mouse, Esc to release,
## WASD to move, Space/C for up/down, Shift for speed.

@export var speed := 8.0          # m/s, about the original run speed (320 ups)
@export var fast_multiplier := 4.0
@export var mouse_sensitivity := 0.15

var _yaw := 0.0
var _pitch := 0.0


func set_view(pos: Vector3, yaw_deg: float, pitch_deg: float = 0.0) -> void:
	position = pos
	# Quake yaw 0 looks along +X; a Godot camera looks along -Z, so add -90.
	_yaw = yaw_deg - 90.0
	_pitch = pitch_deg
	_apply()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	elif event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	elif event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		_yaw -= event.relative.x * mouse_sensitivity
		_pitch = clampf(_pitch + event.relative.y * mouse_sensitivity, -89.0, 89.0)
		_apply()


func _process(delta: float) -> void:
	var dir := Vector3.ZERO
	dir -= basis.z * Input.get_axis("move_back", "move_forward")
	dir += basis.x * Input.get_axis("move_left", "move_right")
	dir.y += Input.get_axis("move_down", "move_up")
	if dir.length_squared() > 0.0:
		var s := speed * (fast_multiplier if Input.is_key_pressed(KEY_SHIFT) else 1.0)
		position += dir.normalized() * s * delta


func _apply() -> void:
	basis = Basis(Vector3.UP, deg_to_rad(_yaw)) * Basis(Vector3.RIGHT, deg_to_rad(-_pitch))
