extends Node

# Owns the one persistent connection a player's own client keeps to the
# relay for live party state -- distinct from NetworkManager, which only
# ever talks to whichever process is acting as a game server. Connects once
# at boot and stays connected for as long as the game runs, independent of
# whether you're in a match, a lobby, or just sitting in the menus (a party
# invite can arrive from anywhere). Mirrors RelayClient's own low-level
# WebSocketPeer + manual poll()/reconnect-timer pattern -- see that file for
# why (this project's established way of talking to the relay over a raw
# socket, not a helper class already built to share).

signal party_updated(party: Dictionary)
signal invite_received(party_id: String, from_client_id: String, from_username: String)
signal invite_declined(target_username: String)
signal kicked
signal connect_now(server_address: String, mode: String, playlist: String)
signal party_error(reason: String)

const UIStyle := preload("res://ui/ui_style.gd")
const MatchIntroScene := preload("res://main/match_intro.tscn")
const PARTY_RELAY_URL_BASE := "wss://codecade.co.za/tag/relay/party/"
const DIRECTORY_URL := "https://codecade.co.za/tag/api/servers"
const RELAY_JOIN_BASE := "wss://codecade.co.za/tag/relay/join/"
const RECONNECT_DELAY_SEC := 5.0
const FOLLOW_SEARCH_RETRY_SEC := 1.0
const FOLLOW_SEARCH_MAX_ATTEMPTS := 10

## {} means no real party (just yourself) -- party_size() below treats that
## as size 1 rather than 0, so "is my party bigger than N" checks read
## naturally without every caller special-casing the empty case.
var current_party: Dictionary = {}

var _socket: WebSocketPeer = null
var _identified := false
var _reconnect_timer: Timer

# Invite popups are owned here rather than by whatever screen happens to be
# open -- an invite can land while you're anywhere in the online menus, not
# just on the Friends screen, and this autoload is the one thing guaranteed
# to be alive regardless of scene. Queued one at a time rather than stacked,
# since two overlapping popups fighting for the same screen space would be
# more confusing than useful.
var _pending_invites: Array[Dictionary] = []
var _invite_popup: CanvasLayer = null

# Follower-side "come along with the leader" state -- see queue_party()/
# _on_connect_now() below. `_follow_target` is a server *name* to search the
# directory for (ranked/casual, matching what ranked_queue.gd/casual_queue.gd
# do to find each other today) except for "private", where it's a direct
# address instead (private servers never appear in the directory at all --
# see casual_matchmaker.gd's own hosted_private_address for the same reason).
var _follow_mode := ""
var _follow_playlist := ""
var _follow_target := ""
var _follow_attempts := 0
var _follow_search_timer: Timer

func _ready() -> void:
	_reconnect_timer = Timer.new()
	_reconnect_timer.wait_time = RECONNECT_DELAY_SEC
	_reconnect_timer.one_shot = true
	_reconnect_timer.timeout.connect(_connect)
	add_child(_reconnect_timer)
	_follow_search_timer = Timer.new()
	_follow_search_timer.wait_time = FOLLOW_SEARCH_RETRY_SEC
	_follow_search_timer.one_shot = true
	_follow_search_timer.timeout.connect(_search_for_leader_server)
	add_child(_follow_search_timer)
	invite_received.connect(_on_invite_received)
	connect_now.connect(_on_connect_now)
	_connect()

func party_size() -> int:
	if current_party.is_empty():
		return 1
	return current_party.get("members", []).size()

func is_leader() -> bool:
	return not current_party.is_empty() and current_party.get("leaderId", "") == PlayerIdentity.client_id

func invite(target_client_id: String) -> void:
	_send({"type": "party_invite", "targetClientId": target_client_id})

func accept_invite(party_id: String) -> void:
	_send({"type": "party_invite_accept", "partyId": party_id})

func decline_invite(party_id: String) -> void:
	_send({"type": "party_invite_decline", "partyId": party_id})

func leave_party() -> void:
	_send({"type": "party_leave"})

func kick(target_client_id: String) -> void:
	_send({"type": "party_kick", "targetClientId": target_client_id})

