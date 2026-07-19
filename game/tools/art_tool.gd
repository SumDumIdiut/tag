extends Control

# Standalone paint tool, exported as its own executable (TagArtTool.exe, see
# export_presets.cfg's "Art Tool" preset). Five pages, switched at the top
# like a dedicated app rather than one cramped screen: PAINT (create/edit
# any number of independent custom skins, hats, and trails -- no pre-made
# defaults, every one starts as a blank canvas), PREVIEW (a single large render of
# any skin/hat combination, picked from real dropdowns), LEVEL (paint a
# tile-based map and publish it live -- see game/levels/level_data.gd),
# TILES (paint the actual texture of the game's built-in tile types --
# boundary/pillar/platform, each with 3 art variants -- which the Level
# page's TileCanvas currently only ever renders as flat placeholder colors;
# see _build_tiles_page), and ICONS, which covers two independent things
# sharing one canvas/toolbar: small mode-bar badge icons (originally 100%
# procedural CanvasItem drawing with no image asset at all; see
# ui/mode_icon.gd's atlas-with-procedural-fallback loading) and whole
# mode-button art (an entire main-menu button -- background, character,
# label, everything -- painted as one 190x360 image per mode, replacing the
# procedural box outright when present; see main_menu.gd's
# MODE_BUTTON_ART_PATH). Both support Import Image (loads a PNG from disk
# into the clipboard) plus the existing Selection > Stamp/Move tools for
# composing from other elements without a dedicated drag-and-drop layer
# system.
#
# Custom skins/hats are unrelated to the game's built-in 8 colors -- they're
# painted in real color directly, the same way the game's own in-shop
# drawing tool works, not tinted from a shared template. Icons are the one
# exception: they're baked/painted in white/grayscale and re-tinted per
# usage at runtime (each mode bar has its own accent color), so painting
# them in a specific hue would look wrong once multiplied by that tint.
#
# PAINT, TILES, and ICONS all drive their canvas through the same shared
# toolbar builder (_build_shared_toolbar) and the same _current_canvas/
# _apply_tool_state() mechanism the rest of this file already used for the
# Paint page, so every tool (shapes, selection, mirror, transforms,
# palette, ...) works identically in all three without duplicated logic.

const UIStyle := preload("res://ui/ui_style.gd")
const CharacterPreviewScene := preload("res://ui/character_preview.gd")
const PixelCanvasScene := preload("res://main/pixel_canvas.gd")
const UpdateCheckerScript := preload("res://net/update_checker.gd")
const UpdatePromptScene := preload("res://ui/update_prompt.gd")
const TileCanvasScene := preload("res://main/tile_canvas.gd")
const LevelData := preload("res://levels/level_data.gd")

const ZOOM := 18

const SKIN_INSTRUCTIONS_TEXT := """Each skin here is a complete, independent design. Adding one to the
game doesn't need a rebuild or a pull request.

Each skin's folder has a ready-to-use composited PNG (named after the
skin) plus its individual parts/ (in case it needs re-editing later).
Send the composited PNG and the skin's name to whoever runs the game's
server -- they add it with one command:

    node add-skin.js path/to/your-skin.png "Skin Name"

and it's live for everyone immediately, no build or restart needed.
"""

const HAT_INSTRUCTIONS_TEXT := """Send each hat PNG and its name to whoever runs the game's server --
they add it with one command:

    node add-hat.js path/to/your-hat.png "Hat Name"

and it's live for everyone immediately, no build or restart needed.
"""

const TRAIL_INSTRUCTIONS_TEXT := """Send each trail PNG and its name to whoever runs the game's server --
they add it with one command:

    node add-trail.js path/to/your-trail.png "Trail Name"

and it's live for everyone immediately, no build or restart needed.
"""

const TILE_INSTRUCTIONS_TEXT := """tag_tiles.png is a horizontal strip, one 10x10 tile per slot, 11 slots in
this exact order: Boundary Piece, Pillar Piece, Platform Piece, Boundary
Corner, Pillar Corner, Platform Corner, Boundary Internal, Pillar
Internal, Platform Internal, Ice, Bouncy -- the same layout tools/
build_tileset.gd generates and game/levels/tag_tileset.tres reads from.
(Slots 0-2 are the same Boundary/Pillar/Platform tiles the original 3-tile
atlas had, in the same order -- the 6 Corner/Internal slots and the 2
behavior slots (Ice/Bouncy, see player.gd) were each appended after, never
inserted, so already-published levels keep decoding the same way.)

To make this the game's real tile texture:

  1. Copy this file to game/assets/tiles/tag_tiles.png, overwriting the
     existing one.
  2. Re-run tools/build_tileset.gd from inside the Godot editor (it
     regenerates tag_tileset.tres's atlas regions/collision from the new
     image -- the tile size and tile order must stay exactly as they are
     here, or the regions will point at the wrong pixels).
  3. Commit both changed files.
"""

const ICON_INSTRUCTIONS_TEXT := """tag_icons.png is a horizontal strip, one 64x64 icon per slot, 6 slots in
this exact order: Globe, Controller, Box, Bolt, Star, Tag -- the same
layout tools/build_icon_atlas.gd generates and game/ui/mode_icon.gd reads
from.

These icons are re-tinted per usage at runtime (each mode bar applies its
own accent color), so they should stay white/grayscale -- a specific hue
here will look wrong once multiplied by a bar's own color.

To make this the game's real menu icon set:

  1. Copy this file to game/assets/icons/tag_icons.png, overwriting the
     existing one.
  2. Commit the changed file -- no rebuild step needed beyond that,
     mode_icon.gd loads it directly at runtime.
"""

const MODE_BUTTON_INSTRUCTIONS_TEXT := """Each file here is one main-menu mode button's ENTIRE art -- background,
character, label, everything -- painted at 190x360, the exact size
main_menu.gd renders that button at.

To make one of these the game's real button art:

  1. Copy the file to game/assets/icons/mode_buttons/<key>.png, where
     <key> is online.png, local.png, or sandbox.png (matching the file's
     own name here).
  2. Commit the file -- no rebuild step needed, main_menu.gd checks for
     it at runtime and uses it in place of the procedural glow/portrait/
     label box automatically.

A mode with no file here just keeps using the procedural fallback -- you
don't need to paint all three at once.
"""

@onready var paint_tab_button: Button = $VBox/PageTabRow/PaintTabButton
@onready var preview_tab_button: Button = $VBox/PageTabRow/PreviewTabButton
@onready var level_tab_button: Button = $VBox/PageTabRow/LevelTabButton
@onready var paint_page: HBoxContainer = $VBox/PaintPage
@onready var preview_page: VBoxContainer = $VBox/PreviewPage
@onready var level_page: HBoxContainer = $VBox/LevelPage

@onready var part_list: VBoxContainer = $VBox/PaintPage/PartPanel/PartScroll/PartList
@onready var canvas_holder: CenterContainer = $VBox/PaintPage/CanvasPanel/CanvasBox/CanvasHolder
@onready var empty_state_label: Label = $VBox/PaintPage/CanvasPanel/CanvasBox/EmptyStateLabel
@onready var toolbar: HBoxContainer = $VBox/PaintPage/CanvasPanel/CanvasBox/Toolbar
@onready var color_picker: ColorPicker = $VBox/PaintPage/RightPanel/RightBox/ColorPicker

@onready var big_preview_center: CenterContainer = $VBox/PreviewPage/BigPreviewPanel/BigPreviewCenter
@onready var skin_select: OptionButton = $VBox/PreviewPage/SelectorRow/SkinSelectBox/SkinSelect
@onready var hat_select: OptionButton = $VBox/PreviewPage/SelectorRow/HatSelectBox/HatSelect

@onready var level_toolbar: HBoxContainer = $VBox/LevelPage/LevelCanvasPanel/LevelCanvasBox/LevelToolbar
@onready var level_canvas_center: CenterContainer = $VBox/LevelPage/LevelCanvasPanel/LevelCanvasBox/LevelCanvasScroll/LevelCanvasCenter
@onready var level_name_edit: LineEdit = $VBox/LevelPage/LevelRightPanel/LevelRightBox/LevelNameEdit
@onready var publish_level_button: Button = $VBox/LevelPage/LevelRightPanel/LevelRightBox/PublishLevelButton

@onready var status_label: Label = $VBox/BottomRow/StatusLabel
@onready var export_button: Button = $VBox/BottomRow/ExportButton

# Which part/hat canvas is currently open for editing -- `_current_id` is
# the stable internal id (see _custom_skins/_custom_hats below), tracked
# explicitly rather than by comparing image content, since two freshly
# created blank skins are byte-identical and would otherwise both appear
# "selected" at once.
var _current_images: Dictionary
var _current_key := ""
var _current_context := "" # "skin", "hat", "trail", or "" (nothing open)
var _current_id := ""
var _current_canvas: PixelCanvas = null

var _part_group := ButtonGroup.new()
var _current_tool := 0 # PixelCanvas.Tool.BRUSH
# Toolbar-level tool settings -- shared by both the Paint and Tiles pages'
# toolbars (_build_shared_toolbar) and reapplied to whichever canvas is
# active by _apply_tool_state(), rather than living on PixelCanvas
# instances themselves, so switching between parts/tiles mid-edit doesn't
# reset the brush size or mirror mode the user just set up.
var _brush_size := 1
var _brush_alpha := 1.0
var _mirror_h := false
var _mirror_v := false
var _show_grid := false
# Which ColorPicker currently feeds _apply_tool_state() -- the Paint and
# Tiles pages each have their own (only one is ever visible/relevant at a
# time), set by _setup_page_tabs()'s tab handlers.
var _active_color_picker: ColorPicker = null
var tiles_color_picker: ColorPicker

var _custom_skins := {} # id -> {part_name -> Image}
var _skin_names := {} # id -> display name
var _custom_skins_list: VBoxContainer
var _next_skin_num := 1

var _custom_hats := {} # id -> {"design": Image}
var _hat_names := {} # id -> display name
var _custom_hats_list: VBoxContainer
var _next_hat_num := 1

var _custom_trails := {} # id -> {"design": Image}
var _trail_names := {} # id -> display name
var _custom_trails_list: VBoxContainer
var _next_trail_num := 1

var _big_preview
var _preview_skin_id := ""
var _preview_hat_id := ""

var _tile_canvas: TileCanvas
const LEVEL_API_BASE := "https://codecade.co.za/tag/api/levels"

# Multiple independent levels, same list-of-named-things pattern skins/hats/
# trails already use -- "+ New Level" starts a fresh blank map, each entry
# in the sidebar switches _tile_canvas to that map's own cells/spawn_points/
# platforms (plain Dictionary/Array, mutated in place by TileCanvas, so
# switching is just repointing _tile_canvas's own references, no explicit
# save-back step needed the way PixelCanvas's Image-swapping tools need).
var _custom_levels := {} # id -> {cells: Dictionary, spawn_points: Array, platforms: Array}
var _level_names := {} # id -> display name
var _custom_levels_list: VBoxContainer
var _next_level_num := 1
var _current_level_id := ""
var _level_button_group := ButtonGroup.new()
var _level_props_container: VBoxContainer
var _level_props_content: VBoxContainer

