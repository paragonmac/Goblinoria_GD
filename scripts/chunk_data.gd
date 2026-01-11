extends RefCounted
class_name ChunkData

var blocks := PackedByteArray()
var dirty: bool = false
var last_access_tick: int = 0
var generated: bool = false

func _init(chunk_size: int, fill_value: int) -> void:
	var volume: int = chunk_size * chunk_size * chunk_size
	blocks.resize(volume)
	blocks.fill(fill_value)
