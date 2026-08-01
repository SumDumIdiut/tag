extends Node

# A real Godot client, driven entirely by command-line args, for scripted
# testing of actual live matches -- joins a real lobby, submits real input,
# receives real server state, exactly like a normal player, just with no
# window and a scripted action sequence instead of a human. This is
# deliberately NOT a reimplementation of the game's wire protocol: it reuses
# NetworkManager (the same autoload every real client uses) directly, so it
# speaks Godot's own internal MultiplayerAPI/SceneMultiplayer RPC format for
# free instead of hand-rolling it (that format is engine-internal, versioned,
# and not worth reverse-engineering -- see this tool's own header comment on
# WHY this approach was chosen over a from-scratch protocol client).
#
# Every significant event prints one line of the form "EVENT:<type>:<json>"
# to stdout so external tooling (a Python/Bash orchestrator launching many
# of these under different --user-data-dir identities) can grep/parse
# progress without needing to talk to this process directly at all -- no
# stdin/IPC channel, just watch the log.
#
# Run via (each instance needs its own --user-data-dir so it gets its own
# client_id.txt/session, exactly like local_server_spawner.gd already does
# for dedicated server processes):
#   godot --headless --user-data-dir <isolated dir> --path . res://tools/headless_client.tscn -- \
#     --relay=wss://codecade.co.za/tag/relay/join/<serverId> --username=TestBot01 \
#     --playlist=1v1 --duration=15
#
# Args (all optional except --relay):
#   --relay=<url>       URL to connect to (a resolved join address, NOT a
#                        server name -- resolve that separately, e.g. via
#                        the existing party_harness.py's directory/party
#                        flow, same as a real client would). Same address
#                        works for either --transport value below --
#                        start_client_auto() derives the right peer type
#                        from --transport, not from the URL itself.
#   --transport=<kind>  "ws" (default) or "webrtc" -- which
#                        NetworkManager.start_client_auto() path to take.
#                        Must match whatever transport the target server is
#                        actually running (--webrtc/--ws on server_main.gd),
#                        same requirement a real client has, just picked
#                        explicitly here instead of read from a directory
#                        listing.
#   --username=<name>   Display name (default: whatever GameSettings/session already has).
#   --playlist=<id>     Passed to quick_join_lobby() once connected -- empty
#                        string (default) means Free-for-all/private (no
#                        playlist restriction).
#   --duration=<sec>    How long to keep submitting input once a match
#                        starts before quitting (default 10).
#   --auto-start=<sec>  A free-for-all/private lobby (empty --playlist) never
#                        auto-starts (see network_manager.gd's
#                        _maybe_autostart_playlist_lobby) -- a real player
#                        has to press Start. If set, this client calls
#                        NetworkManager.start_match() itself this many
#                        seconds after first entering a not-yet-in-match
#                        lobby. Ignored once --playlist is non-empty (those
#                        already auto-start on their own).
#   --move=<pattern>    "idle" (default, no input at all -- just holds
#                        position, still receives/logs real state) or
#                        "wander" (alternates move_dir left/right every
#                        second, occasional jump -- enough to prove input
#                        actually reaches and affects the server sim).

const RELAY_JOIN_BASE := "wss://codecade.co.za/tag/relay/join/"

var _relay_url := ""
## "ws" (default) or "webrtc" -- which NetworkManager.start_client_auto()
## path to take, same as what a real client picks based on a matched
## server's directory-reported transport. Exists so this framework can
## actually exercise the WebRTC connect path directly (a specific server's
## transport is known up front here, unlike a real matchmaking client)
## instead of only ever testing WebSocket.
var _transport := "ws"
var _playlist_id := ""
var _duration_sec := 10.0
var _move_pattern := "idle"
var _auto_start_sec := -1.0
var _auto_start_armed := false
var _match_time_left := 0.0
var _in_match := false
var _wander_dir := 1
var _wander_timer := 0.0
var _state_log_timer := 0.0

func _ready() -> void:
	_parse_args()
	if _relay_url.is_empty():
		_log("FATAL", {"error": "no --relay= given"})
		get_tree().quit(1)
		return

	NetworkManager.connected_to_server.connect(_on_connected)
	NetworkManager.connection_failed.connect(_on_connection_failed)
	NetworkManager.disconnected_from_server.connect(_on_disconnected)
	NetworkManager.lobby_state_updated.connect(_on_lobby_state)
	NetworkManager.match_started.connect(_on_match_started)
	NetworkManager.match_state_received.connect(_on_match_state)
	NetworkManager.match_ended.connect(_on_match_ended)
	NetworkManager.map_vote_phase_started.connect(_on_vote_started)
	NetworkManager.map_vote_phase_ended.connect(_on_vote_ended)

	var username: String = GameSettings.saved_username if GameSettings.saved_username != "" else "HeadlessBot"
	NetworkManager.set_username(username)
	_log("CONNECTING", {"relay": _relay_url, "username": username, "transport": _transport})
	NetworkManager.start_client_auto(_relay_url, username, _transport)

