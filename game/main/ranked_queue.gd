extends Control

# "Find Ranked Match": joins an existing open ranked server if one's already
# listed, or silently hosts one and waits in it if not -- mirrors
# casual_matchmaker.gd's shape, but a ranked server auto-adds/auto-starts on
# its own (see NetworkManager.is_ranked_server), so this screen never has to
# call create/join/quick-join lobby RPCs itself, just connect and wait.

const MATCH_INTRO_SCENE := preload("res://main/match_intro.tscn")
const DIRECTORY_URL := "https://codecade.co.za/tag/api/servers"
const RELAY_JOIN_BASE := "wss://codecade.co.za/tag/relay/join/"

const UIStyle := preload("res://ui/ui_style.gd")
const PlaylistCatalog := preload("res://net/playlist_catalog.gd")
const TeamLobbyViewScene := preload("res://ui/team_lobby_view.gd")
const MapVotePopupScene := preload("res://ui/map_vote_popup.gd")

@onready var status_label: Label = $VBox/StatusPanel/StatusBox/StatusLabel
@onready var back_button: Button = $VBox/BackButton

var _http: HTTPRequest
var _spawner: LocalServerSpawner
var _username := ""
var _playlist_id := ""
var _server_name := "" # whichever server we ended up on (found or spawned) -- see PartyManager.queue_party()
var _team_view: TeamLobbyView
var _map_vote_popup: MapVotePopup
# NetworkManager is an autoload -- its signals outlive this screen, so a
# match_started (or a late directory/connect response) can still fire after
# Cancel is pressed and yank the player into a match anyway. Every async
# callback below checks this first. See casual_matchmaker.gd's _cancelled
# for the full explanation (same bug class, found and fixed there first).
var _cancelled := false

func _ready() -> void:
	_playlist_id = GameSettings.selected_ranked_playlist
	UIStyle.add_glow_background(self, UIStyle.COLOR_RANKED, PlaylistCatalog.team_count(_playlist_id))
	$VBox/StatusPanel.add_theme_stylebox_override("panel", UIStyle.panel_box(UIStyle.COLOR_RANKED))
	UIStyle.style_back_button(back_button)
	# team_count == 2, not is_team_mode() -- is_team_mode() is keyed on
	# team_SIZE > 1 (players per side), which is false for 1v1 (team_size
	# 1, team_count 2) even though it's just as "2-sided" as 2v2 and reads
	# identically in TeamLobbyView's red/blue split. Using team_size here
	# meant 1v1 queueing never got this view at all, only the plain status
	# text -- confirmed live, comparing screenshots of the two side by side.
	if PlaylistCatalog.team_count(_playlist_id) == 2:
		_build_team_view()
	# Built AFTER _build_team_view() -- a later sibling draws on top, and
	# _team_view is a full-rect background (see team_lobby_view.gd's split
	# background), which would otherwise completely cover a visible popup.
	_map_vote_popup = MapVotePopupScene.new()
	add_child(_map_vote_popup)

	back_button.pressed.connect(_on_back_pressed)
	_username = GameSettings.saved_username
	GameSettings.save_username(_username)

	_http = HTTPRequest.new()
	add_child(_http)
	_http.request_completed.connect(_on_directory_response)

	_spawner = LocalServerSpawner.new()
	add_child(_spawner)
	_spawner.failed.connect(_on_spawn_failed)

	# Covers both paths -- joining an already-open ranked server, and the
	# spawner's own internal start_client() once a freshly-hosted one comes
	# up -- since both ultimately go through the same NetworkManager signal.
	NetworkManager.connected_to_server.connect(_on_connected)
	NetworkManager.connection_failed.connect(_on_join_existing_failed)
	NetworkManager.match_started.connect(_on_match_started)
	NetworkManager.lobby_state_updated.connect(_on_lobby_state_updated)
	NetworkManager.map_vote_phase_started.connect(_on_map_vote_phase_started)
	NetworkManager.map_vote_phase_ended.connect(_on_map_vote_phase_ended)

	status_label.text = "Finding a %s match..." % PlaylistCatalog.display_name(_playlist_id)
	if _http.request(DIRECTORY_URL) != OK:
		_host_new_ranked_server()

## The live team-fill view (2 sides, empty slots as dark placeholders) --
## only built for team-mode playlists (1v1/2v2); 1v1v1/1v1v1v1 have no
## "sides" and keep the plain status label the .tscn already has.
func _build_team_view() -> void:
	$VBox.visible = false
	_team_view = TeamLobbyViewScene.new()
	_team_view.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_team_view.playlist_id = _playlist_id
	_team_view.ranked = true
	_team_view.my_id = NetworkManager.my_peer_id
	add_child(_team_view)
	_team_view.set_roster({})

	var cancel_btn := Button.new()
	cancel_btn.text = "Cancel"
	cancel_btn.custom_minimum_size = Vector2(200, 40)
	cancel_btn.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	cancel_btn.position = Vector2(-100, -50)
	UIStyle.style_back_button(cancel_btn)
	cancel_btn.pressed.connect(_on_back_pressed)
	add_child(cancel_btn)