## Called by whoever just resolved/hosted the actual game server exactly like
## a solo player would (see ranked_queue.gd/casual_queue.gd/the private-match
## flow) -- tells every other party member's client to connect+join the same
## place. Only meaningful for the leader; the relay silently ignores it
## otherwise.
##
## `target` is NOT always a literal address despite the wire field's name
## (serverAddress, see relay-server/server.js's party_queue_start) -- for
## "ranked"/"casual" it's the server's own display name, which the leader
## always has on hand (whether they found it via the directory or just
## chose it themselves when hosting) and which a follower can search the
## exact same public directory for (see _search_for_leader_server below) --
## there's no other way for the leader to learn a self-hosted server's
## relay-assigned id, since it never needs one for its own loopback
## connection. Only "private" (never listed in the directory at all) passes
## a real connectable address.
func queue_party(target: String, mode: String, playlist: String) -> void:
	_send({"type": "party_queue_start", "serverAddress": target, "mode": mode, "playlist": playlist})

func _connect() -> void:
	if PlayerIdentity.client_id.is_empty():
		_reconnect_timer.start()
		return
	_socket = WebSocketPeer.new()
	var err := _socket.connect_to_url(PARTY_RELAY_URL_BASE + PlayerIdentity.client_id)
	if err != OK:
		push_warning("PartyManager: failed to start connecting to relay (%s) -- retrying in %ds" % [err, RECONNECT_DELAY_SEC])
		_socket = null
		_reconnect_timer.start()
		return
	_identified = false

func _process(_delta: float) -> void:
	if _socket == null:
		return
	_socket.poll()
	var state := _socket.get_ready_state()
	if state == WebSocketPeer.STATE_OPEN:
		if not _identified:
			_identified = true
			_send({"type": "player_identify", "clientId": PlayerIdentity.client_id, "username": GameSettings.saved_username})
		while _socket.get_available_packet_count() > 0:
			_handle_message(_socket.get_packet())
	elif state == WebSocketPeer.STATE_CLOSED:
		_socket = null
		_identified = false
		# The relay is the only place party membership actually lives --
		# losing the connection means this client can no longer trust
		# whatever it last knew, so treat it the same as being kicked rather
		# than silently keeping a stale party displayed until reconnect.
		if not current_party.is_empty():
			current_party = {}
			party_updated.emit(current_party)
		_reconnect_timer.start()

func _handle_message(raw: PackedByteArray) -> void:
	var parsed = JSON.parse_string(raw.get_string_from_utf8())
	if typeof(parsed) != TYPE_DICTIONARY:
		return
	var msg: Dictionary = parsed
	match msg.get("type", ""):
		"party_updated":
			var party_data = msg.get("party")
			current_party = party_data if typeof(party_data) == TYPE_DICTIONARY else {}
			party_updated.emit(current_party)
		"party_invite_received":
			invite_received.emit(str(msg.get("partyId", "")), str(msg.get("fromClientId", "")), str(msg.get("fromUsername", "")))
		"party_invite_declined":
			invite_declined.emit(str(msg.get("targetUsername", "")))
		"party_kicked":
			current_party = {}
			kicked.emit()
		"party_connect_now":
			connect_now.emit(str(msg.get("serverAddress", "")), str(msg.get("mode", "")), str(msg.get("playlist", "")))
		"party_error":
			party_error.emit(str(msg.get("reason", "")))

func _send(data: Dictionary) -> void:
	if _socket != null and _socket.get_ready_state() == WebSocketPeer.STATE_OPEN:
		_socket.send_text(JSON.stringify(data))

func _on_invite_received(party_id: String, from_client_id: String, from_username: String) -> void:
	_pending_invites.append({"party_id": party_id, "from_client_id": from_client_id, "from_username": from_username})
	_show_next_invite()

