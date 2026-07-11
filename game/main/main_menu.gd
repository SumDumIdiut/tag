extends Control

@onready var local_button: Button = $VBox/LocalButton
@onready var online_button: Button = $VBox/OnlineButton

func _ready() -> void:
	local_button.pressed.connect(_on_local_pressed)
	online_button.pressed.connect(_on_online_pressed)

func _on_local_pressed() -> void:
	get_tree().change_scene_to_file("res://main/local_menu.tscn")

func _on_online_pressed() -> void:
	get_tree().change_scene_to_file("res://main/online_menu.tscn")