# ─── Tiles page (paint the actual texture of the built-in tile types) ───────
const TILE_TEXTURE_SIZE := 10 # must match tools/build_tileset.gd's TILE_SIZE
const TILE_ATLAS_PATH := "res://assets/tiles/tag_tiles.png"
# Same names/order tile_canvas.gd's TILE_COLORS and build_tileset.gd's TILES/
# VARIANT_NAMES all already use -- keeping the order identical is what makes
# tile_index() here line up with atlas slot i in the exported strip. Each
# base type now has 3 art variants (a straight edge Piece, a Corner, and a
# fully-surrounded Internal), so a hand-placed level can use the
# right-looking piece at a platform's edges/corners instead of one flat
# texture tiling awkwardly everywhere -- see _build_tiles_page/_build_level_
# page below, both of which pick a tile index via tile_index().
const TILE_TYPE_NAMES := ["Boundary", "Pillar", "Platform"]
const TILE_VARIANT_NAMES := ["Piece", "Corner", "Internal"]
# Two behaviorally-real floor types (see player.gd's tile-behavior lookup,
# build_tileset.gd's "behavior" custom data layer) -- single flat tiles
# appended after the type/variant grid above (indices 9, 10), not part of
# it: v1 scope is one art variant each, not the full Piece/Corner/Internal
# treatment every other type gets.
const EXTRA_TILE_NAMES := ["Ice", "Bouncy"]
const TILE_TEXTURE_ZOOM := 34 # a 10x10 image needs a much bigger per-pixel
# zoom than a 32x48 skin part to be comfortably paintable at all.

## variant_index * 3 + type_index, NOT type-major -- this is what keeps
## indices 0/1/2 exactly Boundary/Pillar/Platform's Piece variant, matching
## the original 3-tile atlas, so tag_arena.tscn's already-painted cells and
## any level already published before variants existed still render as the
## same tile they always did (see build_tileset.gd's TILES comment).
static func tile_index(type_idx: int, variant_idx: int) -> int:
	return variant_idx * TILE_TYPE_NAMES.size() + type_idx

var tiles_tab_button: Button
var tiles_page: HBoxContainer
var tiles_toolbar: Container
var tiles_canvas_holder: CenterContainer
var _tile_images: Array[Image] = [] # index-matched to tile_index()
var _current_tile_index := -1
var _tile_select_buttons: Array[Button] = [] # index-matched to tile_index()

# Level page's placement palette: which (type, variant) pair PAINT currently
# stamps onto the grid -- Internal is the default variant since it's the
# "fill" piece most of a platform's interior actually uses.
var _level_selected_type := 0
var _level_selected_variant := 2

# ─── Icons page (paint the main menu's procedural mode-bar badge icons) ─────
const ICON_TEXTURE_SIZE := 64 # must match tools/build_icon_atlas.gd's ICON_SIZE
const ICON_ATLAS_PATH := "res://assets/icons/tag_icons.png"
# Same order build_icon_atlas.gd bakes in and ui/mode_icon.gd's
# ATLAS_ICON_ORDER reads by index.
const ICON_TYPE_NAMES := ["Globe", "Controller", "Box", "Bolt", "Star", "Tag"]
const ICON_TEXTURE_ZOOM := 6 # already 64x64 -- a much smaller per-pixel zoom
# than tiles/skins need to stay comfortably on-screen.

var icons_tab_button: Button
var icons_page: HBoxContainer
var icons_toolbar: Container
var icons_canvas_holder: CenterContainer
var icons_color_picker: ColorPicker
var _icon_images: Array[Image] = [] # index-matched to ICON_TYPE_NAMES
var _current_icon_index := -1
var _icon_select_buttons: Array[Button] = []

# Whole-button custom art for the main menu's 3 mode bars (Online/Local/
# Sandbox) -- an alternative to the small badge-icon-on-a-procedural-box
# system above: paint the entire button (background, character, label, all
# of it) as one image, same canvas size the real button renders at, so
# what's painted here is exactly what shows up in-game. Matches
# main_menu.gd's MODES key order exactly -- "online"/"local"/"sandbox".
const MODE_BUTTON_KEYS := ["online", "local", "sandbox"]
const MODE_BUTTON_NAMES := ["Online", "Local", "Sandbox"]
const MODE_BUTTON_SIZE := Vector2i(190, 360) # matches main_menu.gd's BAR_SIZE exactly
const MODE_BUTTON_ART_DIR := "res://assets/icons/mode_buttons"
const MODE_BUTTON_ZOOM := 2 # 190x360 is already large -- a much smaller per-pixel zoom than a 64x64 icon needs
var _button_art_images: Array[Image] = [] # index-matched to MODE_BUTTON_KEYS
var _current_button_art_index := -1
var _button_art_select_buttons: Array[Button] = []
var _import_file_dialog: FileDialog

func _ready() -> void:
	get_window().size = Vector2i(1300, 860)
	get_window().title = "Tag Art Tool"
	UIStyle.add_background(self)
	_setup_page_tabs()
	_build_sidebar()
	_build_shared_toolbar(toolbar)
	_build_level_page()
	_build_tiles_page()
	_build_icons_page()
	_active_color_picker = color_picker
	color_picker.color_changed.connect(_on_color_picked_from_wheel)
	export_button.pressed.connect(_on_export_pressed)
	UIStyle.style_button(export_button, UIStyle.COLOR_SHOP)
	_build_big_preview()
	canvas_holder.visible = false
	empty_state_label.visible = true
	_check_for_update()

func _check_for_update() -> void:
	var checker := UpdateCheckerScript.new("TagArtTool.exe")
	add_child(checker)
	checker.check_completed.connect(_on_update_check_completed)
	checker.check()

func _on_update_check_completed(result: Dictionary) -> void:
	if not result.get("available", false):
		return
	var prompt := UpdatePromptScene.new()
	add_child(prompt)
	prompt.setup(result.version, result.download_url)

func _setup_page_tabs() -> void:
	# TilesTabButton/TilesPage aren't in the .tscn -- built and inserted
	# alongside the other three entirely in code, right next to the tab row/
	# page container that already own the other tabs, so there's nothing
	# scene-file-specific about how this one is wired in.
	var tab_row: HBoxContainer = paint_tab_button.get_parent()
	tiles_tab_button = Button.new()
	tiles_tab_button.custom_minimum_size = Vector2(140, 38)
	tiles_tab_button.toggle_mode = true
	tiles_tab_button.text = "Tiles"
	tab_row.add_child(tiles_tab_button)

	icons_tab_button = Button.new()
	icons_tab_button.custom_minimum_size = Vector2(140, 38)
	icons_tab_button.toggle_mode = true
	icons_tab_button.text = "Icons"
	tab_row.add_child(icons_tab_button)

	var tab_group := ButtonGroup.new()
	paint_tab_button.button_group = tab_group
	preview_tab_button.button_group = tab_group
	level_tab_button.button_group = tab_group
	tiles_tab_button.button_group = tab_group
	icons_tab_button.button_group = tab_group
	UIStyle.style_button(paint_tab_button, UIStyle.COLOR_SHOP, 10)
	UIStyle.style_button(preview_tab_button, UIStyle.COLOR_ONLINE, 10)
	UIStyle.style_button(level_tab_button, UIStyle.COLOR_SANDBOX, 10)
	UIStyle.style_button(tiles_tab_button, UIStyle.COLOR_RANKED, 10)
	UIStyle.style_button(icons_tab_button, UIStyle.COLOR_LOCAL, 10)
	paint_tab_button.pressed.connect(func():
		paint_page.visible = true
		preview_page.visible = false
		level_page.visible = false
		tiles_page.visible = false
		icons_page.visible = false
		export_button.visible = true
		_active_color_picker = color_picker
		_apply_tool_state()
	)
	preview_tab_button.pressed.connect(func():
		paint_page.visible = false
		preview_page.visible = true
		level_page.visible = false
		tiles_page.visible = false
		icons_page.visible = false
		export_button.visible = true
		_refresh_preview_selectors()
		_refresh_big_preview()
	)
	level_tab_button.pressed.connect(func():
		paint_page.visible = false
		preview_page.visible = false
		level_page.visible = true
		tiles_page.visible = false
		icons_page.visible = false
		export_button.visible = false
	)
	tiles_tab_button.pressed.connect(func():
		paint_page.visible = false
		preview_page.visible = false
		level_page.visible = false
		tiles_page.visible = true
		icons_page.visible = false
		export_button.visible = true
		_active_color_picker = tiles_color_picker
		_apply_tool_state()
	)
	icons_tab_button.pressed.connect(func():
		paint_page.visible = false
		preview_page.visible = false
		level_page.visible = false
		tiles_page.visible = false
		icons_page.visible = true
		export_button.visible = true
		_active_color_picker = icons_color_picker
		_apply_tool_state()
	)

## No pre-loaded defaults -- both lists start empty; "+ New Skin"/"+ New
## Hat" are the only way anything appears here.
func _build_sidebar() -> void:
	part_list.add_child(_section_label("CUSTOM SKINS"))
	_custom_skins_list = VBoxContainer.new()
	_custom_skins_list.add_theme_constant_override("separation", 4)
	part_list.add_child(_custom_skins_list)
	var add_skin_btn := Button.new()
	add_skin_btn.text = "+ New Skin"
	UIStyle.style_button(add_skin_btn, UIStyle.COLOR_ONLINE, 8, false)
	add_skin_btn.pressed.connect(_on_add_skin_pressed)
	part_list.add_child(add_skin_btn)

	var hat_spacer := Control.new()
	hat_spacer.custom_minimum_size = Vector2(0, 8)
	part_list.add_child(hat_spacer)

	part_list.add_child(_section_label("CUSTOM HATS"))
	_custom_hats_list = VBoxContainer.new()
	_custom_hats_list.add_theme_constant_override("separation", 4)
	part_list.add_child(_custom_hats_list)
	var add_hat_btn := Button.new()
	add_hat_btn.text = "+ New Hat"
	UIStyle.style_button(add_hat_btn, UIStyle.COLOR_RANKED, 8, false)
	add_hat_btn.pressed.connect(_on_add_hat_pressed)
	part_list.add_child(add_hat_btn)

	var trail_spacer := Control.new()
	trail_spacer.custom_minimum_size = Vector2(0, 8)
	part_list.add_child(trail_spacer)

	part_list.add_child(_section_label("CUSTOM TRAILS"))
	_custom_trails_list = VBoxContainer.new()
	_custom_trails_list.add_theme_constant_override("separation", 4)
	part_list.add_child(_custom_trails_list)
	var add_trail_btn := Button.new()
	add_trail_btn.text = "+ New Trail"
	UIStyle.style_button(add_trail_btn, UIStyle.COLOR_LOCAL, 8, false)
	add_trail_btn.pressed.connect(_on_add_trail_pressed)
	part_list.add_child(add_trail_btn)

