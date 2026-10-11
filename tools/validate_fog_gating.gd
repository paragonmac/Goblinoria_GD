extends SceneTree
## Darkness phase 4 (SEE-ADR-021): unexplored cells cannot be inspected or
## designated, and the gates open once the cell is explored. With no built
## light field (legacy flows) everything counts as explored.

const SelectionInput = preload("res://tools/validate_selection_input.gd")

var checks := 0
var failures := 0


func _init() -> void:
	_run.call_deferred()


func _check(ok: bool, message: String) -> void:
	checks += 1
	if not ok:
		failures += 1
		push_error(message)


func _run() -> void:
	root.size = Vector2i(1000, 800)
	root.gui_embed_subwindows = true
	var scene := load("res://scenes/Main.tscn") as PackedScene
	var main := scene.instantiate()
	main.set_script(SelectionInput.InputMain)
	main.get_node("World").set_script(SelectionInput.SelectionWorld)
	root.add_child(main)
	var world: World = main.world
	await process_frame
	await process_frame
	var controller: MainSelectionController = main.selection_controller
	var feedback: Array[String] = []
	controller.selection_feedback.connect(func(message: String) -> void: feedback.append(message))
	var inspected: Array = []
	controller.cell_inspected.connect(func(block_id: int, pos: Vector3i) -> void: inspected.append(pos))

	# Gate off until the light field is built.
	world.player_mode = World.PlayerMode.DIG
	_check(controller._is_explored(Vector3i(2, 0, 2)), "Without a built light field every cell counts as explored")

	# Missing chunks above the floor count as opaque: the whole fixture is dark.
	world.light_field.build(world)
	world.light_field_built = true
	var dark := Vector3i(2, 0, 2)
	var known := Vector3i(-3, 0, -3)
	_check(not world.light_field.is_explored(dark.x, dark.y, dark.z), "Fixture floor starts unexplored")
	world.light_field.mark_explored(known.x, known.y, known.z)
	world.light_field.mark_explored(known.x, known.y + 1, known.z)

	# Excavation tunnels blind: dig designations reach into unexplored rock.
	var result: Dictionary = controller._enqueue_task_at(dark.x, dark.y, dark.z)
	_check(str(result.get("reason", "")) != "unexplored" and world.has_pending_task_request_at(dark),
		"Dig on an unexplored cell is queued (%s)" % str(result))
	result = controller._enqueue_task_at(known.x, known.y, known.z)
	_check(str(result.get("reason", "")) != "unexplored" and world.has_pending_task_request_at(known),
		"Dig on an explored cell is queued (%s)" % str(result))
	_check(not controller._dig_preview_is_currently_workable(dark), "Dig preview marks unexplored cells invalid")

	world.player_mode = World.PlayerMode.ERASE
	_check(controller._can_erase_at(known), "Erase works on an explored designation")
	_check(not controller._can_erase_at(dark), "Erase is unavailable on an unexplored cell")

	world.player_mode = World.PlayerMode.STOCKPILE
	_check(not controller._can_create_stockpile_at(dark + Vector3i.UP), "Stockpile cannot cover unexplored cells")

	world.player_mode = World.PlayerMode.TORCH
	result = controller._enqueue_task_at(dark.x, dark.y + 1, dark.z)
	_check(str(result.get("reason", "")) == "unexplored", "Torch on an unexplored cell is rejected (%s)" % str(result))

	world.player_mode = World.PlayerMode.DOWN_STAIRS
	var deep := Vector3i(6, 0, 6)
	result = controller._enqueue_task_at(deep.x, deep.y, deep.z)
	_check(str(result.get("reason", "")) != "unexplored", "Stairs into unexplored rock are not fog-gated (%s)" % str(result))

	# Inspect: unexplored clicks report instead of opening details.
	world.player_mode = World.PlayerMode.INFORMATION
	feedback.clear()
	inspected.clear()
	controller._trace_selection("click", dark.x, dark.x, dark.z, dark.z, dark.y, [{"pos": dark, "reason": "unexplored"}])
	_check(feedback.size() == 1 and feedback[0] == "Unexplored", "Unexplored rejection reads 'Unexplored' (%s)" % str(feedback))

	world.player_mode = World.PlayerMode.DIG
	world.task_manager.shutdown()
	world.workers.clear()
	main.free()
	print("Fog gating: %d checks, %d failures" % [checks, failures])
	quit(1 if failures > 0 else 0)
