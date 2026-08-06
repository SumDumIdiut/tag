extends Control

# Standalone paint tool, exported as its own executable (TagArtTool.exe, see
# export_presets.cfg's "Art Tool" preset). Two pages, switched at the top
# like a dedicated app rather than one cramped screen: LEVELS (paint a
# tile-based map and publish it live -- see game/levels/level_data.gd; tiles
# themselves are a single fixed regular tile now, nothing to paint there),
# and SPRITES, which covers small mode-bar badge icons (originally 100%
# procedural CanvasItem drawing with no image asset at all; see
# ui/mode_icon.gd's atlas-with-procedural-fallback loading) plus the app's
# shared button/panel/slider chrome (see tools/build_chrome_art.gd). Sprites
# supports Import Image (loads a PNG from disk into the clipboard) plus the
# existing Selection > Stamp/Move tools for composing from other elements
# without a dedicated drag-and-drop layer system.
#
# Icons and chrome are baked/painted in white/grayscale and re-tinted per
# usage at runtime (each mode bar/accent color applies its own tint), so
# painting them in a specific hue would look wrong once multiplied through.
#
# Levels and Sprites both drive their canvas through the same shared
# toolbar builder (_build_shared_toolbar) and the same _current_canvas/
# _apply_tool_state() mechanism, so every tool (shapes, selection, mirror,
# transforms, palette, ...) works identically across both without
# duplicated logic.

const UIStyle := preload("res://ui/ui_style.gd")
const PixelCanvasScene := preload("res://main/pixel_canvas.gd")
const UpdateCheckerScript := preload("res://net/update_checker.gd")
const UpdatePromptScene := preload("res://ui/update_prompt.gd")
const TileCanvasScene := preload("res://main/tile_canvas.gd")
const LevelData := preload("res://levels/level_data.gd")
const PlaylistCatalog := preload("res://net/playlist_catalog.gd")
const Categories := preload("res://net/game_asset_categories.gd")

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

const CHROME_INSTRUCTIONS_TEXT := """Each file here is one piece of the app's shared button/panel/slider chrome --
a small 9-patch box (fixed-width border pixels, stretchy middle) painted
white on transparent so it re-tints to any screen's own accent color at
runtime. Button is 32x32, Panel is 40x40, Slider Groove/Fill are 20x14.

To make one of these the game's real chrome:

  1. Copy the file to game/assets/icons/chrome/<key>.png, matching the
     file's own name here (button.png, panel.png, slider_groove.png,
     slider_fill.png).
  2. Commit the file -- no rebuild step needed, UIStyle.button_box()/
     panel_box()/style_slider() check for it at runtime and use it in
     place of the plain flat-colored box automatically, everywhere in the
     app at once.

A piece with no file here just keeps every button/panel/slider on the
plain flat-colored fallback -- you don't need to paint all four at once.
"""

const PLATFORM_INSTRUCTIONS_TEXT := """Each file here is one of the 3 tiles a moving platform assembles itself
from, left to right: left.png, middle.png, right.png. All 3 are 10x10 --
a platform is always exactly 3 tiles wide, so there's no auto-tiling/
terrain matching involved, just one fixed piece per position.

To make one of these the game's real platform art:

  1. Copy the file to game/assets/icons/platform/<key>.png, matching the
     file's own name here (left.png, middle.png, right.png).
  2. Commit the file -- no rebuild step needed, moving_platform.gd checks
     for it at runtime and uses it in place of the flat placeholder color
     automatically, on every platform in the game at once.

A piece with no file here just keeps that tile on the plain flat-colored
placeholder -- you don't need to paint all three at once.
"""

@onready var level_tab_button: Button = $VBox/PageTabRow/LevelTabButton
@onready var level_page: HBoxContainer = $VBox/LevelPage

@onready var level_toolbar: HBoxContainer = $VBox/LevelPage/LevelCanvasPanel/LevelCanvasBox/LevelToolbar
@onready var level_canvas_center: CenterContainer = $VBox/LevelPage/LevelCanvasPanel/LevelCanvasBox/LevelCanvasScroll/LevelCanvasCenter
@onready var level_name_edit: LineEdit = $VBox/LevelPage/LevelRightPanel/LevelRightBox/LevelNameEdit
@onready var publish_level_button: Button = $VBox/LevelPage/LevelRightPanel/LevelRightBox/PublishLevelButton

