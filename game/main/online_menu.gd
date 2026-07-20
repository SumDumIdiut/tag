extends Control

const UIStyle := preload("res://ui/ui_style.gd")

@onready var bar_row: HBoxContainer = $VBox/BarRow
@onready var quick_play_button: Button = $VBox/BarRow/QuickPlayButton
@onready var ranked_button: Button = $VBox/BarRow/RankedButton
@onready var browse_button: Button = $VBox/BarRow/BrowseButton
@onready var host_button: Button = $VBox/BarRow/HostButton
@onready var back_button: Button = $VBox/BackButton

const BAR_ICON_PATH := "res://assets/icons/online_bars/%s.png"

func _ready() -> void:
	UIStyle.add_background(self, "online_menu")
	# Plain vertical bars, same shape as the top-level mode cards
	# (main_menu.gd's BAR_SIZE) but no glow behind them -- just the
	# button's own color fill/border, whatever's actually painted there via
	# style_button, nothing procedural layered on top of it.
	UIStyle.style_button(quick_play_button, UIStyle.COLOR_QUICKPLAY, 18)
	UIStyle.style_button(ranked_button, UIStyle.COLOR_RANKED, 18)
	UIStyle.style_button(browse_button, UIStyle.COLOR_ONLINE, 18)
	UIStyle.style_button(host_button, UIStyle.COLOR_ONLINE, 18)
	UIStyle.style_back_button(back_button)
	_add_bar_icon(quick_play_button, "quick_play")
	_add_bar_icon(ranked_button, "ranked")
	_add_bar_icon(browse_button, "browse_servers")
	_add_bar_icon(host_button, "host_server")

	quick_play_button.pressed.connect(_on_quick_play_pressed)
	ranked_button.pressed.connect(_on_ranked_pressed)
	browse_button.pressed.connect(_on_browse_pressed)
	host_button.pressed.connect(_on_host_pressed)
	back_button.pressed.connect(_on_back_pressed)
	_build_friends_bar()

## Moves a bar's own text down into a bottom label band and adds a small
## icon (see tools/generate_menu_art.gd's bar-icon output) above it --
## same icon-then-label composition the mode-button whole-image art uses
## (main_menu.gd), just layered onto the existing styled button instead of
## replacing it with a painted image outright.
func _add_bar_icon(btn: Button, icon_key: String) -> void:
	var icon_path := BAR_ICON_PATH % icon_key
	if not ResourceLoader.exists(icon_path):
		return
	var label_text := btn.text
	btn.text = ""
	btn.clip_contents = true

	var layout := VBoxContainer.new()
	layout.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layout.set_anchors_preset(Control.PRESET_FULL_RECT)
	layout.alignment = BoxContainer.ALIGNMENT_CENTER
	layout.add_theme_constant_override("separation", 16)
	btn.add_child(layout)

	var icon_wrap := CenterContainer.new()
	icon_wrap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	icon_wrap.custom_minimum_size = Vector2(0, 72)
	layout.add_child(icon_wrap)
	var icon := TextureRect.new()
	icon.texture = load(icon_path)
	icon.custom_minimum_size = Vector2(64, 64)
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	icon_wrap.add_child(icon)

	var label := Label.new()
	label.text = label_text
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.autowrap_mode = TextServer.AUTOWRAP_WORD
	label.custom_minimum_size.x = 150
	label.add_theme_font_size_override("font_size", 18)
	label.add_theme_color_override("font_color", Color.WHITE)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layout.add_child(label)

## Built in code rather than added to the .tscn -- appended as a 5th bar
## in BarRow, same "extend an existing hand-authored screen without
## touching its node tree" approach the Art Tool's later pages already
## used.
func _build_friends_bar() -> void:
	var friends_button := Button.new()
	friends_button.text = "Friends"
	friends_button.custom_minimum_size = quick_play_button.custom_minimum_size
	friends_button.clip_contents = true
	UIStyle.style_button(friends_button, UIStyle.COLOR_SHOP, 18)
	friends_button.pressed.connect(func(): get_tree().change_scene_to_file("res://main/friends_menu.tscn"))
	bar_row.add_child(friends_button)
	_add_bar_icon(friends_button, "friends")

func _on_quick_play_pressed() -> void:
	get_tree().change_scene_to_file("res://main/quick_play.tscn")

func _on_ranked_pressed() -> void:
	get_tree().change_scene_to_file("res://main/ranked_queue.tscn")

func _on_browse_pressed() -> void:
	get_tree().change_scene_to_file("res://main/server_browser.tscn")

func _on_host_pressed() -> void:
	get_tree().change_scene_to_file("res://main/host_setup.tscn")

func _on_back_pressed() -> void:
	get_tree().change_scene_to_file("res://main/main_menu.tscn")
