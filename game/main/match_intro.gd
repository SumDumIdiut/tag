extends Control

# Brief pre-match beat between the lobby and actual gameplay -- shows who's
# in the match and what they're wearing, then hands off to net_game.tscn
# exactly the way lobby_room.gd used to do directly. Purely client-side: no
# NetworkManager/RPC changes, just where the scene swap happens.
#
# Any 2-sided playlist (1v1, 2v2 -- ranked or casual) gets the animated
# "VS" reveal via the shared TeamLobbyView (see ui/team_lobby_view.gd,
# reused from lobby_room.gd's live waiting-room view -- this is the same
# component just already-full and playing its reveal animation once).
# 3+-way FFA playlists (1v1v1, 1v1v1v1) and anything with no playlist info
# keep the plain roster list below.

const NET_GAME_SCENE := preload("res://main/net_game.tscn")
const UIStyle := preload("res://ui/ui_style.gd")
const PlaylistCatalog := preload("res://net/playlist_catalog.gd")
const TeamLobbyViewScene := preload("res://ui/team_lobby_view.gd")
const INTRO_DURATION_SEC := 2.5
const VS_INTRO_DURATION_SEC := 4.0 # longer -- there's an entrance animation to let play out

@onready var roster_box: VBoxContainer = $VBox/RosterPanel/RosterBox
@onready var countdown_label: Label = $VBox/CountdownLabel
@onready var skip_button: Button = $VBox/SkipButton

var _my_id := -1
var _roster := {}
var _level_id := ""
var _ranked := false
var _playlist_id := ""
var _time_left := INTRO_DURATION_SEC
var _proceeded := false
var _previews := {} # peer_id -> TextureRect, so a late-arriving custom skin can be re-applied
var _vs_mode := false

func setup(my_id: int, roster: Dictionary, level_id: String = "", ranked: bool = false, playlist_id: String = "") -> void:
	_my_id = my_id
	_level_id = level_id
	_roster = roster
	_ranked = ranked
	_playlist_id = playlist_id

func _ready() -> void:
	# A playlist id tells us exactly how many sides there are (team_count);
	# without one (an older/undifferentiated ranked match), fall back to
	# the original heuristic -- ranked and exactly 2 in the roster.
	if not _playlist_id.is_empty():
		_vs_mode = PlaylistCatalog.team_count(_playlist_id) == 2
	else:
		_vs_mode = _ranked and _roster.size() == 2

	if _vs_mode:
		_time_left = VS_INTRO_DURATION_SEC
		UIStyle.add_background(self, "match_intro_ranked" if _ranked else "match_intro")
		$VBox.visible = false
		_build_vs_layout()
	else:
		UIStyle.add_background(self, "match_intro")
		$VBox/RosterPanel.add_theme_stylebox_override("panel", UIStyle.panel_box(UIStyle.COLOR_NEUTRAL))
		UIStyle.style_back_button(skip_button)
		skip_button.pressed.connect(_proceed)
		for peer_id in _roster.keys():
			roster_box.add_child(_build_row(peer_id, _roster[peer_id]))
	SkinCatalog.skin_received.connect(_on_skin_received)

func _build_row(peer_id: int, info: Dictionary) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)

	var preview := TextureRect.new()
	preview.custom_minimum_size = Vector2(SkinCatalog.VISUAL_WIDTH, SkinCatalog.VISUAL_HEIGHT)
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
	scene.setup(_my_id, _roster, _level_id)
	get_tree().root.add_child(scene)
	get_tree().current_scene.queue_free()
	get_tree().current_scene = scene

# ─── 2-sided VS reveal (1v1 / 2v2, ranked or casual) ───────────────────────

func _build_vs_layout() -> void:
	var vs_root := Control.new()
	vs_root.name = "VsRoot"
	vs_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(vs_root)

	var team_view := TeamLobbyViewScene.new()
	team_view.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	team_view.playlist_id = _playlist_id if not _playlist_id.is_empty() else "1v1"
	team_view.ranked = _ranked
	team_view.my_id = _my_id
	team_view.accent_color = UIStyle.COLOR_RANKED if _ranked else UIStyle.COLOR_ONLINE
	vs_root.add_child(team_view)
	team_view.set_roster(_roster)
	team_view.play_full_reveal()

	var bottom_strip := CenterContainer.new()
	bottom_strip.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	bottom_strip.offset_top = -130
	bottom_strip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vs_root.add_child(bottom_strip)
	var bottom_box := VBoxContainer.new()
	bottom_box.add_theme_constant_override("separation", 10)
	bottom_strip.add_child(bottom_box)

	var countdown := Label.new()
	countdown.name = "VsCountdown"
	countdown.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	countdown.add_theme_font_size_override("font_size", 18)
	bottom_box.add_child(countdown)
	countdown_label = countdown

	var ready_btn := Button.new()
	ready_btn.text = "Ready!"
	ready_btn.custom_minimum_size = Vector2(320, 64)
	var accent: Color = UIStyle.COLOR_RANKED if _ranked else UIStyle.COLOR_ONLINE
	UIStyle.style_button(ready_btn, accent, 18)
	if _ranked:
		UIStyle.apply_bar_art(ready_btn, "ranked_bars", "ready")
	ready_btn.pressed.connect(_proceed)
	bottom_box.add_child(ready_btn)
	skip_button = ready_btn