## Map selection is a timed pop-up right before the match actually starts
## (see network_manager.gd's _begin_match_sequence), not a passive panel
## sitting on this screen the whole time it's waiting.
func _on_map_vote_phase_started(duration: float) -> void:
	# For an FFA playlist (no _team_view, see _build_team_view -- that path
	# already hides $VBox itself), the "Finding a match..." status text and
	# its pulsing star icon were still sitting there the whole time, bleeding
	# through the popup's semi-transparent dim layer once voting starts --
	# a stray red star (COLOR_RANKED) and leftover "Waiting..." text visible
	# behind the vote buttons. Nothing here needs it anymore once a match is
	# actually found.
	$VBox.visible = false
	_map_vote_popup.start_voting(duration)

func _on_map_vote_phase_ended(chosen_level_id: String, countdown: float) -> void:
	_map_vote_popup.show_result(chosen_level_id, countdown)

func _on_lobby_state_updated(lobby: Dictionary) -> void:
	if _cancelled or lobby.is_empty():
		return
	# Bots (see network_manager.gd's _on_bot_fill_timeout) never live in
	# lobby.members -- merge them in here so the vote popup's ballot row
	# shows a slot for every actual voter, not just the real connected ones.
	var voters: Dictionary = lobby.get("members", {}).duplicate()
	voters.merge(lobby.get("bots", {}))
	_map_vote_popup.set_roster(voters)
	_map_vote_popup.set_votes(lobby.get("map_votes", {}))
	if not _team_view:
		return
	_team_view.my_id = NetworkManager.my_peer_id
	_team_view.set_roster(lobby.get("members", {}))

func _on_directory_response(result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	if _cancelled:
		return
	if result != HTTPRequest.RESULT_SUCCESS or response_code != 200:
		_host_new_ranked_server()
		return
	var parsed = JSON.parse_string(body.get_string_from_utf8())
	if typeof(parsed) != TYPE_ARRAY:
		_host_new_ranked_server()
		return
	var best = null
	for s in parsed:
		if not s.get("ranked", false):
			continue
		if s.get("playlist", "") != _playlist_id:
			continue
		if s.playerCount >= s.maxPlayers:
			continue
		if best == null or s.playerCount > best.playerCount:
			best = s
	if best == null:
		_host_new_ranked_server()
		return
	_server_name = str(best.name)
	status_label.text = "Joining a %s match..." % PlaylistCatalog.display_name(_playlist_id)
	NetworkManager.set_username(_username)
	NetworkManager.start_client_auto(RELAY_JOIN_BASE + str(best.id), _username, str(best.get("transport", "ws")))

func _on_join_existing_failed() -> void:
	if _cancelled:
		return
	status_label.text = "That server just went offline -- hosting a new one instead..."
	_host_new_ranked_server()

func _host_new_ranked_server() -> void:
	if _cancelled:
		return
	status_label.text = "No open %s matches -- starting one..." % PlaylistCatalog.display_name(_playlist_id)
	_server_name = "%s's Ranked Match" % _username
	_spawner.spawn(_server_name, _username, ["--ranked", "--playlist=%s" % _playlist_id])

func _on_spawn_failed(reason: String) -> void:
	if _cancelled:
		return
	status_label.text = reason

func _on_connected() -> void:
	if _cancelled:
		return
	status_label.text = "Waiting for more players..."
	# Whichever of us actually found/hosted the server tells the rest of the
	# party to come along too -- see PartyManager.queue_party(). A solo
	# player or a non-leader party member is_leader() == false, so this is a
	# no-op for everyone except whoever's actually driving the party's queue.
	if PartyManager.is_leader():
		PartyManager.queue_party(_server_name, "ranked", _playlist_id)

func _on_match_started(_lobby_id: int, my_id: int, roster: Dictionary, level_id: String, playlist_id: String = "") -> void:
	if _cancelled:
		return
	var scene := MATCH_INTRO_SCENE.instantiate()
	scene.setup(my_id, roster, level_id, true, playlist_id)
	get_tree().root.add_child(scene)
	get_tree().current_scene.queue_free()
	get_tree().current_scene = scene

func _on_back_pressed() -> void:
	_cancelled = true
	# See casual_matchmaker.gd's cancel() for why both of these matter:
	# an in-flight HTTPRequest blocks the engine on its background I/O
	# thread when freed mid-request, and disconnecting our own connection
	# before (not after) killing any server we spawned avoids a graceful
	# close handshake hanging against an already-dead server.
	_http.cancel_request()
	NetworkManager.disconnect_from_server()
	_spawner.kill_child()
	get_tree().change_scene_to_file("res://main/online_menu.tscn")

