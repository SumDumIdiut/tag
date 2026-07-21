extends Control

const UIStyle := preload("res://ui/ui_style.gd")
const MATCH_INTRO_SCENE := preload("res://main/match_intro.tscn")

@onready var username_edit: LineEdit = $VBox/UsernameEdit
@onready var address_edit: LineEdit = $VBox/AddressEdit
@onready var connect_button: Button = $VBox/ButtonRow/ConnectButton
@onready var spectate_button: Button = $VBox/ButtonRow/SpectateButton
@onready var back_button: Button = $VBox/BackButton
@onready var status_label: Label = $VBox/StatusLabel

# NetworkManager is an autoload -- its signals outlive this screen, so a late
# lobby_state_updated (from the CONNECT_ONE_SHOT below) can still fire after
# Back is pressed and pull the player into lobby_room anyway. See
# casual_matchmaker.gd's _cancelled for the full explanation.
var _cancelled := false
## Set by _on_spectate_pressed(), read by _on_connected() to decide whether
## to quick_join_lobby (Connect) or just wait for a match already in
## progress to be pushed to us (Watch) -- start_spectator()/start_client()
## both end in the same connected_to_server signal, so this is the only way
## to tell the two apart once it fires.
var _watching := false

func _ready() -> void:
	UIStyle.add_background(self, "multiplayer_connect")
	UIStyle.style_button(connect_button, UIStyle.COLOR_ONLINE)
	UIStyle.style_button(spectate_button, UIStyle.COLOR_NEUTRAL)
	UIStyle.style_back_button(back_button)
	UIStyle.apply_bar_art(connect_button, "action_bars", "connect")
	UIStyle.apply_bar_art(spectate_button, "action_bars", "watch")
	UIStyle.apply_bar_art(back_button, "action_bars", "back")
	UIStyle.style_line_edit(username_edit)
	UIStyle.style_line_edit(address_edit)

	username_edit.text = GameSettings.saved_username
	connect_button.pressed.connect(_on_connect_pressed)
	spectate_button.pressed.connect(_on_spectate_pressed)
	back_button.pressed.connect(_on_back_pressed)
	NetworkManager.connected_to_server.connect(_on_connected)
	NetworkManager.connection_failed.connect(_on_connection_failed)
	NetworkManager.disconnected_from_server.connect(_on_connection_failed)
	NetworkManager.spectate_failed.connect(_on_spectate_failed)
	NetworkManager.match_started.connect(_on_spectate_match_started)

func _on_connect_pressed() -> void:
	var display_name := username_edit.text
	var address := address_edit.text.strip_edges()
	if address.is_empty():
		address = "127.0.0.1:9000"

	status_label.text = "Connecting..."
	connect_button.disabled = true
	spectate_button.disabled = true
	GameSettings.save_username(display_name)
	NetworkManager.set_username(display_name)
	NetworkManager.start_client(address, display_name)

## Same address field, but registers as a read-only spectator instead of a
## player -- for watching a match at a known address directly (a LAN/
## loopback host, say) without needing it listed in the public server
## browser first. See NetworkManager.start_spectator().
func _on_spectate_pressed() -> void:
	var display_name := username_edit.text
	var address := address_edit.text.strip_edges()
	if address.is_empty():
		address = "127.0.0.1:9000"

	status_label.text = "Connecting..."
	connect_button.disabled = true
	spectate_button.disabled = true
	GameSettings.save_username(display_name)
	NetworkManager.set_username(display_name)
	_watching = true
	NetworkManager.start_spectator(address)

func _on_connected() -> void:
	if _cancelled:
		return
	if _watching:
		status_label.text = "Waiting for a match in progress..."
		return
	status_label.text = "Joining match..."
	NetworkManager.lobby_state_updated.connect(_on_in_lobby, CONNECT_ONE_SHOT)
	NetworkManager.quick_join_lobby()

func _on_in_lobby(_lobby: Dictionary) -> void:
	if _cancelled:
		return
	get_tree().change_scene_to_file("res://main/lobby_room.tscn")

## Only start_spectator() (via _on_spectate_pressed above) ever leaves this
## screen's connection sitting with no lobby to join, so this firing at all
## means we're spectating.
func _on_spectate_match_started(_lobby_id: int, my_id: int, roster: Dictionary, level_id: String) -> void:
	if not _watching or _cancelled:
		return
	var scene := MATCH_INTRO_SCENE.instantiate()
	scene.setup(my_id, roster, level_id)
	get_tree().root.add_child(scene)
	get_tree().current_scene.queue_free()
	get_tree().current_scene = scene

func _on_spectate_failed() -> void:
	if _cancelled:
		return
	status_label.text = "No match is currently in progress at that address."
	NetworkManager.disconnect_from_server()
	_watching = false
	connect_button.disabled = false
	spectate_button.disabled = false

func _on_connection_failed() -> void:
	status_label.text = "Couldn't connect. Check the address and try again."
	connect_button.disabled = false
	spectate_button.disabled = false
	_watching = false

func _on_back_pressed() -> void:
	_cancelled = true
	if NetworkManager.lobby_state_updated.is_connected(_on_in_lobby):
		NetworkManager.lobby_state_updated.disconnect(_on_in_lobby)
	NetworkManager.disconnect_from_server()
	get_tree().change_scene_to_file("res://main/online_menu.tscn")