func _show_next_invite() -> void:
	if _invite_popup != null or _pending_invites.is_empty():
		return
	var invite: Dictionary = _pending_invites.pop_front()

	var layer := CanvasLayer.new()
	layer.layer = 100
	get_tree().root.add_child(layer)

	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.55)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	layer.add_child(dim)

	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	layer.add_child(center)

	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(320, 0)
	panel.add_theme_stylebox_override("panel", UIStyle.panel_box(UIStyle.COLOR_ACCENT))
	center.add_child(panel)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 14)
	panel.add_child(box)

	var label := Label.new()
	label.text = "%s invited you to their party" % invite.from_username
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.autowrap_mode = TextServer.AUTOWRAP_WORD
	box.add_child(label)

	var button_row := HBoxContainer.new()
	button_row.alignment = BoxContainer.ALIGNMENT_CENTER
	button_row.add_theme_constant_override("separation", 12)
	box.add_child(button_row)

	var decline_btn := Button.new()
	decline_btn.text = "Decline"
	UIStyle.style_button(decline_btn, UIStyle.COLOR_NEUTRAL, 8)
	decline_btn.pressed.connect(func():
		decline_invite(invite.party_id)
		_close_invite_popup(layer)
	)
	button_row.add_child(decline_btn)

	var accept_btn := Button.new()
	accept_btn.text = "Accept"
	UIStyle.style_button(accept_btn, UIStyle.COLOR_ONLINE, 8)
	accept_btn.pressed.connect(func():
		accept_invite(invite.party_id)
		_close_invite_popup(layer)
	)
	button_row.add_child(accept_btn)

	_invite_popup = layer

func _close_invite_popup(layer: CanvasLayer) -> void:
	layer.queue_free()
	_invite_popup = null
	_show_next_invite()

## The leader just told us where to go (see queue_party() above) -- for
## "private" `target` is already a real address; for "ranked"/"casual" it's
## a server name we have to resolve to an id via the public directory
## first, same lookup ranked_queue.gd/casual_queue.gd already do to find
## each other, just filtered down to one exact name instead of picking the
## fullest match.
func _on_connect_now(target: String, mode: String, playlist: String) -> void:
	_follow_mode = mode
	_follow_playlist = playlist
	_follow_target = target
	if mode == "private":
		_connect_to_follow_target(target)
	else:
		_follow_attempts = 0
		_search_for_leader_server()

func _search_for_leader_server() -> void:
	_follow_attempts += 1
	var req := HTTPRequest.new()
	add_child(req)
	req.request_completed.connect(func(_result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray):
		req.queue_free()
		if response_code == 200:
			var parsed = JSON.parse_string(body.get_string_from_utf8())
			if typeof(parsed) == TYPE_ARRAY:
				for s in parsed:
					if bool(s.get("ranked", false)) != (_follow_mode == "ranked"):
						continue
					if str(s.get("playlist", "")) != _follow_playlist:
						continue
					if str(s.get("name", "")) != _follow_target:
						continue
					_connect_to_follow_target(RELAY_JOIN_BASE + str(s.id))
					return
		if _follow_attempts < FOLLOW_SEARCH_MAX_ATTEMPTS:
			_follow_search_timer.start()
	)
	req.request(DIRECTORY_URL)

func _connect_to_follow_target(address: String) -> void:
	NetworkManager.connected_to_server.connect(_on_follow_connected, CONNECT_ONE_SHOT)
	NetworkManager.match_started.connect(_on_follow_match_started, CONNECT_ONE_SHOT)
	NetworkManager.set_username(GameSettings.saved_username)
	NetworkManager.start_client(address, GameSettings.saved_username)

## Mirrors each mode's own queue screen: a ranked server auto-joins a
## connecting client into its lobby (see NetworkManager.is_ranked_server /
## _server_register_player), casual and private both need an explicit
## quick_join_lobby() call -- casual with the playlist so it lands in the
## same playlist-restricted lobby the leader did, private with none (a
## private lobby never has one).
func _on_follow_connected() -> void:
	if _follow_mode == "casual":
		NetworkManager.quick_join_lobby(_follow_playlist)
	elif _follow_mode == "private":
		NetworkManager.quick_join_lobby()

func _on_follow_match_started(_lobby_id: int, my_id: int, roster: Dictionary, level_id: String, playlist_id: String = "") -> void:
	var scene := MatchIntroScene.instantiate()
	scene.setup(my_id, roster, level_id, _follow_mode == "ranked", playlist_id)
	get_tree().root.add_child(scene)
	get_tree().current_scene.queue_free()
	get_tree().current_scene = scene