func _section_label(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", 12)
	l.add_theme_color_override("font_color", Color(0.7, 0.72, 0.78))
	return l

func _blank_image(size: Vector2i) -> Image:
	var img := Image.create(size.x, size.y, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	return img

func _on_add_skin_pressed() -> void:
	var id := "skin_%d" % _next_skin_num
	var display_num := _next_skin_num
	_next_skin_num += 1
	_skin_names[id] = "Skin %d" % display_num
	var parts := {}
	for part_name in SkinCatalog.PART_NAMES:
		parts[part_name] = _blank_image(SkinCatalog.PART_DEFS[part_name].rect.size)
	_custom_skins[id] = parts
	_rebuild_custom_skins_list()
	_show_part(parts, "body", "skin", id)

func _on_add_hat_pressed() -> void:
	var id := "hat_%d" % _next_hat_num
	var display_num := _next_hat_num
	_next_hat_num += 1
	_hat_names[id] = "Hat %d" % display_num
	var parts := {"design": _blank_image(Vector2i(SkinCatalog.HAT_WIDTH, SkinCatalog.HAT_HEIGHT))}
	_custom_hats[id] = parts
	_rebuild_custom_hats_list()
	_show_part(parts, "design", "hat", id)

func _on_add_trail_pressed() -> void:
	var id := "trail_%d" % _next_trail_num
	var display_num := _next_trail_num
	_next_trail_num += 1
	_trail_names[id] = "Trail %d" % display_num
	var parts := {"design": _blank_image(Vector2i(SkinCatalog.TRAIL_WIDTH, SkinCatalog.TRAIL_HEIGHT))}
	_custom_trails[id] = parts
	_rebuild_custom_trails_list()
	_show_part(parts, "design", "trail", id)

func _rebuild_custom_skins_list() -> void:
	for child in _custom_skins_list.get_children():
		child.queue_free()
	for id in _custom_skins.keys():
		_custom_skins_list.add_child(_build_skin_entry(id))

## A skin is a single square part now (see SkinCatalog.PART_NAMES) --
## this mirrors _build_hat_entry's shape exactly instead of the old
## expand-to-reveal-6-part-buttons layout that made sense when a skin was a
## 6-part rig.
func _build_skin_entry(id: String) -> Control:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 2)

	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 4)
	var select_btn := Button.new()
	select_btn.text = _skin_names[id]
	select_btn.toggle_mode = true
	select_btn.button_group = _part_group
	select_btn.button_pressed = (_current_context == "skin" and _current_id == id)
	select_btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
	select_btn.size_flags_horizontal = SIZE_EXPAND_FILL
	UIStyle.style_button(select_btn, UIStyle.COLOR_SANDBOX, 8, false)
	select_btn.pressed.connect(_show_part.bind(_custom_skins[id], "body", "skin", id))
	header.add_child(select_btn)
	var publish_btn := Button.new()
	publish_btn.text = "Publish"
	publish_btn.custom_minimum_size = Vector2(72, 0)
	UIStyle.style_button(publish_btn, UIStyle.COLOR_ONLINE, 8, false)
	publish_btn.pressed.connect(_on_publish_skin_pressed.bind(id, publish_btn))
	header.add_child(publish_btn)
	header.add_child(_delete_button(func():
		_custom_skins.erase(id)
		_skin_names.erase(id)
		if _current_context == "skin" and _current_id == id:
			_clear_canvas()
		_rebuild_custom_skins_list()
	))
	box.add_child(header)

	var name_edit := LineEdit.new()
	name_edit.text = _skin_names[id]
	name_edit.placeholder_text = "Skin name"
	name_edit.text_submitted.connect(func(new_text: String):
		var trimmed := new_text.strip_edges()
		if not trimmed.is_empty():
			_skin_names[id] = trimmed
		_rebuild_custom_skins_list()
	)
	box.add_child(name_edit)

	return box

func _rebuild_custom_hats_list() -> void:
	for child in _custom_hats_list.get_children():
		child.queue_free()
	for id in _custom_hats.keys():
		_custom_hats_list.add_child(_build_hat_entry(id))

func _build_hat_entry(id: String) -> Control:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 2)

	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 4)
	var select_btn := Button.new()
	select_btn.text = _hat_names[id]
	select_btn.toggle_mode = true
	select_btn.button_group = _part_group
	select_btn.button_pressed = (_current_context == "hat" and _current_id == id)
	select_btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
	select_btn.size_flags_horizontal = SIZE_EXPAND_FILL
	UIStyle.style_button(select_btn, UIStyle.COLOR_SANDBOX, 8, false)
	select_btn.pressed.connect(_show_part.bind(_custom_hats[id], "design", "hat", id))
	header.add_child(select_btn)
	var publish_btn := Button.new()
	publish_btn.text = "Publish"
	publish_btn.custom_minimum_size = Vector2(72, 0)
	UIStyle.style_button(publish_btn, UIStyle.COLOR_ONLINE, 8, false)
	publish_btn.pressed.connect(_on_publish_hat_pressed.bind(id, publish_btn))
	header.add_child(publish_btn)
	header.add_child(_delete_button(func():
		_custom_hats.erase(id)
		_hat_names.erase(id)
		if _current_context == "hat" and _current_id == id:
			_clear_canvas()
		_rebuild_custom_hats_list()
	))
	box.add_child(header)

	var name_edit := LineEdit.new()
	name_edit.text = _hat_names[id]
	name_edit.placeholder_text = "Hat name"
	name_edit.text_submitted.connect(func(new_text: String):
		var trimmed := new_text.strip_edges()
		if not trimmed.is_empty():
			_hat_names[id] = trimmed
		_rebuild_custom_hats_list()
	)
	box.add_child(name_edit)

	return box

func _rebuild_custom_trails_list() -> void:
	for child in _custom_trails_list.get_children():
		child.queue_free()
	for id in _custom_trails.keys():
		_custom_trails_list.add_child(_build_trail_entry(id))

func _build_trail_entry(id: String) -> Control:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 2)

	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 4)
	var select_btn := Button.new()
	select_btn.text = _trail_names[id]
	select_btn.toggle_mode = true
	select_btn.button_group = _part_group
	select_btn.button_pressed = (_current_context == "trail" and _current_id == id)
	select_btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
	select_btn.size_flags_horizontal = SIZE_EXPAND_FILL
	UIStyle.style_button(select_btn, UIStyle.COLOR_SANDBOX, 8, false)
	select_btn.pressed.connect(_show_part.bind(_custom_trails[id], "design", "trail", id))
	header.add_child(select_btn)
	var publish_btn := Button.new()
	publish_btn.text = "Publish"
	publish_btn.custom_minimum_size = Vector2(72, 0)
	UIStyle.style_button(publish_btn, UIStyle.COLOR_ONLINE, 8, false)
	publish_btn.pressed.connect(_on_publish_trail_pressed.bind(id, publish_btn))
	header.add_child(publish_btn)
	header.add_child(_delete_button(func():
		_custom_trails.erase(id)
		_trail_names.erase(id)
		if _current_context == "trail" and _current_id == id:
			_clear_canvas()
		_rebuild_custom_trails_list()
	))
	box.add_child(header)

	var name_edit := LineEdit.new()
	name_edit.text = _trail_names[id]
	name_edit.placeholder_text = "Trail name"
	name_edit.text_submitted.connect(func(new_text: String):
		var trimmed := new_text.strip_edges()
		if not trimmed.is_empty():
			_trail_names[id] = trimmed
		_rebuild_custom_trails_list()
	)
	box.add_child(name_edit)

	return box

func _delete_button(on_delete: Callable) -> Button:
	var btn := Button.new()
	btn.text = "x"
	btn.custom_minimum_size = Vector2(28, 0)
	UIStyle.style_button(btn, UIStyle.COLOR_RANKED, 8, false)
	btn.pressed.connect(on_delete)
	return btn

## Uploads straight to the shared catalog via the same endpoint the in-game
## drawing tool already uses (SkinCatalog.add_drawn_skin) -- no server
## changes, no admin step, live for every player as soon as this returns.
## `btn` is re-enabled on both success and failure so publishing again (e.g.
## after touching the art up further) doesn't need a full list rebuild;
## is_instance_valid guards against the entry having been deleted or the
## list rebuilt (renamed) while the upload was in flight.
func _on_publish_skin_pressed(id: String, btn: Button) -> void:
	if not _custom_skins.has(id):
		return
	var skin_name: String = _skin_names[id]
	btn.disabled = true
	status_label.text = "Publishing \"%s\"..." % skin_name
	var server_id: String = await SkinCatalog.add_drawn_skin(_custom_skins[id], skin_name)
	if not is_instance_valid(btn):
		return
	btn.disabled = false
	if server_id.is_empty():
		status_label.text = "Publish failed for \"%s\" -- check your connection." % skin_name
	else:
		status_label.text = "Published \"%s\" -- live for everyone now." % skin_name

## Same idea as _on_publish_skin_pressed, for hats.
func _on_publish_hat_pressed(id: String, btn: Button) -> void:
	if not _custom_hats.has(id):
		return
	var hat_name: String = _hat_names[id]
	btn.disabled = true
	status_label.text = "Publishing \"%s\"..." % hat_name
	var server_id: String = await SkinCatalog.add_drawn_hat(_custom_hats[id]["design"], hat_name)
	if not is_instance_valid(btn):
		return
	btn.disabled = false
	if server_id.is_empty():
		status_label.text = "Publish failed for \"%s\" -- check your connection." % hat_name
	else:
		status_label.text = "Published \"%s\" -- live for everyone now." % hat_name

## Same idea as _on_publish_hat_pressed, for trails.
func _on_publish_trail_pressed(id: String, btn: Button) -> void:
	if not _custom_trails.has(id):
		return
	var trail_name: String = _trail_names[id]
	btn.disabled = true
	status_label.text = "Publishing \"%s\"..." % trail_name
	var server_id: String = await SkinCatalog.add_drawn_trail(_custom_trails[id]["design"], trail_name)
	if not is_instance_valid(btn):
		return
	btn.disabled = false
	if server_id.is_empty():
		status_label.text = "Publish failed for \"%s\" -- check your connection." % trail_name
	else:
		status_label.text = "Published \"%s\" -- live for everyone now." % trail_name

## `images` is whichever part-dict is being edited; `context` is "skin",
## "hat", or "trail" (drives the big preview's tinting-free rendering); `id`
## is the stable internal id used for selection-highlighting and delete/
## rebuild.
func _show_part(images: Dictionary, key: String, context: String, id: String) -> void:
	_current_images = images
	_current_key = key
	_current_context = context
	_current_id = id
	empty_state_label.visible = false
	canvas_holder.visible = true
	_clear_canvas_holder()
	var canvas = PixelCanvasScene.new(images[key], ZOOM)
	canvas_holder.add_child(canvas)
	canvas.painted.connect(_on_painted)
	canvas.color_picked.connect(_on_eyedropper_picked)
	_current_canvas = canvas
	_apply_tool_state()

func _clear_canvas() -> void:
	_current_context = ""
	_current_id = ""
	_current_key = ""
	_current_images = {}
	_clear_canvas_holder()
	canvas_holder.visible = false
	empty_state_label.visible = true

## queue_free() only *schedules* removal, it doesn't take a node out of the
## tree immediately -- switching parts faster than one deletion clears (a
## totally normal thing to do, just clicking through the sidebar) left the
## previous canvas still sitting in the CenterContainer when the next one
## was added, and multiple same-sized siblings fighting for centered
## position there collapses everyone's layout to zero size. This is why
## parts stopped rendering at all after a couple of clicks. remove_child()
## first takes it out of the tree synchronously, so there's never more than
## one canvas actually laid out here at a time; queue_free() after that
## still handles the actual memory cleanup.
func _clear_canvas_holder() -> void:
	for child in canvas_holder.get_children():
		canvas_holder.remove_child(child)
		child.queue_free()
	_current_canvas = null

