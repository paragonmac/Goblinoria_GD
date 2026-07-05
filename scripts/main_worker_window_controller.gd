extends RefCounted
class_name MainWorkerWindowController
## Worker management window shown as an in-game panel.

#region Constants
const WINDOW_TITLE := "Workers"
const WINDOW_HINT := "Press W to close"
const POLL_INTERVAL_MSEC := 200
#endregion

#region State
var panel: PanelContainer
var title_label: Label
var hint_label: Label
var summary_label: Label
var details_button: Button
var workers_text: RichTextLabel
var visible: bool = false
var details_visible: bool = true
var last_poll_msec: int = 0
#endregion


func setup(hud_layer: CanvasLayer) -> void:
	if hud_layer == null:
		return

	panel = PanelContainer.new()
	panel.name = "WorkerWindow"
	panel.anchor_left = 0.5
	panel.anchor_top = 0.5
	panel.anchor_right = 0.5
	panel.anchor_bottom = 0.5
	panel.offset_left = -300.0
	panel.offset_top = -220.0
	panel.offset_right = 300.0
	panel.offset_bottom = 220.0
	panel.visible = false

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 12)
	margin.add_theme_constant_override("margin_top", 10)
	margin.add_theme_constant_override("margin_right", 12)
	margin.add_theme_constant_override("margin_bottom", 10)
	panel.add_child(margin)

	var content := VBoxContainer.new()
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content.size_flags_vertical = Control.SIZE_EXPAND_FILL
	content.add_theme_constant_override("separation", 6)
	margin.add_child(content)

	var header := HBoxContainer.new()
	header.name = "Header"
	header.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content.add_child(header)

	title_label = Label.new()
	title_label.name = "TitleLabel"
	title_label.text = WINDOW_TITLE
	title_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(title_label)

	details_button = Button.new()
	details_button.name = "DetailsButton"
	details_button.text = _details_button_text()
	details_button.pressed.connect(_on_details_pressed)
	header.add_child(details_button)

	hint_label = Label.new()
	hint_label.name = "HintLabel"
	hint_label.text = WINDOW_HINT
	content.add_child(hint_label)

	summary_label = Label.new()
	summary_label.name = "SummaryLabel"
	summary_label.text = ""
	content.add_child(summary_label)

	var scroll := ScrollContainer.new()
	scroll.name = "WorkerScroll"
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	content.add_child(scroll)

	workers_text = RichTextLabel.new()
	workers_text.name = "WorkersText"
	workers_text.bbcode_enabled = false
	workers_text.scroll_active = false
	workers_text.fit_content = false
	workers_text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	workers_text.size_flags_vertical = Control.SIZE_EXPAND_FILL
	workers_text.text = ""
	scroll.add_child(workers_text)

	hud_layer.add_child(panel)


func toggle() -> void:
	visible = not visible
	if panel != null:
		panel.visible = visible
	if visible:
		last_poll_msec = 0


func close() -> void:
	visible = false
	if panel != null:
		panel.visible = false


func _on_details_pressed() -> void:
	details_visible = not details_visible
	if details_button != null:
		details_button.text = _details_button_text()
	last_poll_msec = 0


