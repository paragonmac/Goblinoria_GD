extends RefCounted
class_name ChunkData
## Container for voxel data within a single chunk.

#region State
const MESH_STATE_NONE := 0
const MESH_STATE_PENDING := 1
const MESH_STATE_READY := 2

var blocks := PackedByteArray()
var dirty: bool = false
var last_access_tick: int = 0
var generated: bool = false
var mesh_state: int = MESH_STATE_NONE
var mesh_revision: int = 0
#endregion


#region Initialization
func _init(chunk_size: int, fill_value: int) -> void:
	var volume: int = chunk_size * chunk_size * chunk_size
	blocks.resize(volume)
	blocks.fill(fill_value)
#endregion