## Builds the full tool suite into `container` (the Paint page's `toolbar`
## or the Tiles page's `tiles_toolbar`) -- one call site, shared by both
## pages, so every tool (shapes, selection, mirror, transforms, palette
## actions, zoom) works identically everywhere instead of being
## reimplemented per page. Wrapped in an HFlowContainer so the now much
## larger button set wraps to as many rows as the panel needs instead of
## overflowing a single fixed-height HBoxContainer.
func _build_shared_toolbar(container: Container) -> void:
	# A bordered card instead of a bare row of buttons floating on the page
	# background -- same panel treatment every other content well in the
	# tool already uses (sidebar, right-hand color panel, ...), so the
	# toolbar reads as one cohesive control surface instead of a loose
	# strip. `flow`'s own generous separation keeps the now-visually-heavier
	# button groups from feeling cramped against each other.
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", UIStyle.panel_box(UIStyle.COLOR_NEUTRAL, 0.09, 0.28, 12))
	# Without this, PanelContainer only ever claims its child's minimum size
	# inside `container` (an HBoxContainer) instead of the available width --
	# HFlowContainer then has almost no width to actually flow within, and
	# wraps to one button per row instead of the intended compact multi-
	# column layout. Caught by an automated screenshot test, not visually --
	# this would have shipped broken.
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	container.add_child(panel)
	var flow := HFlowContainer.new()
	flow.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	flow.add_theme_constant_override("h_separation", 10)
	flow.add_theme_constant_override("v_separation", 8)
	panel.add_child(flow)

	# Three dropdowns replace what used to be ~22 flat buttons here -- the
	# rest (brush size, mirror/grid, opacity, zoom, undo/redo) stay inline
	# below since those are adjusted constantly mid-stroke and would just add
	# friction behind a click. "Tools" and "Selection" both persist into
	# _current_tool (the same shared state _tool_button always drove), so
	# whichever one you picked from has its own label updated to show the
	# active tool and the other's resets to its default title -- exactly one
	# visible indicator of what's active, regardless of which menu it's in.
	var tools_items := [
		["Brush", PixelCanvas.Tool.BRUSH],
		["Eraser", PixelCanvas.Tool.ERASER],
		["Fill", PixelCanvas.Tool.FILL],
		["Eyedrop", PixelCanvas.Tool.EYEDROPPER],
		["Line", PixelCanvas.Tool.LINE],
		["Rect", PixelCanvas.Tool.RECT],
		["Rect Fill", PixelCanvas.Tool.RECT_FILL],
		["Ellipse", PixelCanvas.Tool.ELLIPSE],
		["Ellipse Fill", PixelCanvas.Tool.ELLIPSE_FILL],
	]
	var selection_tool_items := [
		["Select", PixelCanvas.Tool.SELECT],
		["Move", PixelCanvas.Tool.MOVE],
		["Stamp", PixelCanvas.Tool.STAMP],
	]
	var tools_menu := _build_tool_menu_button("Tools", tools_items)
	var selection_menu := _build_tool_menu_button("Selection", selection_tool_items)
	flow.add_child(tools_menu)
	flow.add_child(selection_menu)

	var sync_labels := func():
		_sync_tool_menu_label(tools_menu, "Tools", tools_items)
		_sync_tool_menu_label(selection_menu, "Selection", selection_tool_items)
	tools_menu.get_popup().id_pressed.connect(func(id: int):
		_current_tool = id
		_apply_tool_state()
		sync_labels.call()
	)

	# Selection's popup mixes two different kinds of item: the 3 tool ids
	# above (persist into _current_tool, same as Tools' menu) and 4 one-shot
	# actions on whatever's currently selected (Copy/Cut/Paste/Deselect --
	# same semantics _action_button already had, no persistent state).
	# Action ids are offset by 100 so they can never collide with a real
	# PixelCanvas.Tool value.
	var selection_actions := [
		["Copy", func(): if _current_canvas: _current_canvas.copy_selection()],
		["Cut", func(): if _current_canvas: _current_canvas.cut_selection()],
		["Paste", func(): if _current_canvas: _current_canvas.paste()],
		["Deselect", func(): if _current_canvas: _current_canvas.clear_selection()],
	]
	var selection_popup := selection_menu.get_popup()
	selection_popup.add_separator()
	for i in selection_actions.size():
		selection_popup.add_item(selection_actions[i][0], 100 + i)
	selection_popup.id_pressed.connect(func(id: int):
		if id >= 100:
			selection_actions[id - 100][1].call()
			return
		_current_tool = id
		_apply_tool_state()
		sync_labels.call()
	)
	sync_labels.call()

	var transform_menu := MenuButton.new()
	transform_menu.text = "Transform ▾"
	# Its own accent (not neutral like Zoom/Undo) -- half of what's in this
	# menu (Clear, Invert) is a whole-canvas destructive action, the same
	# tone Erase already uses on the Level page, so it reads as "be careful
	# in here" at a glance rather than blending into the view-only controls.
	UIStyle.style_button(transform_menu, UIStyle.COLOR_RANKED, 8)
	var transform_actions := [
		["Flip H", func(): if _current_canvas: _current_canvas.flip_horizontal()],
		["Flip V", func(): if _current_canvas: _current_canvas.flip_vertical()],
		["Rot CW", func(): if _current_canvas: _current_canvas.rotate_90_cw()],
		["Rot CCW", func(): if _current_canvas: _current_canvas.rotate_90_ccw()],
		["Clear", func(): if _current_canvas: _current_canvas.clear_canvas()],
		["Invert", func(): if _current_canvas: _current_canvas.invert_colors()],
	]
	var transform_popup := transform_menu.get_popup()
	for i in transform_actions.size():
		transform_popup.add_item(transform_actions[i][0], i)
	transform_popup.id_pressed.connect(func(id: int): transform_actions[id][1].call())
	flow.add_child(transform_menu)

	flow.add_child(_toolbar_separator())
	# toggle_mode + a shared group so the active brush size is actually
	# visible at a glance -- these used to be plain momentary buttons with
	# no lasting pressed state at all, the only control row here that
	# didn't show what was currently selected (Mirror H/V, Grid, and every
	# dropdown already did).
	var size_group := ButtonGroup.new()
	for size_px in [1, 2, 3, 4, 6, 10]:
		var size_btn := Button.new()
		size_btn.text = "%dpx" % size_px
		size_btn.custom_minimum_size = Vector2(40, 0)
		size_btn.toggle_mode = true
		size_btn.button_group = size_group
		size_btn.button_pressed = (size_px == _brush_size)
		UIStyle.style_button(size_btn, UIStyle.COLOR_LOCAL, 8)
		size_btn.pressed.connect(func():
			_brush_size = size_px
			_apply_tool_state()
		)
		flow.add_child(size_btn)

	flow.add_child(_toolbar_separator())
	# COLOR_ONLINE (green) here purely as a third distinct accent, separating
	# these view/canvas toggles at a glance from the destructive-leaning
	# Transform group (COLOR_RANKED) and the brush-size group (COLOR_LOCAL).
	flow.add_child(_toggle_button("Mirror H", func(v: bool): _mirror_h = v, UIStyle.COLOR_ONLINE))
	flow.add_child(_toggle_button("Mirror V", func(v: bool): _mirror_v = v, UIStyle.COLOR_ONLINE))
	flow.add_child(_toggle_button("Grid", func(v: bool): _show_grid = v, UIStyle.COLOR_ONLINE))

	flow.add_child(_toolbar_separator())
	var alpha_label := Label.new()
	alpha_label.text = "Opacity"
	alpha_label.add_theme_color_override("font_color", Color(0.7, 0.72, 0.78))
	flow.add_child(alpha_label)
	var alpha_slider := HSlider.new()
	alpha_slider.min_value = 0.1
	alpha_slider.max_value = 1.0
	alpha_slider.step = 0.05
	alpha_slider.value = 1.0
	alpha_slider.custom_minimum_size = Vector2(90, 0)
	UIStyle.style_slider(alpha_slider, UIStyle.COLOR_LOCAL)
	alpha_slider.value_changed.connect(func(v: float):
		_brush_alpha = v
		_apply_tool_state()
	)
	flow.add_child(alpha_slider)

	flow.add_child(_toolbar_separator())
	flow.add_child(_action_button("Zoom -", func(): if _current_canvas: _current_canvas.set_zoom(_current_canvas.zoom - 2)))
	flow.add_child(_action_button("Zoom +", func(): if _current_canvas: _current_canvas.set_zoom(_current_canvas.zoom + 2)))

	flow.add_child(_toolbar_separator())
	flow.add_child(_action_button("↶ Undo", func(): if _current_canvas: _current_canvas.undo()))
	flow.add_child(_action_button("↷ Redo", func(): if _current_canvas: _current_canvas.redo()))

## Godot's default VSeparator theme box is a 1px near-invisible line -- this
## overrides it with a visible StyleBoxLine so the toolbar's groupings
## (dropdowns / brush sizes / toggles / opacity / zoom / undo-redo) actually
## read as separated clusters instead of one long unbroken row.
func _toolbar_separator() -> VSeparator:
	var sep := VSeparator.new()
	var box := StyleBoxLine.new()
	box.color = Color(1, 1, 1, 0.18)
	box.thickness = 2
	box.vertical = true
	sep.add_theme_stylebox_override("separator", box)
	return sep

## A dropdown grouping several PixelCanvas.Tool ids under one button --
## `items` is `[[label, tool_id], ...]`. Only builds the button + its popup
## entries; the caller wires up `id_pressed` itself (see _build_shared_
## toolbar), since Selection's popup also needs to mix in non-tool action
## ids the same button can't know about here.
func _build_tool_menu_button(label: String, items: Array) -> MenuButton:
	var btn := MenuButton.new()
	btn.text = "%s ▾" % label
	UIStyle.style_button(btn, UIStyle.COLOR_LOCAL, 8)
	var popup := btn.get_popup()
	for item in items:
		popup.add_item(item[0], item[1])
	return btn

## Sets `btn`'s displayed text to show whichever of `items` matches
## _current_tool, or resets it to the plain default label if none do (the
## active tool is in a different dropdown).
func _sync_tool_menu_label(btn: MenuButton, default_label: String, items: Array) -> void:
	for item in items:
		if item[1] == _current_tool:
			btn.text = "%s: %s ▾" % [default_label, item[0]]
			return
	btn.text = "%s ▾" % default_label

## A momentary toggle button (Mirror H/V, Grid) -- `on_toggle` receives the
## new pressed state; `_apply_tool_state()` is called right after so the
## change is reflected on `_current_canvas` immediately, not just on the
## next paint stroke.
func _toggle_button(label: String, on_toggle: Callable, color: Color = UIStyle.COLOR_NEUTRAL) -> Button:
	var btn := Button.new()
	btn.text = label
	btn.toggle_mode = true
	UIStyle.style_button(btn, color, 8)
	btn.toggled.connect(func(pressed: bool):
		on_toggle.call(pressed)
		_apply_tool_state()
	)
	return btn

## A plain one-shot action button (brush size, Zoom, Undo/Redo -- the
## controls that stayed inline instead of moving into a dropdown) --
## `on_press` takes no arguments, matching Button.pressed's signature.
func _action_button(label: String, on_press: Callable) -> Button:
	var btn := Button.new()
	btn.text = label
	btn.custom_minimum_size = Vector2(64, 0)
	UIStyle.style_button(btn, UIStyle.COLOR_NEUTRAL, 8)
	btn.pressed.connect(on_press)
	return btn

func _apply_tool_state() -> void:
	if _current_canvas:
		_current_canvas.tool = _current_tool
		_current_canvas.erasing = false
		_current_canvas.brush_size = _brush_size
		_current_canvas.brush_alpha = _brush_alpha
		_current_canvas.mirror_h = _mirror_h
		_current_canvas.mirror_v = _mirror_v
		_current_canvas.show_grid = _show_grid
		if _active_color_picker:
			_current_canvas.paint_color = _active_color_picker.color

