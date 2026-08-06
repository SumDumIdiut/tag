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
signal connect_now(server_address: String, mode: String, playlist: String, transport: String)
signal party_error(reason: String)
signal friend_request_received(from_client_id: String, from_username: String)
## Fired when someone I sent a friend request to responds -- accepted tells
## the Friends screen it can stop waiting and refresh its list.
signal friend_request_responded(target_username: String, accepted: bool)

const UIStyle := preload("res://ui/ui_style.gd")
const PARTY_RELAY_URL_BASE := "wss://codecade.co.za/tag/relay/party/"
const DIRECTORY_URL := "https://codecade.co.za/tag/api/servers"
const RELAY_JOIN_BASE := "wss://codecade.co.za/tag/relay/join/"
const RECONNECT_DELAY_SEC := 5.0
const FOLLOW_SEARCH_RETRY_SEC := 1.0
const FOLLOW_SEARCH_MAX_ATTEMPTS := 10
## codecade.co.za is served through a Cloudflare Tunnel (see install.sh's
## ensure_portable_cloudflared/CF_DOMAIN), which silently drops an idle
## WebSocket connection after a period of no traffic -- this socket can sit
## completely idle for arbitrarily long (a player just sitting on the
## Friends/lobby screen doing nothing), unlike relay_client.gd's own
## connection, which already sends a real heartbeat every
## HEARTBEAT_INTERVAL_SEC (5s) and has never shown this symptom. Without
## this, get_ready_state() can keep reporting STATE_OPEN long after the
## tunnel has actually dropped the connection (no clean close frame makes
## it back), so leave/kick/invite calls silently go nowhere -- exactly the
## live "buttons don't work, no error, every time" report. Comfortably
## under Cloudflare's ~100s idle timeout, with margin.
const KEEPALIVE_INTERVAL_SEC := 20.0

## {} means no real party (just yourself) -- party_size() below treats that
## as size 1 rather than 0, so "is my party bigger than N" checks read
## naturally without every caller special-casing the empty case.
var current_party: Dictionary = {}

var _socket: WebSocketPeer = null
var _identified := false
var _reconnect_timer: Timer

# Invite/request popups are owned here rather than by whatever screen
# happens to be open -- a party invite or friend request can land while
# you're anywhere in the online menus, not just on the Friends screen, and
# this autoload is the one thing guaranteed to be alive regardless of
# scene. Queued one at a time rather than stacked, since two overlapping
# popups fighting for the same screen space would be more confusing than
# useful. Each queued item is {kind: "party"|"friend_request", ...} --
# both share the same popup shell/styling, just different label text and
# accept/decline actions, so friend requests get the exact same treatment
# a party invite already does rather than a separately-designed prompt.
var _pending_popups: Array[Dictionary] = []
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
## Only meaningful for "private" (see _retry_follow()) -- ranked/casual
## always re-resolve a fresh address via the directory instead, since the
## server they're looking for might not be the one they started with.
var _follow_last_address := ""
var _follow_last_transport := "ws"
var _follow_search_timer: Timer
var _keepalive_timer: Timer

func _ready() -> void:
	_reconnect_timer = Timer.new()
	_reconnect_timer.wait_time = RECONNECT_DELAY_SEC
	_reconnect_timer.one_shot = true
	_reconnect_timer.timeout.connect(_connect)
	add_child(_reconnect_timer)
	_follow_search_timer = Timer.new()
	_follow_search_timer.wait_time = FOLLOW_SEARCH_RETRY_SEC
	_follow_search_timer.one_shot = true
	_follow_search_timer.timeout.connect(_retry_follow)
	add_child(_follow_search_timer)
	_keepalive_timer = Timer.new()
	_keepalive_timer.wait_time = KEEPALIVE_INTERVAL_SEC
	_keepalive_timer.timeout.connect(_send_keepalive)
	add_child(_keepalive_timer)
	_keepalive_timer.start()
	invite_received.connect(_on_invite_received)
	friend_request_received.connect(_on_friend_request_received)
	connect_now.connect(_on_connect_now)
	PlayerIdentity.client_id_changed.connect(_on_client_id_changed)
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

## On-demand "what's my real party state right now" -- see server.js's
## party_resync handler for the full reasoning. Called by friends_menu.gd
## whenever it opens, so a party UI that silently drifted (a fire-and-
## forget leave/kick/invite-accept whose _send() landed on a socket that
## reported OPEN but wasn't really -- the same class of gap
## KEEPALIVE_INTERVAL_SEC exists for but can't fully close between beats)
## self-heals the moment you actually look at it, rather than staying wrong
## until the next full reconnect.
func request_resync() -> void:
	_send({"type": "party_resync"})

func accept_friend_request(from_client_id: String) -> void:
	_send({"type": "friend_request_accept", "fromClientId": from_client_id})

func decline_friend_request(from_client_id: String) -> void:
	_send({"type": "friend_request_decline", "fromClientId": from_client_id})

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