func update_window(world: World) -> void:
	if not visible:
		return
	if panel == null or workers_text == null or summary_label == null:
		return
	if world == null:
		summary_label.text = "No world loaded."
		workers_text.text = ""
		return

	var now_msec: int = Time.get_ticks_msec()
	if last_poll_msec > 0 and now_msec - last_poll_msec < POLL_INTERVAL_MSEC:
		return
	last_poll_msec = now_msec

	var lines: PackedStringArray = PackedStringArray()
	lines.append("ID  State    Position       Task                      Status")
	lines.append("----------------------------------------------------------------")

	var workers: Array = world.workers
	var worker_count := 0
	for index in range(workers.size()):
		var worker = workers[index] as Worker
		if worker == null:
			continue
		worker_count += 1
		var display_id: int = worker.worker_id if worker.worker_id > 0 else index + 1
		var state_text := _worker_state_text(worker.state)
		var pos: Vector3i = worker.get_block_coord()
		var task_text := _worker_task_text(worker, world.task_queue)
		var status_text := _worker_status_text(worker, world)
		lines.append("%02d  %-8s %4d,%4d,%4d  %-24s  %s" % [
			display_id,
			state_text,
			pos.x,
			pos.y,
			pos.z,
			task_text,
			status_text,
		])
		if details_visible:
			var detail_text := _worker_detail_text(worker, world)
			if not detail_text.is_empty():
				lines.append("    %s" % detail_text)
	if worker_count == 0:
		lines.append("No workers.")

	summary_label.text = "Workers: %d | Active Tasks: %d" % [worker_count, world.task_queue.active_count()]
	workers_text.text = "\n".join(lines)


func _worker_state_text(state: int) -> String:
	match state:
		Worker.WorkerState.IDLE:
			return "Idle"
		Worker.WorkerState.MOVING:
			return "Moving"
		Worker.WorkerState.WORKING:
			return "Working"
		Worker.WorkerState.WAITING:
			return "Waiting"
		Worker.WorkerState.FALLING:
			return "Falling"
		_:
			return "?"


func _worker_task_text(worker: Worker, task_queue: TaskQueue) -> String:
	if worker == null or task_queue == null:
		return "No task"
	if worker.current_task_id < 0:
		if worker.state == Worker.WorkerState.IDLE:
			return "Looking for task"
		if worker.state == Worker.WorkerState.WAITING:
			return "Trying to repath"
		return "No task"
	var task = task_queue.get_task(worker.current_task_id)
	if task == null:
		return "Task %d (missing)" % worker.current_task_id
	var type_text := _task_type_text(task.type)
	var pos: Vector3i = task.pos
	var intent := ""
	if worker.state == Worker.WorkerState.WAITING:
		intent = "trying "
	elif worker.state == Worker.WorkerState.MOVING:
		intent = "to "
	return "%s%s @ %d,%d,%d" % [intent, type_text, pos.x, pos.y, pos.z]


func _worker_status_text(worker: Worker, world: World) -> String:
	if worker == null:
		return "Unknown"
	if worker.current_task_id >= 0:
		match worker.state:
			Worker.WorkerState.MOVING:
				return "Moving to job"
			Worker.WorkerState.WORKING:
				return "Working"
			Worker.WorkerState.WAITING:
				return "Repathing"
			Worker.WorkerState.FALLING:
				return "Falling"
			_:
				return "Assigned"
	var reason := _worker_blocked_reason(worker, world)
	if not reason.is_empty():
		return "Blocked"
	match worker.state:
		Worker.WorkerState.MOVING:
			return "Wandering"
		Worker.WorkerState.FALLING:
			return "Falling"
		Worker.WorkerState.WAITING:
			return "Repathing"
		_:
			return "Idle"


func _worker_detail_text(worker: Worker, world: World) -> String:
	if worker == null:
		return ""
	if worker.current_task_id >= 0:
		return _assigned_worker_detail(worker, world)
	var reason := _worker_blocked_reason(worker, world)
	if not reason.is_empty():
		return reason
	if world == null or world.task_queue == null or world.task_queue.active_count() <= 0:
		return "No queued jobs."
	if worker.state == Worker.WorkerState.MOVING:
		return "No assigned job; moving on a wander path."
	return "No assigned job; checking reachable queued jobs."