@onready var status_label: Label = $VBox/BottomRow/StatusLabel
@onready var publish_key_edit: LineEdit = $VBox/BottomRow/PublishKeyEdit
@onready var export_button: Button = $VBox/BottomRow/ExportButton

var _current_canvas: PixelCanvas = null

var _current_tool := 0 # PixelCanvas.Tool.BRUSH
# Toolbar-level tool settings -- shared by both the Level and Sprites pages'
# toolbars (_build_shared_toolbar) and reapplied to whichever canvas is
# active by _apply_tool_state(), rather than living on PixelCanvas
# instances themselves, so switching pages mid-edit doesn't reset the brush
# size or mirror mode the user just set up.
var _brush_size := 1
var _brush_alpha := 1.0
var _mirror_h := false
var _mirror_v := false
var _show_grid := false
# Which ColorPicker currently feeds _apply_tool_state() -- only the Sprites
# page has one (Levels paints with a single fixed tile color); set by
# _setup_page_tabs()'s tab handler.
var _active_color_picker: ColorPicker = null

var _tile_canvas: TileCanvas
const LEVEL_API_BASE := "https://codecade.co.za/tag/api/levels"
const GAME_ASSETS_API_BASE := "https://codecade.co.za/tag/api/game-assets"
const PUBLISH_KEY_PATH := "user://asset_publish_key.txt"

# Multiple independent levels -- "+ New Level" starts a fresh blank map,
# each entry in the sidebar switches _tile_canvas to that map's own cells/
# spawn_points/platforms (plain Dictionary/Array, mutated in place by
# TileCanvas, so switching is just repointing _tile_canvas's own
# references, no explicit save-back step needed the way PixelCanvas's
# Image-swapping tools need).
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
# than tiles need to stay comfortably on-screen.

var icons_tab_button: Button
var icons_page: HBoxContainer
var icons_toolbar: Container
var icons_canvas_holder: CenterContainer
var icons_color_picker: ColorPicker
var _icon_images: Array[Image] = [] # index-matched to ICON_TYPE_NAMES
var _current_icon_index := -1
var _icon_select_buttons: Array[Button] = []

# Every button/panel/slider's own 9-patch box art (see UIStyle.button_box()/
# panel_box()/style_slider() and tools/build_chrome_art.gd) -- the last
# runtime-generated UI visual in the app, now paintable like everything
# else. Unlike every other category on this page, each key here is its
## own real shape/size (a button box isn't the same size as a slider
## groove), so this uses a per-key CHROME_SIZES array instead of one
## shared *_SIZE constant.
const CHROME_KEYS := Categories.CHROME_KEYS
const CHROME_NAMES := ["Button", "Panel", "Slider Groove", "Slider Fill"]
const CHROME_SIZES := [Vector2i(32, 32), Vector2i(40, 40), Vector2i(20, 14), Vector2i(20, 14)]
const CHROME_ART_DIR := "res://assets/icons/chrome"
const CHROME_ZOOM := 10
var _chrome_images: Array[Image] = [] # index-matched to CHROME_KEYS
var _current_chrome_index := -1
var _chrome_select_buttons: Array[Button] = []

# The 3 tiles a MovingPlatform assembles itself from left-to-right (see
# levels/moving_platform.gd/GameAssetCategories.PLATFORM_KEYS) -- all 3 the
# same fixed 10x10 size, unlike Chrome's per-piece CHROME_SIZES. A much
# higher zoom than Chrome's own (10) since 10px is otherwise far too small
# to paint into comfortably.
const PLATFORM_KEYS := Categories.PLATFORM_KEYS
const PLATFORM_NAMES := ["Left", "Middle", "Right"]
const PLATFORM_TILE_SIZE := 10
const PLATFORM_ART_DIR := "res://assets/icons/platform"
const PLATFORM_ZOOM := 32
var _platform_images: Array[Image] = [] # index-matched to PLATFORM_KEYS
var _current_platform_index := -1
var _platform_select_buttons: Array[Button] = []

