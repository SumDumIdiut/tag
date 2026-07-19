extends Node

# One-off tool: bakes the 6 procedural ModeIcon shapes (ui/mode_icon.gd) into
# a paintable atlas image, the same "generate a placeholder, let the artist
# paint over it" pattern build_tileset.gd already established for tiles. Run
# via:
#   godot --path . res://tools/build_icon_atlas.tscn
# Unlike build_tileset.gd (pure Image pixel-buffer manipulation, no
# rendering involved), this one needs an actual rendered frame of a
# _draw()-based Control -- run windowed, NOT --headless, since headless mode
# has no real rendering backend to capture from.
#
# Baked in solid white on transparent, not each usage's real accent color --
# ModeIcon re-tints the loaded texture per call site via draw_texture_rect's
# modulate argument, exactly preserving today's "same icon shape, different
# color per mode bar" behavior once the atlas exists (see mode_icon.gd).
# Re-running regenerates the atlas from scratch; safe/idempotent.

const ModeIconScene := preload("res://ui/mode_icon.gd")
const ICON_SIZE := 64
# Order matters -- this is the atlas-index contract mode_icon.gd reads by
# position, mirroring build_tileset.gd's TILES-array-order contract.
const ICON_TYPES := ["globe", "controller", "box", "bolt", "star", "tag"]
const OUT_ATLAS := "res://assets/icons/tag_icons.png"

func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://assets/icons"))

	var atlas := Image.create(ICON_SIZE * ICON_TYPES.size(), ICON_SIZE, false, Image.FORMAT_RGBA8)
	for i in ICON_TYPES.size():
		var img := await _render_icon(ICON_TYPES[i])
		atlas.blit_rect(img, Rect2i(Vector2i.ZERO, Vector2i(ICON_SIZE, ICON_SIZE)), Vector2i(i * ICON_SIZE, 0))

	atlas.save_png(OUT_ATLAS)
	print("wrote atlas: ", OUT_ATLAS)
	print("BUILD_ICON_ATLAS_DONE")
	get_tree().quit()

## Renders one ModeIcon (in white, so the atlas stays a neutral, re-tintable
## template) into an offscreen SubViewport and captures the result as a
## plain Image -- the only way to get real pixels out of a _draw()-based
## Control, since its icon shapes only exist as immediate-mode draw calls,
## never as data Image.create()/fill_rect() could produce directly.
func _render_icon(icon_type: String) -> Image:
	var viewport := SubViewport.new()
	viewport.size = Vector2i(ICON_SIZE, ICON_SIZE)
	viewport.transparent_bg = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(viewport)
	# Let the viewport itself settle into the tree (own World2D, own render
	# target allocated) before anything is drawn into it -- adding a child
	# that immediately queues a _draw() the same frame the viewport itself
	# was only just added is what produced the truncated/near-empty icons
	# seen on the first attempt (only "box", the icon with by far the
	# largest fill area, survived that race well enough to be recognizable).
	await get_tree().process_frame

	var icon := ModeIconScene.new()
	icon.icon_type = icon_type
	icon.icon_color = Color.WHITE
	viewport.add_child(icon)
	icon.custom_minimum_size = Vector2(ICON_SIZE, ICON_SIZE)
	icon.size = Vector2(ICON_SIZE, ICON_SIZE)
	icon.queue_redraw()

	# Several real frames of headroom -- one coroutine driving 6 sequential
	# viewport renders back-to-back is worth being generous here rather than
	# chasing the exact minimum, since this only ever runs as a one-off
	# authoring tool, never at actual game runtime.
	for i in 8:
		await get_tree().process_frame
	var img := viewport.get_texture().get_image()
	viewport.queue_free()
	return img
