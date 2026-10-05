class_name PlaytestTransport
extends "res://scripts/diagnostics/local_json_transport.gd"

## Authenticated loopback transport for development-only playtest control.
## Main owns the handler and remains the only component allowed to mutate game state.
const OPERATIONS := [
	"status", "act", "set_view", "advance", "run_until", "pause",
	"observe", "operation_status", "shutdown",
]


func _init() -> void:
	descriptor_root = "user://playtest/control"


func get_allowed_operations() -> Array:
	return OPERATIONS


func start(session_id: String, fields: Dictionary = {}) -> Error:
	var metadata := {
		"transport": "playtest",
		"control_version": 1,
	}
	# The controller starts the transport after the launcher has created the
	# run manifest. Include that identity without making the controller pass
	# launcher metadata through the transport API.
	var manifest_path := descriptor_root.get_base_dir().path_join("session.json")
	if FileAccess.file_exists(manifest_path):
		var parsed = JSON.parse_string(FileAccess.get_file_as_string(manifest_path))
		if parsed is Dictionary:
			for key in ["run_id", "scenario", "source_revision", "dirty_worktree", "godot_executable"]:
				if parsed.has(key): metadata[key] = parsed[key]
	metadata.merge(fields, true)
	return super.start(session_id, metadata)
