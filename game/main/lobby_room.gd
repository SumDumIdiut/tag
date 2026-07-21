extends Control

const MATCH_INTRO_SCENE := preload("res://main/match_intro.tscn")
const UIStyle := preload("res://ui/ui_style.gd")
const PlaylistCatalog := preload("res://net/playlist_catalog.gd")
const TeamLobbyViewScene := preload("res://ui/team_lobby_view.gd")
const MapVotePopupScene := preload("res://ui/map_vote_popup.gd")

@onready var lobby_name_label: Label = $VBox/LobbyNameLabel
@onready var roster_list: ItemList = $VBox/RosterList
@onready var ready_button: Button = $VBox/ReadyButton
@onready var start_button: Button = $VBox/StartButton
@onready var leave_button: Button = $VBox/LeaveButton

var _is_ready := false
var _chat_scrollback: RichTextLabel
var _chat_input: LineEdit
var _team_view: TeamLobbyView
var _team_view_built_for_playlist := ""
var _map_vote_popup: MapVotePopup

func _ready() -> void:
	UIStyle.add_background(self, "lobby_room")
	UIStyle.style_button(ready_button, UIStyle.COLOR_ONLINE)
	UIStyle.style_button(start_button, UIStyle.COLOR_ONLINE)
	UIStyle.style_back_button(leave_button)
	# ready_button intentionally has no painted art -- its label toggles
	# between "Ready"/"Unready" (see _on_ready_pressed), which baked art
	# can't represent for both states.
	UIStyle.apply_bar_art(start_button, "action_bars", "start_match")
	UIStyle.apply_bar_art(leave_button, "action_bars", "back")

	ready_button.pressed.connect(_on_ready_pressed)
	start_button.pressed.connect(_on_start_pressed)
	leave_button.pressed.connect(_on_leave_pressed)
	NetworkManager.lobby_state_updated.connect(_on_lobby_state_updated)
	NetworkManager.match_started.connect(_on_match_started)
	NetworkManager.disconnected_from_server.connect(_on_disconnected)
	NetworkManager.chat_message_received.connect(_on_chat_message_received)
	NetworkManager.map_vote_phase_started.connect(_on_map_vote_phase_started)
	NetworkManager.map_vote_phase_ended.connect(_on_map_vote_phase_ended)
	_map_vote_popup = MapVotePopupScene.new()
	add_child(_map_vote_popup)
	_build_chat_panel()
	_on_lobby_state_updated(NetworkManager.current_lobby)

## Map selection is a timed pop-up right before the match actually starts
## (see network_manager.gd's _begin_match_sequence), not a passive panel
## sitting in the lobby the whole time -- these two just show/update the
## shared popup; match_started (already handled below) fires on its own a
## few seconds later and moves on to match_intro.
func _on_map_vote_phase_started(duration: float) -> void:
	_map_vote_popup.start_voting(duration)

func _on_map_vote_phase_ended(chosen_level_id: String, countdown: float) -> void:
	_map_vote_popup.show_result(chosen_level_id, countdown)

## Built in code, not the .tscn -- inserted right after the roster list,
## same "extend an existing hand-authored screen without touching its node
## tree" approach the Art Tool's later pages and online_menu.gd's Friends
## button already used. Lobby-only (see NetworkManager.send_chat_message).
func _build_chat_panel() -> void:
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(0, 160)
	panel.add_theme_stylebox_override("panel", UIStyle.panel_box())
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)
	panel.add_child(box)

	_chat_scrollback = RichTextLabel.new()
	_chat_scrollback.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_chat_scrollback.scroll_following = true
	_chat_scrollback.bbcode_enabled = true
	box.add_child(_chat_scrollback)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	box.add_child(row)
	_chat_input = LineEdit.new()
	_chat_input.placeholder_text = "Say something..."
	_chat_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UIStyle.style_line_edit(_chat_input)
	_chat_input.text_submitted.connect(func(_t): _send_chat())
	row.add_child(_chat_input)
	var send_btn := Button.new()
	send_btn.text = "  Send"
	UIStyle.style_button(send_btn, UIStyle.COLOR_ONLINE, 8)
	send_btn.pressed.connect(_send_chat)
	row.add_child(send_btn)
	UIStyle.prefix_icon(send_btn, "send", UIStyle.COLOR_ONLINE)

	var vbox: VBoxContainer = roster_list.get_parent()
	vbox.add_child(panel)
	vbox.move_child(panel, roster_list.get_index() + 1)

