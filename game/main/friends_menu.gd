extends Control

# Optional social screen -- add friends by code (a player's own client_id
# already is one, no new identifier to generate), see who's currently
# online and which live server they're on, one-click join. Built entirely
# in code (no hand-edited .tscn node tree), same pattern login_screen.gd
# and the Art Tool's later pages already established. Talks to the new
# /api/friends/* endpoints on the relay (relay-server/server.js).

const UIStyle := preload("res://ui/ui_style.gd")
const FRIENDS_API_BASE := "https://codecade.co.za/tag/api/friends"
const RELAY_JOIN_BASE := "wss://codecade.co.za/tag/relay/join/"
const ACCENT := UIStyle.COLOR_ONLINE
const REFRESH_INTERVAL_SEC := 6.0

var _status_label: Label
var _add_edit: LineEdit
var _list_box: VBoxContainer
var _refresh_timer: Timer
var _cancelled := false
var _party_box: VBoxContainer
var _party_status_label: Label
var _last_friends: Array = []

func _ready() -> void:
	UIStyle.add_background(self, "friends_menu")
	NetworkManager.connected_to_server.connect(_on_connected)
	NetworkManager.connection_failed.connect(_on_connection_failed)
	PartyManager.party_updated.connect(_on_party_updated)
	PartyManager.party_error.connect(_on_party_error)
	PartyManager.kicked.connect(_on_kicked)

	var vbox := VBoxContainer.new()
	vbox.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT, Control.PRESET_MODE_MINSIZE, 32)
	vbox.add_theme_constant_override("separation", 14)
	add_child(vbox)

	vbox.add_child(UIStyle.title_label("Friends", 32))
	vbox.add_child(UIStyle.subtitle_label("Optional -- add friends by code, see who's online, join with one click."))

	var code_panel := PanelContainer.new()
	code_panel.add_theme_stylebox_override("panel", UIStyle.panel_box(ACCENT))
	vbox.add_child(code_panel)
	var code_box := VBoxContainer.new()
	code_box.add_theme_constant_override("separation", 6)
	code_panel.add_child(code_box)
	code_box.add_child(_dim_label("YOUR FRIEND CODE"))
	var code_row := HBoxContainer.new()
	code_row.add_theme_constant_override("separation", 10)
	code_box.add_child(code_row)
	var code_edit := LineEdit.new()
	code_edit.text = PlayerIdentity.client_id
	code_edit.editable = false
	code_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UIStyle.style_line_edit(code_edit)
	code_row.add_child(code_edit)
	var copy_btn := Button.new()
	copy_btn.text = "Copy"
	UIStyle.style_button(copy_btn, ACCENT, 8)
	copy_btn.pressed.connect(func():
		DisplayServer.clipboard_set(PlayerIdentity.client_id)
		_status_label.text = "Copied to clipboard."
	)
	code_row.add_child(copy_btn)

	var party_panel := PanelContainer.new()
	party_panel.add_theme_stylebox_override("panel", UIStyle.panel_box(UIStyle.COLOR_ACCENT))
	vbox.add_child(party_panel)
	var party_outer := VBoxContainer.new()
	party_outer.add_theme_constant_override("separation", 6)
	party_panel.add_child(party_outer)
	party_outer.add_child(_dim_label("MY PARTY"))
	_party_box = VBoxContainer.new()
	_party_box.add_theme_constant_override("separation", 4)
	party_outer.add_child(_party_box)
	_party_status_label = Label.new()
	_party_status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_party_status_label.add_theme_font_size_override("font_size", 12)
	_party_status_label.add_theme_color_override("font_color", Color(0.85, 0.4, 0.4))
	party_outer.add_child(_party_status_label)
	_render_party()

	var add_row := HBoxContainer.new()
	add_row.add_theme_constant_override("separation", 10)
	vbox.add_child(add_row)
	_add_edit = LineEdit.new()
	_add_edit.placeholder_text = "Friend's code"
	_add_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UIStyle.style_line_edit(_add_edit)
	add_row.add_child(_add_edit)
	var add_btn := Button.new()
	add_btn.text = "Add Friend"
	UIStyle.style_button(add_btn, UIStyle.COLOR_ACCENT, 8)
	add_btn.pressed.connect(_on_add_pressed)
	add_row.add_child(add_btn)

	_status_label = Label.new()
	_status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status_label.add_theme_color_override("font_color", Color(0.7, 0.72, 0.78))
	vbox.add_child(_status_label)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vbox.add_child(scroll)
	_list_box = VBoxContainer.new()
	_list_box.add_theme_constant_override("separation", 8)
	_list_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_list_box)

	var back_btn := Button.new()
	back_btn.text = "Back"
	back_btn.custom_minimum_size = Vector2(0, 40)
	UIStyle.style_back_button(back_btn)
	back_btn.pressed.connect(_on_back_pressed)
	vbox.add_child(back_btn)

	_refresh_timer = Timer.new()
	_refresh_timer.wait_time = REFRESH_INTERVAL_SEC
	_refresh_timer.timeout.connect(_fetch_friends)
	add_child(_refresh_timer)
	_refresh_timer.start()

	_fetch_friends()