## This autoload's socket connects once at boot under whatever client_id was
## current then -- almost always the local-device id, since login is a menu
## action that happens well after _ready() runs. The relay identifies a
## /relay/party/:clientId connection by whatever id was in the URL at
## connect time for the socket's whole lifetime, so without this, logging
## in later left every party action (invite/kick/leave) silently operating
## under the OLD pre-login id forever -- friends added under the real
## account afterward would never match against it, failing invites with a
## confusing "not_friend" error despite the Friends list (a fresh HTTP call
## using the current client_id) correctly showing them as a friend.
##
## If already in a party when this fires, just discarding the old socket
## isn't safe on its own: the relay's own ws.on('close') handler treats
## ANY disconnect as a real "left the party" (see relay-server's
## handlePartyLeave), which for a leader silently hands leadership to
## whoever else is still in the party and drops this client out of it for
## good -- confirmed live (a raw two-socket reproduction: closing the
## leader's old socket handed leadership to the other member, and the new
## socket that reconnected under the correct id was never associated with
## any party at all). Kick/Leave Party then looked like they'd simply
## stopped working, since the client displayed a party it no longer
## server-side belonged to. identity_migrate tells the relay to carry
## membership/leadership over to the new id BEFORE the old socket closes,
## so the close that follows finds nothing left to "leave".
func _on_client_id_changed(new_id: String) -> void:
	if not current_party.is_empty() and _socket != null and _socket.get_ready_state() == WebSocketPeer.STATE_OPEN:
		_send({"type": "identity_migrate", "newClientId": new_id})
		# send_text() only queues the message -- give it a moment to actually
		# reach the relay (via _process()'s own poll(), still running on this
		# same socket during the wait) before tearing the socket down below,
		# rather than risking the plain disconnect winning the race.
		await get_tree().create_timer(0.3).timeout
	_socket = null
	_identified = false
	if not current_party.is_empty():
		current_party = {}
		party_updated.emit(current_party)
	_connect()

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
			# transport is null (not "ws") for ranked/casual -- server.js only
			# resolves it for private (see handlePartyQueueStart); str(null)
			# would stringify to the literal "<null>", not "ws", so it needs
			# the same null-check-before-stringifying fix friends_menu.gd's
			# "Playing: <null>" bug needed.
			var raw_transport = msg.get("transport", null)
			var transport: String = str(raw_transport) if raw_transport != null else "ws"
			connect_now.emit(str(msg.get("serverAddress", "")), str(msg.get("mode", "")), str(msg.get("playlist", "")), transport)
		"party_error":
			party_error.emit(str(msg.get("reason", "")))
		"friend_request_received":
			friend_request_received.emit(str(msg.get("fromClientId", "")), str(msg.get("fromUsername", "")))
		"friend_request_accepted":
			friend_request_responded.emit(str(msg.get("targetUsername", "")), true)
		"friend_request_declined":
			friend_request_responded.emit(str(msg.get("targetUsername", "")), false)

func _send(data: Dictionary) -> void:
	if _socket != null and _socket.get_ready_state() == WebSocketPeer.STATE_OPEN:
		_socket.send_text(JSON.stringify(data))

## See KEEPALIVE_INTERVAL_SEC's own comment -- an unrecognized message type
## is already silently ignored by relay-server's handlePlayerParty dispatch,
## so this needs no server-side counterpart at all, just real traffic
## flowing often enough that the tunnel never sees this socket go idle.
func _send_keepalive() -> void:
	_send({"type": "keepalive"})

func _on_invite_received(party_id: String, from_client_id: String, from_username: String) -> void:
	_pending_popups.append({"kind": "party", "party_id": party_id, "from_client_id": from_client_id, "from_username": from_username})
	_show_next_popup()

func _on_friend_request_received(from_client_id: String, from_username: String) -> void:
	_pending_popups.append({"kind": "friend_request", "from_client_id": from_client_id, "from_username": from_username})
	_show_next_popup()

func _show_next_popup() -> void:
	if _invite_popup != null or _pending_popups.is_empty():
		return
	var item: Dictionary = _pending_popups.pop_front()
	var is_party: bool = item.kind == "party"

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
	label.text = ("%s invited you to their party" % item.from_username) if is_party else ("%s wants to be friends" % item.from_username)
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
		if is_party:
			decline_invite(item.party_id)
		else:
			decline_friend_request(item.from_client_id)
		_close_invite_popup(layer)
	)
	button_row.add_child(decline_btn)

	var accept_btn := Button.new()
	accept_btn.text = "Accept"
	UIStyle.style_button(accept_btn, UIStyle.COLOR_ONLINE, 8)
	accept_btn.pressed.connect(func():
		if is_party:
			accept_invite(item.party_id)
		else:
			accept_friend_request(item.from_client_id)
		_close_invite_popup(layer)
	)
	button_row.add_child(accept_btn)

	_invite_popup = layer

func _close_invite_popup(layer: CanvasLayer) -> void:
	layer.queue_free()
	_invite_popup = null
	_show_next_popup()

