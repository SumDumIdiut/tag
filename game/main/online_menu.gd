extends Control

const UIStyle := preload("res://ui/ui_style.gd")

@onready var quick_play_button: Button = $VBox/MatchmakingRow/QuickPlayButton
@onready var ranked_button: Button = $VBox/MatchmakingRow/RankedButton
@onready var browse_button: Button = $VBox/BrowseButton
@onready var host_button: Button = $VBox/HostButton
@onready var direct_connect_button: Button = $VBox/DirectConnectButton
@onready var back_button: Button = $VBox/BackButton

func _ready() -> void:
	UIStyle.add_background(self)
	# Quick Play/Ranked keep their own identity color (matching their main
	# menu bar, back when they had one) even though they now live one level
	# under Online's own green -- they're still visually "their own thing,"
	# just reached from here instead of the top level. Same glow-card
	# treatment the top-level mode bars use (see main_menu.gd's _build_bar)
	# for the two primary destinations here, so this screen reads as a
	# continuation of that same visual language instead of a plainer
	# generic-button screen one level in.
	UIStyle.style_button(quick_play_button, UIStyle.COLOR_QUICKPLAY, 18)
	UIStyle.style_button(ranked_button, UIStyle.COLOR_RANKED, 18)
	_add_card_glow(quick_play_button, UIStyle.COLOR_QUICKPLAY)
	_add_card_glow(ranked_button, UIStyle.COLOR_RANKED)
	_enlarge_label(quick_play_button, 20)
	_enlarge_label(ranked_button, 20)

	UIStyle.style_button(browse_button, UIStyle.COLOR_ONLINE, 14)
	UIStyle.style_button(host_button, UIStyle.COLOR_ONLINE, 14)
	_add_card_glow(browse_button, UIStyle.COLOR_ONLINE, 120)
	_add_card_glow(host_button, UIStyle.COLOR_ONLINE, 120)
	_enlarge_label(browse_button, 17)
	_enlarge_label(host_button, 17)

	UIStyle.style_button(direct_connect_button, UIStyle.COLOR_NEUTRAL, 12)
	UIStyle.style_back_button(back_button)

	quick_play_button.pressed.connect(_on_quick_play_pressed)
	ranked_button.pressed.connect(_on_ranked_pressed)
	browse_button.pressed.connect(_on_browse_pressed)
	host_button.pressed.connect(_on_host_pressed)
	direct_connect_button.pressed.connect(_on_direct_connect_pressed)
	back_button.pressed.connect(_on_back_pressed)
	_build_friends_button()

## Same soft radial glow the top-level mode bars sit on top of, centered
## behind whatever's already in the button rather than positioned for one
## specific fixed size -- online_menu's cards aren't all the same
## dimensions the way the three mode bars are.
func _add_card_glow(btn: Button, color: Color, size: int = 170) -> void:
	var glow := TextureRect.new()
	glow.mouse_filter = Control.MOUSE_FILTER_IGNORE
	glow.texture = UIStyle.glow_texture(color, size)
	glow.stretch_mode = TextureRect.STRETCH_SCALE
	glow.set_anchors_preset(Control.PRESET_CENTER)
	glow.position = Vector2(-size / 2.0, -size / 2.0)
	glow.custom_minimum_size = Vector2(size, size)
	glow.size = Vector2(size, size)
	btn.add_child(glow)
	btn.move_child(glow, 0)

## Button.text alone stays at the theme's default size -- these cards are
## big enough now that the stock size reads small/lost in the middle of
## them, unlike the original compact buttons this replaced.
func _enlarge_label(btn: Button, font_size: int) -> void:
	btn.add_theme_font_size_override("font_size", font_size)

## Built in code rather than added to the .tscn -- inserted right before
## Back, same "extend an existing hand-authored screen without touching its
## node tree" approach the Art Tool's later pages already used.
func _build_friends_button() -> void:
	var friends_button := Button.new()
	friends_button.text = "Friends"
	friends_button.custom_minimum_size = direct_connect_button.custom_minimum_size
	UIStyle.style_button(friends_button, UIStyle.COLOR_SHOP, 12)
	friends_button.pressed.connect(func(): get_tree().change_scene_to_file("res://main/friends_menu.tscn"))
	var vbox: VBoxContainer = back_button.get_parent()
	vbox.add_child(friends_button)
	vbox.move_child(friends_button, back_button.get_index())

func _on_quick_play_pressed() -> void:
	get_tree().change_scene_to_file("res://main/quick_play.tscn")

func _on_ranked_pressed() -> void:
	get_tree().change_scene_to_file("res://main/ranked_queue.tscn")

func _on_browse_pressed() -> void:
	get_tree().change_scene_to_file("res://main/server_browser.tscn")

func _on_host_pressed() -> void:
	get_tree().change_scene_to_file("res://main/host_setup.tscn")

func _on_direct_connect_pressed() -> void:
	get_tree().change_scene_to_file("res://main/multiplayer_connect.tscn")

func _on_back_pressed() -> void:
	get_tree().change_scene_to_file("res://main/main_menu.tscn")
