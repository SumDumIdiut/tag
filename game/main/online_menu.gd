extends Control

const UIStyle := preload("res://ui/ui_style.gd")

@onready var bar_row: HBoxContainer = $VBox/BarRow
@onready var quick_play_button: Button = $VBox/BarRow/QuickPlayButton
@onready var ranked_button: Button = $VBox/BarRow/RankedButton
@onready var browse_button: Button = $VBox/BarRow/BrowseButton
@onready var host_button: Button = $VBox/BarRow/HostButton
@onready var back_button: Button = $VBox/BackButton

func _ready() -> void:
	UIStyle.add_background(self)
	# Plain vertical bars, same shape as the top-level mode cards
	# (main_menu.gd's BAR_SIZE) but no glow behind them -- just the
	# button's own color fill/border, whatever's actually painted there via
	# style_button, nothing procedural layered on top of it.
	UIStyle.style_button(quick_play_button, UIStyle.COLOR_QUICKPLAY, 18)
	UIStyle.style_button(ranked_button, UIStyle.COLOR_RANKED, 18)
	UIStyle.style_button(browse_button, UIStyle.COLOR_ONLINE, 18)
	UIStyle.style_button(host_button, UIStyle.COLOR_ONLINE, 18)
	UIStyle.style_back_button(back_button)
	for btn in [quick_play_button, ranked_button, browse_button, host_button]:
		btn.add_theme_font_size_override("font_size", 18)

	quick_play_button.pressed.connect(_on_quick_play_pressed)
	ranked_button.pressed.connect(_on_ranked_pressed)
	browse_button.pressed.connect(_on_browse_pressed)
	host_button.pressed.connect(_on_host_pressed)
	back_button.pressed.connect(_on_back_pressed)
	_build_friends_bar()

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
	friends_button.add_theme_font_size_override("font_size", 18)
	friends_button.pressed.connect(func(): get_tree().change_scene_to_file("res://main/friends_menu.tscn"))
	bar_row.add_child(friends_button)

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