## Builds the Level page's levels sidebar, tile palette + tool row, the
## TileCanvas itself, and the selected-object properties panel -- same
## click/drag-paint interaction PixelCanvas uses for pixel art, just
## operating on tile cells (see tile_canvas.gd).
func _build_level_page() -> void:
	var levels_panel := PanelContainer.new()
	levels_panel.custom_minimum_size = Vector2(180, 0)
	levels_panel.add_theme_stylebox_override("panel", UIStyle.panel_box())
	level_page.add_child(levels_panel)
	level_page.move_child(levels_panel, 0)
	var levels_box := VBoxContainer.new()
	levels_box.add_theme_constant_override("separation", 6)
	levels_panel.add_child(levels_box)
	levels_box.add_child(_section_label("LEVELS"))
	_custom_levels_list = VBoxContainer.new()
	_custom_levels_list.add_theme_constant_override("separation", 4)
	levels_box.add_child(_custom_levels_list)
	var add_level_btn := Button.new()
	add_level_btn.text = "+ New Level"
	UIStyle.style_button(add_level_btn, UIStyle.COLOR_SANDBOX, 8, false)
	add_level_btn.pressed.connect(_on_add_level_pressed)
	levels_box.add_child(add_level_btn)

	_tile_canvas = TileCanvasScene.new()
	level_canvas_center.add_child(_tile_canvas)
	_tile_canvas.selection_changed.connect(_refresh_level_properties_panel)

	# Type swatches pick which base tile (Boundary/Pillar/Platform) PAINT
	# places; the variant row alongside them picks which of that type's 3
	## art pieces (Piece/Corner/Internal) gets placed -- both feed into
	# _apply_level_tile_type(), which is also where PAINT mode + the actual
	# tile_index() get set, so pressing either kind of button places tiles
	# immediately rather than needing a separate "apply" step.
	var level_tool_group := ButtonGroup.new()
	for t in TILE_TYPE_NAMES.size():
		var swatch := Button.new()
		swatch.text = TILE_TYPE_NAMES[t]
		swatch.toggle_mode = true
		swatch.button_group = level_tool_group
		swatch.button_pressed = (t == 0)
		UIStyle.style_button(swatch, TileCanvas.TILE_COLORS[tile_index(t, 2)], 8)
		swatch.pressed.connect(func():
			_level_selected_type = t
			_apply_level_tile_type()
		)
		level_toolbar.add_child(swatch)

	level_toolbar.add_child(VSeparator.new())

	# Separate ButtonGroup from level_tool_group above -- variant is an
	# independent axis from "which top-level tool mode is active"
	# (paint-a-type/erase/spawn), so it must stay togglable on its own.
	var variant_group := ButtonGroup.new()
	for v in TILE_VARIANT_NAMES.size():
		var variant_btn := Button.new()
		variant_btn.text = TILE_VARIANT_NAMES[v]
		variant_btn.toggle_mode = true
		variant_btn.button_group = variant_group
		variant_btn.button_pressed = (v == _level_selected_variant)
		UIStyle.style_button(variant_btn, UIStyle.COLOR_NEUTRAL, 8)
		variant_btn.pressed.connect(func():
			_level_selected_variant = v
			_apply_level_tile_type()
		)
		level_toolbar.add_child(variant_btn)

	level_toolbar.add_child(VSeparator.new())

	# Ice/Bouncy (see EXTRA_TILE_NAMES) place directly via PAINT, same as the
	# type swatches above -- single flat tile each, no variant row.
	for e in EXTRA_TILE_NAMES.size():
		var extra_idx := TILE_TYPE_NAMES.size() * TILE_VARIANT_NAMES.size() + e
		var extra_btn := Button.new()
		extra_btn.text = EXTRA_TILE_NAMES[e]
		extra_btn.toggle_mode = true
		extra_btn.button_group = level_tool_group
		UIStyle.style_button(extra_btn, TileCanvas.TILE_COLORS[extra_idx], 8)
		extra_btn.pressed.connect(func():
			_tile_canvas.tool = TileCanvas.Tool.PAINT
			_tile_canvas.current_tile_type = extra_idx
		)
		level_toolbar.add_child(extra_btn)

	var erase_btn := Button.new()
	erase_btn.text = "Erase"
	erase_btn.toggle_mode = true
	erase_btn.button_group = level_tool_group
	UIStyle.style_button(erase_btn, UIStyle.COLOR_RANKED, 8)
	erase_btn.pressed.connect(func(): _tile_canvas.tool = TileCanvas.Tool.ERASE)
	level_toolbar.add_child(erase_btn)

	var spawn_btn := Button.new()
	spawn_btn.text = "Spawn Point"
	spawn_btn.toggle_mode = true
	spawn_btn.button_group = level_tool_group
	UIStyle.style_button(spawn_btn, UIStyle.COLOR_ONLINE, 8)
	spawn_btn.pressed.connect(func(): _tile_canvas.tool = TileCanvas.Tool.SPAWN)
	level_toolbar.add_child(spawn_btn)

	# Click a start cell, then an end cell, to place a synced moving
	# platform between them (see moving_platform.gd) -- two discrete clicks,
	# not a drag, so TileCanvas itself special-cases this tool to not repeat
	# on mouse motion the way PAINT/ERASE do.
	var platform_btn := Button.new()
	platform_btn.text = "Platform"
	platform_btn.toggle_mode = true
	platform_btn.button_group = level_tool_group
	UIStyle.style_button(platform_btn, UIStyle.COLOR_LOCAL, 8)
	platform_btn.pressed.connect(func(): _tile_canvas.tool = TileCanvas.Tool.PLATFORM)
	level_toolbar.add_child(platform_btn)

	var period_label := Label.new()
	period_label.text = "Period (s):"
	period_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	level_toolbar.add_child(period_label)
	var period_spin := SpinBox.new()
	period_spin.min_value = 0.5
	period_spin.max_value = 60.0
	period_spin.step = 0.5
	period_spin.value = TileCanvas.DEFAULT_PLATFORM_PERIOD_SEC
	period_spin.custom_minimum_size = Vector2(70, 0)
	period_spin.value_changed.connect(func(v: float): _tile_canvas.current_platform_period_sec = v)
	level_toolbar.add_child(period_spin)

	level_toolbar.add_child(VSeparator.new())

	# Click-and-drag manipulation of already-placed spawn points/platform
	# endpoints, plus a numeric properties panel for the current grab (see
	# _build_level_properties_panel below) -- grab a marker, drag it around
	# or type exact coordinates, Delete/the Delete button removes it. Every
	# other tool here only ever places new things; this is the one that
	# edits what's already down.
	var select_btn := Button.new()
	select_btn.text = "Select"
	select_btn.toggle_mode = true
	select_btn.button_group = level_tool_group
	UIStyle.style_button(select_btn, UIStyle.COLOR_SHOP, 8)
	select_btn.pressed.connect(func(): _tile_canvas.tool = TileCanvas.Tool.EDIT)
	level_toolbar.add_child(select_btn)

	level_toolbar.add_child(VSeparator.new())

	var clear_btn := Button.new()
	clear_btn.text = "Clear"
	UIStyle.style_button(clear_btn, UIStyle.COLOR_NEUTRAL, 8)
	clear_btn.pressed.connect(func(): _tile_canvas.clear())
	level_toolbar.add_child(clear_btn)

	UIStyle.style_button(publish_level_button, UIStyle.COLOR_SHOP)
	publish_level_button.pressed.connect(_on_publish_level_pressed)

	var level_right_box: VBoxContainer = level_name_edit.get_parent()
	# Each handler reads level_name_edit.text directly rather than trusting
	# that text_changed already ran -- text_changed covers live typing, but
	# submitting/blurring should capture whatever the field actually shows
	# right now regardless of how it got there.
	level_name_edit.text_changed.connect(func(new_text: String):
		if not _current_level_id.is_empty():
			_level_names[_current_level_id] = new_text
	)
	level_name_edit.text_submitted.connect(func(new_text: String):
		if not _current_level_id.is_empty():
			_level_names[_current_level_id] = new_text
		_rebuild_custom_levels_list()
	)
	level_name_edit.focus_exited.connect(func():
		if not _current_level_id.is_empty():
			_level_names[_current_level_id] = level_name_edit.text
		_rebuild_custom_levels_list()
	)
	_build_level_properties_panel(level_right_box)

	_apply_level_tile_type()
	_on_add_level_pressed()

## Pushes the currently-selected (type, variant) pair onto the TileCanvas
## and switches it to PAINT mode -- called by both the type swatches and the
## variant row, since either one changing should immediately affect what
## the next click paints, not just the swatch that was actually clicked.
func _apply_level_tile_type() -> void:
	_tile_canvas.tool = TileCanvas.Tool.PAINT
	_tile_canvas.current_tile_type = tile_index(_level_selected_type, _level_selected_variant)

func _on_add_level_pressed() -> void:
	var id := "level_%d" % _next_level_num
	_level_names[id] = "Level %d" % _next_level_num
	_next_level_num += 1
	_custom_levels[id] = {"cells": {}, "spawn_points": [], "platforms": []}
	_show_level(id)
	_rebuild_custom_levels_list()

func _rebuild_custom_levels_list() -> void:
	for child in _custom_levels_list.get_children():
		child.queue_free()
	for id in _custom_levels.keys():
		_custom_levels_list.add_child(_build_level_entry(id))

func _build_level_entry(id: String) -> Control:
	var box := HBoxContainer.new()
	box.add_theme_constant_override("separation", 4)
	var select_btn := Button.new()
	select_btn.text = _level_names[id]
	select_btn.toggle_mode = true
	select_btn.button_group = _level_button_group
	select_btn.button_pressed = (_current_level_id == id)
	select_btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
	select_btn.size_flags_horizontal = SIZE_EXPAND_FILL
	select_btn.clip_text = true
	UIStyle.style_button(select_btn, UIStyle.COLOR_SANDBOX, 8, false)
	select_btn.pressed.connect(_show_level.bind(id))
	box.add_child(select_btn)
	box.add_child(_delete_button(func():
		_custom_levels.erase(id)
		_level_names.erase(id)
		if _current_level_id == id:
			_current_level_id = ""
			if not _custom_levels.is_empty():
				_show_level(_custom_levels.keys()[0])
			else:
				_on_add_level_pressed()
				return # _on_add_level_pressed already rebuilds the list
		_rebuild_custom_levels_list()
	))
	return box

## Repoints the live TileCanvas at this level's own cells/spawn_points/
## platforms -- since those are plain Dictionary/Array (mutated in place,
## never reassigned wholesale by TileCanvas itself), further edits land
## directly in _custom_levels[id] with no explicit save-back step needed.
func _show_level(id: String) -> void:
	if not _custom_levels.has(id):
		return
	_current_level_id = id
	var data: Dictionary = _custom_levels[id]
	_tile_canvas.cells = data["cells"]
	_tile_canvas.spawn_points = data["spawn_points"]
	_tile_canvas.platforms = data["platforms"]
	_tile_canvas.deselect()
	_tile_canvas.queue_redraw()
	level_name_edit.text = _level_names.get(id, "")

## Builds the (initially hidden) "SELECTED OBJECT" panel that appears below
## Map Name/Publish whenever TileCanvas's EDIT tool has something grabbed --
## the properties half of the Geometry-Dash-style edit flow (drag on the
## canvas is the other half, see tile_canvas.gd's _drag_selection_to).
func _build_level_properties_panel(right_box: VBoxContainer) -> void:
	var spacer := Control.new()
	spacer.custom_minimum_size = Vector2(0, 10)
	right_box.add_child(spacer)
	_level_props_container = VBoxContainer.new()
	_level_props_container.add_theme_constant_override("separation", 6)
	_level_props_container.visible = false
	right_box.add_child(_level_props_container)
	_level_props_container.add_child(_section_label("SELECTED OBJECT"))
	_level_props_content = VBoxContainer.new()
	_level_props_content.add_theme_constant_override("separation", 6)
	_level_props_container.add_child(_level_props_content)

