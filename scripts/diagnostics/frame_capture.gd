extends RefCounted
class_name FrameCapture
## Main-thread frame boundary adapter shared by bug and playtest captures.
## Scene reads happen in the callbacks; the image is handed to the writer only.

const SCREENSHOT_MAX_PIXELS := 8 * 1024 * 1024

var owner
var _pending: Dictionary = {}
var _last_result: Dictionary = {}


func initialize(owner_ref) -> void:
	owner = owner_ref
	if not RenderingServer.frame_pre_draw.is_connected(_on_pre_draw):
		RenderingServer.frame_pre_draw.connect(_on_pre_draw)
	if not RenderingServer.frame_post_draw.is_connected(_on_post_draw):
		RenderingServer.frame_post_draw.connect(_on_post_draw)


func begin(operation_id: String, pre_snapshot: Callable, post_snapshot: Callable = Callable(), metadata: Dictionary = {}) -> Dictionary:
	if not _pending.is_empty():
		return {"state": "busy", "operation_id": str(_pending.get("operation_id", ""))}
	_pending = {"operation_id": operation_id, "pre_snapshot": pre_snapshot,
		"post_snapshot": post_snapshot, "metadata": metadata.duplicate(true),
		"requested_usec": Time.get_ticks_usec()}
	return {"state": "pending", "operation_id": operation_id}


func pending() -> bool:
	return not _pending.is_empty()


func pre_draw() -> void:
	_on_pre_draw()


func post_draw() -> Dictionary:
	_on_post_draw()
	return take_result()


func poll_headless() -> Dictionary:
	if _pending.is_empty() or DisplayServer.get_name() != "headless":
		return {}
	_on_pre_draw()
	_on_post_draw()
	return take_result()


func timeout_result() -> Dictionary:
	## Finish evidence collection without pretending a draw boundary or reading pixels.
	## The callbacks still snapshot scene state, but this path never calls _readback().
	if _pending.is_empty():
		return {}
	var pre_callback: Callable = _pending.get("pre_snapshot", Callable())
	var pre_value: Variant = pre_callback.call() if pre_callback.is_valid() else {}
	var pre_snapshot: Dictionary = pre_value.duplicate(true) if pre_value is Dictionary else {"unavailable": "pre_snapshot"}
	var post_callback: Callable = _pending.get("post_snapshot", Callable())
	var post_value: Variant = post_callback.call() if post_callback.is_valid() else {}
	var post_snapshot: Dictionary = post_value.duplicate(true) if post_value is Dictionary else {"unavailable": "post_snapshot"}
	var now := Time.get_ticks_usec()
	var screenshot := {
		"available": false, "reason": "render_timeout", "timeout": true,
		"real_draw_boundary": false, "pre_draw_frame": -1, "post_draw_frame": -1,
		"pre_draw_usec": now, "post_draw_usec": now,
	}
	var result := {"operation_id": _pending.operation_id, "pre_snapshot": pre_snapshot,
		"post_snapshot": post_snapshot, "metadata": _pending.get("metadata", {}).duplicate(true),
		"screenshot": screenshot, "image": null}
	_last_result = result
	_pending.clear()
	return take_result()


func take_result() -> Dictionary:
	var result: Dictionary = _last_result
	_last_result = {}
	return result


func shutdown() -> void:
	if RenderingServer.frame_pre_draw.is_connected(_on_pre_draw):
		RenderingServer.frame_pre_draw.disconnect(_on_pre_draw)
	if RenderingServer.frame_post_draw.is_connected(_on_post_draw):
		RenderingServer.frame_post_draw.disconnect(_on_post_draw)
	_pending.clear()
	_last_result.clear()
	owner = null


func _on_pre_draw() -> void:
	if _pending.is_empty() or _pending.has("pre"):
		return
	var callback: Callable = _pending.get("pre_snapshot", Callable())
	var value: Variant = callback.call() if callback.is_valid() else {}
	_pending["pre"] = value.duplicate(true) if value is Dictionary else {"unavailable": "pre_snapshot"}
	_pending["pre_draw_frame"] = Engine.get_frames_drawn()
	_pending["pre_draw_usec"] = Time.get_ticks_usec()


func _on_post_draw() -> void:
	if _pending.is_empty() or not _pending.has("pre"):
		return
	var callback: Callable = _pending.get("post_snapshot", Callable())
	var post_value: Variant = callback.call() if callback.is_valid() else {}
	var post_snapshot: Dictionary = post_value.duplicate(true) if post_value is Dictionary else {"unavailable": "post_snapshot"}
	var metadata: Dictionary = _pending.get("metadata", {})
	var image_result: Dictionary = _readback()
	var screenshot: Dictionary = image_result.metadata
	screenshot["pre_draw_frame"] = int(_pending.get("pre_draw_frame", -1))
	screenshot["post_draw_frame"] = Engine.get_frames_drawn()
	screenshot["pre_draw_usec"] = int(_pending.get("pre_draw_usec", 0))
	screenshot["post_draw_usec"] = Time.get_ticks_usec()
	var result := {"operation_id": _pending.operation_id, "pre_snapshot": _pending.pre,
		"post_snapshot": post_snapshot, "metadata": metadata,
		"screenshot": screenshot, "image": image_result.image}
	_last_result = result
	_pending.clear()


func _readback() -> Dictionary:
	return read_viewport_image(owner)


static func read_viewport_image(owner_ref) -> Dictionary:
	## Shared main-thread viewport readback used by playtest and the F1 capture.
	## It returns metadata plus an Image; callers decide how to serialize status.
	var unavailable: Dictionary = {"available": false, "reason": "image_unavailable"}
	if owner_ref == null or not is_instance_valid(owner_ref):
		return {"metadata": {"available": false, "reason": "owner_unavailable"}, "image": null}
	var display_name: String = DisplayServer.get_name()
	if display_name == "headless":
		return {"metadata": {"available": false, "reason": "headless"}, "image": null}
	var viewport: Viewport = owner_ref.get_viewport() if owner_ref.has_method("get_viewport") else null
	if viewport == null:
		return {"metadata": unavailable, "image": null}
	if DisplayServer.window_get_mode() == DisplayServer.WINDOW_MODE_MINIMIZED:
		return {"metadata": {"available": false, "reason": "minimized"}, "image": null}
	var size: Vector2 = viewport.get_visible_rect().size
	if size.x <= 0.0 or size.y <= 0.0:
		return {"metadata": {"available": false, "reason": "readback_unavailable"}, "image": null}
	if size.x * size.y > SCREENSHOT_MAX_PIXELS:
		return {"metadata": {"available": false, "reason": "pixel_limit"}, "image": null}
	var texture: Texture2D = viewport.get_texture()
	if texture == null:
		return {"metadata": {"available": false, "reason": "readback_unavailable"}, "image": null}
	var image: Image = texture.get_image()
	if image == null or image.is_empty():
		return {"metadata": {"available": false, "reason": "readback_unavailable"}, "image": null}
	return {"metadata": {"available": true, "reason": "", "width": image.get_width(), "height": image.get_height()}, "image": image}
