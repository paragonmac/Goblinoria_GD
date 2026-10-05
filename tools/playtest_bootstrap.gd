extends SceneTree
## Isolated graphical playtest entry point.
##
## This script is intentionally explicit-argument only. It refuses to start the
## production Main scene unless the launcher-provided user-data directory is
## below the selected run root, so a playtest cannot touch ordinary user data.

const MainScene = preload("res://scenes/Main.tscn")
const Scenarios = preload("res://scripts/playtest/playtest_scenarios.gd")
const Controller = preload("res://scripts/playtest/playtest_controller.gd")

var _args: Dictionary = {}
var _run_root := ""
var _run_id := ""
var _scenario_name := ""
const PLAYTEST_WINDOW_SIZE := Vector2i(1920, 1080)
const PLAYTEST_WINDOW_NO_FOCUS := true


func _init() -> void:
	call_deferred("_bootstrap")


func _bootstrap() -> void:
	if not OS.is_debug_build():
		_fail("Playtest bootstrap requires a debug build")
		return
	var parsed := _parse_args()
	if not parsed["ok"]:
		_fail(str(parsed["error"]))
		return
	_args = parsed
	_run_root = str(parsed["run_root"])
	_run_id = str(parsed["run_id"])
	_scenario_name = str(parsed["scenario"])
	var root_check := _verify_run_root_user_data()
	if not root_check["ok"]:
		_fail(str(root_check["error"]))
		return

	var scenario = Scenarios.make(_scenario_name, int(parsed.get("seed", -1)))
	if scenario == null:
		_fail("Unknown playtest scenario: %s" % _scenario_name)
		return

	# Set the mode before Main enters the tree. This is the only point where the
	# production scene is allowed to be instantiated by this entry point.
	var main = MainScene.instantiate()
	main.playtest_mode = true
	main.input_state.synthetic = true
	main.generate_full_map_on_startup = false
	root.size = PLAYTEST_WINDOW_SIZE
	root.set_flag(Window.FLAG_NO_FOCUS, PLAYTEST_WINDOW_NO_FOCUS)
	Engine.max_fps = 60
	if DisplayServer.get_name() != "headless":
		DisplayServer.window_set_title("Goblinoria Playtest - %s" % _scenario_name)
	root.add_child(main)
	if PLAYTEST_WINDOW_NO_FOCUS:
		root.unfocusable = true
		root.set_flag(Window.FLAG_NO_FOCUS, true)
	await process_frame
	if not is_instance_valid(main) or main.world == null:
		_fail("Playtest Main did not become ready")
		return

	var controller = Controller.new()
	main.playtest_controller = controller
	controller.initialize(main, _run_root, _run_id, {
		"scenario": _scenario_name,
		"scenario_version": Scenarios.SCENARIO_VERSION,
		"seed": scenario.world_seed,
	})
	var fixture: Dictionary = await scenario.prepare(main)
	if fixture.is_empty():
		_fail("Playtest scenario preparation failed")
		return
	var diagnostics_result := _enable_diagnostics(main)
	if not diagnostics_result["ok"]:
		_fail(str(diagnostics_result["error"]))
		return
	controller.set_ready(fixture)
	_write_runtime_manifest(fixture, controller, main)


func _parse_args() -> Dictionary:
	var values: Array = []
	values.append_array(OS.get_cmdline_args())
	for value in OS.get_cmdline_user_args():
		if not values.has(value):
			values.append(value)
	var result := {
		"ok": false,
		"run_id": "",
		"run_root": "",
		"scenario": "",
		"seed": -1,
	}
	if not values.has("--playtest"):
		result["error"] = "Playtest bootstrap requires explicit --playtest"
		return result
	var index := 0
	while index < values.size():
		var arg := str(values[index])
		if arg == "--run-id" or arg == "--run-root" or arg == "--scenario" or arg == "--seed":
			if index + 1 >= values.size():
				result["error"] = "%s requires a value" % arg
				return result
			var value := str(values[index + 1])
			match arg:
				"--run-id": result["run_id"] = value
				"--run-root": result["run_root"] = value
				"--scenario": result["scenario"] = value
				"--seed": result["seed"] = int(value)
			index += 2
			continue
		index += 1
	var run_id := str(result["run_id"])
	var run_root := str(result["run_root"])
	var scenario := str(result["scenario"])
	if run_id.is_empty() or run_root.is_empty() or scenario.is_empty():
		result["error"] = "--run-id, --run-root, and --scenario are required"
		return result
	var run_id_pattern := RegEx.new()
	run_id_pattern.compile("^[A-Za-z0-9_-]{1,96}$")
	if run_id.contains("..") or run_id_pattern.search(run_id) == null:
		result["error"] = "Invalid run ID"
		return result
	if not Scenarios.VALID_SCENARIOS.has(scenario):
		result["error"] = "Invalid scenario: %s" % scenario
		return result
	var normalized_root := _normalize_path(run_root)
	if not _is_absolute_path(normalized_root):
		result["error"] = "--run-root must be an absolute path"
		return result
	result["run_root"] = normalized_root.trim_suffix("/")
	result["ok"] = true
	return result


