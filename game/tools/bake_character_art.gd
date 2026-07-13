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
# deterministic given the same templates.

const TEMPLATE_DIR := "res://assets/character_templates"
const OUT_DIR := "res://assets/character"

# How close (per channel, 0-1 range) a template pixel needs to be to one of
# SkinCatalog's marker tones to be treated as that role rather than a custom
# paint addition -- wide enough to absorb 8-bit PNG round-trip quantization,
# narrow enough that a friend's own deliberately-different colors don't
# accidentally get swallowed by a marker role.
const TOLERANCE := 0.05

func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR + "/hats"))

	var baked_count := 0
	for part_name in SkinCatalog.PART_NAMES:
		var template := _load_template("%s/%s.png" % [TEMPLATE_DIR, part_name])
		if not template:
			push_warning("skipping missing template for part: " + part_name)
			continue
		for skin in SkinCatalog.BUILTIN_SKINS:
			var baked := _bake(template, skin.color, SkinCatalog.CHARACTER_SHADE_AMOUNT, SkinCatalog.CHARACTER_HIGHLIGHT_AMOUNT)
			baked.save_png("%s/%s_%s.png" % [OUT_DIR, skin.id, part_name])
			baked_count += 1
		print("baked ", part_name, " x", SkinCatalog.BUILTIN_SKINS.size(), " skins")

	for h in SkinCatalog.BUILTIN_HATS:
		var template := _load_template("%s/hats/%s.png" % [TEMPLATE_DIR, h.shape])
		if not template:
			push_warning("skipping missing template for hat: " + h.shape)
			continue
		var baked := _bake(template, h.color, SkinCatalog.HAT_SHADE_AMOUNT, SkinCatalog.HAT_HIGHLIGHT_AMOUNT)
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

## Marker regions (base/shade/highlight) get the exact same transform the
## original procedural painter used (color / darkened / lightened) for
## pixel-parity with the pre-template look. Anything else -- eyes, hat
## accents, or a friend's own custom paint -- gets a generic multiply tint
## instead: for the fixed-dark accent colors already in use (eyes, the
## crown's jewel) this stays visually close to unchanged across every skin
## color, since multiplying an already-dark color by anything <=1 can only
## keep it dark, while still giving a friend's own additions a reasonable
## per-skin recolor rather than staying frozen in whatever color they drew.
func _bake(template: Image, color: Color, shade_amount: float, highlight_amount: float) -> Image:
	var w := template.get_width()
	var h := template.get_height()
	var out := Image.create(w, h, false, Image.FORMAT_RGBA8)
	var shade := color.darkened(shade_amount)
	var highlight := color.lightened(highlight_amount)
	for y in h:
		for x in w:
			var px := template.get_pixel(x, y)
			if px.a <= 0.001:
				continue
			var out_color: Color
			if _close(px, SkinCatalog.TEMPLATE_BASE):
				out_color = color
			elif _close(px, SkinCatalog.TEMPLATE_SHADE):
				out_color = shade
			elif _close(px, SkinCatalog.TEMPLATE_HIGHLIGHT):
				out_color = highlight
			else:
				out_color = Color(px.r * color.r, px.g * color.g, px.b * color.b, 1.0)
			out_color.a = px.a
			out.set_pixel(x, y, out_color)
	return out

func _close(a: Color, b: Color) -> bool:
	return absf(a.r - b.r) < TOLERANCE and absf(a.g - b.g) < TOLERANCE and absf(a.b - b.b) < TOLERANCE