func _dim_label(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", 11)
	l.add_theme_color_override("font_color", Color(0.7, 0.72, 0.78))
	return l

func _on_party_updated(_party: Dictionary) -> void:
	_render_party()
	_render_friends(_last_friends) # re-render so Invite buttons reflect current membership

func _on_party_error(reason: String) -> void:
	var messages := {
		"not_friend": "You can only invite a friend.",
		"offline": "That friend isn't online right now.",
		"party_full": "Your party is full (16 max).",
	}
	_party_status_label.text = messages.get(reason, "Couldn't do that.")

## party_manager.gd already clears current_party the instant a "party_kicked"
## message arrives, but that alone never touches this screen's rendered
## _party_box -- only the party_updated signal does that, and a kick doesn't
## send the kicked player one of those (only the party's remaining members
## get a fresh party_updated broadcast). Without this, a kicked player's
## Friends screen kept showing their old party/Leave button until something
## else happened to trigger a re-render.
func _on_kicked() -> void:
	_render_party()
	_party_status_label.text = "You were removed from the party."

func _render_party() -> void:
	for child in _party_box.get_children():
		_party_box.remove_child(child)
		child.queue_free()

	if PartyManager.current_party.is_empty():
		var empty := _dim_label("Not in a party -- invite an online friend below.")
		_party_box.add_child(empty)
		return

	var members: Array = PartyManager.current_party.get("members", [])
	var leader_id: String = PartyManager.current_party.get("leaderId", "")
	for member in members:
		_party_box.add_child(_build_party_member_row(member, leader_id))

	var leave_btn := Button.new()
	leave_btn.text = "Leave Party"
	UIStyle.style_button(leave_btn, UIStyle.COLOR_NEUTRAL, 8)
	leave_btn.pressed.connect(func(): PartyManager.leave_party())
	_party_box.add_child(leave_btn)

func _build_party_member_row(member: Dictionary, leader_id: String) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)

	var member_id: String = member.get("clientId", "")
	var is_me: bool = member_id == PlayerIdentity.client_id
	var suffix := ""
	if member_id == leader_id:
		suffix += "  (Leader)"
	if is_me:
		suffix += "  (You)"
	var name_label := Label.new()
	name_label.text = "%s%s" % [member.get("username", "Player"), suffix]
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(name_label)

	if PartyManager.is_leader() and not is_me:
		var kick_btn := Button.new()
		kick_btn.text = "Kick"
		UIStyle.style_button(kick_btn, UIStyle.COLOR_RANKED, 8)
		kick_btn.pressed.connect(func(): PartyManager.kick(member_id))
		row.add_child(kick_btn)

	return row

func _on_add_pressed() -> void:
	var code := _add_edit.text.strip_edges()
	if code.is_empty():
		return
	if PlayerIdentity.client_id.is_empty():
		_status_label.text = "No local identity yet -- try again in a moment."
		return
	var req := HTTPRequest.new()
	add_child(req)
	req.request_completed.connect(func(_result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray):
		req.queue_free()
		var parsed = JSON.parse_string(body.get_string_from_utf8())
		if response_code != 200:
			var err_msg := "Couldn't add that friend."
			if typeof(parsed) == TYPE_DICTIONARY and parsed.has("error"):
				err_msg = str(parsed["error"])
			_status_label.text = err_msg
			return
		_add_edit.text = ""
		_status_label.text = "Friend added."
		_fetch_friends()
	)
	var url := "%s/%s/add" % [FRIENDS_API_BASE, PlayerIdentity.client_id]
	var body := JSON.stringify({"friendCode": code})
	req.request(url, ["Content-Type: application/json"], HTTPClient.METHOD_POST, body)

