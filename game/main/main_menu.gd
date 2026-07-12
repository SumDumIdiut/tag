extends Control

@onready var local_button: Button = $VBox/LocalButton
@onready var online_button: Button = $VBox/OnlineButton
@onready var shop_button: Button = $VBox/ShopButton

func _ready() -> void:
	local_button.pressed.connect(_on_local_pressed)
	online_button.pressed.connect(_on_online_pressed)
	shop_button.pressed.connect(_on_shop_pressed)

func _on_local_pressed() -> void:
	get_tree().change_scene_to_file("res://main/local_menu.tscn")

func _on_online_pressed() -> void:
	get_tree().change_scene_to_file("res://main/online_menu.tscn")

func _on_shop_pressed() -> void:
	get_tree().change_scene_to_file("res://main/shop.tscn")
