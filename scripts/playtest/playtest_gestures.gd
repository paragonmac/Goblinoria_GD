extends RefCounted
class_name PlaytestGestures
## Compile and deliver deterministic, synthetic input gestures for playtests.
##
## The driver deliberately uses the same Viewport input path as a real event.
## Main's input adapter is updated first, so polling code and event handlers see
## the same state during the frame in which an event is delivered.

const MAX_EXPANDED_STAGES := 128
const MAX_TEXT_LENGTH := 64
const MAX_WAIT_FRAMES := 60

var main
var delivering := false

var _stages: Array = []
var _stage_index := 0
var _held_keys: Dictionary = {}
var _held_buttons: Dictionary = {}
var _pressed_controls: Dictionary = {}
var _pointer := Vector2.ZERO


func initialize(main_ref) -> void:
	main = main_ref
	_stages.clear()
	_stage_index = 0
	_held_keys.clear()
	_held_buttons.clear()
	_pressed_controls.clear()
	delivering = false
	_pointer = _read_pointer()


func compile(events: Array) -> Dictionary:
	if delivering or not _stages.is_empty():
		return _failure("a gesture is already being delivered")
	if events == null:
		return _failure("events must be an array")

	var stages: Array = []
	var held_keys := _held_keys.duplicate()
	var held_buttons := _held_buttons.duplicate()
	var pointer := _pointer

	for event_index in range(events.size()):
		var event = events[event_index]
		if not event is Dictionary:
			return _failure("event %d must be an object" % event_index)
		var expanded := _compile_event(event, held_keys, held_buttons, pointer)
		if not expanded.ok:
			return _failure("event %d: %s" % [event_index, expanded.error])
		for stage in expanded.stages:
			stages.append(stage)
			if stages.size() > MAX_EXPANDED_STAGES:
				return _failure("expanded gesture exceeds %d stages" % MAX_EXPANDED_STAGES)
		# The helper mutates state copies by reference. Its final pointer is
		# carried separately because Vector2 is a value type.
		pointer = expanded.pointer

	_stages = stages
	_stage_index = 0
	# `delivering` is a synchronous dispatch guard. It is raised only around
	# Viewport.push_input below so Main can distinguish a synthetic event that
	# is currently being routed from a real event between gesture stages.
	delivering = false
	return {"ok": true, "stages": stages.duplicate(true)}


func deliver(stage: Dictionary) -> Dictionary:
	if _stages.is_empty():
		return _failure("no gesture is queued")
	if not stage is Dictionary:
		return _failure("stage must be an object")
	if _stage_index >= _stages.size():
		return _failure("gesture has no remaining stages")

	# The controller normally passes the exact dictionary returned by compile.
	# Comparing kind and payload rather than object identity also accommodates a
	# transport round trip that reconstructs the JSON dictionary.
	if not _stage_matches(stage, _stages[_stage_index]):
		return _failure("stage is out of order")

	var result := _deliver_stage(stage)
	if not result.ok:
		return result
	_stage_index += 1
	return {"ok": true}


func finish() -> void:
	## Complete a normally processed action and release residual key/button state.
	## Mouse releases are intentionally not pushed through the GUI: a partial
	## gesture must never turn cleanup into a button activation or selection.
	var had_buttons := not _held_buttons.is_empty()
	if had_buttons:
		_cancel_context_owners()
	_release_all(false)
	if had_buttons:
		_clear_gui_pressed_state()
	_stages.clear()
	_stage_index = 0
	delivering = false


func cancel() -> void:
	## Abort a pending action and clear world context ownership. Cleanup itself
	## dispatches no mouse release.
	# Main clears pending selection/context ownership first. This is essential:
	# releasing a synthetic mouse button through a live world could otherwise
	# commit a partial selection. Keep this optional for small unit fixtures.
	if main != null and main.has_method("_cancel_context_input"):
		main._cancel_context_input()
	_cancel_jobs_drag()
	_release_all(false)
	_clear_gui_pressed_state()
	if main != null and main.has_method("_sync_context_key_state"):
		main._sync_context_key_state()
	_stages.clear()
	_stage_index = 0
	delivering = false


