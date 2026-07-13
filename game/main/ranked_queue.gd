extends Control

# "Find Ranked Match": joins an existing open ranked server if one's already
# listed, or silently hosts one and waits in it if not -- mirrors
# quick_play.gd's shape, but a ranked server auto-adds/auto-starts on its
# own (see NetworkManager.is_ranked_server), so this screen never has to
# call create/join/quick-join lobby RPCs itself, just connect and wait.

const MATCH_INTRO_SCENE := preload("res://main/match_intro.tscn")
const DIRECTORY_URL := "https://codecade.co.za/tag/api/servers"
const RELAY_JOIN_BASE := "wss://codecade.co.za/tag/relay/join/"

const UIStyle := preload("res://ui/ui_style.gd")
const ModeIconScene := preload("res://ui/mode_icon.gd")

@onready var status_label: Label = $VBox/StatusPanel/StatusBox/StatusLabel
@onready var back_button: Button = $VBox/BackButton
@onready var icon_slot: Control = $VBox/StatusPanel/StatusBox/Icon

var _http: HTTPRequest
var _spawner: LocalServerSpawner
var _username := ""
# NetworkManager is an autoload -- its signals outlive this screen, so a
# match_started (or a late directory/connect response) can still fire after
# Cancel is pressed and yank the player into a match anyway. Every async
# callback below checks this first. See quick_play.gd's _cancelled for the
# full explanation (same bug class, found and fixed there first).
var _cancelled := false

func _ready() -> void:
	UIStyle.add_background(self)
	$VBox/StatusPanel.add_theme_stylebox_override("panel", UIStyle.panel_box(UIStyle.COLOR_RANKED))
	UIStyle.style_back_button(back_button)
	_setup_pulsing_icon()

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

	status_label.text = "Finding a ranked match..."
	if _http.request(DIRECTORY_URL) != OK:
		_host_new_ranked_server()

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
		if s.playerCount >= s.maxPlayers:
			continue
		if best == null or s.playerCount > best.playerCount:
			best = s
	if best == null:
		_host_new_ranked_server()
		return
	status_label.text = "Joining a ranked match..."
	NetworkManager.set_username(_username)
	NetworkManager.start_client(RELAY_JOIN_BASE + str(best.id), _username)

func _on_join_existing_failed() -> void:
	if _cancelled:
		return
	status_label.text = "That server just went offline -- hosting a new one instead..."
	_host_new_ranked_server()

func _host_new_ranked_server() -> void:
	if _cancelled:
		return
	status_label.text = "No open ranked matches -- starting one..."
	_spawner.spawn("%s's Ranked Match" % _username, _username, ["--ranked"])

func _on_spawn_failed(reason: String) -> void:
	if _cancelled:
		return
	status_label.text = reason

func _on_connected() -> void:
	if _cancelled:
		return
	status_label.text = "Waiting for more players..."

func _on_match_started(_lobby_id: int, my_id: int, roster: Dictionary) -> void:
	if _cancelled:
		return
	var scene := MATCH_INTRO_SCENE.instantiate()
	scene.setup(my_id, roster)
	get_tree().root.add_child(scene)
	get_tree().current_scene.queue_free()
	get_tree().current_scene = scene

func _on_back_pressed() -> void:
	_cancelled = true
	# See quick_play.gd's _on_back_pressed for why both of these matter:
	# an in-flight HTTPRequest blocks the engine on its background I/O
	# thread when freed mid-request, and disconnecting our own connection
	# before (not after) killing any server we spawned avoids a graceful
	# close handshake hanging against an already-dead server.
	_http.cancel_request()
	NetworkManager.disconnect_from_server()
	_spawner.kill_child()
	get_tree().change_scene_to_file("res://main/main_menu.tscn")

## A small pulsing star icon over the status text, matching the Ranked
## bar's own icon/color from the main menu.
func _setup_pulsing_icon() -> void:
	var icon = ModeIconScene.new()
	icon.icon_type = "star"
	icon.icon_color = UIStyle.COLOR_RANKED
	icon.custom_minimum_size = Vector2(40, 48)
	icon.set_anchors_preset(Control.PRESET_CENTER_TOP)
	icon.position = Vector2(-20, 0)
	icon_slot.add_child(icon)
	var tween := create_tween().set_loops()
	tween.tween_property(icon, "modulate:a", 0.4, 0.6).set_trans(Tween.TRANS_SINE)
	tween.tween_property(icon, "modulate:a", 1.0, 0.6).set_trans(Tween.TRANS_SINE)
