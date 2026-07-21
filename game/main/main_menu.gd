extends Control

const ModeIconScene := preload("res://ui/mode_icon.gd")
const CharacterPreviewScene := preload("res://ui/character_preview.gd")
const UIStyle := preload("res://ui/ui_style.gd")
const UpdateCheckerScript := preload("res://net/update_checker.gd")
const UpdatePromptScene := preload("res://ui/update_prompt.gd")
const GameAssetUpdaterScript := preload("res://net/game_asset_updater.gd")
const GameAssetUpdatePromptScene := preload("res://ui/game_asset_update_prompt.gd")

# Two top-level destinations, each fanning out to its own related
# sub-screens instead of a flat list of unrelated modes: ONLINE covers
# everything network-related (quick play, ranked, browse/host/direct
# connect -- see online_menu.tscn), LOCAL is bot practice. Shop doesn't fit
# "a mode to play" so it isn't one of the bars -- see the small corner
# button built in _ready() instead. skin/hat pick which real in-game
# character (see CharacterPreview) fronts each bar -- built-in skin colors
# line up 1:1 with the bar accents.
const MODES := [
	{"key": "online", "label": "ONLINE", "icon": "globe", "color": UIStyle.COLOR_ONLINE, "skin": "green", "hat": "", "scene": "res://main/online_menu.tscn"},
	{"key": "local", "label": "LOCAL", "icon": "controller", "color": UIStyle.COLOR_LOCAL, "skin": "blue", "hat": "", "scene": "res://main/local_menu.tscn"},
]

const BAR_SIZE := Vector2(190, 360)

@onready var mode_bar: HBoxContainer = $VBox/ModeBar

func _ready() -> void:
	UIStyle.add_background(self, "main_menu")
	for mode in MODES:
		mode_bar.add_child(_build_bar(mode))
	_build_shop_button()
	_build_account_button()
	_check_for_update()
	_check_for_asset_update()

func _check_for_update() -> void:
	var checker := UpdateCheckerScript.new("Tag.exe")
	add_child(checker)
	checker.check_completed.connect(_on_update_check_completed)
	checker.check()

func _on_update_check_completed(result: Dictionary) -> void:
	if not result.get("available", false):
		return
	var prompt := UpdatePromptScene.new()
	add_child(prompt)
	prompt.setup(result.version, result.download_url)

## Separate from the whole-binary check above -- tiles/icons/mode-button-art
## published from the Art Tool (see game_asset_updater.gd) don't need a new
## release or a relaunch, just a couple small PNGs applied live.
func _check_for_asset_update() -> void:
	var updater := GameAssetUpdaterScript.new()
	add_child(updater)
	updater.check_completed.connect(_on_asset_check_completed)
	updater.check()

func _on_asset_check_completed(result: Dictionary) -> void:
	if not result.get("available", false):
		return
	var prompt := GameAssetUpdatePromptScene.new()
	add_child(prompt)
	prompt.setup(result.categories, result.manifest)
	# A freshly downloaded chrome update only affects buttons built after the
	# download (see GameAssetOverrides) -- rebuild the bar so it doesn't need
	# leaving and coming back to the main menu to pick it up.
	prompt.applied.connect(_rebuild_mode_bar)

func _rebuild_mode_bar() -> void:
	for child in mode_bar.get_children():
		mode_bar.remove_child(child)
		child.queue_free()
	for mode in MODES:
		mode_bar.add_child(_build_bar(mode))

