extends Control

# Brief pre-match beat between the lobby and actual gameplay -- shows who's
# in the match and their assigned color, then hands off to net_game.tscn
# exactly the way lobby_room.gd used to do directly. Purely client-side: no
# NetworkManager/RPC changes, just where the scene swap happens.
#
# Any 2-sided playlist (1v1, 2v2 -- ranked or casual) gets the animated
# "VS" reveal via the shared TeamLobbyView (see ui/team_lobby_view.gd,
# reused from lobby_room.gd's live waiting-room view -- this is the same
# component just already-full and playing its reveal animation once). 1v1v1
# gets a 3-column reveal (see ui/columns_reveal_view.gd), 1v1v1v1 a 4-corner
# one (see ui/corners_reveal_view.gd). A private match with no playlist info
# and >4 players gets the circular reveal (ui/circle_reveal_view.gd);
# anything else (an older/undifferentiated ranked match, or a small private
# party) keeps the plain roster list below.

const NET_GAME_SCENE := preload("res://main/net_game.tscn")
const UIStyle := preload("res://ui/ui_style.gd")
const PlaylistCatalog := preload("res://net/playlist_catalog.gd")
const TeamLobbyViewScene := preload("res://ui/team_lobby_view.gd")
const CircleRevealViewScene := preload("res://ui/circle_reveal_view.gd")
const ColumnsRevealViewScene := preload("res://ui/columns_reveal_view.gd")
const CornersRevealViewScene := preload("res://ui/corners_reveal_view.gd")
const CharacterPreviewScene := preload("res://ui/character_preview.gd")
const INTRO_DURATION_SEC := 2.5
const VS_INTRO_DURATION_SEC := 4.0 # longer -- there's an entrance animation to let play out
const CIRCLE_REVEAL_DURATION_SEC := 4.0
const COLUMNS_REVEAL_DURATION_SEC := 4.0
const CORNERS_REVEAL_DURATION_SEC := 4.0

@onready var title_label: Label = $VBox/Title
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
var _vs_mode := false
var _circle_mode := false
var _columns_mode := false
var _corners_mode := false

func setup(my_id: int, roster: Dictionary, level_id: String = "", ranked: bool = false, playlist_id: String = "") -> void:
	_my_id = my_id
	_level_id = level_id
	_roster = roster
	_ranked = ranked
	_playlist_id = playlist_id

func _ready() -> void:
	# A playlist id tells us exactly how many sides there are (team_count);
	# without one (an older/undifferentiated ranked match, or a private
	# party match, which never carries one -- private matches are never
	# ranked and never carry a playlist_id at all), there's no team info to
	# read, so fall back to roster size alone: 2 reads as a natural "VS", 3
	# or 4 as a natural 3-/4-way split -- the exact same reveals ranked/
	# casual get for those same headcounts, just without any team-color
	# meaning (see _build_vs_layout's own playlist_id fallback to "1v1" for
	# the no-teams case). Previously gated on `_ranked`, which meant a
	# private match's own 2/3/4-player games never got ANY of these reveals
	# at all (fell straight to the plain roster list) -- confirmed by
	# reading through this dispatch, not just the >4 circle-reveal case
	# private matches already had.
	if not _playlist_id.is_empty():
		_vs_mode = PlaylistCatalog.team_count(_playlist_id) == 2
		_columns_mode = PlaylistCatalog.team_count(_playlist_id) == 3
		_corners_mode = PlaylistCatalog.team_count(_playlist_id) == 4
	else:
		match _roster.size():
			2:
				_vs_mode = true
			3:
				_columns_mode = true
			4:
				_corners_mode = true
	_circle_mode = not (_vs_mode or _columns_mode or _corners_mode) and _roster.size() > 4

	if _vs_mode:
		_time_left = VS_INTRO_DURATION_SEC
		UIStyle.add_background(self, "match_intro_ranked" if _ranked else "match_intro")
		$VBox.visible = false
		_build_vs_layout()
	elif _columns_mode:
		_time_left = COLUMNS_REVEAL_DURATION_SEC
		UIStyle.add_background(self, "match_intro_ranked" if _ranked else "match_intro")
		$VBox.visible = false
		_build_columns_layout()
	elif _corners_mode:
		_time_left = CORNERS_REVEAL_DURATION_SEC
		UIStyle.add_background(self, "match_intro_ranked" if _ranked else "match_intro")
		$VBox.visible = false
		_build_corners_layout()
	elif _circle_mode:
		_time_left = CIRCLE_REVEAL_DURATION_SEC
		UIStyle.add_background(self, "match_intro")
		$VBox.visible = false
		_build_circle_layout()
	else:
		UIStyle.add_background(self, "match_intro")
		$VBox/RosterPanel.add_theme_stylebox_override("panel", UIStyle.panel_box(UIStyle.COLOR_NEUTRAL))
		UIStyle.style_back_button(skip_button)
		skip_button.pressed.connect(_proceed)
		# Title/CountdownLabel/SkipButton/RosterPanel are only ever actually
		# visible for a roster shape none of the 4 real playlists produce (see
		# the mode dispatch above -- every real 2/3/4-player match hides $VBox
		# entirely in favor of the vs/columns/corners reveal instead).
		# Registered anyway, same futureproofing reasoning as casual_queue.gd/
		# ranked_queue.gd's identical fallback UI.
		UIStyle.apply_layout_override(title_label, "match_intro.title")
		UIStyle.apply_layout_override(countdown_label, "match_intro.countdown_label")
		UIStyle.apply_layout_override(skip_button, "match_intro.skip_button")
		for peer_id in _roster.keys():
			roster_box.add_child(_build_row(peer_id, _roster[peer_id]))

