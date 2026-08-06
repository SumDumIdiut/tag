extends Control

# Optional account screen -- logging in is never a wall in front of playing.
# Built entirely in code (no hand-edited .tscn node tree), matching this
# project's established pattern for anything added after the initial hand-
# authored screens (see art_tool.gd's Tiles/Icons pages). Talks to the new
# /api/auth/* endpoints on the relay (relay-server/server.js) added
# alongside this screen.
#
# Session persistence/restore itself lives in PlayerIdentity (an autoload),
# not here -- it runs the instant the app boots, before any scene including
# this one even exists, so account-keyed features (friends, party, display
# name) don't silently stay on this device's local id for the whole session
# just because the player never happened to open this screen. This screen
# just reflects whatever PlayerIdentity.logged_in_username already is (the
# common case by the time anyone could navigate here) and listens for
# account_restored in case it's still in flight, or fires fresh right after
# a login/register submitted from here.

const UIStyle := preload("res://ui/ui_style.gd")
const AUTH_BASE := PlayerIdentity.AUTH_BASE
const ACCENT := UIStyle.COLOR_ACCENT

var _status_label: Label
var _logged_in_box: VBoxContainer
var _form_box: VBoxContainer
var _username_edit: LineEdit
var _password_edit: LineEdit
var _account_label: Label

func _ready() -> void:
	UIStyle.add_background(self, "login_screen")
	PlayerIdentity.account_restored.connect(_show_logged_in)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(center)

	var vbox := VBoxContainer.new()
	vbox.custom_minimum_size = Vector2(360, 0)
	vbox.add_theme_constant_override("separation", 14)
	center.add_child(vbox)

	var title_label := UIStyle.title_label("Account", 32)
	vbox.add_child(title_label)
	UIStyle.apply_layout_override(title_label, "login_screen.title")
	var subtitle_label := UIStyle.subtitle_label("Optional -- lets your progress follow you across devices.")
	vbox.add_child(subtitle_label)
	UIStyle.apply_layout_override(subtitle_label, "login_screen.subtitle")

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
	back_btn.pressed.connect(func(): get_tree().change_scene_to_file("res://main/main_menu.tscn"))
	vbox.add_child(back_btn)
	UIStyle.apply_layout_override(back_btn, "login_screen.back_button")

	if PlayerIdentity.logged_in_username.is_empty():
		_show_form()
	else:
		_show_logged_in(PlayerIdentity.logged_in_username)

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
	login_btn.pressed.connect(_on_login_pressed)
	row.add_child(login_btn)
	UIStyle.apply_layout_override(login_btn, "login_screen.login_button")

	var register_btn := Button.new()
	register_btn.text = "Create Account"
	register_btn.custom_minimum_size = Vector2(0, 44)
	register_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UIStyle.style_button(register_btn, UIStyle.COLOR_ONLINE)
	register_btn.pressed.connect(_on_register_pressed)
	row.add_child(register_btn)
	UIStyle.apply_layout_override(register_btn, "login_screen.register_button")

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
	logout_btn.pressed.connect(_on_logout_pressed)
	_logged_in_box.add_child(logout_btn)
	UIStyle.apply_layout_override(logout_btn, "login_screen.logout_button")

func _show_form() -> void:
	_form_box.visible = true
	_logged_in_box.visible = false

func _show_logged_in(username: String) -> void:
	_account_label.text = "Logged in as %s" % username
	_form_box.visible = false
	_logged_in_box.visible = true

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
	var body := JSON.stringify({"username": username, "password": password, "clientId": PlayerIdentity.client_id})
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
		PlayerIdentity.save_token(token)
		_password_edit.text = ""
		# set_logged_in() emits account_restored, which _ready() already
		# connected to _show_logged_in -- no need to call it directly here too.
		PlayerIdentity.set_logged_in(_username_edit.text.strip_edges(), str(parsed.get("primaryClientId", "")))
	)
	var err := req.request(url, ["Content-Type: application/json"], HTTPClient.METHOD_POST, body)
	if err != OK:
		_status_label.text = "Couldn't start the request."

func _on_logout_pressed() -> void:
	PlayerIdentity.log_out()
	_username_edit.text = ""
	_password_edit.text = ""
	_status_label.text = ""
	_show_form()