func _assigned_worker_detail(worker: Worker, world: World) -> String:
	if world == null or world.task_queue == null:
		return ""
	var task = world.task_queue.get_task(worker.current_task_id)
	if task == null:
		return "Assigned task is missing from the queue."
	var pos: Vector3i = task.pos
	match worker.state:
		Worker.WorkerState.MOVING:
			return "Pathing to %s @ %d,%d,%d; node %d/%d." % [
				_task_type_text(task.type),
				pos.x,
				pos.y,
				pos.z,
				worker.path_index,
				worker.path.size(),
			]
		Worker.WorkerState.WORKING:
			return "Working %s @ %d,%d,%d; %.1fs remaining." % [
				_task_type_text(task.type),
				pos.x,
				pos.y,
				pos.z,
				maxf(worker.work_timer, 0.0),
			]
		Worker.WorkerState.WAITING:
			return "Work position invalid; trying to repath to %s @ %d,%d,%d." % [
				_task_type_text(task.type),
				pos.x,
				pos.y,
				pos.z,
			]
		_:
			return "Assigned to %s @ %d,%d,%d." % [
				_task_type_text(task.type),
				pos.x,
				pos.y,
				pos.z,
			]


func _worker_blocked_reason(worker: Worker, world: World) -> String:
	if world == null or worker == null or world.task_queue == null:
		return ""
	var summary := _worker_task_summary(worker, world.task_queue)
	var pending_count: int = int(summary.get("pending", 0))
	if pending_count <= 0:
		return ""
	var excluded_count: int = int(summary.get("excluded", 0))
	if excluded_count > 0:
		var excluded_task = summary.get("nearest_excluded", null)
		if excluded_task != null:
			var pos: Vector3i = excluded_task.pos
			var worker_pos := worker.get_block_coord()
			if worker_pos.y != pos.y:
				return "No path to %d queued job(s). Nearest blocked %s @ %d,%d,%d is on level %d; worker is on level %d and needs a route by ramp or stairs." % [
					excluded_count,
					_task_type_text(excluded_task.type),
					pos.x,
					pos.y,
					pos.z,
					pos.y,
					worker_pos.y,
				]
			return "No path to %d queued job(s). Nearest blocked %s @ %d,%d,%d." % [
				excluded_count,
				_task_type_text(excluded_task.type),
				pos.x,
				pos.y,
				pos.z,
			]
	var reachable_count: int = int(summary.get("reachable", 0))
	if reachable_count > 0:
		return ""
	var unknown_count: int = int(summary.get("unknown", 0))
	if unknown_count > 0:
		return "Queued jobs are waiting for path checks."
	var unreachable_count: int = int(summary.get("unreachable", 0))
	if unreachable_count > 0:
		return "%d queued job(s) have no valid worker path." % unreachable_count
	return ""


func _worker_task_summary(worker: Worker, task_queue: TaskQueue) -> Dictionary:
	var summary := {
		"pending": 0,
		"reachable": 0,
		"unknown": 0,
		"unreachable": 0,
		"excluded": 0,
		"nearest_excluded": null,
	}
	var nearest_excluded_dist := INF
	var worker_pos := worker.get_block_coord()
	var now_msec := Time.get_ticks_msec()
	for task in task_queue.tasks:
		if task.status != TaskQueue.TaskStatus.PENDING:
			continue
		summary["pending"] += 1
		match task.accessibility:
			TaskQueue.TaskAccessibility.REACHABLE:
				summary["reachable"] += 1
			TaskQueue.TaskAccessibility.UNREACHABLE:
				summary["unreachable"] += 1
			_:
				summary["unknown"] += 1
		if not task.is_worker_unreachable(worker.worker_id, now_msec):
			continue
		summary["excluded"] += 1
		var dist: float = task.pos.distance_squared_to(worker_pos)
		if dist < nearest_excluded_dist:
			nearest_excluded_dist = dist
			summary["nearest_excluded"] = task
	return summary


func _details_button_text() -> String:
	return "Hide details" if details_visible else "Show details"


func _task_type_text(task_type: int) -> String:
	match task_type:
		TaskQueue.TaskType.DIG:
			return "Dig"
		TaskQueue.TaskType.PLACE:
			return "Place"
		TaskQueue.TaskType.STAIRS:
			return "Stairs"
		TaskQueue.TaskType.HAUL:
			return "Haul"
		_:
			return "Task"
