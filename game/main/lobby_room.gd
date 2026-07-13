extends Control

const MATCH_INTRO_SCENE := preload("res://main/match_intro.tscn")

@onready var lobby_name_label: Label = $VBox/LobbyNameLabel
@onready var roster_list: ItemList = $VBox/RosterList
@onready var ready_button: Button = $VBox/ReadyButton
@onready var start_button: Button = $VBox/StartButton
@onready var leave_button: Button = $VBox/LeaveButton

var _is_ready := false

func _ready() -> void:
	ready_button.pressed.connect(_on_ready_pressed)
	start_button.pressed.connect(_on_start_pressed)
	leave_button.pressed.connect(_on_leave_pressed)
	NetworkManager.lobby_state_updated.connect(_on_lobby_state_updated)
	NetworkManager.match_started.connect(_on_match_started)
	NetworkManager.disconnected_from_server.connect(_on_disconnected)
	_on_lobby_state_updated(NetworkManager.current_lobby)

func _on_lobby_state_updated(lobby: Dictionary) -> void:
	if lobby.is_empty():
		return
	lobby_name_label.text = lobby.name
	roster_list.clear()
	for peer_id in lobby.members.keys():
		var member: Dictionary = lobby.members[peer_id]
		var host_tag := "  [host]" if peer_id == lobby.host_peer else ""
		var ready_tag := "  READY" if member.ready else ""
		roster_list.add_item("%s%s%s" % [member.username, host_tag, ready_tag])
	start_button.visible = lobby.host_peer == NetworkManager.my_peer_id

func _on_ready_pressed() -> void:
	_is_ready = not _is_ready
	ready_button.text = "Unready" if _is_ready else "Ready"
	NetworkManager.set_ready(_is_ready)

func _on_start_pressed() -> void:
	NetworkManager.start_match()

func _on_match_started(_lobby_id: int, my_id: int, roster: Dictionary) -> void:
	var scene := MATCH_INTRO_SCENE.instantiate()
	scene.setup(my_id, roster)
	get_tree().root.add_child(scene)
	get_tree().current_scene.queue_free()
	get_tree().current_scene = scene

func _on_leave_pressed() -> void:
	NetworkManager.leave_lobby()
	get_tree().change_scene_to_file("res://main/lobby_browser.tscn")

func _on_disconnected() -> void:
	get_tree().change_scene_to_file("res://main/main_menu.tscn")