var _import_file_dialog: FileDialog

func _ready() -> void:
	# 860 wasn't tall enough: Title + PageTabRow + BottomRow (~213px) plus a
	# page's own right-hand color column -- a stock ColorPicker alone wants
	# ~700px -- already summed to more than the old window's usable height
	# on the default Levels page, before any tab-specific content. Since
	# VBox's full-rect anchoring can't shrink below its children's minimum
	# size, that overflow silently pushed everything above it up the page.
	get_window().size = Vector2i(1300, 940)
	get_window().title = "Tag Art Tool"
	UIStyle.add_background(self)
	UIStyle.style_line_edit(level_name_edit)
	UIStyle.style_line_edit(publish_key_edit)
	_setup_page_tabs()
	_build_level_page()
	_build_icons_page()
	export_button.pressed.connect(_on_export_pressed)
	UIStyle.style_button(export_button, UIStyle.COLOR_ACCENT)
	# Levels (the default open tab) publishes via its own PublishLevelButton,
	# not the shared bottom-row Export Edits button -- that only applies to
	# the Sprites tab (see _setup_page_tabs()'s icons_tab_button handler).
	export_button.visible = false
	_load_publish_key()
	publish_key_edit.text_changed.connect(_save_publish_key)
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

## 2 tabs -- Levels / Sprites. IconsTabButton/IconsPage isn't in the .tscn --
## built and inserted alongside LevelTabButton entirely in code, so there's
## nothing scene-file-specific about how it's wired in.
func _setup_page_tabs() -> void:
	var tab_row: HBoxContainer = level_tab_button.get_parent()
	icons_tab_button = Button.new()
	icons_tab_button.custom_minimum_size = Vector2(140, 38)
	icons_tab_button.toggle_mode = true
	icons_tab_button.text = "Sprites"
	tab_row.add_child(icons_tab_button)

	var tab_group := ButtonGroup.new()
	level_tab_button.button_group = tab_group
	icons_tab_button.button_group = tab_group
	UIStyle.style_button(level_tab_button, UIStyle.COLOR_SANDBOX, 10)
	UIStyle.style_button(icons_tab_button, UIStyle.COLOR_LOCAL, 10)
	level_tab_button.pressed.connect(func():
		level_page.visible = true
		icons_page.visible = false
		export_button.visible = false
	)
	icons_tab_button.pressed.connect(func():
		level_page.visible = false
		icons_page.visible = true
		export_button.visible = true
		_active_color_picker = icons_color_picker
		_apply_tool_state()
	)
