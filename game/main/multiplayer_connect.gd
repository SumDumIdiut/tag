extends Control

const UIStyle := preload("res://ui/ui_style.gd")

@onready var username_edit: LineEdit = $VBox/UsernameEdit
@onready var address_edit: LineEdit = $VBox/AddressEdit
@onready var connect_button: Button = $VBox/ConnectButton
@onready var back_button: Button = $VBox/BackButton
@onready var status_label: Label = $VBox/StatusLabel

func _ready() -> void:
	UIStyle.add_background(self)
	UIStyle.style_button(connect_button, UIStyle.COLOR_ONLINE)
	UIStyle.style_back_button(back_button)

	username_edit.text = GameSettings.saved_username
	connect_button.pressed.connect(_on_connect_pressed)
	back_button.pressed.connect(_on_back_pressed)
	NetworkManager.connected_to_server.connect(_on_connected)
	NetworkManager.connection_failed.connect(_on_connection_failed)
	NetworkManager.disconnected_from_server.connect(_on_connection_failed)

func _on_connect_pressed() -> void:
	var display_name := username_edit.text
	var address := address_edit.text.strip_edges()
	if address.is_empty():
		address = "127.0.0.1:9000"

	status_label.text = "Connecting..."
	connect_button.disabled = true
	GameSettings.save_username(display_name)
	NetworkManager.set_username(display_name)
	NetworkManager.start_client(address, display_name)

func _on_connected() -> void:
	get_tree().change_scene_to_file("res://main/lobby_browser.tscn")

func _on_connection_failed() -> void:
	status_label.text = "Couldn't connect. Check the address and try again."
	connect_button.disabled = false

func _on_back_pressed() -> void:
	get_tree().change_scene_to_file("res://main/online_menu.tscn")