func is_complete() -> bool:
	return not _stages.is_empty() and _stage_index >= _stages.size()


func remaining_stages() -> int:
	return maxi(0, _stages.size() - _stage_index)


func _compile_event(event: Dictionary, held_keys: Dictionary, held_buttons: Dictionary,
		pointer: Vector2) -> Dictionary:
	var kind_value = event.get("kind", null)
	if not kind_value is String:
		return _failure("kind must be a string")
	var kind := String(kind_value).to_lower()
	match kind:
		"pointer_move":
			var point_result := _read_point(event.get("point", null), "point")
			if not point_result.ok:
				return point_result
			var point: Vector2 = point_result.point
			return {"ok": true, "stages": [{"kind": "pointer_move", "point": _point_array(point)}], "pointer": point}
		"button":
			var button_result := _read_button(event.get("button", null))
			if not button_result.ok:
				return button_result
			var state_result := _read_state(event.get("state", null))
			if not state_result.ok:
				return state_result
			var button: int = button_result.button
			var state: String = state_result.state
			if state == "down":
				if held_buttons.has(button):
					return _failure("button is already held")
				held_buttons[button] = true
			else:
				if not held_buttons.has(button):
					return _failure("button is not held")
				held_buttons.erase(button)
			var point := pointer
			if event.has("point"):
				var button_point_result := _read_point(event.get("point"), "point")
				if not button_point_result.ok:
					return button_point_result
				point = button_point_result.point
			return {"ok": true, "stages": [{
				"kind": "button", "button": button, "state": state,
				"point": _point_array(point) if event.has("point") else null,
			}], "pointer": point}
		"click":
			var click_point := _read_point(event.get("point", null), "point")
			if not click_point.ok:
				return click_point
			var click_button := _read_button(event.get("button", "left"))
			if not click_button.ok:
				return click_button
			var b: int = click_button.button
			if held_buttons.has(b):
				return _failure("button is already held")
			held_buttons[b] = true
			held_buttons.erase(b)
			var p: Vector2 = click_point.point
			return {"ok": true, "stages": [
				{"kind": "pointer_move", "point": _point_array(p)},
				{"kind": "button", "button": b, "state": "down", "point": _point_array(p)},
				{"kind": "button", "button": b, "state": "up", "point": _point_array(p)},
			], "pointer": p}
		"drag":
			var from_result := _read_point(event.get("from", null), "from")
			if not from_result.ok:
				return from_result
			var to_result := _read_point(event.get("to", null), "to")
			if not to_result.ok:
				return to_result
			var drag_button := _read_button(event.get("button", "left"))
			if not drag_button.ok:
				return drag_button
			var steps_result := _read_steps(event.get("steps", 4))
			if not steps_result.ok:
				return steps_result
			var drag_button_index: int = drag_button.button
			if held_buttons.has(drag_button_index):
				return _failure("button is already held")
			held_buttons[drag_button_index] = true
			var from_point: Vector2 = from_result.point
			var to_point: Vector2 = to_result.point
			var steps: int = steps_result.steps
			var drag_stages: Array = [{"kind": "pointer_move", "point": _point_array(from_point)},
				{"kind": "button", "button": drag_button_index, "state": "down", "point": _point_array(from_point)}]
			for step in range(1, steps + 1):
				var fraction := float(step) / float(steps)
				drag_stages.append({"kind": "pointer_move", "point": _point_array(from_point.lerp(to_point, fraction))})
			drag_stages.append({"kind": "button", "button": drag_button_index, "state": "up", "point": _point_array(to_point)})
			held_buttons.erase(drag_button_index)
			return {"ok": true, "stages": drag_stages, "pointer": to_point}
		"wheel":
			var delta = event.get("delta", null)
			if not _is_number(delta) or (float(delta) != 1.0 and float(delta) != -1.0):
				return _failure("delta must be 1 or -1")
			var wheel_point := pointer
			if event.has("point"):
				var wheel_point_result := _read_point(event.get("point"), "point")
				if not wheel_point_result.ok:
					return wheel_point_result
				wheel_point = wheel_point_result.point
			var wheel_button := MOUSE_BUTTON_WHEEL_UP if float(delta) > 0.0 else MOUSE_BUTTON_WHEEL_DOWN
			return {"ok": true, "stages": [{"kind": "wheel", "button": wheel_button, "point": _point_array(wheel_point)}], "pointer": wheel_point}
		"key":
			var key_result := _read_key(event.get("key", null))
			if not key_result.ok:
				return key_result
			var key_state := _read_state(event.get("state", null))
			if not key_state.ok:
				return key_state
			var key_code: int = key_result.key
			if key_state.state == "down":
				if held_keys.has(key_code):
					return _failure("key is already held")
				held_keys[key_code] = true
			else:
				if not held_keys.has(key_code):
					return _failure("key is not held")
				held_keys.erase(key_code)
			return {"ok": true, "stages": [{"kind": "key", "key": key_code, "state": key_state.state}], "pointer": pointer}
		"text":
			var text_value = event.get("text", null)
			if not text_value is String:
				return _failure("text must be a string")
			var text := String(text_value)
			if text.length() > MAX_TEXT_LENGTH:
				return _failure("text exceeds %d characters" % MAX_TEXT_LENGTH)
			var text_stages: Array = []
			for i in text.length():
				var codepoint := text.unicode_at(i)
				text_stages.append({"kind": "text", "unicode": codepoint, "state": "down"})
				text_stages.append({"kind": "text", "unicode": codepoint, "state": "up"})
			return {"ok": true, "stages": text_stages, "pointer": pointer}
		"wait", "wait_frames":
			var wait_result := _read_wait(event.get("frames", event.get("wait_frames", null)))
			if not wait_result.ok:
				return wait_result
			var wait_stages: Array = []
			for _frame in wait_result.frames:
				wait_stages.append({"kind": "wait"})
			return {"ok": true, "stages": wait_stages, "pointer": pointer}
		_:
			return _failure("unknown kind '%s'" % kind)