## Rebuilds the properties panel's fields for whatever's now selected (or
## hides it if nothing is) -- connected to TileCanvas.selection_changed,
## which only fires when *what's* grabbed changes, not on every drag-frame
## position update. That's deliberate: rebuilding these fields (destroying
## and recreating the SpinBoxes) on every drag frame would also fire while
## a field itself is being typed into (a SpinBox's own value_changed drives
## the same canvas edit that would trigger a rebuild), stealing focus mid-
## edit. The canvas itself already gives live visual feedback while
## dragging; the numeric fields catch up once the drag ends and a new
## selection event fires.
func _refresh_level_properties_panel() -> void:
	if not _level_props_container:
		return
	for child in _level_props_content.get_children():
		child.queue_free()
	if not _tile_canvas.has_selection():
		_level_props_container.visible = false
		return
	_level_props_container.visible = true
	match _tile_canvas.selected_kind():
		TileCanvas.SelectionKind.SPAWN:
			_level_props_content.add_child(_build_spawn_properties())
		TileCanvas.SelectionKind.PLATFORM_START, TileCanvas.SelectionKind.PLATFORM_END:
			_level_props_content.add_child(_build_platform_properties())

## A Label + SpinBox row -- shared by the spawn/platform properties below.
func _labeled_spinbox(label_text: String, value: float, on_changed: Callable, min_v: float = 0.0, max_v: float = 999.0, step: float = 1.0) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	var label := Label.new()
	label.text = label_text
	label.custom_minimum_size = Vector2(70, 0)
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(label)
	var spin := SpinBox.new()
	spin.min_value = min_v
	spin.max_value = max_v
	spin.step = step
	spin.value = value
	spin.custom_minimum_size = Vector2(90, 0)
	spin.value_changed.connect(on_changed)
	row.add_child(spin)
	return row

func _build_spawn_properties() -> Control:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 4)
	var label := Label.new()
	label.text = "Spawn Point"
	label.add_theme_font_size_override("font_size", 13)
	box.add_child(label)
	var cell := _tile_canvas.get_selected_spawn()
	box.add_child(_labeled_spinbox("X", cell.x, func(v: float):
		var c := _tile_canvas.get_selected_spawn()
		_tile_canvas.set_selected_spawn(Vector2i(int(v), c.y))
	, 0, _tile_canvas.grid_size.x - 1))
	box.add_child(_labeled_spinbox("Y", cell.y, func(v: float):
		var c := _tile_canvas.get_selected_spawn()
		_tile_canvas.set_selected_spawn(Vector2i(c.x, int(v)))
	, 0, _tile_canvas.grid_size.y - 1))
	box.add_child(_build_delete_selected_button())
	return box

func _build_platform_properties() -> Control:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 4)
	var p := _tile_canvas.get_selected_platform()
	var start: Vector2i = p.get("start", Vector2i.ZERO)
	var end: Vector2i = p.get("end", Vector2i.ZERO)
	var period: float = p.get("period_sec", TileCanvas.DEFAULT_PLATFORM_PERIOD_SEC)
	var which := "start" if _tile_canvas.selected_kind() == TileCanvas.SelectionKind.PLATFORM_START else "end"

	var title := Label.new()
	title.text = "Platform (%s handle grabbed)" % which
	title.add_theme_font_size_override("font_size", 13)
	box.add_child(title)

	box.add_child(_section_label("START"))
	box.add_child(_labeled_spinbox("X", start.x, func(v: float):
		var s: Vector2i = _tile_canvas.get_selected_platform().get("start", Vector2i.ZERO)
		_tile_canvas.set_selected_platform_start(Vector2i(int(v), s.y))
	, 0, _tile_canvas.grid_size.x - 1))
	box.add_child(_labeled_spinbox("Y", start.y, func(v: float):
		var s: Vector2i = _tile_canvas.get_selected_platform().get("start", Vector2i.ZERO)
		_tile_canvas.set_selected_platform_start(Vector2i(s.x, int(v)))
	, 0, _tile_canvas.grid_size.y - 1))

	box.add_child(_section_label("END"))
	box.add_child(_labeled_spinbox("X", end.x, func(v: float):
		var e: Vector2i = _tile_canvas.get_selected_platform().get("end", Vector2i.ZERO)
		_tile_canvas.set_selected_platform_end(Vector2i(int(v), e.y))
	, 0, _tile_canvas.grid_size.x - 1))
	box.add_child(_labeled_spinbox("Y", end.y, func(v: float):
		var e: Vector2i = _tile_canvas.get_selected_platform().get("end", Vector2i.ZERO)
		_tile_canvas.set_selected_platform_end(Vector2i(e.x, int(v)))
	, 0, _tile_canvas.grid_size.y - 1))

	box.add_child(_labeled_spinbox("Period (s)", period, func(v: float):
		_tile_canvas.set_selected_platform_period(v)
	, 0.5, 60.0, 0.5))

	box.add_child(_build_delete_selected_button())
	return box

func _build_delete_selected_button() -> Button:
	var del_btn := Button.new()
	del_btn.text = "Delete"
	UIStyle.style_button(del_btn, UIStyle.COLOR_RANKED, 8)
	del_btn.pressed.connect(func(): _tile_canvas.delete_selected())
	return del_btn

## Live-publish, same trust model as the skin/hat Publish buttons -- goes
## straight to the shared level catalog with no review step, immediately
## selectable by any host (see host_setup.gd's map dropdown).
func _on_publish_level_pressed() -> void:
	var data := _tile_canvas.to_level_data()
	if not LevelData.is_valid(data):
		status_label.text = "Add some tiles and at least 2 spawn points before publishing."
		return

	var level_name := level_name_edit.text.strip_edges()
	if level_name.is_empty():
		level_name = "Untitled Map"

	publish_level_button.disabled = true
	status_label.text = "Publishing \"%s\"..." % level_name
	var req := HTTPRequest.new()
	add_child(req)
	var body := JSON.stringify({"name": level_name, "tiles": data.tiles, "spawn_points": data.spawn_points, "platforms": data.platforms})
	var err := req.request(
		"%s/%s/upload" % [LEVEL_API_BASE, SkinCatalog.client_id], ["Content-Type: application/json"], HTTPClient.METHOD_POST, body
	)
	if err != OK:
		req.queue_free()
		status_label.text = "Publish failed -- couldn't start the request."
		publish_level_button.disabled = false
		return
	var response: Array = await req.request_completed
	req.queue_free()
	publish_level_button.disabled = false
	if response[1] == 200:
		status_label.text = "Published \"%s\" -- live for everyone now." % level_name
	else:
		status_label.text = "Publish failed for \"%s\" -- check your connection." % level_name

## Builds the Tiles page entirely in code (no .tscn changes -- see the file
## header): a left-hand list of the 3 built-in tile types, each grouped into
## its 3 art variants (Piece/Corner/Internal -- 9 textures total), a canvas
## panel driven by the exact same _build_shared_toolbar/_current_canvas
## machinery the Paint page uses, and its own ColorPicker (the Paint page's
## is hidden while this page is showing, so it needs an independent one to
## stay usable -- see _active_color_picker).
func _build_tiles_page() -> void:
	var vbox: VBoxContainer = paint_page.get_parent()
	tiles_page = HBoxContainer.new()
	tiles_page.size_flags_vertical = Control.SIZE_EXPAND_FILL
	tiles_page.add_theme_constant_override("separation", 12)
	tiles_page.visible = false
	vbox.add_child(tiles_page)
	vbox.move_child(tiles_page, level_page.get_index() + 1)

	var select_panel := PanelContainer.new()
	select_panel.custom_minimum_size = Vector2(180, 0)
	select_panel.add_theme_stylebox_override("panel", UIStyle.panel_box())
	tiles_page.add_child(select_panel)
	var select_box := VBoxContainer.new()
	select_box.add_theme_constant_override("separation", 6)
	select_panel.add_child(select_box)
	select_box.add_child(_section_label("TILE TYPES"))

	# Grouped by base type (Boundary/Pillar/Platform), each with its own row
	# of 3 variant buttons (Piece/Corner/Internal) -- 9 total selectable
	# textures, one ButtonGroup shared across all of them so exactly one is
	# ever the active canvas.
	var tile_group := ButtonGroup.new()
	var grid_total := TILE_TYPE_NAMES.size() * TILE_VARIANT_NAMES.size()
	_tile_select_buttons.resize(grid_total + EXTRA_TILE_NAMES.size())
	for t in TILE_TYPE_NAMES.size():
		var type_label := _section_label(TILE_TYPE_NAMES[t].to_upper())
		type_label.add_theme_font_size_override("font_size", 11)
		select_box.add_child(type_label)
		var variant_row := HBoxContainer.new()
		variant_row.add_theme_constant_override("separation", 4)
		select_box.add_child(variant_row)
		for v in TILE_VARIANT_NAMES.size():
			var idx := tile_index(t, v)
			var btn := Button.new()
			btn.text = TILE_VARIANT_NAMES[v]
			btn.toggle_mode = true
			btn.button_group = tile_group
			btn.custom_minimum_size = Vector2(0, 36)
			btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			UIStyle.style_button(btn, TileCanvas.TILE_COLORS[idx], 8, false)
			btn.pressed.connect(_show_tile.bind(idx))
			variant_row.add_child(btn)
			_tile_select_buttons[idx] = btn

	select_box.add_child(_section_label("SPECIAL"))
	var extra_row := HBoxContainer.new()
	extra_row.add_theme_constant_override("separation", 4)
	select_box.add_child(extra_row)
	for e in EXTRA_TILE_NAMES.size():
		var idx := grid_total + e
		var btn := Button.new()
		btn.text = EXTRA_TILE_NAMES[e]
		btn.toggle_mode = true
		btn.button_group = tile_group
		btn.custom_minimum_size = Vector2(0, 36)
		btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		UIStyle.style_button(btn, TileCanvas.TILE_COLORS[idx], 8, false)
		btn.pressed.connect(_show_tile.bind(idx))
		extra_row.add_child(btn)
		_tile_select_buttons[idx] = btn

	var canvas_panel := PanelContainer.new()
	canvas_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	canvas_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	canvas_panel.add_theme_stylebox_override("panel", UIStyle.panel_box())
	tiles_page.add_child(canvas_panel)
	var canvas_box := VBoxContainer.new()
	canvas_panel.add_child(canvas_box)

	tiles_toolbar = HBoxContainer.new()
	canvas_box.add_child(tiles_toolbar)
	_build_shared_toolbar(tiles_toolbar)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	canvas_box.add_child(scroll)
	tiles_canvas_holder = CenterContainer.new()
	tiles_canvas_holder.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tiles_canvas_holder.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.add_child(tiles_canvas_holder)

	var right_panel := PanelContainer.new()
	right_panel.custom_minimum_size = Vector2(220, 0)
	right_panel.add_theme_stylebox_override("panel", UIStyle.panel_box())
	tiles_page.add_child(right_panel)
	var right_box := VBoxContainer.new()
	right_box.add_theme_constant_override("separation", 8)
	right_panel.add_child(right_box)
	right_box.add_child(_section_label("COLOR"))
	tiles_color_picker = ColorPicker.new()
	right_box.add_child(tiles_color_picker)
	tiles_color_picker.color_changed.connect(func(color: Color):
		if _current_canvas:
			_current_canvas.paint_color = color
	)
	var tiles_help := Label.new()
	tiles_help.text = "Paint each tile at its native 10x10 size -- zoomed in for editing, this is exactly how it tiles across every platform in-game."
	tiles_help.autowrap_mode = TextServer.AUTOWRAP_WORD
	tiles_help.add_theme_font_size_override("font_size", 12)
	tiles_help.add_theme_color_override("font_color", Color(0.7, 0.72, 0.78))
	right_box.add_child(tiles_help)

	_load_tile_images()
	_show_tile(0)
	_tile_select_buttons[0].button_pressed = true