func _verify_run_root_user_data() -> Dictionary:
	var appdata_root := _normalize_path(_run_root.path_join("appdata"))
	var make_status := DirAccess.make_dir_recursive_absolute(appdata_root)
	if make_status != OK and not DirAccess.dir_exists_absolute(appdata_root):
		return {"ok": false, "error": "Could not create run appdata directory"}
	var global_user := _normalize_path(ProjectSettings.globalize_path("user://"))
	if not _is_within(global_user, appdata_root):
		return {
			"ok": false,
			"error": "Godot user:// escapes playtest appdata: %s (expected under %s)" % [global_user, appdata_root],
		}
	return {"ok": true, "user_data": global_user, "appdata_root": appdata_root}


func _enable_diagnostics(main) -> Dictionary:
	var diagnostics = main.diagnostics_controller
	if diagnostics == null:
		return {"ok": false, "error": "Main diagnostics controller is unavailable"}
	diagnostics.set_enabled(true)
	var service_enabled: bool = diagnostics.service != null and diagnostics.service.enabled
	var transport_enabled: bool = diagnostics.transport != null and diagnostics.transport.enabled
	if not service_enabled or not transport_enabled:
		var transport_error := str(diagnostics.transport.last_error) if diagnostics.transport != null else "transport_unavailable"
		return {
			"ok": false,
			"error": "Playtest diagnostics failed to start: %s" % transport_error,
		}
	var descriptor_path := _normalize_path(str(diagnostics.transport.descriptor_path))
	var user_data_path := _normalize_path(ProjectSettings.globalize_path("user://"))
	if descriptor_path.is_empty() or not _is_within(descriptor_path, user_data_path):
		return {
			"ok": false,
			"error": "Playtest diagnostics descriptor escaped isolated user data",
		}
	if not FileAccess.file_exists(descriptor_path):
		return {
			"ok": false,
			"error": "Playtest diagnostics descriptor was not created",
		}
	return {
		"ok": true,
		"descriptor_path": descriptor_path,
	}


func _write_runtime_manifest(fixture: Dictionary, controller, main) -> void:
	var source_info := {}
	var session_path := _run_root.path_join("session.json")
	if FileAccess.file_exists(session_path):
		var session_file := FileAccess.open(session_path, FileAccess.READ)
		if session_file != null:
			var decoded = JSON.parse_string(session_file.get_as_text())
			if decoded is Dictionary:
				for key in ["source_revision", "dirty_worktree", "godot_executable", "scenario_version"]:
					if decoded.has(key):
						source_info[key] = decoded[key]
	var rendering_method = ProjectSettings.get_setting("rendering/renderer/rendering_method", "unknown")
	var diagnostics = main.diagnostics_controller
	var diagnostics_descriptor := ""
	var diagnostics_enabled := false
	var diagnostics_transport_enabled := false
	if diagnostics != null:
		diagnostics_enabled = diagnostics.service != null and diagnostics.service.enabled
		diagnostics_transport_enabled = diagnostics.transport != null and diagnostics.transport.enabled
		if diagnostics.transport != null:
			diagnostics_descriptor = _normalize_path(str(diagnostics.transport.descriptor_path))
	var runtime := {
		"schema": 1,
		"status": "ready",
		"run_id": _run_id,
		"run_root": _run_root,
		"scenario": _scenario_name,
		"scenario_version": fixture.get("scenario_version", Scenarios.SCENARIO_VERSION),
		"seed": fixture.get("seed", -1),
		"user_data_path": _normalize_path(ProjectSettings.globalize_path("user://")),
		"engine": Engine.get_version_info(),
		"os": OS.get_name(),
		"rendering_method": str(rendering_method),
		"rendering_driver": str(ProjectSettings.get_setting("rendering/driver/driver_name", "unknown")),
		"window_size": [PLAYTEST_WINDOW_SIZE.x, PLAYTEST_WINDOW_SIZE.y],
		"window_no_focus": PLAYTEST_WINDOW_NO_FOCUS,
		"max_fps": Engine.max_fps,
		"audio_driver": AudioServer.get_driver_name(),
		"diagnostics_enabled": diagnostics_enabled,
		"diagnostics_transport_enabled": diagnostics_transport_enabled,
		"diagnostics_descriptor_path": diagnostics_descriptor,
		"source": source_info,
		"controller_status": controller.status_identity() if controller != null and controller.has_method("status_identity") else {},
	}
	_atomic_json_write(_run_root.path_join("runtime.json"), runtime)


func _atomic_json_write(path: String, value: Dictionary) -> bool:
	var temporary := "%s.tmp.%s" % [path, str(OS.get_process_id())]
	var file := FileAccess.open(temporary, FileAccess.WRITE)
	if file == null:
		push_error("Unable to write playtest runtime metadata")
		return false
	file.store_string(JSON.stringify(value, "\t"))
	file.close()
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)
	return DirAccess.rename_absolute(temporary, path) == OK


func _fail(message: String) -> void:
	push_error("PLAYTEST_BOOTSTRAP_FAILED: %s" % message)
	quit(2)


func _normalize_path(path: String) -> String:
	var value := path.replace("\\", "/")
	while value.ends_with("/") and value.length() > 1:
		value = value.trim_suffix("/")
	return value


func _is_absolute_path(path: String) -> bool:
	return path.begins_with("/") or (path.length() >= 3 and path[1] == ":" and path[2] == "/")


func _is_within(path: String, base: String) -> bool:
	var normalized_path := path.to_lower()
	var normalized_base := base.to_lower()
	return normalized_path == normalized_base or normalized_path.begins_with(normalized_base + "/")
