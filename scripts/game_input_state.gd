extends RefCounted
## Polling state shared by gameplay and the development input driver.
## Native sessions retain Godot's existing input semantics.
var synthetic := false
var pointer := Vector2.ZERO
var keys: Dictionary = {}
var buttons: Dictionary = {}


func mouse_position(viewport: Viewport) -> Vector2:
	return pointer if synthetic else viewport.get_mouse_position()


func is_key_pressed(key: int) -> bool:
	return keys.has(key) if synthetic else Input.is_key_pressed(key)


func is_mouse_button_pressed(button: int) -> bool:
	return buttons.has(button) if synthetic else Input.is_mouse_button_pressed(button)


func accept(event: InputEvent) -> void:
	if event is InputEventMouse:
		pointer = event.position
	if event is InputEventKey:
		var code: int = event.keycode if event.keycode != 0 else event.physical_keycode
		if event.pressed:
			keys[code] = true
		else:
			keys.erase(code)
	elif event is InputEventMouseButton:
		if event.pressed:
			buttons[event.button_index] = true
		else:
			buttons.erase(event.button_index)


func button_mask() -> int:
	var mask := 0
	for button in buttons:
		mask |= 1 << (int(button) - 1)
	return mask


func clear() -> void:
	keys.clear()
	buttons.clear()