func _build_row(peer_id: int, info: Dictionary) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)

	var preview := CharacterPreviewScene.new()
	preview.custom_minimum_size = Vector2(40, 40)
	preview.color_id = info.get("color_id", PlayerColors.DEFAULT_ID)
	row.add_child(preview)

	var name_label := Label.new()
	var you_tag := "  (you)" if peer_id == _my_id else ""
	name_label.text = "%s%s" % [info.get("username", "Player"), you_tag]
	name_label.add_theme_font_size_override("font_size", 20)
	name_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	name_label.add_theme_color_override("font_color", UIStyle.tier_color(info.get("tier", "")))
	row.add_child(name_label)

	return row

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

# ─── Circle reveal (private match, >4 players) ─────────────────────────────

func _build_circle_layout() -> void:
	var circle := CircleRevealViewScene.new()
	circle.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	circle.my_id = _my_id
	add_child(circle)
	circle.set_roster(_roster)
	countdown_label = circle.countdown_label

# ─── 3-column reveal (1v1v1, ranked or casual) ─────────────────────────────

func _build_columns_layout() -> void:
	var columns := ColumnsRevealViewScene.new()
	columns.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	columns.my_id = _my_id
	add_child(columns)
	columns.set_roster(_roster)
	countdown_label = columns.countdown_label

# ─── 4-corner reveal (1v1v1v1, ranked or casual) ───────────────────────────

func _build_corners_layout() -> void:
	var corners := CornersRevealViewScene.new()
	corners.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	corners.my_id = _my_id
	add_child(corners)
	corners.set_roster(_roster)
	countdown_label = corners.countdown_label

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
	# Plain reveal style, matching columns_reveal_view.gd/corners_reveal_
	# view.gd's own 3+-way reveals (no background, no VS badge, flat-
	# bordered cards with no rank line) -- the richer look is a waiting-
	# room-only identity cue (see team_lobby_view.gd's own comment), not
	# part of the "match found" moment itself.
	team_view.queue_style = false
	vs_root.add_child(team_view)
	team_view.set_roster(_roster)
	team_view.play_full_reveal()
	# No countdown text or Ready button here -- the reveal plays and
	# _process()'s existing _time_left timer (still ticking against the
	# original, now-invisible $VBox/CountdownLabel) auto-proceeds once
	# VS_INTRO_DURATION_SEC elapses, same as the circle reveal already does
	# with no manual skip.