func _build_bar(mode: Dictionary) -> Button:
	var color: Color = mode["color"]
	var btn := Button.new()
	btn.text = ""
	btn.custom_minimum_size = BAR_SIZE
	btn.focus_mode = Control.FOCUS_ALL
	btn.clip_contents = true
	UIStyle.style_button(btn, color, 18)
	btn.pressed.connect(_on_mode_pressed.bind(mode["scene"]))

	# A soft radial glow behind the character, in the bar's own color --
	# gives the portrait a bit of depth/stage-lighting instead of sitting
	# flat against the panel, and reads as "this button is alive" even
	# before the hover animation kicks in.
	var glow := TextureRect.new()
	glow.mouse_filter = Control.MOUSE_FILTER_IGNORE
	glow.texture = UIStyle.glow_texture(color)
	glow.stretch_mode = TextureRect.STRETCH_SCALE
	glow.set_anchors_preset(Control.PRESET_CENTER_TOP)
	glow.position = Vector2(-85, -10)
	glow.custom_minimum_size = Vector2(170, 170)
	glow.size = Vector2(170, 170)
	btn.add_child(glow)

	var layout := VBoxContainer.new()
	layout.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layout.set_anchors_preset(Control.PRESET_FULL_RECT)
	layout.alignment = BoxContainer.ALIGNMENT_CENTER
	layout.add_theme_constant_override("separation", 18)
	btn.add_child(layout)

	var portrait_wrap := CenterContainer.new()
	portrait_wrap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	portrait_wrap.custom_minimum_size = Vector2(0, 160)
	layout.add_child(portrait_wrap)
	var portrait = CharacterPreviewScene.new()
	portrait.skin_id = mode["skin"]
	portrait.hat_id = mode["hat"]
	portrait.zoom = 2.6
	portrait.custom_minimum_size = Vector2(120, 154)
	portrait_wrap.add_child(portrait)

	var label := Label.new()
	label.text = mode["label"]
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", 20)
	label.add_theme_color_override("font_color", Color.WHITE)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layout.add_child(label)

	return btn

## A small persistent button, not one of the three mode bars -- customizing
## your character isn't itself "a mode to play," it's available no matter
## which mode you're about to pick, so it lives in its own corner instead of
## competing with the three real destinations for equal visual weight.
func _build_shop_button() -> void:
	var btn := Button.new()
	btn.text = "  Customize"
	btn.custom_minimum_size = Vector2(150, 44)
	btn.focus_mode = Control.FOCUS_ALL
	UIStyle.style_button(btn, UIStyle.COLOR_SHOP, 10)
	btn.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	btn.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	btn.position = Vector2(-170, 24)
	btn.pressed.connect(_on_mode_pressed.bind("res://main/shop.tscn"))

	var icon_wrap := Control.new()
	icon_wrap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	icon_wrap.set_anchors_preset(Control.PRESET_CENTER_LEFT)
	icon_wrap.position = Vector2(14, -10)
	icon_wrap.custom_minimum_size = Vector2(20, 20)
	btn.add_child(icon_wrap)
	var icon := ModeIconScene.new()
	icon.icon_type = "tag"
	icon.icon_color = UIStyle.COLOR_SHOP
	icon.custom_minimum_size = Vector2(18, 20)
	icon_wrap.add_child(icon)

	add_child(btn)

## Mirrors _build_shop_button()'s corner-button treatment, opposite corner --
## logging in is optional and never gates play (see login_screen.gd), so it
## gets the same "always available, doesn't compete with the three real
## mode bars" placement as Customize.
func _build_account_button() -> void:
	var btn := Button.new()
	btn.text = "  Account"
	btn.custom_minimum_size = Vector2(150, 44)
	btn.focus_mode = Control.FOCUS_ALL
	UIStyle.style_button(btn, UIStyle.COLOR_ONLINE, 10)
	btn.set_anchors_preset(Control.PRESET_TOP_LEFT)
	btn.position = Vector2(20, 24)
	btn.pressed.connect(_on_mode_pressed.bind("res://main/login_screen.tscn"))

	var icon_wrap := Control.new()
	icon_wrap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	icon_wrap.set_anchors_preset(Control.PRESET_CENTER_LEFT)
	icon_wrap.position = Vector2(14, -10)
	icon_wrap.custom_minimum_size = Vector2(20, 20)
	btn.add_child(icon_wrap)
	var icon := ModeIconScene.new()
	icon.icon_type = "star"
	icon.icon_color = UIStyle.COLOR_ONLINE
	icon.custom_minimum_size = Vector2(18, 20)
	icon_wrap.add_child(icon)

	add_child(btn)

func _on_mode_pressed(scene_path: String) -> void:
	get_tree().change_scene_to_file(scene_path)