func _parse_args() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--relay="):
			_relay_url = arg.substr(8)
		elif arg.begins_with("--username="):
			GameSettings.save_username(arg.substr(11))
		elif arg.begins_with("--playlist="):
			_playlist_id = arg.substr(11)
		elif arg.begins_with("--duration="):
			_duration_sec = arg.substr(11).to_float()
		elif arg.begins_with("--move="):
			_move_pattern = arg.substr(7)
		elif arg.begins_with("--auto-start="):
			_auto_start_sec = arg.substr(13).to_float()
		elif arg.begins_with("--transport="):
			_transport = arg.substr(12)

func _on_connected() -> void:
	_log("CONNECTED", {"peer_id": multiplayer.get_unique_id()})
	NetworkManager.quick_join_lobby(_playlist_id)

func _on_connection_failed() -> void:
	_log("CONNECTION_FAILED", {})
	get_tree().quit(1)

func _on_disconnected() -> void:
	_log("DISCONNECTED", {})
	if not _in_match:
		get_tree().quit()

func _on_lobby_state(lobby: Dictionary) -> void:
	_log("LOBBY_STATE", {
		"id": lobby.get("id", -1),
		"members": lobby.get("members", {}).size(),
		"max_players": lobby.get("max_players", -1),
		"in_match": lobby.get("in_match", false),
		"playlist": lobby.get("playlist", ""),
	})
	if _auto_start_sec >= 0.0 and _playlist_id.is_empty() and not lobby.get("in_match", false) and not _auto_start_armed:
		_auto_start_armed = true
		get_tree().create_timer(_auto_start_sec).timeout.connect(func():
			_log("AUTO_START", {})
			NetworkManager.start_match()
		)

func _on_vote_started(duration: float) -> void:
	_log("VOTE_STARTED", {"duration": duration})

func _on_vote_ended(chosen_level_id: String, countdown: float) -> void:
	_log("VOTE_ENDED", {"chosen": chosen_level_id, "countdown": countdown})

func _on_match_started(lobby_id: int, my_peer_id: int, roster: Dictionary, level_id: String, playlist_id: String) -> void:
	_in_match = true
	_match_time_left = _duration_sec
	var usernames := []
	for peer_id in roster.keys():
		usernames.append(String(roster[peer_id].get("username", "?")))
	_log("MATCH_STARTED", {
		"lobby_id": lobby_id, "my_peer_id": my_peer_id, "level_id": level_id,
		"playlist_id": playlist_id, "roster_size": roster.size(), "usernames": usernames,
	})

func _on_match_state(tick: int, states: Dictionary) -> void:
	# Logged at most once/second (this fires at ~60Hz -- logging every tick
	# would flood stdout with no benefit) so external tooling can confirm
	# real position/tag state is actually flowing without drowning in it.
	_state_log_timer -= get_process_delta_time()
	if _state_log_timer > 0.0:
		return
	_state_log_timer = 1.0
	var it_peer := -1
	for peer_id in states.keys():
		if bool(states[peer_id].get("is_it", false)):
			it_peer = peer_id
			break
	_log("MATCH_STATE", {"tick": tick, "player_count": states.size(), "it_peer": it_peer})

func _on_match_ended(ranking: Array) -> void:
	_log("MATCH_ENDED", {"ranking": ranking})
	_in_match = false
	get_tree().create_timer(1.0).timeout.connect(func(): get_tree().quit())

func _physics_process(delta: float) -> void:
	if not _in_match:
		return
	_match_time_left -= delta
	if _match_time_left <= 0.0:
		_log("DURATION_ELAPSED", {})
		NetworkManager.disconnect_from_server()
		_in_match = false
		get_tree().create_timer(0.5).timeout.connect(func(): get_tree().quit())
		return

	var input := {
		"move_dir": Vector2.ZERO,
		"jump_pressed": false,
		"jump_held": false,
		"dash_pressed": false,
		"climb_held": false,
	}
	if _move_pattern == "wander":
		_wander_timer -= delta
		if _wander_timer <= 0.0:
			_wander_timer = 1.0
			_wander_dir *= -1
		input["move_dir"] = Vector2(_wander_dir, 0)
	NetworkManager.submit_input(input)

func _log(event_type: String, data: Dictionary) -> void:
	print("EVENT:%s:%s" % [event_type, JSON.stringify(data)])
