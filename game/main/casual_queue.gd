extends Control

# "Find Casual Match" for a specific playlist -- near-duplicate of
# ranked_queue.gd's shape, with two real differences: a casual server
# doesn't auto-join a connecting client into its playlist lobby the way
# NetworkManager.is_ranked_server does server-side (see
# _server_register_player), so this screen has to explicitly call
# quick_join_lobby(_playlist_id) once connected; and there's no ELO/tier
# anything to fetch or show, so match_intro's roster cards just render
# plain (ranked=false).

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
# See ranked_queue.gd's identical field for why every async callback below
# checks this first -- NetworkManager's signals outlive this screen.
var _cancelled := false

func _ready() -> void:
	_playlist_id = GameSettings.selected_casual_playlist
	UIStyle.add_background(self, "casual_queue")
	$VBox/StatusPanel.add_theme_stylebox_override("panel", UIStyle.panel_box(UIStyle.COLOR_QUICKPLAY))
	UIStyle.style_back_button(back_button)
	if PlaylistCatalog.is_team_mode(_playlist_id):
		_build_team_view()
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

	NetworkManager.connected_to_server.connect(_on_connected)
	NetworkManager.connection_failed.connect(_on_join_existing_failed)
	NetworkManager.match_started.connect(_on_match_started)
	NetworkManager.lobby_state_updated.connect(_on_lobby_state_updated)
	NetworkManager.map_vote_phase_started.connect(_on_map_vote_phase_started)
	NetworkManager.map_vote_phase_ended.connect(_on_map_vote_phase_ended)

	status_label.text = "Finding a %s match..." % PlaylistCatalog.display_name(_playlist_id)
	if _http.request(DIRECTORY_URL) != OK:
		_host_new_casual_server()

func _build_team_view() -> void:
	$VBox.visible = false
	_team_view = TeamLobbyViewScene.new()
	_team_view.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_team_view.playlist_id = _playlist_id
	_team_view.ranked = false
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

func _on_map_vote_phase_started(duration: float) -> void:
	_map_vote_popup.start_voting(duration)

func _on_map_vote_phase_ended(chosen_level_id: String, countdown: float) -> void:
	_map_vote_popup.show_result(chosen_level_id, countdown)

func _on_lobby_state_updated(lobby: Dictionary) -> void:
	if _cancelled or lobby.is_empty():
		return
	_map_vote_popup.set_votes(lobby.get("map_votes", {}))
	if not _team_view:
		return
	_team_view.my_id = NetworkManager.my_peer_id
	_team_view.set_roster(lobby.get("members", {}))

func _on_directory_response(result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	if _cancelled:
		return
	if result != HTTPRequest.RESULT_SUCCESS or response_code != 200:
		_host_new_casual_server()
		return
	var parsed = JSON.parse_string(body.get_string_from_utf8())
	if typeof(parsed) != TYPE_ARRAY:
		_host_new_casual_server()
		return
	var best = null
	for s in parsed:
		if s.get("ranked", false):
			continue
		if s.get("playlist", "") != _playlist_id:
			continue
		if s.playerCount >= s.maxPlayers:
			continue
		if best == null or s.playerCount > best.playerCount:
			best = s
	if best == null:
		_host_new_casual_server()
		return
	_server_name = str(best.name)
	status_label.text = "Joining a %s match..." % PlaylistCatalog.display_name(_playlist_id)
	NetworkManager.set_username(_username)
	NetworkManager.start_client_auto(RELAY_JOIN_BASE + str(best.id), _username, str(best.get("transport", "ws")))

func _on_join_existing_failed() -> void:
	if _cancelled:
		return
	status_label.text = "That server just went offline -- hosting a new one instead..."
	_host_new_casual_server()

func _host_new_casual_server() -> void:
	if _cancelled:
		return
	status_label.text = "No open %s matches -- starting one..." % PlaylistCatalog.display_name(_playlist_id)
	_server_name = "%s's Match" % _username
	_spawner.spawn(_server_name, _username, ["--playlist=%s" % _playlist_id])

func _on_spawn_failed(reason: String) -> void:
	if _cancelled:
		return
	status_label.text = reason

func _on_connected() -> void:
	if _cancelled:
		return
	status_label.text = "Waiting for more players..."
	NetworkManager.quick_join_lobby(_playlist_id)
	# See ranked_queue.gd's identical call for what this does and why it's
	# a no-op for anyone but the party leader.
	if PartyManager.is_leader():
		PartyManager.queue_party(_server_name, "casual", _playlist_id)

func _on_match_started(_lobby_id: int, my_id: int, roster: Dictionary, level_id: String, playlist_id: String = "") -> void:
	if _cancelled:
		return
	var scene := MATCH_INTRO_SCENE.instantiate()
	scene.setup(my_id, roster, level_id, false, playlist_id)
	get_tree().root.add_child(scene)
	get_tree().current_scene.queue_free()
	get_tree().current_scene = scene

func _on_back_pressed() -> void:
	_cancelled = true
	_http.cancel_request()
	NetworkManager.disconnect_from_server()
	_spawner.kill_child()
	get_tree().change_scene_to_file("res://main/online_menu.tscn")
