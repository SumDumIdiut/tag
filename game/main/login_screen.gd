extends Control

# Optional account screen -- logging in is never a wall in front of playing.
# Built entirely in code (no hand-edited .tscn node tree), matching this
# project's established pattern for anything added after the initial hand-
# authored screens (see art_tool.gd's Tiles/Icons pages). Talks to the new
# /api/auth/* endpoints on the relay (relay-server/server.js) added
# alongside this screen.
#
# Session persistence: a bearer token in user://session_token.txt. On launch
# (_ready), if a token exists, it's validated against /api/auth/me; on
# success SkinCatalog.override_client_id() adopts the account's real
# clientId (see skin_catalog.gd) so progress follows the account across
# devices. Any failure (expired token, relay unreachable) just falls back to
# showing the login form -- never blocks getting back to the main menu.

const UIStyle := preload("res://ui/ui_style.gd")
const AUTH_BASE := "https://codecade.co.za/tag/api/auth"
const SESSION_TOKEN_PATH := "user://session_token.txt"
const ACCENT := UIStyle.COLOR_SHOP

var _status_label: Label
var _logged_in_box: VBoxContainer
var _form_box: VBoxContainer
var _username_edit: LineEdit
var _password_edit: LineEdit
var _account_label: Label
var _token := ""

func _ready() -> void:
	UIStyle.add_background(self, "login_screen")
	_token = _load_token()

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(center)

	var vbox := VBoxContainer.new()
	vbox.custom_minimum_size = Vector2(360, 0)
	vbox.add_theme_constant_override("separation", 14)
	center.add_child(vbox)

	vbox.add_child(UIStyle.title_label("Account", 32))
	vbox.add_child(UIStyle.subtitle_label("Optional -- lets your progress follow you across devices."))

	_status_label = Label.new()
	_status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD
	_status_label.add_theme_color_override("font_color", Color(0.95, 0.4, 0.4))
	vbox.add_child(_status_label)

	_build_logged_in_box(vbox)
	_build_form_box(vbox)

	var back_btn := Button.new()
	back_btn.text = "Back"
	back_btn.custom_minimum_size = Vector2(0, 40)
	UIStyle.style_back_button(back_btn)
	UIStyle.apply_bar_art(back_btn, "action_bars", "back")
	back_btn.pressed.connect(func(): get_tree().change_scene_to_file("res://main/main_menu.tscn"))
	vbox.add_child(back_btn)

	if _token.is_empty():
		_show_form()
	else:
		_check_session()

func _build_form_box(parent: VBoxContainer) -> void:
	_form_box = VBoxContainer.new()
	_form_box.add_theme_constant_override("separation", 10)
	parent.add_child(_form_box)

	_username_edit = LineEdit.new()
	_username_edit.placeholder_text = "Username"
	_username_edit.custom_minimum_size = Vector2(0, 40)
	UIStyle.style_line_edit(_username_edit)
	_form_box.add_child(_username_edit)

	_password_edit = LineEdit.new()
	_password_edit.placeholder_text = "Password"
	_password_edit.secret = true
	_password_edit.custom_minimum_size = Vector2(0, 40)
	UIStyle.style_line_edit(_password_edit)
	_form_box.add_child(_password_edit)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	_form_box.add_child(row)

	var login_btn := Button.new()
	login_btn.text = "Log In"
	login_btn.custom_minimum_size = Vector2(0, 44)
	login_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UIStyle.style_button(login_btn, ACCENT)
	UIStyle.apply_bar_art(login_btn, "action_bars", "login")
	login_btn.pressed.connect(_on_login_pressed)
	row.add_child(login_btn)

	var register_btn := Button.new()
	register_btn.text = "Create Account"
	register_btn.custom_minimum_size = Vector2(0, 44)
	register_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UIStyle.style_button(register_btn, UIStyle.COLOR_ONLINE)
	UIStyle.apply_bar_art(register_btn, "action_bars", "create_account")
	register_btn.pressed.connect(_on_register_pressed)
	row.add_child(register_btn)