## The leader just told us where to go (see queue_party() above) -- for
## "private" `target` is already a bare relay server id, resolved
## server-side by relay-server/server.js's handlePartyQueueStart (a
## private match is unlisted, deliberately excluded from the public
## /api/servers directory, so there's nothing here for a client-side name
## search to find the way ranked/casual do); for "ranked"/"casual" it's a
## server name we have to resolve to an id via that public directory
## ourselves, same lookup ranked_queue.gd/casual_queue.gd already do to
## find each other, just filtered down to one exact name instead of
## picking the fullest match.
func _on_connect_now(target: String, mode: String, playlist: String, transport: String) -> void:
	_follow_mode = mode
	_follow_playlist = playlist
	_follow_target = target
	_follow_attempts = 0
	if mode == "private":
		_follow_last_address = RELAY_JOIN_BASE + target
		_follow_last_transport = transport
		_connect_to_follow_target(_follow_last_address, transport)
	else:
		_search_for_leader_server()

## Shared by both the "not found in the directory yet" retry (below) and a
## failed connect attempt (_on_follow_connect_failed) -- private has no
## directory to re-search, so it just redials the same resolved address.
func _retry_follow() -> void:
	if _follow_mode == "private":
		_connect_to_follow_target(_follow_last_address, _follow_last_transport)
	else:
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
					_connect_to_follow_target(RELAY_JOIN_BASE + str(s.id), str(s.get("transport", "ws")))
					return
		if _follow_attempts < FOLLOW_SEARCH_MAX_ATTEMPTS:
			_follow_search_timer.start()
	)
	req.request(DIRECTORY_URL)

## A follower's own client can still be mid-cleanup from the PREVIOUS match
## (e.g. still sitting on the match-results screen, "Continue" not yet
## clicked -- see match_results.gd's _on_continue_pressed, the only thing
## that actually calls NetworkManager.disconnect_from_server() today) when
## the leader queues again. Reassigning multiplayer.multiplayer_peer to a
## brand-new peer while the OLD one is still open leaves the new WS/WebRTC
## handshake racing that old peer's teardown -- confirmed as the live
## "party comes along fine for match 1, not match 2" cause. Forcing a clean
## disconnect_from_server() first, unconditionally, means every follow
## attempt starts from the exact same known-empty state regardless of
## whatever screen/connection state the follower's client happened to be in
## -- a no-op on the (normal) case where it was already disconnected.
##
## Also guards both one-shot connections against a leftover from an attempt
## that never fired (retry racing a slow first attempt) -- connecting an
## already-connected callable is a silent no-op in Godot, which would leave
## the OLD attempt's context wired up instead of this one.
func _connect_to_follow_target(address: String, transport: String) -> void:
	NetworkManager.disconnect_from_server()
	if NetworkManager.connected_to_server.is_connected(_on_follow_connected):
		NetworkManager.connected_to_server.disconnect(_on_follow_connected)
	if NetworkManager.connection_failed.is_connected(_on_follow_connect_failed):
		NetworkManager.connection_failed.disconnect(_on_follow_connect_failed)
	NetworkManager.connected_to_server.connect(_on_follow_connected, CONNECT_ONE_SHOT)
	NetworkManager.connection_failed.connect(_on_follow_connect_failed, CONNECT_ONE_SHOT)
	NetworkManager.set_username(GameSettings.saved_username)
	NetworkManager.start_client_auto(address, GameSettings.saved_username, transport)

## A failed connect used to strand the follower silently forever -- no
## retry, no error, nothing -- while everyone else who made it through went
## on into the match without them. Retries the same bounded way the initial
## "not found in the directory yet" case already does.
func _on_follow_connect_failed() -> void:
	_follow_attempts += 1
	if _follow_attempts < FOLLOW_SEARCH_MAX_ATTEMPTS:
		_follow_search_timer.start()

## Mirrors each mode's own queue screen: a ranked server auto-joins a
## connecting client into its lobby (see NetworkManager.is_ranked_server /
## _server_register_player), casual and private both need an explicit
## quick_join_lobby() call -- casual with the playlist so it lands in the
## same playlist-restricted lobby the leader did, private with none (a
## private lobby never has one).
func _on_follow_connected() -> void:
	# The leader's own path (online_menu.gd's entered_lobby handler) switches
	# to lobby_room.tscn the moment it's actually in a lobby -- this used to
	# be entirely missing here, so a follower stayed on whatever screen it
	# was already on (never seeing the waiting room/team-select view at all)
	# until match_started eventually fired and yanked them straight into the
	# match. lobby_room.gd already listens for match_started itself and
	# handles that transition on its own once we're actually there, so this
	# is the only piece that was missing -- no separate follower-specific
	# match-started handling needed (that used to exist here too, and would
	# now double-fire alongside lobby_room.gd's own handler, racing to
	# instantiate two MatchIntroScenes for the same event).
	NetworkManager.lobby_state_updated.connect(_on_follow_in_lobby, CONNECT_ONE_SHOT)
	if _follow_mode == "casual":
		NetworkManager.quick_join_lobby(_follow_playlist)
	elif _follow_mode == "private":
		NetworkManager.quick_join_lobby()

func _on_follow_in_lobby(_lobby: Dictionary) -> void:
	get_tree().change_scene_to_file("res://main/lobby_room.tscn")