func _send_chat() -> void:
	var text := _chat_input.text.strip_edges()
	if text.is_empty():
		return
	NetworkManager.send_chat_message(text)
	_chat_input.text = ""

func _on_chat_message_received(sender_username: String, text: String) -> void:
	_chat_scrollback.append_text("[b]%s:[/b] %s\n" % [sender_username.replace("[", "").replace("]", ""), text.replace("[", "").replace("]", "")])

func _on_lobby_state_updated(lobby: Dictionary) -> void:
	if lobby.is_empty():
		return
	lobby_name_label.text = lobby.name
	var lobby_playlist: String = lobby.get("playlist", "")
	# Any playlist lobby (team or FFA-headcount) auto-starts on fill server-
	# side (see network_manager.gd's _maybe_autostart_playlist_lobby) -- no
	# manual Start for either. Ready is purely cosmetic even for the
	# unrestricted "Free-for-all" case (server never gates Start on it), but
	# hiding it too for playlist lobbies avoids a toggle that does nothing.
	start_button.visible = lobby.host_peer == NetworkManager.my_peer_id and lobby_playlist.is_empty()
	ready_button.visible = lobby_playlist.is_empty()
	_map_vote_popup.set_votes(lobby.get("map_votes", {}))

	if PlaylistCatalog.is_team_mode(lobby_playlist):
		_ensure_team_view(lobby_playlist)
		_team_view.my_id = NetworkManager.my_peer_id
		_team_view.set_roster(lobby.members)
		return
	_teardown_team_view()
	roster_list.visible = true
	roster_list.clear()
	for peer_id in lobby.members.keys():
		var member: Dictionary = lobby.members[peer_id]
		var host_tag := "  [host]" if peer_id == lobby.host_peer else ""
		var ready_tag := "  READY" if member.ready else ""
		roster_list.add_item("%s%s%s" % [member.username, host_tag, ready_tag])

## Lazily built the first time a team-mode playlist lobby is seen -- replaces
## roster_list with the live team-card view (2 sides, empty slots as dark
## placeholders) the user asked for, filling in as players join.
func _ensure_team_view(lobby_playlist: String) -> void:
	if _team_view and _team_view_built_for_playlist == lobby_playlist:
		return
	_teardown_team_view()
	roster_list.visible = false
	_team_view = TeamLobbyViewScene.new()
	_team_view.custom_minimum_size = Vector2(0, 320)
	_team_view.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_team_view.playlist_id = lobby_playlist
	_team_view.ranked = false
	_team_view.accent_color = UIStyle.COLOR_ONLINE
	var vbox: VBoxContainer = roster_list.get_parent()
	vbox.add_child(_team_view)
	vbox.move_child(_team_view, roster_list.get_index() + 1)
	_team_view_built_for_playlist = lobby_playlist

func _teardown_team_view() -> void:
	if _team_view:
		_team_view.queue_free()
		_team_view = null
		_team_view_built_for_playlist = ""

func _on_ready_pressed() -> void:
	_is_ready = not _is_ready
	ready_button.text = "Unready" if _is_ready else "Ready"
	NetworkManager.set_ready(_is_ready)

func _on_start_pressed() -> void:
	NetworkManager.start_match()

func _on_match_started(_lobby_id: int, my_id: int, roster: Dictionary, level_id: String, playlist_id: String = "") -> void:
	var scene := MATCH_INTRO_SCENE.instantiate()
	scene.setup(my_id, roster, level_id, false, playlist_id)
	get_tree().root.add_child(scene)
	get_tree().current_scene.queue_free()
	get_tree().current_scene = scene

func _on_leave_pressed() -> void:
	NetworkManager.leave_lobby()
	NetworkManager.disconnect_from_server()
	get_tree().change_scene_to_file("res://main/online_menu.tscn")

func _on_disconnected() -> void:
	get_tree().change_scene_to_file("res://main/online_menu.tscn")