func _build_logged_in_box(parent: VBoxContainer) -> void:
	_logged_in_box = VBoxContainer.new()
	_logged_in_box.add_theme_constant_override("separation", 10)
	_logged_in_box.visible = false
	parent.add_child(_logged_in_box)

	_account_label = Label.new()
	_account_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_account_label.add_theme_font_size_override("font_size", 18)
	_logged_in_box.add_child(_account_label)

	var logout_btn := Button.new()
	logout_btn.text = "Log Out"
	logout_btn.custom_minimum_size = Vector2(0, 44)
	UIStyle.style_button(logout_btn, UIStyle.COLOR_RANKED)
	UIStyle.apply_bar_art(logout_btn, "action_bars", "logout")
	logout_btn.pressed.connect(_on_logout_pressed)
	_logged_in_box.add_child(logout_btn)

func _show_form() -> void:
	_form_box.visible = true
	_logged_in_box.visible = false

func _show_logged_in(username: String) -> void:
	_account_label.text = "Logged in as %s" % username
	_form_box.visible = false
	_logged_in_box.visible = true

func _load_token() -> String:
	if not FileAccess.file_exists(SESSION_TOKEN_PATH):
		return ""
	var f := FileAccess.open(SESSION_TOKEN_PATH, FileAccess.READ)
	if not f:
		return ""
	return f.get_as_text().strip_edges()

func _save_token(token: String) -> void:
	var f := FileAccess.open(SESSION_TOKEN_PATH, FileAccess.WRITE)
	if f:
		f.store_string(token)

func _clear_token() -> void:
	_token = ""
	if FileAccess.file_exists(SESSION_TOKEN_PATH):
		DirAccess.remove_absolute(SESSION_TOKEN_PATH)

func _check_session() -> void:
	var req := HTTPRequest.new()
	add_child(req)
	req.request_completed.connect(func(_result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray):
		req.queue_free()
		if response_code != 200:
			_clear_token()
			_show_form()
			return
		var parsed = JSON.parse_string(body.get_string_from_utf8())
		if typeof(parsed) != TYPE_DICTIONARY:
			_clear_token()
			_show_form()
			return
		SkinCatalog.override_client_id(str(parsed.get("primaryClientId", "")))
		_show_logged_in(str(parsed.get("username", "")))
	)
	var err := req.request("%s/me" % AUTH_BASE, ["Authorization: Bearer %s" % _token])
	if err != OK:
		_show_form()

func _on_login_pressed() -> void:
	_status_label.text = ""
	var username := _username_edit.text.strip_edges()
	var password := _password_edit.text
	if username.is_empty() or password.is_empty():
		_status_label.text = "Enter a username and password."
		return
	var body := JSON.stringify({"username": username, "password": password})
	_send_auth_request("%s/login" % AUTH_BASE, body)

func _on_register_pressed() -> void:
	_status_label.text = ""
	var username := _username_edit.text.strip_edges()
	var password := _password_edit.text
	if username.is_empty() or password.is_empty():
		_status_label.text = "Enter a username and password."
		return
	var body := JSON.stringify({"username": username, "password": password, "clientId": SkinCatalog.client_id})
	_send_auth_request("%s/register" % AUTH_BASE, body)

func _send_auth_request(url: String, body: String) -> void:
	var req := HTTPRequest.new()
	add_child(req)
	req.request_completed.connect(func(_result: int, response_code: int, _headers: PackedStringArray, resp_body: PackedByteArray):
		req.queue_free()
		var parsed = JSON.parse_string(resp_body.get_string_from_utf8())
		if response_code != 200:
			var err_msg := "Request failed -- check your connection."
			if typeof(parsed) == TYPE_DICTIONARY and parsed.has("error"):
				err_msg = str(parsed["error"])
			_status_label.text = err_msg
			return
		if typeof(parsed) != TYPE_DICTIONARY:
			_status_label.text = "Unexpected response from server."
			return
		var token := str(parsed.get("token", ""))
		if token.is_empty():
			_status_label.text = "Unexpected response from server."
			return
		_token = token
		_save_token(token)
		SkinCatalog.override_client_id(str(parsed.get("primaryClientId", "")))
		_password_edit.text = ""
		_show_logged_in(_username_edit.text.strip_edges())
	)
	var err := req.request(url, ["Content-Type: application/json"], HTTPClient.METHOD_POST, body)
	if err != OK:
		_status_label.text = "Couldn't start the request."

func _on_logout_pressed() -> void:
	_clear_token()
	SkinCatalog.override_client_id(SkinCatalog.get_local_device_client_id())
	_username_edit.text = ""
	_password_edit.text = ""
	_status_label.text = ""
	_show_form()