## Loads the atlas already baked into the build (flat, slightly-shaded
## placeholder colors today -- see build_tileset.gd) and slices it into one
## Image per (type, variant) texture plus the two EXTRA_TILE_NAMES slots, so
## the Tiles page always opens with something real on the canvas instead of
## a blank transparent square.
## Falls back to a flat-color square per slot if the atlas can't be loaded
## or is still the old narrower size for any reason (e.g. running this tool
## against a stripped-down or stale export), so the page is never left
## totally broken.
func _load_tile_images() -> void:
	_tile_images.clear()
	# load() (not Image.load_from_file) so this also works from the exported
	# .pck TagArtTool.exe actually ships as, not just when run from source.
	var atlas: Image = null
	var atlas_tex: Texture2D = load(TILE_ATLAS_PATH)
	if atlas_tex:
		atlas = atlas_tex.get_image()
	var total := TILE_TYPE_NAMES.size() * TILE_VARIANT_NAMES.size() + EXTRA_TILE_NAMES.size()
	for i in total:
		var tile_img: Image
		if atlas and not atlas.is_empty() and (i + 1) * TILE_TEXTURE_SIZE <= atlas.get_width():
			tile_img = atlas.get_region(Rect2i(i * TILE_TEXTURE_SIZE, 0, TILE_TEXTURE_SIZE, TILE_TEXTURE_SIZE))
			tile_img.convert(Image.FORMAT_RGBA8)
		else:
			tile_img = Image.create(TILE_TEXTURE_SIZE, TILE_TEXTURE_SIZE, false, Image.FORMAT_RGBA8)
			tile_img.fill(TileCanvas.TILE_COLORS[i])
		_tile_images.append(tile_img)

func _show_tile(index: int) -> void:
	_current_tile_index = index
	for i in _tile_select_buttons.size():
		_tile_select_buttons[i].button_pressed = (i == index)
	for child in tiles_canvas_holder.get_children():
		tiles_canvas_holder.remove_child(child)
		child.queue_free()
	var canvas = PixelCanvasScene.new(_tile_images[index], TILE_TEXTURE_ZOOM)
	tiles_canvas_holder.add_child(canvas)
	canvas.painted.connect(_on_painted)
	canvas.color_picked.connect(_on_eyedropper_picked)
	_current_canvas = canvas
	_apply_tool_state()

## Builds the Icons page entirely in code, mirroring _build_tiles_page()
## exactly: a left-hand list of the 6 procedural mode-bar icon types, a
## canvas panel driven by the same _build_shared_toolbar/_current_canvas
## machinery, and its own ColorPicker. Unlike Tiles/skins, icons are baked
## and painted in white/grayscale (see the file header comment) since
## they're re-tinted per usage at runtime -- the right-panel help text below
## says so directly, since painting a specific hue here would silently look
## wrong in-game rather than erroring anywhere obvious.
func _build_icons_page() -> void:
	var vbox: VBoxContainer = paint_page.get_parent()
	icons_page = HBoxContainer.new()
	icons_page.size_flags_vertical = Control.SIZE_EXPAND_FILL
	icons_page.add_theme_constant_override("separation", 12)
	icons_page.visible = false
	vbox.add_child(icons_page)
	vbox.move_child(icons_page, tiles_page.get_index() + 1)

	var select_panel := PanelContainer.new()
	select_panel.custom_minimum_size = Vector2(180, 0)
	select_panel.add_theme_stylebox_override("panel", UIStyle.panel_box())
	icons_page.add_child(select_panel)
	var select_box := VBoxContainer.new()
	select_box.add_theme_constant_override("separation", 6)
	select_panel.add_child(select_box)
	select_box.add_child(_section_label("MENU ICONS"))

	var icon_group := ButtonGroup.new()
	_icon_select_buttons.clear()
	for i in ICON_TYPE_NAMES.size():
		var btn := Button.new()
		btn.text = ICON_TYPE_NAMES[i]
		btn.toggle_mode = true
		btn.button_group = icon_group
		btn.custom_minimum_size = Vector2(0, 40)
		UIStyle.style_button(btn, UIStyle.COLOR_LOCAL, 10, false)
		btn.pressed.connect(_show_icon.bind(i))
		select_box.add_child(btn)
		_icon_select_buttons.append(btn)

	var button_art_spacer := Control.new()
	button_art_spacer.custom_minimum_size = Vector2(0, 8)
	select_box.add_child(button_art_spacer)

	# Same ButtonGroup as the icon buttons above -- one shared canvas, so
	# picking a mode button here correctly deselects whichever icon was
	# active (and vice versa).
	select_box.add_child(_section_label("MODE BUTTON ART"))
	_button_art_select_buttons.clear()
	for i in MODE_BUTTON_NAMES.size():
		var btn := Button.new()
		btn.text = MODE_BUTTON_NAMES[i]
		btn.toggle_mode = true
		btn.button_group = icon_group
		btn.custom_minimum_size = Vector2(0, 40)
		UIStyle.style_button(btn, UIStyle.COLOR_SANDBOX, 10, false)
		btn.pressed.connect(_show_button_art.bind(i))
		select_box.add_child(btn)
		_button_art_select_buttons.append(btn)

	var canvas_panel := PanelContainer.new()
	canvas_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	canvas_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	canvas_panel.add_theme_stylebox_override("panel", UIStyle.panel_box())
	icons_page.add_child(canvas_panel)
	var canvas_box := VBoxContainer.new()
	canvas_panel.add_child(canvas_box)

	icons_toolbar = HBoxContainer.new()
	canvas_box.add_child(icons_toolbar)
	_build_shared_toolbar(icons_toolbar)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	canvas_box.add_child(scroll)
	icons_canvas_holder = CenterContainer.new()
	icons_canvas_holder.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	icons_canvas_holder.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.add_child(icons_canvas_holder)

	var right_panel := PanelContainer.new()
	right_panel.custom_minimum_size = Vector2(220, 0)
	right_panel.add_theme_stylebox_override("panel", UIStyle.panel_box())
	icons_page.add_child(right_panel)
	var right_box := VBoxContainer.new()
	right_box.add_theme_constant_override("separation", 8)
	right_panel.add_child(right_box)
	right_box.add_child(_section_label("COLOR"))
	icons_color_picker = ColorPicker.new()
	right_box.add_child(icons_color_picker)
	icons_color_picker.color_changed.connect(func(color: Color):
		if _current_canvas:
			_current_canvas.paint_color = color
	)
	var icons_help := Label.new()
	icons_help.text = "Icons are re-tinted per usage in-game -- each mode bar applies its own accent color on top of whatever's painted here. Stick to white/grayscale (like the built-in defaults) so that re-tinting still reads correctly; a specific hue here will look wrong once multiplied by a bar's own color."
	icons_help.autowrap_mode = TextServer.AUTOWRAP_WORD
	icons_help.add_theme_font_size_override("font_size", 12)
	icons_help.add_theme_color_override("font_color", Color(0.7, 0.72, 0.78))
	right_box.add_child(icons_help)

	var import_spacer := Control.new()
	import_spacer.custom_minimum_size = Vector2(0, 4)
	right_box.add_child(import_spacer)
	var import_btn := Button.new()
	import_btn.text = "Import Image..."
	UIStyle.style_button(import_btn, UIStyle.COLOR_NEUTRAL, 8)
	import_btn.pressed.connect(_on_import_image_pressed)
	right_box.add_child(import_btn)
	var import_help := Label.new()
	import_help.text = "Loads a PNG from disk into the clipboard -- use Selection > Stamp to place it anywhere on the current canvas, then Select + Move to drag it into position. Works on any page's canvas, including whole mode-button art below."
	import_help.autowrap_mode = TextServer.AUTOWRAP_WORD
	import_help.add_theme_font_size_override("font_size", 12)
	import_help.add_theme_color_override("font_color", Color(0.7, 0.72, 0.78))
	right_box.add_child(import_help)

	_load_icon_images()
	_load_button_art_images()
	_show_icon(0)
	_icon_select_buttons[0].button_pressed = true

## Loads the atlas already baked into the build (tools/build_icon_atlas.gd)
## and slices it into one Image per icon type, so the Icons page always
## opens with the real built-in icon shapes instead of a blank transparent
## square. Falls back to a blank (fully transparent) square per slot if the
## atlas can't be loaded -- unlike tiles, there's no meaningful flat-color
## placeholder for an icon shape, so blank is the honest fallback here.
func _load_icon_images() -> void:
	_icon_images.clear()
	var atlas: Image = null
	var atlas_tex: Texture2D = load(ICON_ATLAS_PATH)
	if atlas_tex:
		atlas = atlas_tex.get_image()
	for i in ICON_TYPE_NAMES.size():
		var icon_img: Image
		if atlas and not atlas.is_empty() and (i + 1) * ICON_TEXTURE_SIZE <= atlas.get_width():
			icon_img = atlas.get_region(Rect2i(i * ICON_TEXTURE_SIZE, 0, ICON_TEXTURE_SIZE, ICON_TEXTURE_SIZE))
			icon_img.convert(Image.FORMAT_RGBA8)
		else:
			icon_img = Image.create(ICON_TEXTURE_SIZE, ICON_TEXTURE_SIZE, false, Image.FORMAT_RGBA8)
			icon_img.fill(Color(0, 0, 0, 0))
		_icon_images.append(icon_img)

func _show_icon(index: int) -> void:
	_current_icon_index = index
	_current_button_art_index = -1
	for i in _icon_select_buttons.size():
		_icon_select_buttons[i].button_pressed = (i == index)
	for i in _button_art_select_buttons.size():
		_button_art_select_buttons[i].button_pressed = false
	for child in icons_canvas_holder.get_children():
		icons_canvas_holder.remove_child(child)
		child.queue_free()
	var canvas = PixelCanvasScene.new(_icon_images[index], ICON_TEXTURE_ZOOM)
	icons_canvas_holder.add_child(canvas)
	canvas.painted.connect(_on_painted)
	# Defensive: several tools (shape drag, undo/redo) reassign the canvas's
	# own `image` to a new Image object rather than mutating the original in
	# place, which would silently desync _icon_images[index] from what's
	# actually on screen the next time this icon is re-selected. Keeping the
	# backing array's reference live on every paint avoids that.
	canvas.painted.connect(func(): _icon_images[index] = canvas.image)
	canvas.color_picked.connect(_on_eyedropper_picked)
	_current_canvas = canvas
	_apply_tool_state()

## Loads each mode's whole-button art (see MODE_BUTTON_KEYS/main_menu.gd's
## MODE_BUTTON_ART_PATH) if it's already been painted and committed, else a
## blank transparent MODE_BUTTON_SIZE canvas -- same "always something real
## or an honest blank canvas" rule _load_icon_images() follows.
func _load_button_art_images() -> void:
	_button_art_images.clear()
	for key in MODE_BUTTON_KEYS:
		var path := "%s/%s.png" % [MODE_BUTTON_ART_DIR, key]
		var img: Image
		if ResourceLoader.exists(path):
			var tex: Texture2D = load(path)
			img = tex.get_image() if tex else null
			if img:
				img.convert(Image.FORMAT_RGBA8)
		if not img:
			img = Image.create(MODE_BUTTON_SIZE.x, MODE_BUTTON_SIZE.y, false, Image.FORMAT_RGBA8)
			img.fill(Color(0, 0, 0, 0))
		_button_art_images.append(img)

func _show_button_art(index: int) -> void:
	_current_button_art_index = index
	_current_icon_index = -1
	for i in _icon_select_buttons.size():
		_icon_select_buttons[i].button_pressed = false
	for i in _button_art_select_buttons.size():
		_button_art_select_buttons[i].button_pressed = (i == index)
	for child in icons_canvas_holder.get_children():
		icons_canvas_holder.remove_child(child)
		child.queue_free()
	var canvas = PixelCanvasScene.new(_button_art_images[index], MODE_BUTTON_ZOOM)
	icons_canvas_holder.add_child(canvas)
	canvas.painted.connect(_on_painted)
	canvas.painted.connect(func(): _button_art_images[index] = canvas.image)
	canvas.color_picked.connect(_on_eyedropper_picked)
	_current_canvas = canvas
	_apply_tool_state()

