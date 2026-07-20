extends Control

const UIStyle := preload("res://ui/ui_style.gd")

@onready var bar_row: HBoxContainer = $VBox/BarRow
@onready var quick_play_button: Button = $VBox/BarRow/QuickPlayButton
@onready var ranked_button: Button = $VBox/BarRow/RankedButton
@onready var browse_button: Button = $VBox/BarRow/BrowseButton
@onready var host_button: Button = $VBox/BarRow/HostButton
@onready var back_button: Button = $VBox/BackButton

# Whole-bar custom art (background scene, icon, character, label all
# painted as one image) for these 5 bars -- same "%s" whole-button-art
# pattern main_menu.gd's mode buttons already use, just here instead of
# being 2 top-level modes. "%s" is the bar's own key (see BAR_KEYS below).
const ONLINE_BAR_ART_PATH := "res://assets/icons/online_bars/%s.png"

func _ready() -> void:
	UIStyle.add_background(self, "online_menu")
	_style_bar(quick_play_button, UIStyle.COLOR_QUICKPLAY, "quick_play", "Quick Play")
	_style_bar(ranked_button, UIStyle.COLOR_RANKED, "ranked", "Ranked")
	_style_bar(browse_button, UIStyle.COLOR_ONLINE, "browse_servers", "Browse Servers")
	_style_bar(host_button, UIStyle.COLOR_ONLINE, "host_server", "Host Server")
	UIStyle.style_back_button(back_button)

	quick_play_button.pressed.connect(_on_quick_play_pressed)
	ranked_button.pressed.connect(_on_ranked_pressed)
	browse_button.pressed.connect(_on_browse_pressed)
	host_button.pressed.connect(_on_host_pressed)
	back_button.pressed.connect(_on_back_pressed)
	_build_friends_bar()

## A downloaded override (see game_asset_updater.gd) takes priority over
## whatever got baked into this build at CI time, same fallback chain
## main_menu.gd's mode-button art already uses. Falls back to the plain
## styled button (just text, no art) if neither exists -- never a hard
## failure for a bar nobody's painted yet.
func _style_bar(btn: Button, color: Color, key: String, label_text: String) -> void:
	btn.text = label_text
	UIStyle.style_button(btn, color, 18)
	btn.add_theme_font_size_override("font_size", 18)

	var tex: Texture2D = GameAssetOverrides.load_override_texture(GameAssetOverrides.online_bar_override_path(key))
	if not tex:
		var path := ONLINE_BAR_ART_PATH % key
		if ResourceLoader.exists(path):
			tex = load(path)
	if not tex:
		return

	btn.text = ""
	btn.clip_contents = true
	var art := TextureRect.new()
	art.mouse_filter = Control.MOUSE_FILTER_IGNORE
	art.texture = tex
	art.stretch_mode = TextureRect.STRETCH_SCALE
	art.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	art.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	btn.add_child(art)

## Built in code rather than added to the .tscn -- appended as a 5th bar
## in BarRow, same "extend an existing hand-authored screen without
## touching its node tree" approach the Art Tool's later pages already
## used.
func _build_friends_bar() -> void:
	var friends_button := Button.new()
	friends_button.custom_minimum_size = quick_play_button.custom_minimum_size
	friends_button.clip_contents = true
	friends_button.pressed.connect(func(): get_tree().change_scene_to_file("res://main/friends_menu.tscn"))
	bar_row.add_child(friends_button)
	_style_bar(friends_button, UIStyle.COLOR_SHOP, "friends", "Friends")

func _on_quick_play_pressed() -> void:
	get_tree().change_scene_to_file("res://main/quick_play.tscn")

func _on_ranked_pressed() -> void:
	get_tree().change_scene_to_file("res://main/ranked_playlist_select.tscn")

func _on_browse_pressed() -> void:
	get_tree().change_scene_to_file("res://main/server_browser.tscn")

func _on_host_pressed() -> void:
	get_tree().change_scene_to_file("res://main/host_setup.tscn")

func _on_back_pressed() -> void:
	get_tree().change_scene_to_file("res://main/main_menu.tscn")
