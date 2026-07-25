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
var _team_view: TeamLobbyView
var _team_view_built_for_playlist := ""
var _map_vote_popup: MapVotePopup

func _ready() -> void:
	UIStyle.add_background(self, "lobby_room")
	UIStyle.style_button(ready_button, UIStyle.COLOR_ONLINE)
	UIStyle.style_button(start_button, UIStyle.COLOR_ONLINE)
	UIStyle.style_back_button(leave_button)

	ready_button.pressed.connect(_on_ready_pressed)
	start_button.pressed.connect(_on_start_pressed)
	leave_button.pressed.connect(_on_leave_pressed)
	NetworkManager.lobby_state_updated.connect(_on_lobby_state_updated)
	NetworkManager.match_started.connect(_on_match_started)
	NetworkManager.disconnected_from_server.connect(_on_disconnected)
	NetworkManager.map_vote_phase_started.connect(_on_map_vote_phase_started)
	NetworkManager.map_vote_phase_ended.connect(_on_map_vote_phase_ended)
	_map_vote_popup = MapVotePopupScene.new()
	add_child(_map_vote_popup)
	_build_share_address_panel()
	_on_lobby_state_updated(NetworkManager.current_lobby)

## Only built when NetworkManager.hosted_private_address is set -- i.e. this
## client just hosted a fresh Private match (see online_menu.gd/
## casual_matchmaker.gd) -- normal public lobbies (Casual/Ranked/joining a
## friend) have nothing to show here since there's no separate address to
## share, the relay directory already handles discovery for those.
func _build_share_address_panel() -> void:
	if NetworkManager.hosted_private_address.is_empty():
		return
	# A party's private match brings its members in automatically (see
	# PartyManager.queue_party()/casual_matchmaker.gd) -- nothing to
	# manually share, matching "no settings at all" for that case.
	if NetworkManager.current_lobby.get("is_party_private", false):
		return
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", UIStyle.panel_box(UIStyle.COLOR_ONLINE))
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)
	panel.add_child(box)
	var label := Label.new()
	label.text = "PRIVATE MATCH -- SHARE THIS ADDRESS"
	label.add_theme_font_size_override("font_size", 12)
	label.add_theme_color_override("font_color", Color(0.7, 0.72, 0.78))
	box.add_child(label)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	box.add_child(row)
	var address_edit := LineEdit.new()
	address_edit.name = "PrivateAddressEdit"
	address_edit.text = NetworkManager.hosted_private_address
	address_edit.editable = false
	address_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UIStyle.style_line_edit(address_edit)
	row.add_child(address_edit)
	var copy_btn := Button.new()
	copy_btn.text = "  Copy"
	UIStyle.style_button(copy_btn, UIStyle.COLOR_ONLINE, 8)
	UIStyle.prefix_icon(copy_btn, "copy", UIStyle.COLOR_ONLINE)
	copy_btn.pressed.connect(func(): DisplayServer.clipboard_set(NetworkManager.hosted_private_address))
	row.add_child(copy_btn)

	var vbox: VBoxContainer = lobby_name_label.get_parent()
	vbox.add_child(panel)
	vbox.move_child(panel, lobby_name_label.get_index() + 1)

## Map selection is a timed pop-up right before the match actually starts
## (see network_manager.gd's _begin_match_sequence), not a passive panel
## sitting in the lobby the whole time -- these two just show/update the
## shared popup; match_started (already handled below) fires on its own a
## few seconds later and moves on to match_intro.
func _on_map_vote_phase_started(duration: float) -> void:
	_map_vote_popup.start_voting(duration)

func _on_map_vote_phase_ended(chosen_level_id: String, countdown: float) -> void:
	_map_vote_popup.show_result(chosen_level_id, countdown)

func _on_lobby_state_updated(lobby: Dictionary) -> void:
	if lobby.is_empty():
		return
	lobby_name_label.text = lobby.name
	var lobby_playlist: String = lobby.get("playlist", "")
	var is_party_private: bool = lobby.get("is_party_private", false)
	# Any playlist lobby (team or FFA-headcount) auto-starts on fill server-
	# side (see network_manager.gd's _maybe_autostart_playlist_lobby) -- no
	# manual Start for either. Ready is purely cosmetic even for the
	# unrestricted "Free-for-all" case (server never gates Start on it), but
	# hiding it too for playlist lobbies avoids a toggle that does nothing.
	# A party's private match (is_party_private) auto-starts below the same
	# way -- no manual Start/Ready for it either, though it still gets the
	# same map-vote pop-up (below) as any other match before the reveal.
	start_button.visible = lobby.host_peer == NetworkManager.my_peer_id and lobby_playlist.is_empty() and not is_party_private
	ready_button.visible = lobby_playlist.is_empty() and not is_party_private
	# Bots (see network_manager.gd's _on_bot_fill_timeout) never live in
	# lobby.members -- merge them in here so the vote popup's ballot row
	# shows a slot for every actual voter, not just the real connected ones.
	var voters: Dictionary = lobby.get("members", {}).duplicate()
	voters.merge(lobby.get("bots", {}))
	_map_vote_popup.set_roster(voters)
	_map_vote_popup.set_votes(lobby.get("map_votes", {}))
	# Normally driven entirely by the one-shot map_vote_phase_started RPC
	# (_on_map_vote_phase_started below) -- but a party follower can reach
	# this scene (see party_manager.gd's _on_follow_in_lobby) AFTER the
	# leader's own client already triggered start_match() and the vote
	# phase began, since the follower's own connect-then-join round trip is
	# real network latency the leader's fast local loopback never pays.
	# Signals aren't buffered for late connections, so that RPC's emission
	# is simply missed if this scene wasn't loaded and listening yet --
	# lobby.voting_open is part of this same lobby_state sync instead,
	# which (unlike the one-shot RPC) keeps arriving throughout the vote
	# window, so a follower who missed the original signal still catches up
	# here. Guarded to only actually (re)start the popup once: calling
	# start_voting() again would reset its own countdown back to the full
	# duration on every subsequent lobby_state update (e.g. every time
	# another player's vote comes in).
	if lobby.get("voting_open", false) and not _map_vote_popup.is_voting_active():
		_map_vote_popup.start_voting(NetworkManager.MAP_VOTE_DURATION_SEC)

	# The leader's own client drives this -- same _server_start_match RPC
	# and host-only check a manual Start press uses, just triggered the
	# instant the whole party (not just this one connection) has arrived
	# rather than waiting on a button. Safe to call more than once as more
	# members trickle in: _server_start_match no-ops once lobby.in_match.
	if is_party_private and lobby.host_peer == NetworkManager.my_peer_id and lobby.members.size() >= PartyManager.party_size():
		NetworkManager.start_match()

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
	# A party-queued lobby only ever exists because PartyManager told this
	# client to connect here (see party_manager.gd's _on_connect_now) -- if
	# this player is still in that party, leaving the lobby without also
	# telling the relay meant they'd disconnect from the match but keep
	# showing up as a party member everywhere else (Friends screen, future
	# invites) until they separately found the dedicated Leave Party button.
	if not PartyManager.current_party.is_empty():
		PartyManager.leave_party()
	NetworkManager.leave_lobby()
	NetworkManager.disconnect_from_server()
	get_tree().change_scene_to_file("res://main/online_menu.tscn")

func _on_disconnected() -> void:
	get_tree().change_scene_to_file("res://main/online_menu.tscn")
