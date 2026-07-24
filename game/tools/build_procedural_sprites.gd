extends Node

# Bakes the remaining runtime-drawn UI sprites into real PNG files, same
# "capture a _draw()-based Control's real pixels once, load the file at
# runtime from then on" technique build_icon_atlas.gd already established
# for mode_icon.gd's icon shapes -- "every sprite should be pixel art,
# nothing made at runtime" per the user's own explicit ask. Covers:
#   - rank_badge.gd's 6 tier badges (5 named tiers + the unranked default)
#   - local_map_icon.gd's 6 fixed local-map preview silhouettes
#   - ui_style.gd's slider grabber dot (only ever actually called with one
#     color, COLOR_LOCAL, across every real call site)
# Run via:
#   godot --path . res://tools/build_procedural_sprites.tscn
# NOT --headless -- same SubViewport-capture requirement build_icon_atlas.gd
# documents (headless has no real rendering backend to capture from).

const UIStyle := preload("res://ui/ui_style.gd")
const RankBadgeScene := preload("res://ui/rank_badge.gd")
const LocalMapIconScene := preload("res://ui/local_map_icon.gd")
const LocalMapCatalog := preload("res://levels/local_maps/catalog.gd")

const RANK_BADGE_SIZE := Vector2i(44, 52) # 2x rank_badge.gd's real 22x26 render size
const RANK_BADGE_OUT_DIR := "res://assets/icons/rank_badges"
# "" (empty tier) is the unranked/default case -- see UIStyle.RANK_TIER_DEFAULT_COLOR.
const RANK_TIERS := ["Bronze", "Silver", "Gold", "Platinum", "Diamond", "Master", "Grandmaster", "Champion", "Legend", "Mythic", "Immortal", "Creator", ""]

const MAP_ICON_SIZE := Vector2i(208, 110) # source resolution; LocalMapIcon stretches the baked PNG to whatever size a caller actually displays it at
const MAP_ICON_OUT_DIR := "res://assets/icons/local_map_icons"
const MAP_IDS := ["classic_arena", "wide_open", "twin_towers", "staircase", "scattered_islands", "pillars_and_ledges"]

const SLIDER_GRABBER_OUT := "res://assets/icons/slider_grabber_local.png"

func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(RANK_BADGE_OUT_DIR))
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(MAP_ICON_OUT_DIR))

	for tier in RANK_TIERS:
		var img := await _render_rank_badge(tier)
		var key: String = tier.to_lower() if not tier.is_empty() else "default"
		img.save_png("%s/%s.png" % [RANK_BADGE_OUT_DIR, key])
		print("baked rank badge: ", key)

	for map_id in MAP_IDS:
		var img := await _render_map_icon(map_id)
		img.save_png("%s/%s.png" % [MAP_ICON_OUT_DIR, map_id])
		print("baked local map icon: ", map_id)

	_bake_slider_grabber()

	print("BUILD_PROCEDURAL_SPRITES_DONE")
	get_tree().quit()

## Same offscreen-SubViewport-capture technique build_icon_atlas.gd uses for
## mode_icon.gd -- renders the real, already-correct _draw() Control once
## and captures its actual pixels, instead of hand-reimplementing the shield
## shape as raw Image math (which would risk drifting from what rank_badge.gd
## actually draws).
func _render_rank_badge(tier: String) -> Image:
	var viewport := SubViewport.new()
	viewport.size = RANK_BADGE_SIZE
	viewport.transparent_bg = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(viewport)
	await get_tree().process_frame

	var badge := RankBadgeScene.new()
	badge.tier = tier
	viewport.add_child(badge)
	badge.custom_minimum_size = Vector2(RANK_BADGE_SIZE)
	badge.size = Vector2(RANK_BADGE_SIZE)
	badge.queue_redraw()

	for i in 8:
		await get_tree().process_frame
	var img := viewport.get_texture().get_image()
	viewport.queue_free()
	return img

func _render_map_icon(map_id: String) -> Image:
	var viewport := SubViewport.new()
	viewport.size = MAP_ICON_SIZE
	viewport.transparent_bg = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(viewport)
	await get_tree().process_frame

	var icon := LocalMapIconScene.new()
	icon.map_id = map_id
	icon.accent_color = UIStyle.COLOR_LOCAL
	viewport.add_child(icon)
	icon.custom_minimum_size = Vector2(MAP_ICON_SIZE)
	icon.size = Vector2(MAP_ICON_SIZE)
	icon.queue_redraw()

	for i in 8:
		await get_tree().process_frame
	var img := viewport.get_texture().get_image()
	viewport.queue_free()
	return img

## Pure Image pixel math, same as ui_style.gd's own generation -- no
## viewport capture needed here, this was never a _draw()-based Control.
## Only bakes the one color (COLOR_LOCAL) every real call site actually
## uses; style_slider() falls back to generating it live for any other
## color, so this never hard-fails on an uncommon accent.
func _bake_slider_grabber() -> void:
	var dot := Image.create(14, 14, false, Image.FORMAT_RGBA8)
	dot.fill(Color(0, 0, 0, 0))
	var ring := Color(0.08, 0.08, 0.11)
	var color := UIStyle.COLOR_LOCAL
	for y in 14:
		for x in 14:
			var dist := Vector2(x - 6.5, y - 6.5).length()
			if dist <= 6.5:
				dot.set_pixel(x, y, ring)
			if dist <= 5.0:
				dot.set_pixel(x, y, color)
	dot.save_png(SLIDER_GRABBER_OUT)
	print("baked slider grabber dot")