func _deliver_stage(stage: Dictionary) -> Dictionary:
	var kind_value = stage.get("kind", null)
	if not kind_value is String:
		return _failure("stage kind must be a string")
	var kind := String(kind_value).to_lower()
	if kind == "wait":
		return {"ok": true}
	var viewport := _get_viewport()
	if viewport == null:
		return _failure("main viewport is unavailable")
	match kind:
		"pointer_move":
			var point_result := _read_point(stage.get("point", null), "point")
			if not point_result.ok:
				return point_result
			var point: Vector2 = point_result.point
			var event := InputEventMouseMotion.new()
			event.position = point
			event.global_position = point
			event.relative = point - _pointer
			event.button_mask = _button_mask()
			_dispatch(event, viewport)
			_pointer = point
			return {"ok": true}
		"button":
			var button_result := _read_button(stage.get("button", null))
			if not button_result.ok:
				return button_result
			var state_result := _read_state(stage.get("state", null))
			if not state_result.ok:
				return state_result
			var point := _stage_point(stage)
			var event := InputEventMouseButton.new()
			event.position = point
			event.global_position = point
			event.button_index = button_result.button
			event.pressed = state_result.state == "down"
			_dispatch(event, viewport)
			if state_result.state == "down":
				_held_buttons[button_result.button] = true
			else:
				_held_buttons.erase(button_result.button)
				_pressed_controls.erase(button_result.button)
			_pointer = point if stage.has("point") else _pointer
			return {"ok": true}
		"wheel":
			var button_result := _read_wheel_button(stage.get("button", null))
			if not button_result.ok:
				return button_result
			var point := _stage_point(stage)
			var event := InputEventMouseButton.new()
			event.position = point
			event.global_position = point
			event.button_index = button_result.button
			event.pressed = true
			_dispatch(event, viewport)
			# Wheel buttons are transient and must never remain in the synthetic
			# polling adapter after their one event.
			_erase_adapter_button(button_result.button)
			_pointer = point if stage.has("point") else _pointer
			return {"ok": true}
		"key":
			var key_result := _read_key(stage.get("key", null))
			if not key_result.ok:
				return key_result
			var state_result := _read_state(stage.get("state", null))
			if not state_result.ok:
				return state_result
			var event := _make_key_event(key_result.key, state_result.state == "down")
			_dispatch(event, viewport)
			if state_result.state == "down":
				_held_keys[key_result.key] = true
			else:
				_held_keys.erase(key_result.key)
			return {"ok": true}
		"text":
			var unicode_value = stage.get("unicode", null)
			if not _is_number(unicode_value) or float(unicode_value) < 0.0 or float(unicode_value) > 0x10ffff:
				return _failure("text unicode value is invalid")
			var state_result := _read_state(stage.get("state", null))
			if not state_result.ok:
				return state_result
			var event := InputEventKey.new()
			event.unicode = int(unicode_value)
			event.pressed = state_result.state == "down"
			event.echo = false
			_set_modifiers(event, -1, event.pressed)
			_dispatch(event, viewport)
			return {"ok": true}
		_:
			return _failure("unknown stage kind '%s'" % kind)


