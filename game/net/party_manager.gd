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
const PARTY_RELAY_URL_BASE := "wss://codecade.co.za/tag/relay/party/"
const RECONNECT_DELAY_SEC := 5.0

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

func _ready() -> void:
	_reconnect_timer = Timer.new()
	_reconnect_timer.wait_time = RECONNECT_DELAY_SEC
	_reconnect_timer.one_shot = true
	_reconnect_timer.timeout.connect(_connect)
	add_child(_reconnect_timer)
	invite_received.connect(_on_invite_received)
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
func queue_party(server_address: String, mode: String, playlist: String) -> void:
	_send({"type": "party_queue_start", "serverAddress": server_address, "mode": mode, "playlist": playlist})

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