func _fetch_friends() -> void:
	if PlayerIdentity.client_id.is_empty():
		return
	var req := HTTPRequest.new()
	add_child(req)
	req.request_completed.connect(func(_result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray):
		req.queue_free()
		if response_code != 200:
			return
		var parsed = JSON.parse_string(body.get_string_from_utf8())
		if typeof(parsed) != TYPE_ARRAY:
			return
		_last_friends = parsed
		_render_friends(parsed)
	)
	req.request("%s/%s" % [FRIENDS_API_BASE, PlayerIdentity.client_id])

func _render_friends(friends: Array) -> void:
	for child in _list_box.get_children():
		_list_box.remove_child(child)
		child.queue_free()
	if friends.is_empty():
		var empty := _dim_label("No friends added yet.")
		empty.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_list_box.add_child(empty)
		return
	for entry in friends:
		_list_box.add_child(_build_friend_row(entry))

func _build_friend_row(entry: Dictionary) -> Control:
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", UIStyle.panel_box())
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	panel.add_child(row)

	var online: bool = entry.get("online", false)
	var dot := ColorRect.new()
	dot.color = Color(0.35, 0.9, 0.55) if online else Color(0.4, 0.42, 0.48)
	dot.custom_minimum_size = Vector2(10, 10)
	var dot_wrap := CenterContainer.new()
	dot_wrap.custom_minimum_size = Vector2(20, 0)
	dot_wrap.add_child(dot)
	row.add_child(dot_wrap)

	var name_str: String = entry.get("username", "") if entry.get("username", null) else str(entry.get("clientId", "")).left(12) + "…"
	var name_label := Label.new()
	name_label.text = name_str
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(name_label)

	var status_label := Label.new()
	# "online" only means their app is open (see server.js's playerSockets-
	# based check) -- serverName is null whenever they're just sitting in
	# menus rather than actually in a match, which str()'d straight into the
	# label used to show the literal text "Playing: <null>".
	var server_name: String = str(entry.get("serverName", ""))
	if not online:
		status_label.text = "Offline"
	elif server_name.is_empty() or server_name == "null":
		status_label.text = "Online"
	else:
		status_label.text = "Playing: %s" % server_name
	status_label.add_theme_color_override("font_color", Color(0.7, 0.72, 0.78))
	status_label.add_theme_font_size_override("font_size", 12)
	row.add_child(status_label)

	if online:
		var join_btn := Button.new()
		join_btn.text = "Join"
		UIStyle.style_button(join_btn, UIStyle.COLOR_ONLINE, 8)
		join_btn.pressed.connect(_on_join_pressed.bind(entry.get("serverId", "")))
		row.add_child(join_btn)

		var friend_id: String = str(entry.get("clientId", ""))
		if not _is_in_my_party(friend_id) and PartyManager.party_size() < 16:
			var invite_btn := Button.new()
			invite_btn.text = "Invite"
			UIStyle.style_button(invite_btn, UIStyle.COLOR_ACCENT, 8)
			invite_btn.pressed.connect(func():
				PartyManager.invite(friend_id)
				_party_status_label.text = ""
			)
			row.add_child(invite_btn)

	return panel

func _is_in_my_party(client_id: String) -> bool:
	if PartyManager.current_party.is_empty():
		return false
	for member in PartyManager.current_party.get("members", []):
		if member.get("clientId", "") == client_id:
			return true
	return false

func _on_join_pressed(server_id: String) -> void:
	if server_id.is_empty():
		return
	_status_label.text = "Connecting..."
	NetworkManager.set_username(GameSettings.saved_username)
	NetworkManager.start_client(RELAY_JOIN_BASE + server_id, GameSettings.saved_username)

func _on_connected() -> void:
	if _cancelled:
		return
	_status_label.text = "Joining match..."
	NetworkManager.lobby_state_updated.connect(_on_in_lobby, CONNECT_ONE_SHOT)
	NetworkManager.quick_join_lobby()

func _on_in_lobby(_lobby: Dictionary) -> void:
	if _cancelled:
		return
	get_tree().change_scene_to_file("res://main/lobby_room.tscn")

func _on_connection_failed() -> void:
	_status_label.text = "Couldn't connect -- your friend's server may have gone offline."

func _on_back_pressed() -> void:
	_cancelled = true
	if NetworkManager.lobby_state_updated.is_connected(_on_in_lobby):
		NetworkManager.lobby_state_updated.disconnect(_on_in_lobby)
	NetworkManager.disconnect_from_server()
	get_tree().change_scene_to_file("res://main/main_menu.tscn")