func _dispatch(event: InputEvent, viewport: Viewport) -> void:
	# This ordering is intentional. Main's pollers run after begin_frame and
	# must observe the new state even when a Control consumes the event.
	if main != null and main.input_state != null:
		main.input_state.accept(event)
		if event is InputEventMouseButton:
			event.button_mask = main.input_state.button_mask()
		elif event is InputEventMouseMotion:
			event.button_mask = main.input_state.button_mask()
	if event is InputEventMouse:
		_set_modifiers(event)
	if event is InputEventMouseButton and event.pressed and _is_regular_button(event.button_index):
		_remember_button_target(viewport, event.button_index)
	delivering = true
	viewport.push_input(event, true)
	delivering = false
	if event is InputEventMouseButton and event.pressed and _is_regular_button(event.button_index):
		_remember_button_target(viewport, event.button_index)


func _make_key_event(key: int, pressed: bool) -> InputEventKey:
	var event := InputEventKey.new()
	event.keycode = key
	event.physical_keycode = key
	event.pressed = pressed
	event.echo = false
	_set_modifiers(event, key, pressed)
	return event


func _set_modifiers(event: InputEventWithModifiers, key: int = -1, prospective_key_down: bool = false) -> void:
	var shift := _held_keys.has(KEY_SHIFT)
	var ctrl := _held_keys.has(KEY_CTRL)
	var alt := _held_keys.has(KEY_ALT)
	var meta := _held_keys.has(KEY_META)
	if key == KEY_SHIFT: shift = prospective_key_down
	if key == KEY_CTRL: ctrl = prospective_key_down
	if key == KEY_ALT: alt = prospective_key_down
	if key == KEY_META: meta = prospective_key_down
	event.shift_pressed = shift
	event.ctrl_pressed = ctrl
	event.alt_pressed = alt
	event.meta_pressed = meta


func _is_regular_button(button: int) -> bool:
	return button in [MOUSE_BUTTON_LEFT, MOUSE_BUTTON_RIGHT, MOUSE_BUTTON_MIDDLE]


func _remember_button_target(viewport: Viewport, button: int) -> void:
	if _pressed_controls.has(button):
		return
	var hovered := viewport.gui_get_hovered_control()
	if not hovered is BaseButton:
		return
	_pressed_controls[button] = {
		"target": hovered,
		"pressed": hovered.button_pressed,
		"disabled": hovered.disabled,
	}


func _release_all(dispatch_keys: bool) -> void:
	var viewport := _get_viewport()
	var keys_to_clear := _held_keys.keys()
	if dispatch_keys and viewport != null:
		for key in keys_to_clear:
			var event := _make_key_event(int(key), false)
			_dispatch(event, viewport)
	if main != null and main.input_state != null:
		for key in keys_to_clear:
			main.input_state.keys.erase(key)
		for button in _held_buttons.keys():
			main.input_state.buttons.erase(button)
		var key_state = main.get("key_state")
		if key_state is Dictionary:
			for key in keys_to_clear:
				key_state.erase(key)
	_held_keys.clear()
	_held_buttons.clear()


func _cancel_context_owners() -> void:
	if main != null and main.has_method("_cancel_context_input"):
		main._cancel_context_input()
	_cancel_jobs_drag()


