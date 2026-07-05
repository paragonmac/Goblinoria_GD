extends SceneTree

var main


func _init() -> void:
	var scene: PackedScene = load("res://scenes/Main.tscn")
	main = scene.instantiate()
	root.add_child(main)
	_run_contract.call_deferred()


func _run_contract() -> void:
	await process_frame
	await process_frame

	var hud = main.hud_controller
	var initial_status_count: int = hud.status_refresh_count
	var initial_inventory_count: int = hud.inventory_refresh_count
	var initial_stockpile_count: int = hud.stockpile_refresh_count
	for _i in range(5):
		await process_frame
	var idle_hud_ok: bool = hud.status_refresh_count == initial_status_count \
		and hud.inventory_refresh_count == initial_inventory_count \
		and hud.stockpile_refresh_count == initial_stockpile_count

	var task_id: int = main.world.task_queue.add_dig_task(Vector3i(1, 1, 1))
	await process_frame
	var task_signal_ok: bool = hud.status_refresh_count == initial_status_count + 1 \
		and main.hud_label.text.contains("Tasks: 1")
	main.world.task_queue.complete_task(main.world.task_queue.get_task(task_id))
	await process_frame
	var completion_signal_ok: bool = main.world.task_queue.active_count() == 0 \
		and main.hud_label.text.contains("Tasks: 0")

	var previous_stockpile_count: int = hud.stockpile_refresh_count
	var stockpile_cells: Array[Vector3i] = [Vector3i(2, 1, 2)]
	main.world.create_stockpile(stockpile_cells)
	await process_frame
	var stockpile_signal_ok: bool = hud.stockpile_refresh_count == previous_stockpile_count + 1

	var worker_window = main.worker_window_controller
	var worker_timer_idle_ok: bool = worker_window.poll_timer != null \
		and worker_window.poll_timer.is_stopped() \
		and is_equal_approx(worker_window.poll_timer.wait_time, 0.2)
	worker_window.toggle()
	var worker_timer_active_ok: bool = not worker_window.poll_timer.is_stopped()
	worker_window.close()
	var worker_timer_stopped_ok: bool = worker_window.poll_timer.is_stopped()
	var generation_timer_ok: bool = main.generation_status_timer != null \
		and is_equal_approx(main.generation_status_timer.wait_time, 0.25)

	main.world.task_manager.shutdown()
	main.queue_free()

	if not idle_hud_ok:
		push_error("HUD sections refreshed without a state-change signal")
		quit(1)
		return
	if not task_signal_ok or not completion_signal_ok:
		push_error("Task-count signal did not refresh the HUD")
		quit(1)
		return
	if not stockpile_signal_ok:
		push_error("Stockpile signal did not refresh the stockpile HUD")
		quit(1)
		return
	if not worker_timer_idle_ok or not worker_timer_active_ok or not worker_timer_stopped_ok:
		push_error("Worker window timer lifecycle is invalid")
		quit(1)
		return
	if not generation_timer_ok:
		push_error("Generation HUD timer interval is invalid")
		quit(1)
		return

	print("Event-driven worker update contract OK")
	quit(0)
