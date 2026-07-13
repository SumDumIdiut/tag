extends Control

const UIStyle := preload("res://ui/ui_style.gd")

@onready var lobby_list: ItemList = $VBox/LobbyList
@onready var name_edit: LineEdit = $VBox/CreateRow/NameEdit
@onready var max_players_spin: SpinBox = $VBox/CreateRow/MaxPlayersSpin
@onready var create_button: Button = $VBox/CreateRow/CreateButton
@onready var join_button: Button = $VBox/JoinButton
@onready var disconnect_button: Button = $VBox/DisconnectButton

var _lobbies: Array = []

func _ready() -> void:
	UIStyle.add_background(self)
	UIStyle.style_button(join_button, UIStyle.COLOR_ONLINE)
	UIStyle.style_button(create_button, UIStyle.COLOR_ONLINE, 8)
	UIStyle.style_back_button(disconnect_button)

	create_button.pressed.connect(_on_create_pressed)
	join_button.pressed.connect(_on_join_pressed)
	disconnect_button.pressed.connect(_on_disconnect_pressed)
	lobby_list.item_activated.connect(func(_idx): _on_join_pressed())
	NetworkManager.lobby_list_updated.connect(_on_lobby_list_updated)
	NetworkManager.lobby_state_updated.connect(_on_lobby_state_updated)
	NetworkManager.disconnected_from_server.connect(_on_disconnected)

func _on_lobby_list_updated(lobbies: Array) -> void:
	_lobbies = lobbies
	lobby_list.clear()
	for lobby in lobbies:
		lobby_list.add_item("%s  (%d/%d)" % [lobby.name, lobby.player_count, lobby.max_players])

func _on_create_pressed() -> void:
	NetworkManager.create_lobby(name_edit.text, int(max_players_spin.value))

func _on_join_pressed() -> void:
	var selected := lobby_list.get_selected_items()
	if selected.is_empty():
		return
	var lobby = _lobbies[selected[0]]
	NetworkManager.join_lobby(lobby.id)

func _on_lobby_state_updated(_lobby: Dictionary) -> void:
	get_tree().change_scene_to_file("res://main/lobby_room.tscn")

func _on_disconnect_pressed() -> void:
	NetworkManager.disconnect_from_server()
	get_tree().change_scene_to_file("res://main/main_menu.tscn")

func _on_disconnected() -> void:
	get_tree().change_scene_to_file("res://main/main_menu.tscn")