func _cancel_jobs_drag() -> void:
	if main == null:
		return
	var ui = main.get("colony_ui")
	if ui == null or not ui.has_method("get"):
		return
	var jobs = ui.get("jobs_popup")
	if jobs != null and jobs.has_method("cancel_drag"):
		jobs.cancel_drag()
	var window_layout = ui.get("layout")
	if window_layout != null and window_layout.has_method("cancel_interaction"):
		window_layout.cancel_interaction()


func _clear_gui_pressed_state() -> void:
	if main == null:
		return
	var ui = main.get("colony_ui")
	if ui != null:
		var held = ui.get("_held_buttons")
		if held is Dictionary:
			held.clear()
	for button in _pressed_controls.keys():
		var state = _pressed_controls[button]
		var target = state.get("target") if state is Dictionary else null
		if not is_instance_valid(target) or not target is BaseButton:
			continue
		var was_disabled := bool(state.get("disabled", false))
		var was_pressed := bool(state.get("pressed", false))
		# Toggling disabled briefly makes BaseButton abandon its private
		# mouse-press state without synthesizing a release (which could activate
		# the control). Restore the target's prior toggle/disabled values.
		target.disabled = true
		target.set_pressed_no_signal(was_pressed)
		target.disabled = was_disabled
	_pressed_controls.clear()


func _stage_point(stage: Dictionary) -> Vector2:
	if stage.has("point") and stage.point is Vector2:
		return stage.point
	if stage.has("point"):
		var result := _read_point(stage.point, "point")
		if result.ok:
			return result.point
	return _pointer


func _stage_matches(actual: Dictionary, expected: Dictionary) -> bool:
	if String(actual.get("kind", "")).to_lower() != String(expected.get("kind", "")).to_lower():
		return false
	for key in expected.keys():
		if key == "point":
			var actual_point = actual.get(key, null)
			var expected_point = expected.get(key, null)
			if expected_point is Vector2 and actual_point is Array:
				var point_result := _read_point(actual_point, "point")
				if not point_result.ok or point_result.point != expected_point:
					return false
			elif actual_point is Vector2 and expected_point is Vector2:
				if actual_point != expected_point: return false
			elif actual_point != expected_point:
				return false
		elif actual.get(key, null) != expected.get(key, null):
			return false
	return true


func _read_point(value, label: String) -> Dictionary:
	if not value is Array or value.size() != 2 or not _is_number(value[0]) or not _is_number(value[1]):
		return _failure("%s must be a two-number array" % label)
	var point := Vector2(float(value[0]), float(value[1]))
	if not point.is_finite():
		return _failure("%s must contain finite coordinates" % label)
	var size := _viewport_size()
	if size.x > 0.0 and size.y > 0.0 and (point.x < 0.0 or point.y < 0.0 or point.x >= size.x or point.y >= size.y):
		return _failure("%s is outside the viewport" % label)
	if point.x < 0.0 or point.y < 0.0:
		return _failure("%s is outside the viewport" % label)
	return {"ok": true, "point": point}


func _point_array(point: Vector2) -> Array:
	return [point.x, point.y]


func _read_button(value) -> Dictionary:
	if value is String:
		match String(value).to_lower():
			"left": return {"ok": true, "button": MOUSE_BUTTON_LEFT}
			"right": return {"ok": true, "button": MOUSE_BUTTON_RIGHT}
			"middle": return {"ok": true, "button": MOUSE_BUTTON_MIDDLE}
			_: return _failure("button must be left, right, or middle")
	if _is_number(value) and int(value) in [MOUSE_BUTTON_LEFT, MOUSE_BUTTON_RIGHT, MOUSE_BUTTON_MIDDLE]:
		return {"ok": true, "button": int(value)}
	return _failure("button must be left, right, or middle")


func _read_wheel_button(value) -> Dictionary:
	if _is_number(value) and int(value) in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]:
		return {"ok": true, "button": int(value)}
	return _failure("wheel button is invalid")


func _read_state(value) -> Dictionary:
	if value is String:
		var state := String(value).to_lower()
		if state in ["down", "up"]:
			return {"ok": true, "state": state}
	return _failure("state must be down or up")


