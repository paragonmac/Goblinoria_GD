# Blockbench → Godot workflow ⚒️💠

This document shows a quick, practical workflow for exporting models and animations from **Blockbench** and importing them into **Godot 4** (GLTF / .glb recommended).

---

## Why use glTF (.glb)? ✅
- **GLB (binary glTF)** embeds textures and materials in one file, making it easy to move assets into Godot.
- Godot has robust glTF support and imports meshes, materials, and animations well.

---

## Recommended export steps in Blockbench 🔧
1. Finalize model and textures in Blockbench (keep textures in sensible resolutions — e.g., 512/1024).
2. Optional: organize models so 1 unit = 1 block in Godot; use consistent scaling.
3. File → Export → **glTF (.glb)**.
   - Choose **GLB** to embed textures.
   - Enable **Export animations** if you have animations and name them clearly.
   - Check orientation/axis: Godot uses **Y-up**. If your model is rotated on import, rotate it in Blockbench or correct it during import.
   - Ensure any vertex skinning or bones used for animation are exported.

---

## Importing into Godot 🛠️
1. Put the exported `.glb` into your project (e.g. `res://assets/models/`).
2. Select the file in the **Filesystem** dock and open the **Import** tab.
   - Import as **Scene** (default) so Godot creates a scene (`.scn`/instantiable resource).
   - Enable **Import Animations** if your model contains animations.
   - If scale looks off, adjust **Import Scale** or correct in the model root node.
3. Click **Reimport** after changing import settings.
4. To use the model from code:

```gdscript
# example: spawn a glb scene
var ModelScene = preload("res://assets/models/my_model.glb")
var inst = ModelScene.instantiate()
add_child(inst)
```

---

## Handling textures & materials 🎨
- If using GLB with embedded textures, Godot will create images under `res://` (in the import cache). If textures are missing, export with embedded textures or copy the texture files next to the `.glb`.
- For stylized/blocky assets, you may prefer unshaded or simple PBR settings. After import, tune `StandardMaterial3D` nodes or create custom `ShaderMaterial`s.

---

## Animations 🕺
- Animations exported from Blockbench will appear under an `AnimationPlayer` or as `Animation` resources inside the imported scene.
- Play them via the `AnimationPlayer` node or control via an `AnimationTree` for complex blending.

---

## Physics & Collisions ⚠️
- Blockbench doesn't export Godot collision shapes. Create `CollisionShape3D` nodes manually (e.g., `BoxCollider`, `ConvexPolygonShape3D`) to match your meshes.

---

## Troubleshooting tips 🔎
- Model rotated: re-export with Y-up or rotate root in Godot and re-save the scene.
- Invisible mesh: check normals and material flags (backface culling, transparency modes).
- Animations not present: confirm bones/armature were correctly exported and "Export animations" was enabled.

---

## Recommended project layout and workflow 💡
- Keep source `.bbmodel` files in `res://assets/blockbench_sources/`.
- Put exported `.glb` files in `res://assets/models/` and version them (e.g., `dragon_v01.glb`).
- Reimport the `.glb` after making changes in Blockbench.

---

## Next steps I can do for you 🔧
- Create a small example scene in `scenes/` that demonstrates importing a sample `.glb` and playing an animation. ✅
- Add a template folder structure (`assets/blockbench_sources/`, `assets/models/`). ✅

If you'd like, tell me which next step you want me to do and I’ll add it to the repo.