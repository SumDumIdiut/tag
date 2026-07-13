extends Control

# Brief pre-match beat between the lobby and actual gameplay -- shows who's
# in the match and what they're wearing, then hands off to net_game.tscn
# exactly the way lobby_room.gd used to do directly. Purely client-side: no
# NetworkManager/RPC changes, just where the scene swap happens.

const NET_GAME_SCENE := preload("res://main/net_game.tscn")
const INTRO_DURATION_SEC := 2.5

@onready var roster_box: VBoxContainer = $VBox/RosterBox
@onready var countdown_label: Label = $VBox/CountdownLabel
@onready var skip_button: Button = $VBox/SkipButton

var _my_id := -1
var _roster := {}
var _time_left := INTRO_DURATION_SEC
var _proceeded := false
var _previews := {} # peer_id -> TextureRect, so a late-arriving custom skin can be re-applied

func setup(my_id: int, roster: Dictionary) -> void:
	_my_id = my_id
	_roster = roster

func _ready() -> void:
	skip_button.pressed.connect(_proceed)
	SkinCatalog.skin_received.connect(_on_skin_received)
	for peer_id in _roster.keys():
		roster_box.add_child(_build_row(peer_id, _roster[peer_id]))

func _build_row(peer_id: int, info: Dictionary) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)

	var preview := TextureRect.new()
	preview.custom_minimum_size = Vector2(32, 48)
	preview.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	preview.texture = SkinCatalog.get_texture(info.get("skin_id", "red"))
	row.add_child(preview)
	_previews[peer_id] = preview

	var name_label := Label.new()
	var you_tag := "  (you)" if peer_id == _my_id else ""
	name_label.text = "%s%s" % [info.get("username", "Player"), you_tag]
	name_label.add_theme_font_size_override("font_size", 20)
	name_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(name_label)

	return row

func _on_skin_received(skin_id: String) -> void:
	for peer_id in _roster.keys():
		if _roster[peer_id].get("skin_id", "") == skin_id and _previews.has(peer_id):
			_previews[peer_id].texture = SkinCatalog.get_texture(skin_id)

func _process(delta: float) -> void:
	_time_left -= delta
	countdown_label.text = "Starting in %d..." % maxi(ceili(_time_left), 0)
	if _time_left <= 0.0:
		_proceed()

func _proceed() -> void:
	if _proceeded:
		return
	_proceeded = true
	var scene := NET_GAME_SCENE.instantiate()
	scene.setup(_my_id, _roster)
	get_tree().root.add_child(scene)
	get_tree().current_scene.queue_free()
	get_tree().current_scene = scene