func _read_steps(value) -> Dictionary:
	if not _is_integer(value) or int(value) < 1 or int(value) > MAX_EXPANDED_STAGES:
		return _failure("steps must be an integer from 1 to %d" % MAX_EXPANDED_STAGES)
	return {"ok": true, "steps": int(value)}


func _read_wait(value) -> Dictionary:
	if not _is_integer(value) or int(value) < 1 or int(value) > MAX_WAIT_FRAMES:
		return _failure("frames must be an integer from 1 to %d" % MAX_WAIT_FRAMES)
	return {"ok": true, "frames": int(value)}


func _read_key(value) -> Dictionary:
	if _is_integer(value):
		if int(value) <= 0:
			return _failure("key code must be positive")
		return {"ok": true, "key": int(value)}
	if not value is String:
		return _failure("key must be a name or character")
	var name := String(value)
	if name.length() == 1:
		var character := name.unicode_at(0)
		if character >= 97 and character <= 122:
			character -= 32
		return {"ok": true, "key": character}
	var normalized := name.to_lower().replace("_", "").replace("-", "").replace(" ", "")
	var names := {
		"escape": KEY_ESCAPE, "esc": KEY_ESCAPE, "shift": KEY_SHIFT,
		"ctrl": KEY_CTRL, "control": KEY_CTRL, "alt": KEY_ALT, "meta": KEY_META,
		"super": KEY_META, "tab": KEY_TAB, "enter": KEY_ENTER, "return": KEY_ENTER,
		"backspace": KEY_BACKSPACE, "space": KEY_SPACE, "up": KEY_UP, "down": KEY_DOWN,
		"left": KEY_LEFT, "right": KEY_RIGHT, "pageup": KEY_PAGEUP, "pagedown": KEY_PAGEDOWN,
		"home": KEY_HOME, "end": KEY_END, "delete": KEY_DELETE, "insert": KEY_INSERT,
		# Punctuation keycodes are their ASCII values. This also keeps the
		# parser independent of keyboard-layout-specific aliases.
		"comma": 44, "period": 46, "dot": 46,
		"bracketleft": 91, "bracketright": 93,
		"slash": 47, "backslash": 92, "semicolon": 59,
		"apostrophe": 39, "quote": 39, "grave": 96,
		"capslock": KEY_CAPSLOCK, "minus": 45, "plus": 61,
	}
	if names.has(normalized):
		return {"ok": true, "key": int(names[normalized])}
	if normalized.begins_with("f") and normalized.substr(1).is_valid_int():
		var function_number := int(normalized.substr(1))
		if function_number >= 1 and function_number <= 12:
			return {"ok": true, "key": KEY_F1 + function_number - 1}
	return _failure("unknown key '%s'" % name)


func _get_viewport() -> Viewport:
	if main == null:
		return null
	var viewport = main.get_viewport()
	return viewport if viewport is Viewport else null


func _viewport_size() -> Vector2:
	var viewport := _get_viewport()
	if viewport == null:
		return Vector2.ZERO
	var size := viewport.get_visible_rect().size
	return size if size.x > 0.0 and size.y > 0.0 else viewport.size


func _read_pointer() -> Vector2:
	if main == null or main.input_state == null:
		return Vector2.ZERO
	# Playtest input is fully synthetic; never seed a gesture from the OS cursor.
	return main.input_state.pointer if main.input_state.synthetic else Vector2.ZERO


func _button_mask() -> int:
	if main != null and main.input_state != null:
		return main.input_state.button_mask()
	var mask := 0
	for button in _held_buttons:
		mask |= 1 << (int(button) - 1)
	return mask


func _erase_adapter_button(button: int) -> void:
	if main != null and main.input_state != null:
		main.input_state.buttons.erase(button)


func _is_number(value) -> bool:
	return typeof(value) in [TYPE_INT, TYPE_FLOAT]


func _is_integer(value) -> bool:
	return _is_number(value) and float(value) == floor(float(value)) and absf(float(value)) <= 9007199254740991.0


func _is_modifier(key: int) -> bool:
	return key in [KEY_SHIFT, KEY_CTRL, KEY_ALT, KEY_META]


func _failure(message: String) -> Dictionary:
	return {"ok": false, "stages": [], "error": message}