## Opens a native file picker for a PNG and loads it straight into the
## active canvas's clipboard -- from there Selection > Stamp places it (see
## PixelCanvas.Tool.STAMP), and Select + Move drags it into its final
## position, reusing tools this page already has rather than building a
## separate drag-and-drop layer system. No resizing: an imported image is
## used at its real pixel size, so a whole-button-sized import can be
## stamped as-is onto the (also whole-button-sized) mode button canvas.
func _on_import_image_pressed() -> void:
	if not _current_canvas:
		return
	if not _import_file_dialog:
		_import_file_dialog = FileDialog.new()
		_import_file_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
		_import_file_dialog.access = FileDialog.ACCESS_FILESYSTEM
		_import_file_dialog.add_filter("*.png", "PNG Image")
		_import_file_dialog.size = Vector2i(700, 500)
		_import_file_dialog.file_selected.connect(_on_import_file_selected)
		add_child(_import_file_dialog)
	_import_file_dialog.popup_centered()

func _on_import_file_selected(path: String) -> void:
	var img := Image.new()
	if img.load(path) != OK:
		status_label.text = "Couldn't load \"%s\" as a PNG." % path.get_file()
		return
	img.convert(Image.FORMAT_RGBA8)
	_current_canvas.clipboard = img
	status_label.text = "Imported \"%s\" -- use Selection > Stamp to place it, or Paste." % path.get_file()

func _on_color_picked_from_wheel(color: Color) -> void:
	if _current_canvas:
		_current_canvas.paint_color = color

func _on_eyedropper_picked(color: Color) -> void:
	if _active_color_picker:
		_active_color_picker.color = color

func _on_painted() -> void:
	if preview_page.visible:
		_refresh_big_preview()

func _build_big_preview() -> void:
	_big_preview = CharacterPreviewScene.new()
	_big_preview.skin_id = "red"
	_big_preview.hat_id = ""
	_big_preview.zoom = 5.0
	# 4x render resolution -- at the default VIEWPORT_SIZE (56x72), stretching
	# up to this preview's 260x340 display size is a ~4.6x non-integer
	# scale, which reads as visibly uneven/jagged even with nearest
	# filtering. Rendering more real pixels up front (see
	# CharacterPreview.render_scale) brings that final stretch down to a
	# mild ~1.16x, close enough to invisible.
	_big_preview.render_scale = 4.0
	_big_preview.custom_minimum_size = Vector2(260, 340)
	big_preview_center.add_child(_big_preview)

func _refresh_preview_selectors() -> void:
	skin_select.clear()
	skin_select.add_item("None")
	var skin_ids := _custom_skins.keys()
	for id in skin_ids:
		skin_select.add_item(_skin_names[id])
	var sel_idx := 0
	if not _preview_skin_id.is_empty() and _custom_skins.has(_preview_skin_id):
		sel_idx = skin_ids.find(_preview_skin_id) + 1
	else:
		_preview_skin_id = ""
	skin_select.selected = sel_idx
	if not skin_select.item_selected.is_connected(_on_skin_select_changed):
		skin_select.item_selected.connect(_on_skin_select_changed)

	hat_select.clear()
	hat_select.add_item("None")
	var hat_ids := _custom_hats.keys()
	for id in hat_ids:
		hat_select.add_item(_hat_names[id])
	var hsel_idx := 0
	if not _preview_hat_id.is_empty() and _custom_hats.has(_preview_hat_id):
		hsel_idx = hat_ids.find(_preview_hat_id) + 1
	else:
		_preview_hat_id = ""
	hat_select.selected = hsel_idx
	if not hat_select.item_selected.is_connected(_on_hat_select_changed):
		hat_select.item_selected.connect(_on_hat_select_changed)

func _on_skin_select_changed(idx: int) -> void:
	var skin_ids := _custom_skins.keys()
	_preview_skin_id = "" if idx == 0 else skin_ids[idx - 1]
	_refresh_big_preview()

func _on_hat_select_changed(idx: int) -> void:
	var hat_ids := _custom_hats.keys()
	_preview_hat_id = "" if idx == 0 else hat_ids[idx - 1]
	_refresh_big_preview()

## No selection ("None") falls back to a plain default-colored character
## (via the game's own normal builtin-skin system) rather than showing
## nothing -- there's always something to look at.
func _refresh_big_preview() -> void:
	if not _big_preview:
		return
	var default_parts := SkinCatalog.get_part_textures("red")
	var skin_parts: Dictionary = _custom_skins.get(_preview_skin_id, {})
	for part_name in SkinCatalog.PART_NAMES:
		if skin_parts.has(part_name):
			_big_preview.set_part_override(part_name, ImageTexture.create_from_image(skin_parts[part_name]))
		elif default_parts.has(part_name):
			_big_preview.set_part_override(part_name, default_parts[part_name])

	if _preview_hat_id.is_empty():
		_big_preview.set_hat_override(null)
	else:
		var hat_parts: Dictionary = _custom_hats.get(_preview_hat_id, {})
		if hat_parts.has("design"):
			_big_preview.set_hat_override(ImageTexture.create_from_image(hat_parts["design"]))

func _on_export_pressed() -> void:
	var base_dir := OS.get_executable_path().get_base_dir()
	var status_parts: Array[String] = []

	if not _custom_skins.is_empty():
		var skins_out_dir := base_dir.path_join("edited_skins")
		for id in _custom_skins.keys():
			var safe_name := _safe_filename(_skin_names[id], id)
			var skin_dir := skins_out_dir.path_join(safe_name)
			DirAccess.make_dir_recursive_absolute(skin_dir.path_join("parts"))
			for part_name in SkinCatalog.PART_NAMES:
				var part_img: Image = _custom_skins[id][part_name]
				part_img.save_png(skin_dir.path_join("parts/%s.png" % part_name))
			var whole := _composite_whole_skin(_custom_skins[id])
			whole.save_png(skin_dir.path_join("%s.png" % safe_name))
		var f := FileAccess.open(skins_out_dir.path_join("HOW_TO_SUBMIT.txt"), FileAccess.WRITE)
		if f:
			f.store_string(SKIN_INSTRUCTIONS_TEXT)
		status_parts.append(skins_out_dir)

	if not _custom_hats.is_empty():
		var hats_out_dir := base_dir.path_join("edited_hats")
		DirAccess.make_dir_recursive_absolute(hats_out_dir)
		for id in _custom_hats.keys():
			var safe_name := _safe_filename(_hat_names[id], id)
			var img: Image = _custom_hats[id]["design"]
			img.save_png(hats_out_dir.path_join("%s.png" % safe_name))
		var f2 := FileAccess.open(hats_out_dir.path_join("HOW_TO_SUBMIT.txt"), FileAccess.WRITE)
		if f2:
			f2.store_string(HAT_INSTRUCTIONS_TEXT)
		status_parts.append(hats_out_dir)

	if not _custom_trails.is_empty():
		var trails_out_dir := base_dir.path_join("edited_trails")
		DirAccess.make_dir_recursive_absolute(trails_out_dir)
		for id in _custom_trails.keys():
			var safe_name := _safe_filename(_trail_names[id], id)
			var img: Image = _custom_trails[id]["design"]
			img.save_png(trails_out_dir.path_join("%s.png" % safe_name))
		var f5 := FileAccess.open(trails_out_dir.path_join("HOW_TO_SUBMIT.txt"), FileAccess.WRITE)
		if f5:
			f5.store_string(TRAIL_INSTRUCTIONS_TEXT)
		status_parts.append(trails_out_dir)

	if not _tile_images.is_empty():
		var tiles_out_dir := base_dir.path_join("edited_tiles")
		DirAccess.make_dir_recursive_absolute(tiles_out_dir)
		var atlas := Image.create(TILE_TEXTURE_SIZE * _tile_images.size(), TILE_TEXTURE_SIZE, false, Image.FORMAT_RGBA8)
		for i in _tile_images.size():
			atlas.blit_rect(_tile_images[i], Rect2i(Vector2i.ZERO, Vector2i(TILE_TEXTURE_SIZE, TILE_TEXTURE_SIZE)), Vector2i(i * TILE_TEXTURE_SIZE, 0))
		atlas.save_png(tiles_out_dir.path_join("tag_tiles.png"))
		var f3 := FileAccess.open(tiles_out_dir.path_join("HOW_TO_SUBMIT.txt"), FileAccess.WRITE)
		if f3:
			f3.store_string(TILE_INSTRUCTIONS_TEXT)
		status_parts.append(tiles_out_dir)

	if not _icon_images.is_empty():
		var icons_out_dir := base_dir.path_join("edited_icons")
		DirAccess.make_dir_recursive_absolute(icons_out_dir)
		var atlas := Image.create(ICON_TEXTURE_SIZE * _icon_images.size(), ICON_TEXTURE_SIZE, false, Image.FORMAT_RGBA8)
		for i in _icon_images.size():
			atlas.blit_rect(_icon_images[i], Rect2i(Vector2i.ZERO, Vector2i(ICON_TEXTURE_SIZE, ICON_TEXTURE_SIZE)), Vector2i(i * ICON_TEXTURE_SIZE, 0))
		atlas.save_png(icons_out_dir.path_join("tag_icons.png"))
		var f4 := FileAccess.open(icons_out_dir.path_join("HOW_TO_SUBMIT.txt"), FileAccess.WRITE)
		if f4:
			f4.store_string(ICON_INSTRUCTIONS_TEXT)
		status_parts.append(icons_out_dir)

	if not _button_art_images.is_empty():
		# One file per mode (not one shared atlas the way icons/tiles are) --
		# each mode button is its own independent whole-button image, so
		# there's no fixed-slot strip layout to keep in sync here.
		var buttons_out_dir := base_dir.path_join("edited_icons/mode_buttons")
		DirAccess.make_dir_recursive_absolute(buttons_out_dir)
		for i in _button_art_images.size():
			_button_art_images[i].save_png(buttons_out_dir.path_join("%s.png" % MODE_BUTTON_KEYS[i]))
		var f5 := FileAccess.open(buttons_out_dir.path_join("HOW_TO_SUBMIT.txt"), FileAccess.WRITE)
		if f5:
			f5.store_string(MODE_BUTTON_INSTRUCTIONS_TEXT)
		status_parts.append(buttons_out_dir)

	if status_parts.is_empty():
		status_label.text = "Nothing to export yet -- create a skin, hat, or trail first."
	else:
		status_label.text = "Exported to: " + ", ".join(status_parts)

func _safe_filename(display_name: String, fallback_id: String) -> String:
	var safe := display_name.strip_edges().to_lower().replace(" ", "_")
	return safe if not safe.is_empty() else fallback_id

## Blits a custom skin's single body part into a whole-canvas image at its
## real in-game position (see SkinCatalog.PART_DEFS) -- the exact format the
## game's existing admin ingestion tool (relay-server/add-skin.js) already
## expects, so a custom skin needs no new server-side code to go live.
func _composite_whole_skin(parts: Dictionary) -> Image:
	var whole := Image.create(SkinCatalog.VISUAL_WIDTH, SkinCatalog.VISUAL_HEIGHT, false, Image.FORMAT_RGBA8)
	whole.fill(Color(0, 0, 0, 0))
	for part_name in SkinCatalog.PART_NAMES:
		if not parts.has(part_name):
			continue
		var rect: Rect2i = SkinCatalog.PART_DEFS[part_name].rect
		whole.blit_rect(parts[part_name], Rect2i(Vector2i.ZERO, rect.size), rect.position)
	return whole
