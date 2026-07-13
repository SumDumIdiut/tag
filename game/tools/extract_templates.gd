extends Node

# One-off tool: dumps the neutral-marker template PNGs for every paintable
# rig part + hat shape into game/assets/character_templates/, for a friend
# to open in the Art Tool (or any image editor) and paint over. Run via:
#   godot --headless --path . res://tools/extract_templates.tscn
# Re-running is safe/idempotent -- it always regenerates from the current
# shape geometry in skin_catalog.gd, so if the rig shapes ever change,
# rerun this once to refresh the templates before anyone paints over them.
# This should only need to run once per shape change, not on every build --
# unlike tools/bake_character_art.gd, this is NOT part of the CI pipeline.

const OUT_DIR := "res://assets/character_templates"

func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR + "/hats"))

	var whole := SkinCatalog.paint_character_template()
	for part_name in SkinCatalog.PART_NAMES:
		var rect: Rect2i = SkinCatalog.PART_DEFS[part_name].rect
		var cropped := whole.get_region(rect)
		cropped.save_png("%s/%s.png" % [OUT_DIR, part_name])
		print("wrote ", part_name)

	for h in SkinCatalog.BUILTIN_HATS:
		var img := SkinCatalog.paint_hat_template(h.shape)
		img.save_png("%s/hats/%s.png" % [OUT_DIR, h.shape])
		print("wrote hat ", h.shape)

	print("EXTRACT_DONE")
	get_tree().quit()
