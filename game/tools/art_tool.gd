extends Control

# Standalone paint tool, exported as its own executable (TagArtTool.exe, see
# export_presets.cfg's "Art Tool" preset). Four pages, switched at the top
# like a dedicated app rather than one cramped screen: PAINT (create/edit
# any number of independent custom skins, hats, and trails -- no pre-made
# defaults, every one starts as a blank canvas), PREVIEW (a single large render of
# any skin/hat combination, picked from real dropdowns), LEVEL (paint a
# tile-based map and publish it live -- see game/levels/level_data.gd; tiles
# themselves are a single fixed regular tile now, nothing to paint there),
# and ICONS, which covers three independent things sharing one canvas/
# toolbar: small mode-bar badge icons (originally 100% procedural CanvasItem
# drawing with no image asset at all; see ui/mode_icon.gd's atlas-with-
# procedural-fallback loading), whole mode-button art (an entire main-menu
# button -- background, character, label, everything -- painted as one
# 190x360 image per mode, replacing the procedural box outright when
# present; see main_menu.gd's MODE_BUTTON_ART_PATH), and whole menu-screen
# backgrounds (a full GAME_VIEWPORT_WIDTH x GAME_VIEWPORT_HEIGHT image per
# screen, replacing UIStyle.add_background()'s procedural gradient when
# present). All three support Import Image (loads a PNG from disk into the
# clipboard) plus the existing Selection > Stamp/Move tools for composing
# from other elements without a dedicated drag-and-drop layer system.
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
const PlaylistCatalog := preload("res://net/playlist_catalog.gd")

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
     <key> is online.png or local.png (matching the file's own name here).
  2. Commit the file -- no rebuild step needed, main_menu.gd checks for
     it at runtime and uses it in place of the procedural glow/portrait/
     label box automatically.

A mode with no file here just keeps using the procedural fallback -- you
don't need to paint both at once.
"""

const ACTION_BAR_INSTRUCTIONS_TEXT := """Each file here is one shared utility button's ENTIRE art -- icon, label,
background, everything -- painted at 380x44. The same file is reused on
every screen that has that button (e.g. back.png shows up as Back,
Cancel, and Leave everywhere), so painting one image touches many screens
at once.

To make one of these the game's real button art:

  1. Copy the file to game/assets/icons/action_bars/<key>.png, matching
     the file's own name here (back.png, connect.png, etc).
  2. Commit the file -- no rebuild step needed, every screen using that
     key checks for it at runtime and uses it in place of the plain
     flat-colored button automatically.

A button with no file here just keeps using the plain flat-colored
fallback -- you don't need to paint all nine at once.
"""

const PLAYLIST_CARD_INSTRUCTIONS_TEXT := """Each file here is one ranked playlist picker card's ENTIRE art -- icon
figures, label, background, everything -- painted at 170x150, the exact
size ranked_playlist_select.gd renders that card at.

To make one of these the game's real card art:

  1. Copy the file to game/assets/icons/playlist_cards/<key>.png, where
     <key> is 1v1.png, 2v2.png, 1v1v1.png, or 1v1v1v1.png (matching the
     file's own name here).
  2. Commit the file -- no rebuild step needed, ranked_playlist_select.gd
     checks for it at runtime and uses it in place of the procedural
     icon/name/sub-label box automatically.

A playlist with no file here just keeps using the procedural fallback --
you don't need to paint all four at once.
"""

const BACKGROUND_INSTRUCTIONS_TEXT := """Each file here is one menu screen's ENTIRE background, painted at
1152x648, the game's real viewport size.

To make one of these the game's real screen background:

  1. Copy the file to game/assets/backgrounds/<key>.png -- see the
     filename here for <key> (main_menu.png, online_menu.png, etc).
  2. Commit the file -- no rebuild step needed, UIStyle.add_background()
     checks for it at runtime and uses it in place of the procedural
     gradient automatically.

A screen with no file here just keeps using the procedural gradient -- you
don't need to paint all of them at once.
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
@onready var publish_key_edit: LineEdit = $VBox/BottomRow/PublishKeyEdit
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
# Icons pages each have their own (only one is ever visible/relevant at a
# time), set by _setup_page_tabs()'s tab handlers.
var _active_color_picker: ColorPicker = null

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
const GAME_ASSETS_API_BASE := "https://codecade.co.za/tag/api/game-assets"
const PUBLISH_KEY_PATH := "user://asset_publish_key.txt"

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

# Whole-button custom art for the main menu's 2 mode bars (Online/Local)
# -- an alternative to the small badge-icon-on-a-procedural-box system
# above: paint the entire button (background, character, label, all of
# it) as one image, same canvas size the real button renders at, so what's
# painted here is exactly what shows up in-game. Matches main_menu.gd's
# MODES key order exactly -- "online"/"local" (Sandbox removed).
const MODE_BUTTON_KEYS := ["online", "local"]
const MODE_BUTTON_NAMES := ["Online", "Local"]
const MODE_BUTTON_SIZE := Vector2i(190, 360) # matches main_menu.gd's BAR_SIZE exactly
const MODE_BUTTON_ART_DIR := "res://assets/icons/mode_buttons"
const MODE_BUTTON_ZOOM := 2 # 190x360 is already large -- a much smaller per-pixel zoom than a 64x64 icon needs
var _button_art_images: Array[Image] = [] # index-matched to MODE_BUTTON_KEYS
var _current_button_art_index := -1
var _button_art_select_buttons: Array[Button] = []

# Whole-screen custom background art for every menu screen -- an
# alternative to UIStyle.add_background()'s procedural radial gradient:
# paint the entire screen background as one image, the real game viewport
# size (see UIStyle.BACKGROUND_SIZE), so what's painted here is exactly
# what shows up in-game. Keys/order must match every UIStyle.add_background
# call site across game/main/*.gd (also mirrored in
# game_asset_updater.gd's BACKGROUND_KEYS and relay-server/server.js's,
# same "kept in sync by convention" relationship MODE_BUTTON_KEYS already
# has across those same 3 files).
const BACKGROUND_KEYS := [
	"main_menu", "online_menu", "local_menu", "shop", "friends_menu",
	"lobby_room", "host_setup", "login_screen", "match_intro", "match_results",
	"multiplayer_connect", "quick_play", "ranked_queue", "server_browser",
]
const BACKGROUND_NAMES := [
	"Main Menu", "Online Menu", "Local Menu", "Shop", "Friends",
	"Lobby Room", "Host Setup", "Login Screen", "Match Intro", "Match Results",
	"Direct Connect", "Quick Play", "Ranked Queue", "Server Browser",
]
const BACKGROUND_ZOOM := 1 # already full game-viewport size, no per-pixel zoom needed
var _background_images: Array[Image] = [] # index-matched to BACKGROUND_KEYS
var _current_background_index := -1
var _background_select_buttons: Array[Button] = []

# Every plain full-width utility bar shared across many screens at once
# (Back/Cancel/Leave everywhere, server browser's Connect/Watch, host
# setup's Host Server, lobby room's Start Match, login screen's Log In/
# Create Account/Log Out) -- see tools/generate_menu_art.gd's ACTION_BARS
# for the same key set/order this must stay in sync with, one whole-bar
# image each (not a shared atlas), same shape as mode button art above.
const ACTION_BAR_KEYS := ["back", "connect", "watch", "host_server", "ready", "start_match", "login", "create_account", "logout"]
const ACTION_BAR_NAMES := ["Back", "Connect", "Watch", "Host Server", "Ready", "Start Match", "Log In", "Create Account", "Log Out"]
const ACTION_BAR_SIZE := Vector2i(380, 44) # matches generate_menu_art.gd's ACTION_BAR_FINAL_SIZE
const ACTION_BAR_ART_DIR := "res://assets/icons/action_bars"
const ACTION_BAR_ZOOM := 2
var _action_bar_images: Array[Image] = [] # index-matched to ACTION_BAR_KEYS
var _current_action_bar_index := -1
var _action_bar_select_buttons: Array[Button] = []

# Ranked playlist picker's 4 cards (ranked_playlist_select.gd) -- same
# whole-card painted-art shape as mode buttons/action bars above. Keys/
# order must match PlaylistCatalog.PLAYLIST_ORDER, same "kept in sync by
# convention" relationship every other *_KEYS list on this page already
# has with its own real source of truth.
const PLAYLIST_CARD_KEYS := ["1v1", "2v2", "1v1v1", "1v1v1v1"]
const PLAYLIST_CARD_NAMES := ["1v1", "2v2", "1v1v1", "1v1v1v1"]
const PLAYLIST_CARD_SIZE := Vector2i(170, 150) # matches ranked_playlist_select.gd's card custom_minimum_size
const PLAYLIST_CARD_ART_DIR := "res://assets/icons/playlist_cards"
const PLAYLIST_CARD_ZOOM := 4
var _playlist_card_images: Array[Image] = [] # index-matched to PLAYLIST_CARD_KEYS
var _current_playlist_card_index := -1
var _playlist_card_select_buttons: Array[Button] = []

var _import_file_dialog: FileDialog

func _ready() -> void:
	# 860 wasn't tall enough: Title + PageTabRow + BottomRow (~213px) plus a
	# page's own right-hand color column -- a stock ColorPicker alone wants
	# ~700px -- already summed to more than the old window's usable height
	# on the default Paint page, before any tab-specific content. Since
	# VBox's full-rect anchoring can't shrink below its children's minimum
	# size, that overflow silently pushed everything above it up the page.
	get_window().size = Vector2i(1300, 940)
	get_window().title = "Tag Art Tool"
	UIStyle.add_background(self)
	_setup_page_tabs()
	_build_sidebar()
	_build_shared_toolbar(toolbar)
	_build_level_page()
	_build_icons_page()
	_active_color_picker = color_picker
	color_picker.color_changed.connect(_on_color_picked_from_wheel)
	export_button.pressed.connect(_on_export_pressed)
	UIStyle.style_button(export_button, UIStyle.COLOR_SHOP)
	_load_publish_key()
	publish_key_edit.text_changed.connect(_save_publish_key)
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
	# IconsTabButton/IconsPage isn't in the .tscn -- built and inserted
	# alongside the other three entirely in code, right next to the tab row/
	# page container that already own the other tabs, so there's nothing
	# scene-file-specific about how this one is wired in.
	var tab_row: HBoxContainer = paint_tab_button.get_parent()
	icons_tab_button = Button.new()
	icons_tab_button.custom_minimum_size = Vector2(140, 38)
	icons_tab_button.toggle_mode = true
	icons_tab_button.text = "Icons"
	tab_row.add_child(icons_tab_button)

	var tab_group := ButtonGroup.new()
	paint_tab_button.button_group = tab_group
	preview_tab_button.button_group = tab_group
	level_tab_button.button_group = tab_group
	icons_tab_button.button_group = tab_group
	UIStyle.style_button(paint_tab_button, UIStyle.COLOR_SHOP, 10)
	UIStyle.style_button(preview_tab_button, UIStyle.COLOR_ONLINE, 10)
	UIStyle.style_button(level_tab_button, UIStyle.COLOR_SANDBOX, 10)
	UIStyle.style_button(icons_tab_button, UIStyle.COLOR_LOCAL, 10)
	paint_tab_button.pressed.connect(func():
		paint_page.visible = true
		preview_page.visible = false
		level_page.visible = false
		icons_page.visible = false
		export_button.visible = true
		_active_color_picker = color_picker
		_apply_tool_state()
	)
	preview_tab_button.pressed.connect(func():
		paint_page.visible = false
		preview_page.visible = true
		level_page.visible = false
		icons_page.visible = false
		export_button.visible = true
		_refresh_preview_selectors()
		_refresh_big_preview()
	)
	level_tab_button.pressed.connect(func():
		paint_page.visible = false
		preview_page.visible = false
		level_page.visible = true
		icons_page.visible = false
		export_button.visible = false
	)
	icons_tab_button.pressed.connect(func():
		paint_page.visible = false
		preview_page.visible = false
		level_page.visible = false
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
## or the Icons page's `icons_toolbar`) -- one call site, shared by both
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
	# Without this, the HFlowContainer row stretches both to the height of
	# its tallest sibling (the size/toggle buttons) and top-aligns them --
	# fine for a Label/HSlider's own content, but visually anchors them well
	# above the row's vertical middle. SIZE_SHRINK_CENTER keeps each at its
	# natural height and centers that within the row instead.
	alpha_label.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	flow.add_child(alpha_label)
	var alpha_slider := HSlider.new()
	alpha_slider.min_value = 0.1
	alpha_slider.max_value = 1.0
	alpha_slider.step = 0.05
	alpha_slider.value = 1.0
	alpha_slider.custom_minimum_size = Vector2(90, 0)
	alpha_slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
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

	# A single regular tile -- no more type/variant swatches to pick between,
	# PAINT just places it.
	var level_tool_group := ButtonGroup.new()
	var paint_btn := Button.new()
	paint_btn.text = "Paint"
	paint_btn.toggle_mode = true
	paint_btn.button_group = level_tool_group
	paint_btn.button_pressed = true
	UIStyle.style_button(paint_btn, TileCanvas.TILE_COLOR, 8)
	paint_btn.pressed.connect(func(): _tile_canvas.tool = TileCanvas.Tool.PAINT)
	level_toolbar.add_child(paint_btn)

	level_toolbar.add_child(VSeparator.new())

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

	_tile_canvas.tool = TileCanvas.Tool.PAINT
	_on_add_level_pressed()

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
## Builds the Icons page entirely in code: a left-hand list of the 6
## procedural mode-bar icon types, a canvas panel driven by the shared
## _build_shared_toolbar/_current_canvas machinery, and its own ColorPicker.
## Unlike skins, icons are baked and painted in white/grayscale (see the file
## header comment) since they're re-tinted per usage at runtime -- the
## right-panel help text below says so directly, since painting a specific
## hue here would silently look wrong in-game rather than erroring anywhere
## obvious.
func _build_icons_page() -> void:
	var vbox: VBoxContainer = paint_page.get_parent()
	icons_page = HBoxContainer.new()
	icons_page.size_flags_vertical = Control.SIZE_EXPAND_FILL
	icons_page.add_theme_constant_override("separation", 12)
	icons_page.visible = false
	vbox.add_child(icons_page)
	vbox.move_child(icons_page, level_page.get_index() + 1)

	var select_panel := PanelContainer.new()
	select_panel.custom_minimum_size = Vector2(180, 0)
	select_panel.add_theme_stylebox_override("panel", UIStyle.panel_box())
	icons_page.add_child(select_panel)
	# 6 icons + 2 mode buttons + 14 backgrounds is too many entries for a
	# fixed-height sidebar -- see the ScrollContainer on the right-hand color
	# column above for the same overflow-into-the-whole-page bug this
	# prevents.
	var select_scroll := ScrollContainer.new()
	select_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	select_panel.add_child(select_scroll)
	var select_box := VBoxContainer.new()
	select_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	select_box.add_theme_constant_override("separation", 6)
	select_scroll.add_child(select_box)
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

	var background_spacer := Control.new()
	background_spacer.custom_minimum_size = Vector2(0, 8)
	select_box.add_child(background_spacer)

	# Same shared ButtonGroup again -- picking a screen background here
	# deselects whichever icon/mode button was active, and vice versa.
	select_box.add_child(_section_label("MENU BACKGROUNDS"))
	_background_select_buttons.clear()
	for i in BACKGROUND_NAMES.size():
		var btn := Button.new()
		btn.text = BACKGROUND_NAMES[i]
		btn.toggle_mode = true
		btn.button_group = icon_group
		btn.custom_minimum_size = Vector2(0, 32)
		UIStyle.style_button(btn, UIStyle.COLOR_RANKED, 10, false)
		btn.pressed.connect(_show_background.bind(i))
		select_box.add_child(btn)
		_background_select_buttons.append(btn)

	var action_bar_spacer := Control.new()
	action_bar_spacer.custom_minimum_size = Vector2(0, 8)
	select_box.add_child(action_bar_spacer)

	# Same shared ButtonGroup again -- picking an action button here
	# deselects whichever icon/mode button/background was active.
	select_box.add_child(_section_label("ACTION BUTTON ART"))
	_action_bar_select_buttons.clear()
	for i in ACTION_BAR_NAMES.size():
		var btn := Button.new()
		btn.text = ACTION_BAR_NAMES[i]
		btn.toggle_mode = true
		btn.button_group = icon_group
		btn.custom_minimum_size = Vector2(0, 32)
		UIStyle.style_button(btn, UIStyle.COLOR_ONLINE, 10, false)
		btn.pressed.connect(_show_action_bar.bind(i))
		select_box.add_child(btn)
		_action_bar_select_buttons.append(btn)

	var playlist_card_spacer := Control.new()
	playlist_card_spacer.custom_minimum_size = Vector2(0, 8)
	select_box.add_child(playlist_card_spacer)

	# Same shared ButtonGroup again -- picking a playlist card here
	# deselects whichever icon/mode button/background/action button was
	# active.
	select_box.add_child(_section_label("PLAYLIST CARD ART"))
	_playlist_card_select_buttons.clear()
	for i in PLAYLIST_CARD_NAMES.size():
		var btn := Button.new()
		btn.text = PLAYLIST_CARD_NAMES[i]
		btn.toggle_mode = true
		btn.button_group = icon_group
		btn.custom_minimum_size = Vector2(0, 32)
		UIStyle.style_button(btn, UIStyle.COLOR_RANKED, 10, false)
		btn.pressed.connect(_show_playlist_card.bind(i))
		select_box.add_child(btn)
		_playlist_card_select_buttons.append(btn)

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
	# A stock ColorPicker alone wants ~700px of height -- fine next to just a
	# title label (see Paint page's static ColorPicker), but stacked with the
	# help text and Import button below it here, the column's total minimum
	# height exceeded the window's. Since VBox's full-rect anchoring can't
	# shrink below its children's minimum size, that overflow pushed the
	# whole toolbar (and everything above it) up the instant this page
	# became visible. A ScrollContainer absorbs any future overflow here
	# instead of forcing the page -- and everything above it -- to grow.
	var right_scroll := ScrollContainer.new()
	right_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	right_panel.add_child(right_scroll)
	var right_box := VBoxContainer.new()
	right_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right_box.add_theme_constant_override("separation", 8)
	right_scroll.add_child(right_box)
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
	# See tiles_help above -- same fix, more critical here since this page
	# starts hidden and stacks two long autowrap labels in one column.
	icons_help.custom_minimum_size.x = 200
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
	# See tiles_help above -- same fix.
	import_help.custom_minimum_size.x = 200
	import_help.add_theme_font_size_override("font_size", 12)
	import_help.add_theme_color_override("font_color", Color(0.7, 0.72, 0.78))
	right_box.add_child(import_help)

	_load_icon_images()
	_load_button_art_images()
	_load_background_images()
	_load_action_bar_images()
	_load_playlist_card_images()
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
	_current_background_index = -1
	_current_action_bar_index = -1
	_current_playlist_card_index = -1
	for i in _icon_select_buttons.size():
		_icon_select_buttons[i].button_pressed = (i == index)
	for i in _button_art_select_buttons.size():
		_button_art_select_buttons[i].button_pressed = false
	for i in _background_select_buttons.size():
		_background_select_buttons[i].button_pressed = false
	for i in _action_bar_select_buttons.size():
		_action_bar_select_buttons[i].button_pressed = false
	for i in _playlist_card_select_buttons.size():
		_playlist_card_select_buttons[i].button_pressed = false
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
	_current_background_index = -1
	_current_action_bar_index = -1
	_current_playlist_card_index = -1
	for i in _icon_select_buttons.size():
		_icon_select_buttons[i].button_pressed = false
	for i in _button_art_select_buttons.size():
		_button_art_select_buttons[i].button_pressed = (i == index)
	for i in _background_select_buttons.size():
		_background_select_buttons[i].button_pressed = false
	for i in _action_bar_select_buttons.size():
		_action_bar_select_buttons[i].button_pressed = false
	for i in _playlist_card_select_buttons.size():
		_playlist_card_select_buttons[i].button_pressed = false
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

## Loads each screen's whole-background art (see BACKGROUND_KEYS/
## UIStyle.add_background) if it's already been painted and committed, else
## a blank transparent UIStyle.BACKGROUND_SIZE canvas -- same "always
## something real or an honest blank canvas" rule _load_icon_images()/
## _load_button_art_images() follow.
func _load_background_images() -> void:
	_background_images.clear()
	for key in BACKGROUND_KEYS:
		var path := "%s/%s.png" % [UIStyle.BACKGROUND_ART_DIR, key]
		var img: Image
		if ResourceLoader.exists(path):
			var tex: Texture2D = load(path)
			img = tex.get_image() if tex else null
			if img:
				img.convert(Image.FORMAT_RGBA8)
		if not img:
			img = Image.create(UIStyle.BACKGROUND_SIZE.x, UIStyle.BACKGROUND_SIZE.y, false, Image.FORMAT_RGBA8)
			img.fill(Color(0, 0, 0, 0))
		_background_images.append(img)

func _show_background(index: int) -> void:
	_current_background_index = index
	_current_icon_index = -1
	_current_button_art_index = -1
	_current_action_bar_index = -1
	_current_playlist_card_index = -1
	for i in _icon_select_buttons.size():
		_icon_select_buttons[i].button_pressed = false
	for i in _button_art_select_buttons.size():
		_button_art_select_buttons[i].button_pressed = false
	for i in _background_select_buttons.size():
		_background_select_buttons[i].button_pressed = (i == index)
	for i in _action_bar_select_buttons.size():
		_action_bar_select_buttons[i].button_pressed = false
	for i in _playlist_card_select_buttons.size():
		_playlist_card_select_buttons[i].button_pressed = false
	for child in icons_canvas_holder.get_children():
		icons_canvas_holder.remove_child(child)
		child.queue_free()
	var canvas = PixelCanvasScene.new(_background_images[index], BACKGROUND_ZOOM)
	icons_canvas_holder.add_child(canvas)
	canvas.painted.connect(_on_painted)
	canvas.painted.connect(func(): _background_images[index] = canvas.image)
	canvas.color_picked.connect(_on_eyedropper_picked)
	_current_canvas = canvas
	_apply_tool_state()

## Loads each shared utility bar's whole-button art (see ACTION_BAR_KEYS)
## if it's already been painted and committed, else a blank transparent
## ACTION_BAR_SIZE canvas -- same "always something real or an honest
## blank canvas" rule every other section on this page follows.
func _load_action_bar_images() -> void:
	_action_bar_images.clear()
	for key in ACTION_BAR_KEYS:
		var path := "%s/%s.png" % [ACTION_BAR_ART_DIR, key]
		var img: Image
		if ResourceLoader.exists(path):
			var tex: Texture2D = load(path)
			img = tex.get_image() if tex else null
			if img:
				img.convert(Image.FORMAT_RGBA8)
		if not img:
			img = Image.create(ACTION_BAR_SIZE.x, ACTION_BAR_SIZE.y, false, Image.FORMAT_RGBA8)
			img.fill(Color(0, 0, 0, 0))
		_action_bar_images.append(img)

func _show_action_bar(index: int) -> void:
	_current_action_bar_index = index
	_current_icon_index = -1
	_current_button_art_index = -1
	_current_background_index = -1
	_current_playlist_card_index = -1
	for i in _icon_select_buttons.size():
		_icon_select_buttons[i].button_pressed = false
	for i in _button_art_select_buttons.size():
		_button_art_select_buttons[i].button_pressed = false
	for i in _background_select_buttons.size():
		_background_select_buttons[i].button_pressed = false
	for i in _action_bar_select_buttons.size():
		_action_bar_select_buttons[i].button_pressed = (i == index)
	for i in _playlist_card_select_buttons.size():
		_playlist_card_select_buttons[i].button_pressed = false
	for child in icons_canvas_holder.get_children():
		icons_canvas_holder.remove_child(child)
		child.queue_free()
	var canvas = PixelCanvasScene.new(_action_bar_images[index], ACTION_BAR_ZOOM)
	icons_canvas_holder.add_child(canvas)
	canvas.painted.connect(_on_painted)
	canvas.painted.connect(func(): _action_bar_images[index] = canvas.image)
	canvas.color_picked.connect(_on_eyedropper_picked)
	_current_canvas = canvas
	_apply_tool_state()

## Loads each playlist's whole-card art (see PLAYLIST_CARD_KEYS/
## ranked_playlist_select.gd) if it's already been painted and committed,
## else a blank transparent PLAYLIST_CARD_SIZE canvas -- same "always
## something real or an honest blank canvas" rule every other section on
## this page follows.
func _load_playlist_card_images() -> void:
	_playlist_card_images.clear()
	for key in PLAYLIST_CARD_KEYS:
		var path := "%s/%s.png" % [PLAYLIST_CARD_ART_DIR, key]
		var img: Image
		if ResourceLoader.exists(path):
			var tex: Texture2D = load(path)
			img = tex.get_image() if tex else null
			if img:
				img.convert(Image.FORMAT_RGBA8)
		if not img:
			img = Image.create(PLAYLIST_CARD_SIZE.x, PLAYLIST_CARD_SIZE.y, false, Image.FORMAT_RGBA8)
			img.fill(Color(0, 0, 0, 0))
		_playlist_card_images.append(img)

func _show_playlist_card(index: int) -> void:
	_current_playlist_card_index = index
	_current_icon_index = -1
	_current_button_art_index = -1
	_current_background_index = -1
	_current_action_bar_index = -1
	for i in _icon_select_buttons.size():
		_icon_select_buttons[i].button_pressed = false
	for i in _button_art_select_buttons.size():
		_button_art_select_buttons[i].button_pressed = false
	for i in _background_select_buttons.size():
		_background_select_buttons[i].button_pressed = false
	for i in _action_bar_select_buttons.size():
		_action_bar_select_buttons[i].button_pressed = false
	for i in _playlist_card_select_buttons.size():
		_playlist_card_select_buttons[i].button_pressed = (i == index)
	for child in icons_canvas_holder.get_children():
		icons_canvas_holder.remove_child(child)
		child.queue_free()
	var canvas = PixelCanvasScene.new(_playlist_card_images[index], PLAYLIST_CARD_ZOOM)
	icons_canvas_holder.add_child(canvas)
	canvas.painted.connect(_on_painted)
	canvas.painted.connect(func(): _playlist_card_images[index] = canvas.image)
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

func _load_publish_key() -> void:
	if FileAccess.file_exists(PUBLISH_KEY_PATH):
		var f := FileAccess.open(PUBLISH_KEY_PATH, FileAccess.READ)
		if f:
			publish_key_edit.text = f.get_as_text().strip_edges()

func _save_publish_key(_new_text: String) -> void:
	var f := FileAccess.open(PUBLISH_KEY_PATH, FileAccess.WRITE)
	if f:
		f.store_string(publish_key_edit.text.strip_edges())

## Pushes one of the game's own built-in art categories (tiles/icons/
## mode_buttons -- NOT the player-cosmetic skins/hats/trails, which already
## publish live through their own per-entry Publish buttons above) straight
## to the relay, gated by the key in publish_key_edit -- see relay-server/
## server.js's "HTTP: game assets" section. `body` is the request payload
## the category's endpoint expects: {imageBase64} for tiles/icons, {images}
## (a key->base64 dict) for mode_buttons.
func _publish_game_asset(category: String, body: Dictionary) -> Dictionary:
	var key := publish_key_edit.text.strip_edges()
	if key.is_empty():
		return {"ok": false, "error": "Enter a publish key first."}
	body["key"] = key
	var req := HTTPRequest.new()
	add_child(req)
	var err := req.request(
		"%s/%s/publish" % [GAME_ASSETS_API_BASE, category], ["Content-Type: application/json"], HTTPClient.METHOD_POST, JSON.stringify(body)
	)
	if err != OK:
		req.queue_free()
		return {"ok": false, "error": "Couldn't start the request."}
	var response: Array = await req.request_completed
	req.queue_free()
	var response_body: String = (response[3] as PackedByteArray).get_string_from_utf8()
	var parsed = JSON.parse_string(response_body)
	if response[1] == 200 and typeof(parsed) == TYPE_DICTIONARY:
		return {"ok": true, "version": parsed.get("version", 0)}
	var error_msg: String = parsed.get("error", "publish failed") if typeof(parsed) == TYPE_DICTIONARY else "publish failed"
	return {"ok": false, "error": error_msg}

func _on_export_pressed() -> void:
	var base_dir := OS.get_executable_path().get_base_dir()
	var status_parts: Array[String] = []
	var publish_parts: Array[String] = []

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

		status_label.text = "Publishing icons..."
		var icons_result := await _publish_game_asset("icons", {"imageBase64": Marshalls.raw_to_base64(atlas.save_png_to_buffer())})
		publish_parts.append("icons (v%d)" % icons_result.get("version", 0) if icons_result.get("ok", false) else "icons failed: %s" % icons_result.get("error", ""))

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

		# Unlike the tiles/icons atlas (a fixed-layout strip that must always
		# publish whole), mode button art is 3 fully independent images -- only
		# send the ones actually painted (or already loaded from a prior
		# override), so exporting after touching up just one mode doesn't
		# publish the other two's still-blank canvases over whatever's live.
		var images_payload := {}
		for i in _button_art_images.size():
			if _image_has_content(_button_art_images[i]):
				images_payload[MODE_BUTTON_KEYS[i]] = Marshalls.raw_to_base64(_button_art_images[i].save_png_to_buffer())
		if not images_payload.is_empty():
			status_label.text = "Publishing mode button art..."
			var buttons_result := await _publish_game_asset("mode_buttons", {"images": images_payload})
			publish_parts.append("mode buttons (v%d)" % buttons_result.get("version", 0) if buttons_result.get("ok", false) else "mode buttons failed: %s" % buttons_result.get("error", ""))

	if not _background_images.is_empty():
		# Same one-file-per-key shape as mode button art, just a different
		# key set/canvas size -- see BACKGROUND_KEYS.
		var backgrounds_out_dir := base_dir.path_join("edited_icons/backgrounds")
		DirAccess.make_dir_recursive_absolute(backgrounds_out_dir)
		for i in _background_images.size():
			_background_images[i].save_png(backgrounds_out_dir.path_join("%s.png" % BACKGROUND_KEYS[i]))
		var f6 := FileAccess.open(backgrounds_out_dir.path_join("HOW_TO_SUBMIT.txt"), FileAccess.WRITE)
		if f6:
			f6.store_string(BACKGROUND_INSTRUCTIONS_TEXT)
		status_parts.append(backgrounds_out_dir)

		# Only send screens actually painted (or already loaded from a prior
		# override), same reasoning as mode button art above -- exporting
		# after touching up one screen shouldn't republish the other 13
		# still-blank canvases over whatever's live.
		var bg_images_payload := {}
		for i in _background_images.size():
			if _image_has_content(_background_images[i]):
				bg_images_payload[BACKGROUND_KEYS[i]] = Marshalls.raw_to_base64(_background_images[i].save_png_to_buffer())
		if not bg_images_payload.is_empty():
			status_label.text = "Publishing menu backgrounds..."
			var backgrounds_result := await _publish_game_asset("backgrounds", {"images": bg_images_payload})
			publish_parts.append("backgrounds (v%d)" % backgrounds_result.get("version", 0) if backgrounds_result.get("ok", false) else "backgrounds failed: %s" % backgrounds_result.get("error", ""))

	if not _action_bar_images.is_empty():
		# Same one-file-per-key shape as mode button art -- see ACTION_BAR_KEYS.
		var action_bars_out_dir := base_dir.path_join("edited_icons/action_bars")
		DirAccess.make_dir_recursive_absolute(action_bars_out_dir)
		for i in _action_bar_images.size():
			_action_bar_images[i].save_png(action_bars_out_dir.path_join("%s.png" % ACTION_BAR_KEYS[i]))
		var f7 := FileAccess.open(action_bars_out_dir.path_join("HOW_TO_SUBMIT.txt"), FileAccess.WRITE)
		if f7:
			f7.store_string(ACTION_BAR_INSTRUCTIONS_TEXT)
		status_parts.append(action_bars_out_dir)

		# Only send buttons actually painted (or already loaded from a prior
		# override), same reasoning as mode button art/backgrounds above.
		var action_bar_images_payload := {}
		for i in _action_bar_images.size():
			if _image_has_content(_action_bar_images[i]):
				action_bar_images_payload[ACTION_BAR_KEYS[i]] = Marshalls.raw_to_base64(_action_bar_images[i].save_png_to_buffer())
		if not action_bar_images_payload.is_empty():
			status_label.text = "Publishing action button art..."
			var action_bars_result := await _publish_game_asset("action_bars", {"images": action_bar_images_payload})
			publish_parts.append("action buttons (v%d)" % action_bars_result.get("version", 0) if action_bars_result.get("ok", false) else "action buttons failed: %s" % action_bars_result.get("error", ""))

	if not _playlist_card_images.is_empty():
		# Same one-file-per-key shape as mode button/action bar art.
		var playlist_cards_out_dir := base_dir.path_join("edited_icons/playlist_cards")
		DirAccess.make_dir_recursive_absolute(playlist_cards_out_dir)
		for i in _playlist_card_images.size():
			_playlist_card_images[i].save_png(playlist_cards_out_dir.path_join("%s.png" % PLAYLIST_CARD_KEYS[i]))
		var f8 := FileAccess.open(playlist_cards_out_dir.path_join("HOW_TO_SUBMIT.txt"), FileAccess.WRITE)
		if f8:
			f8.store_string(PLAYLIST_CARD_INSTRUCTIONS_TEXT)
		status_parts.append(playlist_cards_out_dir)

		# Only send cards actually painted (or already loaded from a prior
		# override), same reasoning as every other category above.
		var playlist_card_images_payload := {}
		for i in _playlist_card_images.size():
			if _image_has_content(_playlist_card_images[i]):
				playlist_card_images_payload[PLAYLIST_CARD_KEYS[i]] = Marshalls.raw_to_base64(_playlist_card_images[i].save_png_to_buffer())
		if not playlist_card_images_payload.is_empty():
			status_label.text = "Publishing playlist card art..."
			var playlist_cards_result := await _publish_game_asset("playlist_cards", {"images": playlist_card_images_payload})
			publish_parts.append("playlist cards (v%d)" % playlist_cards_result.get("version", 0) if playlist_cards_result.get("ok", false) else "playlist cards failed: %s" % playlist_cards_result.get("error", ""))

	if status_parts.is_empty():
		status_label.text = "Nothing to export yet -- create a skin, hat, or trail first."
	elif publish_parts.is_empty():
		status_label.text = "Exported to: " + ", ".join(status_parts)
	else:
		status_label.text = "Exported to: %s. Published live: %s." % [", ".join(status_parts), ", ".join(publish_parts)]

## Any non-fully-transparent pixel counts as "actually painted" -- a freshly
## created blank canvas (see _load_button_art_images) is 100% alpha=0.
func _image_has_content(img: Image) -> bool:
	var used_rect := img.get_used_rect()
	return used_rect.size.x > 0 and used_rect.size.y > 0

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
