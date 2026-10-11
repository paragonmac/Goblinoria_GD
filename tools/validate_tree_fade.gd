extends SceneTree
## Trees that stand between the camera and a goblin, stockpile cell or pending
## job fade; trees behind a target or away from it do not.

const DepthFixture = preload("res://tools/validate_assignment_depth_scaling.gd")
const TreeRendererScript = preload("res://scripts/rendering/tree_renderer.gd")

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
	var world := DepthFixture.TestWorld.new()
	world.world_size_y = 256
	world._init_ramp_lookup()
	world.block_registry.load_from_csv(World.BLOCK_DATA_PATH)
	for x in range(-16, 16):
		for z in range(-16, 16):
			world.set_block_raw(x, 20, z, World.BLOCK_ID_GRASS, false)
	world.top_render_y = 21
	# Game camera: looking down at the scene; view_dir points toward the camera.
	var view_dir := Basis.from_euler(Vector3(-0.610865, 0.785398, 0.0)).z
	var flat := Vector3(view_dir.x, 0.0, view_dir.z).normalized()
	var renderer := TreeRendererScript.new()
	renderer.world = world
	renderer.material = preload("res://scripts/rendering/prop_mesh_util.gd").make_prop_material(0.0, true)
	var front := Vector3i(0, 21, 0)
	var behind := Vector3i(-6, 21, -6) # far side of the goblin from the camera
	var aside := Vector3i(8, 21, -8)
	world.tree_store.add_tree(front, 0, 0, 6)
	world.tree_store.add_tree(behind, 0, 1, 6)
	world.tree_store.add_tree(aside, 1, 2, 7)
	renderer.sync()
	_check(renderer.trees_drawn == 3, "All three trees are drawn")

	# Goblin a little behind the front tree (away from the camera).
	var worker := Worker.new()
	worker.worker_id = 1
	worker.position = Vector3(front) - flat * 2.0
	world.workers.append(worker)
	renderer.update_fades(view_dir)
	_check(renderer._faded.has(front), "A tree between the camera and a goblin fades")
	_check(not renderer._faded.has(behind), "A tree behind the goblin stays solid")
	_check(not renderer._faded.has(aside), "An unrelated tree stays solid")
	var slot: Array = renderer._slots[front]
	var mm: MultiMesh = renderer._instances[slot[0]].multimesh
	# Headless rendering does not keep MultiMesh data; check the channel exists.
	_check(mm.use_custom_data, "Tree MultiMeshes carry per-instance fade data")

	# Goblin moves in front of the tree (toward the camera): nothing to cover.
	worker.position = Vector3(front) + flat * 3.0
	renderer.update_fades(view_dir)
	_check(not renderer._faded.has(front), "The fade clears when nothing is behind the tree")

	# Stockpile cell behind the aside tree fades it; pending job behind the front tree too.
	world.workers.clear()
	var cell := Vector3i(aside) - Vector3i(roundi(flat.x * 2.0), 0, roundi(flat.z * 2.0))
	world.stockpile_store.stockpiles[1] = {"id": 1, "cells": [cell]}
	renderer.update_fades(view_dir)
	_check(renderer._faded.has(aside) and not renderer._faded.has(front), "A stockpile cell behind a tree fades only that tree")
	world.stockpile_store.stockpiles.clear()
	renderer.update_fades(view_dir)
	_check(renderer.faded_count == 0, "No targets, no fades")

	# Slicing below the trees hides them and drops their fades.
	world.top_render_y = 19
	renderer.sync()
	_check(renderer.trees_drawn == 0 and renderer._faded.is_empty(), "Trees hidden below their ground drop out of fading")

	worker.free()
	renderer.free()
	print("Tree fade: %d checks, %d failures" % [checks, failures])
	world.free()
	quit(1 if failures > 0 else 0)
