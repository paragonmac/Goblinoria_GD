class_name LiveDiagnosticsTransport
extends "res://scripts/diagnostics/local_json_transport.gd"

const OPERATIONS := [
	"status", "inspect_screen", "inspect_cell", "inspect_chunk", "list_workers",
	"list_tasks", "inspect_worker", "inspect_task", "inspect_item",
	"inspect_stockpile", "recent_events", "capture_bug", "capture_status",
]


func get_allowed_operations() -> Array:
	return OPERATIONS
