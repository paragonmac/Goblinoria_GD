extends RefCounted
## Stages a complete slot beside its destination, on the same filesystem.
## The backup remains recoverable if the filesystem also refuses rollback.

const STAGE_SUFFIX := ".save-stage"
const BACKUP_SUFFIX := ".save-backup"

var world_dir := ""
var stage_dir := ""
var backup_dir := ""


func begin(destination: String) -> bool:
	if not _is_slot_path_safe(destination):
		return false
	world_dir = ProjectSettings.globalize_path(destination).simplify_path().trim_suffix("/")
	var parent := DirAccess.open(world_dir.get_base_dir())
	if parent != null and parent.is_link(world_dir.get_file()):
		return false
	stage_dir = world_dir + STAGE_SUFFIX
	backup_dir = world_dir + BACKUP_SUFFIX
	if not recover(world_dir):
		return false
	# These reserved siblings belong to an earlier interrupted transaction.
	if not _remove_tree(stage_dir) or not _remove_tree(backup_dir):
		return false
	if FileAccess.file_exists(world_dir):
		return false
	if DirAccess.make_dir_recursive_absolute(stage_dir) != OK:
		return false
	# Preserve legacy chunks and other existing slot files.
	if DirAccess.dir_exists_absolute(world_dir) and not _copy_tree(world_dir, stage_dir):
		abort()
		return false
	return true


func promote() -> bool:
	var had_slot := DirAccess.dir_exists_absolute(world_dir)
	if had_slot and _rename_directory(world_dir, backup_dir) != OK:
		return false
	if _rename_directory(stage_dir, world_dir) != OK:
		if had_slot and _rename_directory(backup_dir, world_dir) != OK:
			push_error("World save rollback failed; previous save retained at %s" % backup_dir)
		return false
	# Promotion is the commit point. Cleanup failure must not report a failed save.
	if had_slot and not _remove_tree(backup_dir):
		push_warning("World save committed; old backup retained at %s" % backup_dir)
	return true


func abort() -> void:
	if not stage_dir.is_empty() and not _remove_tree(stage_dir):
		push_warning("World save staging cleanup failed: %s" % stage_dir)


func recover(destination: String) -> bool:
	if not _is_slot_path_safe(destination):
		return false
	var target := ProjectSettings.globalize_path(destination).simplify_path().trim_suffix("/")
	var backup := target + BACKUP_SUFFIX
	if not DirAccess.dir_exists_absolute(backup):
		return true
	if DirAccess.dir_exists_absolute(target):
		return true
	if FileAccess.file_exists(target) or _rename_directory(backup, target) != OK:
		push_warning("World save recovery failed; previous save retained at %s" % backup)
		return false
	return true


func _is_slot_path_safe(destination: String) -> bool:
	if destination.strip_edges().is_empty():
		return false
	var absolute := ProjectSettings.globalize_path(destination).simplify_path().trim_suffix("/")
	if absolute.is_empty() or absolute.ends_with(":") or absolute.get_file().is_empty():
		return false
	if absolute.begins_with("//") and absolute.split("/", false).size() <= 2:
		return false
	for root_path in ["res://", "user://"]:
		var root := ProjectSettings.globalize_path(root_path).simplify_path().trim_suffix("/")
		if absolute.nocasecmp_to(root) == 0:
			return false
	return true


func _rename_directory(source: String, destination: String) -> Error:
	return DirAccess.rename_absolute(source, destination)


static func finish_write(file: FileAccess) -> bool:
	var path := file.get_path_absolute()
	var expected_length := file.get_position()
	var ok := file.get_error() == OK
	file.flush()
	ok = ok and file.get_error() == OK
	file.close()
	# Also catch short buffered writes: flush() does not return an Error.
	var check := FileAccess.open(path, FileAccess.READ)
	return ok and check != null and check.get_length() == expected_length


func _copy_tree(source: String, destination: String) -> bool:
	var dir := DirAccess.open(source)
	if dir == null:
		return false
	dir.include_hidden = true
	dir.include_navigational = false
	if dir.list_dir_begin() != OK:
		return false
	var name := dir.get_next()
	while not name.is_empty():
		var from := source.path_join(name)
		var to := destination.path_join(name)
		# Do not follow links out of the slot during copying or cleanup.
		if dir.is_link(name):
			return false
		if dir.current_is_dir():
			if DirAccess.make_dir_absolute(to) != OK or not _copy_tree(from, to):
				return false
		elif DirAccess.copy_absolute(from, to) != OK:
			return false
		name = dir.get_next()
	return true


func _remove_tree(path: String) -> bool:
	var parent := DirAccess.open(path.get_base_dir())
	if parent != null and parent.is_link(path.get_file()):
		return false
	if FileAccess.file_exists(path):
		return DirAccess.remove_absolute(path) == OK
	if not DirAccess.dir_exists_absolute(path):
		return true
	var dir := DirAccess.open(path)
	if dir == null:
		return false
	dir.include_hidden = true
	dir.include_navigational = false
	if dir.list_dir_begin() != OK:
		return false
	var name := dir.get_next()
	while not name.is_empty():
		if dir.is_link(name) or not _remove_tree(path.path_join(name)):
			return false
		name = dir.get_next()
	dir.list_dir_end()
	dir = null
	return DirAccess.remove_absolute(path) == OK
