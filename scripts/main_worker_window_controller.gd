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
var workers_text: RichTextLabel
var visible: bool = false
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

	title_label = Label.new()
	title_label.name = "TitleLabel"
	title_label.text = WINDOW_TITLE
	content.add_child(title_label)

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
	lines.append("ID  State    Position       Task")
	lines.append("-----------------------------------------------")

	var workers: Array = world.workers
	var worker_count := 0
	for index in range(workers.size()):
		var worker = workers[index] as Worker
		if worker == null:
			continue
		worker_count += 1
		var state_text := _worker_state_text(worker.state)
		var pos: Vector3i = worker.get_block_coord()
		var task_text := _worker_task_text(worker, world.task_queue)
		lines.append("%02d  %-8s %4d,%4d,%4d  %s" % [
			index + 1,
			state_text,
			pos.x,
			pos.y,
			pos.z,
			task_text,
		])
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


func _task_type_text(task_type: int) -> String:
	match task_type:
		TaskQueue.TaskType.DIG:
			return "Dig"
		TaskQueue.TaskType.PLACE:
			return "Place"
		TaskQueue.TaskType.STAIRS:
			return "Stairs"
		_:
			return "Task"