func _section_label(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", 12)
	l.add_theme_color_override("font_color", Color(0.7, 0.72, 0.78))
	return l

func _delete_button(on_delete: Callable) -> Button:
	var btn := Button.new()
	btn.text = "x"
	btn.custom_minimum_size = Vector2(28, 0)
	UIStyle.style_button(btn, UIStyle.COLOR_RANKED, 8, false)
	btn.pressed.connect(on_delete)
	return btn

## Builds the full tool suite into `container` (the Sprites page's
## `icons_toolbar`) -- pixel-art tools (shapes, selection, mirror,
## transforms, palette actions, zoom, all driven through _current_canvas/
## _apply_tool_state()). The Level page paints tile cells instead (see
## _build_level_page()'s own small Paint/Erase toolbar, driven directly by
## TileCanvas.tool) so it doesn't go through this. Wrapped in an
## HFlowContainer so the button set wraps to as many rows as the panel
## needs instead of overflowing a single fixed-height HBoxContainer.
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
	UIStyle.style_button(select_btn, UIStyle.COLOR_ACCENT, 8)
	select_btn.pressed.connect(func(): _tile_canvas.tool = TileCanvas.Tool.EDIT)
	level_toolbar.add_child(select_btn)

	level_toolbar.add_child(VSeparator.new())

	var clear_btn := Button.new()
	clear_btn.text = "Clear"
	UIStyle.style_button(clear_btn, UIStyle.COLOR_NEUTRAL, 8)
	clear_btn.pressed.connect(func(): _tile_canvas.clear())
	level_toolbar.add_child(clear_btn)

	UIStyle.style_button(publish_level_button, UIStyle.COLOR_ACCENT)
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

## Live-publish -- goes straight to the shared level catalog with no review
## step, immediately selectable by any host (see host_setup.gd's map
## dropdown).
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
		"%s/%s/upload" % [LEVEL_API_BASE, PlayerIdentity.client_id], ["Content-Type: application/json"], HTTPClient.METHOD_POST, body
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

## Builds the Sprites page entirely in code (no .tscn changes -- see the
## file header): a left-hand list of the 6 procedural mode-bar icon types
## plus the 4 chrome pieces, a canvas panel driven by the shared
## _build_shared_toolbar/_current_canvas machinery, and its own ColorPicker
## (Levels doesn't use one, so this needs its own to stay usable -- see
## _active_color_picker). Icons/chrome are baked and painted in white/
## grayscale (see the file header comment) since they're re-tinted per
## usage at runtime -- the right-panel help text below says so directly,
## since painting a specific hue here would silently look wrong in-game
## rather than erroring anywhere obvious.
func _build_icons_page() -> void:
	var vbox: VBoxContainer = level_page.get_parent()
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

	var chrome_spacer := Control.new()
	chrome_spacer.custom_minimum_size = Vector2(0, 8)
	select_box.add_child(chrome_spacer)

	# Same shared ButtonGroup again -- picking a chrome piece here
	# deselects whichever other section was active.
	select_box.add_child(_section_label("CHROME (BUTTON/PANEL/SLIDER)"))
	_chrome_select_buttons.clear()
	for i in CHROME_NAMES.size():
		var btn := Button.new()
		btn.text = CHROME_NAMES[i]
		btn.toggle_mode = true
		btn.button_group = icon_group
		btn.custom_minimum_size = Vector2(0, 32)
		UIStyle.style_button(btn, UIStyle.COLOR_ACCENT, 10, false)
		btn.pressed.connect(_show_chrome.bind(i))
		select_box.add_child(btn)
		_chrome_select_buttons.append(btn)

	var platform_spacer := Control.new()
	platform_spacer.custom_minimum_size = Vector2(0, 8)
	select_box.add_child(platform_spacer)

	# Same shared ButtonGroup again -- picking a platform tile here
	# deselects whichever other section was active.
	select_box.add_child(_section_label("PLATFORM (MOVING PLATFORM TILES)"))
	_platform_select_buttons.clear()
	for i in PLATFORM_NAMES.size():
		var btn := Button.new()
		btn.text = PLATFORM_NAMES[i]
		btn.toggle_mode = true
		btn.button_group = icon_group
		btn.custom_minimum_size = Vector2(0, 32)
		UIStyle.style_button(btn, UIStyle.COLOR_SANDBOX, 10, false)
		btn.pressed.connect(_show_platform.bind(i))
		select_box.add_child(btn)
		_platform_select_buttons.append(btn)

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
	import_help.text = "Loads a PNG from disk into the clipboard -- use Selection > Stamp to place it anywhere on the current canvas, then Select + Move to drag it into position. Works on any page's canvas."
	import_help.autowrap_mode = TextServer.AUTOWRAP_WORD
	# See tiles_help above -- same fix.
	import_help.custom_minimum_size.x = 200
	import_help.add_theme_font_size_override("font_size", 12)
	import_help.add_theme_color_override("font_color", Color(0.7, 0.72, 0.78))
	right_box.add_child(import_help)

	_load_icon_images()
	_load_chrome_images()
	_load_platform_images()
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
	_current_chrome_index = -1
	_current_platform_index = -1
	for i in _icon_select_buttons.size():
		_icon_select_buttons[i].button_pressed = (i == index)
	for i in _chrome_select_buttons.size():
		_chrome_select_buttons[i].button_pressed = false
	for i in _platform_select_buttons.size():
		_platform_select_buttons[i].button_pressed = false
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

## Loads each chrome piece's baked 9-patch art (see CHROME_KEYS/
## tools/build_chrome_art.gd) if it's already been painted and committed,
## else a blank transparent canvas at that key's own real size (each key
## has a different shape/size, unlike every other category on this page)
## -- same "always something real or an honest blank canvas" rule every
## other section here follows.
func _load_chrome_images() -> void:
	_chrome_images.clear()
	for i in CHROME_KEYS.size():
		var key: String = CHROME_KEYS[i]
		var size: Vector2i = CHROME_SIZES[i]
		var path := "%s/%s.png" % [CHROME_ART_DIR, key]
		var img: Image
		if ResourceLoader.exists(path):
			var tex: Texture2D = load(path)
			img = tex.get_image() if tex else null
			if img:
				img.convert(Image.FORMAT_RGBA8)
		if not img:
			img = Image.create(size.x, size.y, false, Image.FORMAT_RGBA8)
			img.fill(Color(0, 0, 0, 0))
		_chrome_images.append(img)

func _show_chrome(index: int) -> void:
	_current_chrome_index = index
	_current_icon_index = -1
	_current_platform_index = -1
	for i in _icon_select_buttons.size():
		_icon_select_buttons[i].button_pressed = false
	for i in _chrome_select_buttons.size():
		_chrome_select_buttons[i].button_pressed = (i == index)
	for i in _platform_select_buttons.size():
		_platform_select_buttons[i].button_pressed = false
	for child in icons_canvas_holder.get_children():
		icons_canvas_holder.remove_child(child)
		child.queue_free()
	var canvas = PixelCanvasScene.new(_chrome_images[index], CHROME_ZOOM)
	icons_canvas_holder.add_child(canvas)
	canvas.painted.connect(_on_painted)
	canvas.painted.connect(func(): _chrome_images[index] = canvas.image)
	canvas.color_picked.connect(_on_eyedropper_picked)
	_current_canvas = canvas
	_apply_tool_state()

## Same "baked art if it exists, else a flat placeholder" rule
## _load_chrome_images() follows, except the fallback here is the platform's
## own real flat color (matching moving_platform.gd's own fallback) instead
## of a blank transparent square -- a platform tile always renders as
## *something* solid in-game even before anyone's painted it, so previewing
## that same solid color here (rather than blank) is the honest starting
## point.
func _load_platform_images() -> void:
	_platform_images.clear()
	for key in PLATFORM_KEYS:
		var path := "%s/%s.png" % [PLATFORM_ART_DIR, key]
		var img: Image
		if ResourceLoader.exists(path):
			var tex: Texture2D = load(path)
			img = tex.get_image() if tex else null
			if img:
				img.convert(Image.FORMAT_RGBA8)
		if not img:
			img = Image.create(PLATFORM_TILE_SIZE, PLATFORM_TILE_SIZE, false, Image.FORMAT_RGBA8)
			img.fill(Color(0.85, 0.55, 0.2, 1))
		_platform_images.append(img)

func _show_platform(index: int) -> void:
	_current_platform_index = index
	_current_icon_index = -1
	_current_chrome_index = -1
	for i in _icon_select_buttons.size():
		_icon_select_buttons[i].button_pressed = false
	for i in _chrome_select_buttons.size():
		_chrome_select_buttons[i].button_pressed = false
	for i in _platform_select_buttons.size():
		_platform_select_buttons[i].button_pressed = (i == index)
	for child in icons_canvas_holder.get_children():
		icons_canvas_holder.remove_child(child)
		child.queue_free()
	var canvas = PixelCanvasScene.new(_platform_images[index], PLATFORM_ZOOM)
	icons_canvas_holder.add_child(canvas)
	canvas.painted.connect(_on_painted)
	canvas.painted.connect(func(): _platform_images[index] = canvas.image)
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

## No-op now that Items (the only page that ever consumed a post-paint
## hook, to refresh its live big-preview panel) is gone -- still connected
## from every Sprites-page canvas builder (_show_icon/_show_chrome) so
## adding a future post-paint hook doesn't mean re-wiring each one again.
func _on_painted() -> void:
	pass

func _load_publish_key() -> void:
	if FileAccess.file_exists(PUBLISH_KEY_PATH):
		var f := FileAccess.open(PUBLISH_KEY_PATH, FileAccess.READ)
		if f:
			publish_key_edit.text = f.get_as_text().strip_edges()

func _save_publish_key(_new_text: String) -> void:
	var f := FileAccess.open(PUBLISH_KEY_PATH, FileAccess.WRITE)
	if f:
		f.store_string(publish_key_edit.text.strip_edges())

## Pushes one of the game's own built-in art categories (icons/chrome --
## see GameAssetCategories) straight to the relay, gated by the key in
## publish_key_edit -- see relay-server/server.js's "HTTP: game assets"
## section. `body` is the request payload the category's endpoint expects:
## {imageBase64} for icons, {images} (a key->base64 dict) for chrome.
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

	if not _chrome_images.is_empty():
		# Same one-file-per-key shape as every other category.
		var chrome_out_dir := base_dir.path_join("edited_icons/chrome")
		DirAccess.make_dir_recursive_absolute(chrome_out_dir)
		for i in _chrome_images.size():
			_chrome_images[i].save_png(chrome_out_dir.path_join("%s.png" % CHROME_KEYS[i]))
		var f10 := FileAccess.open(chrome_out_dir.path_join("HOW_TO_SUBMIT.txt"), FileAccess.WRITE)
		if f10:
			f10.store_string(CHROME_INSTRUCTIONS_TEXT)
		status_parts.append(chrome_out_dir)

		var chrome_images_payload := {}
		for i in _chrome_images.size():
			if _image_has_content(_chrome_images[i]):
				chrome_images_payload[CHROME_KEYS[i]] = Marshalls.raw_to_base64(_chrome_images[i].save_png_to_buffer())
		if not chrome_images_payload.is_empty():
			status_label.text = "Publishing chrome art..."
			var chrome_result := await _publish_game_asset("chrome", {"images": chrome_images_payload})
			publish_parts.append("chrome (v%d)" % chrome_result.get("version", 0) if chrome_result.get("ok", false) else "chrome failed: %s" % chrome_result.get("error", ""))

	if not _platform_images.is_empty():
		# Same one-file-per-key shape as chrome. Unlike chrome/icons, a
		# platform tile's own "untouched" state is a flat solid color, not
		# transparent -- _image_has_content() would always be true here, so
		# every export always republishes all 3 tiles rather than only the
		# ones actually painted over. Harmless (worst case: an extra no-op
		# version bump with identical pixels) and matches the tile's own
		# always-something-visible nature.
		var platform_out_dir := base_dir.path_join("edited_icons/platform")
		DirAccess.make_dir_recursive_absolute(platform_out_dir)
		for i in _platform_images.size():
			_platform_images[i].save_png(platform_out_dir.path_join("%s.png" % PLATFORM_KEYS[i]))
		var f11 := FileAccess.open(platform_out_dir.path_join("HOW_TO_SUBMIT.txt"), FileAccess.WRITE)
		if f11:
			f11.store_string(PLATFORM_INSTRUCTIONS_TEXT)
		status_parts.append(platform_out_dir)

		var platform_images_payload := {}
		for i in _platform_images.size():
			platform_images_payload[PLATFORM_KEYS[i]] = Marshalls.raw_to_base64(_platform_images[i].save_png_to_buffer())
		status_label.text = "Publishing platform tiles..."
		var platform_result := await _publish_game_asset("platform", {"images": platform_images_payload})
		publish_parts.append("platform (v%d)" % platform_result.get("version", 0) if platform_result.get("ok", false) else "platform failed: %s" % platform_result.get("error", ""))

	if status_parts.is_empty():
		status_label.text = "Nothing to export yet -- paint an icon or chrome piece first."
	elif publish_parts.is_empty():
		status_label.text = "Exported to: " + ", ".join(status_parts)
	else:
		status_label.text = "Exported to: %s. Published live: %s." % [", ".join(status_parts), ", ".join(publish_parts)]

## Any non-fully-transparent pixel counts as "actually painted" -- a freshly
## created blank canvas (see _load_chrome_images) is 100% alpha=0.
func _image_has_content(img: Image) -> bool:
	var used_rect := img.get_used_rect()
	return used_rect.size.x > 0 and used_rect.size.y > 0
