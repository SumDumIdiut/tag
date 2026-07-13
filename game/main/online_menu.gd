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
	# just reached from here instead of the top level.
	UIStyle.style_button(quick_play_button, UIStyle.COLOR_QUICKPLAY)
	UIStyle.style_button(ranked_button, UIStyle.COLOR_RANKED)
	UIStyle.style_button(browse_button, UIStyle.COLOR_ONLINE)
	UIStyle.style_button(host_button, UIStyle.COLOR_ONLINE)
	UIStyle.style_button(direct_connect_button, UIStyle.COLOR_NEUTRAL)
	UIStyle.style_back_button(back_button)

	quick_play_button.pressed.connect(_on_quick_play_pressed)
	ranked_button.pressed.connect(_on_ranked_pressed)
	browse_button.pressed.connect(_on_browse_pressed)
	host_button.pressed.connect(_on_host_pressed)
	direct_connect_button.pressed.connect(_on_direct_connect_pressed)
	back_button.pressed.connect(_on_back_pressed)

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
