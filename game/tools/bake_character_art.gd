extends Node

# Regenerates every baked character/hat PNG the running game actually loads
# (see skin_catalog.gd's _load_or_paint_character_parts/_load_or_paint_hat)
# from whatever currently lives in game/assets/character_templates/. Run via:
#   godot --headless --path . res://tools/bake_character_art.tscn
# This is the piece CI runs before every export (.github/workflows/build.yml)
# -- a friend's edited template just needs to land in
# game/assets/character_templates/ on main, and this script (run
# automatically by CI) is the entire rest of the mechanism that turns it
# into what players actually see. Safe to re-run any time; fully
# deterministic given the same templates. The actual per-pixel tint math
# lives in SkinCatalog.tint_template() -- shared with the Art Tool's live
# preview panel so both use identical logic.

const TEMPLATE_DIR := "res://assets/character_templates"
const OUT_DIR := "res://assets/character"

func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR + "/hats"))

	var baked_count := 0
	for part_name in SkinCatalog.PART_NAMES:
		var template := _load_template("%s/%s.png" % [TEMPLATE_DIR, part_name])
		if not template:
			push_warning("skipping missing template for part: " + part_name)
			continue
		for skin in SkinCatalog.BUILTIN_SKINS:
			var baked := SkinCatalog.tint_template(template, skin.color, SkinCatalog.CHARACTER_SHADE_AMOUNT, SkinCatalog.CHARACTER_HIGHLIGHT_AMOUNT)
			baked.save_png("%s/%s_%s.png" % [OUT_DIR, skin.id, part_name])
			baked_count += 1
		print("baked ", part_name, " x", SkinCatalog.BUILTIN_SKINS.size(), " skins")

	for h in SkinCatalog.BUILTIN_HATS:
		var template := _load_template("%s/hats/%s.png" % [TEMPLATE_DIR, h.shape])
		if not template:
			push_warning("skipping missing template for hat: " + h.shape)
			continue
		var baked := SkinCatalog.tint_template(template, h.color, SkinCatalog.HAT_SHADE_AMOUNT, SkinCatalog.HAT_HIGHLIGHT_AMOUNT)
		baked.save_png("%s/hats/%s.png" % [OUT_DIR, h.id])
		baked_count += 1
		print("baked hat ", h.id)

	print("BAKE_DONE count=", baked_count)
	get_tree().quit()

func _load_template(path: String) -> Image:
	var img := Image.new()
	if img.load(path) != OK:
		return null
	return img
