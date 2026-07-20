extends Control

# Brief pre-match beat between the lobby and actual gameplay -- shows who's
# in the match and what they're wearing, then hands off to net_game.tscn
# exactly the way lobby_room.gd used to do directly. Purely client-side: no
# NetworkManager/RPC changes, just where the scene swap happens.
#
# A ranked 1v1 gets a dedicated animated "VS" reveal (see _build_vs_layout)
# instead of the plain roster list every other match (casual, or ranked
# with >2 players) still uses -- server_match.gd only bothers fetching
# elo/tier for ranked matches at all, and the sketch this was built from was
# explicitly a 2-player face-off, so that's the one case worth the bespoke
# treatment.

const NET_GAME_SCENE := preload("res://main/net_game.tscn")
const UIStyle := preload("res://ui/ui_style.gd")
const CharacterPreviewScene := preload("res://ui/character_preview.gd")
const RankBadgeScene := preload("res://ui/rank_badge.gd")
const INTRO_DURATION_SEC := 2.5
const VS_INTRO_DURATION_SEC := 4.0 # longer -- there's an entrance animation to let play out

@onready var roster_box: VBoxContainer = $VBox/RosterPanel/RosterBox
@onready var countdown_label: Label = $VBox/CountdownLabel
@onready var skip_button: Button = $VBox/SkipButton

var _my_id := -1
var _roster := {}
var _level_id := ""
var _ranked := false
var _time_left := INTRO_DURATION_SEC
var _proceeded := false
var _previews := {} # peer_id -> TextureRect, so a late-arriving custom skin can be re-applied
var _vs_mode := false

func setup(my_id: int, roster: Dictionary, level_id: String = "", ranked: bool = false) -> void:
	_my_id = my_id
	_level_id = level_id
	_roster = roster
	_ranked = ranked

func _ready() -> void:
	_vs_mode = _ranked and _roster.size() == 2
	if _vs_mode:
		_time_left = VS_INTRO_DURATION_SEC
		UIStyle.add_background(self, "match_intro_ranked")
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

# ─── Ranked 1v1 VS reveal ──────────────────────────────────────────────────

const CARD_PORTRAIT_SIZE := Vector2(150, 190)
const CARD_WIDTH := 340.0

func _build_vs_layout() -> void:
	var peer_ids: Array = _roster.keys()
	# My own entry always on the left -- reads as "you" facing outward
	# toward the opponent, rather than an arbitrary left/right assignment.
	if peer_ids.size() == 2 and peer_ids[0] != _my_id:
		peer_ids = [peer_ids[1], peer_ids[0]]

	var vs_root := Control.new()
	vs_root.name = "VsRoot"
	vs_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	vs_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(vs_root)

	var divider := _DividerLine.new()
	divider.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	vs_root.add_child(divider)

	var left_card := _build_vs_card(peer_ids[0], _roster[peer_ids[0]])
	var right_card := _build_vs_card(peer_ids[1], _roster[peer_ids[1]])
	var vs_label := _build_vs_label()

	# Build inside a throwaway CenterContainer/HBoxContainer first so Godot's
	# own layout engine computes correct centered positions for both cards
	# -- hand-computed anchor/offset math for this placed the right card
	# off-screen entirely and clipped the left one on a first pass
	# (confirmed by screenshot). Once layout has resolved one frame later,
	# each piece is reparented directly to vs_root (a plain Control, which
	# never auto-repositions children the way a Container does) at its
	# computed global position, so the entrance tween below can freely
	# animate `position` without a Container fighting it back every sort.
	var layout_calc := CenterContainer.new()
	layout_calc.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	vs_root.add_child(layout_calc)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 60)
	layout_calc.add_child(row)
	row.add_child(left_card)
	row.add_child(vs_label)
	row.add_child(right_card)
	await get_tree().process_frame

	var left_final := left_card.global_position
	var right_final := right_card.global_position
	var vs_final := vs_label.global_position
	var vs_size := vs_label.size

	row.remove_child(left_card)
	row.remove_child(vs_label)
	row.remove_child(right_card)
	layout_calc.queue_free()

	vs_root.add_child(left_card)
	vs_root.add_child(right_card)
	vs_root.add_child(vs_label)
	left_card.global_position = left_final
	right_card.global_position = right_final
	vs_label.global_position = vs_final
	vs_label.pivot_offset = vs_size * 0.5
	vs_label.scale = Vector2.ZERO

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
	UIStyle.style_button(ready_btn, UIStyle.COLOR_RANKED, 18)
	_apply_ready_button_art(ready_btn)
	ready_btn.pressed.connect(_proceed)
	bottom_box.add_child(ready_btn)
	skip_button = ready_btn

	_animate_vs_entrance(left_card, right_card, vs_label)

func _build_vs_label() -> Label:
	var vs_label := Label.new()
	vs_label.text = "VS"
	vs_label.add_theme_font_size_override("font_size", 64)
	vs_label.add_theme_color_override("font_color", UIStyle.COLOR_RANKED)
	vs_label.custom_minimum_size = Vector2(120, 0)
	vs_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vs_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	vs_label.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	return vs_label

func _build_vs_card(peer_id: int, info: Dictionary) -> VBoxContainer:
	var card := VBoxContainer.new()
	card.name = "Card%d" % peer_id
	card.custom_minimum_size = Vector2(CARD_WIDTH, 320)
	card.alignment = BoxContainer.ALIGNMENT_CENTER
	card.add_theme_constant_override("separation", 8)

	var portrait_wrap := CenterContainer.new()
	portrait_wrap.custom_minimum_size = Vector2(0, CARD_PORTRAIT_SIZE.y)
	card.add_child(portrait_wrap)
	var portrait := CharacterPreviewScene.new()
	portrait.skin_id = info.get("skin_id", "red")
	portrait.hat_id = info.get("hat_id", "")
	portrait.zoom = 3.4
	portrait.custom_minimum_size = CARD_PORTRAIT_SIZE
	portrait_wrap.add_child(portrait)

	var you_tag := "  (You)" if peer_id == _my_id else ""
	var name_label := Label.new()
	name_label.text = "%s%s" % [info.get("username", "Player"), you_tag]
	name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	name_label.add_theme_font_size_override("font_size", 22)
	card.add_child(name_label)

	var elo: int = int(info.get("elo", -1))
	var tier: String = String(info.get("tier", ""))
	var stats_row := HBoxContainer.new()
	stats_row.alignment = BoxContainer.ALIGNMENT_CENTER
	stats_row.add_theme_constant_override("separation", 8)
	card.add_child(stats_row)
	if elo >= 0:
		var badge := RankBadgeScene.new()
		badge.tier = tier
		badge.custom_minimum_size = Vector2(28, 32)
		stats_row.add_child(badge)
		var elo_label := Label.new()
		elo_label.text = "%s  ·  %d ELO" % [tier, elo]
		elo_label.add_theme_font_size_override("font_size", 16)
		elo_label.add_theme_color_override("font_color", UIStyle.tier_color(tier))
		elo_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		stats_row.add_child(elo_label)
	else:
		var unranked := Label.new()
		unranked.text = "Unranked"
		unranked.add_theme_font_size_override("font_size", 16)
		unranked.add_theme_color_override("font_color", UIStyle.COLOR_NEUTRAL)
		stats_row.add_child(unranked)

	_previews[peer_id] = portrait
	return card

func _apply_ready_button_art(btn: Button) -> void:
	var tex: Texture2D = GameAssetOverrides.load_override_texture(GameAssetOverrides.ranked_bar_override_path("ready"))
	if not tex:
		var path := "res://assets/icons/ranked_bars/ready.png"
		if ResourceLoader.exists(path):
			tex = load(path)
	if not tex:
		return
	btn.text = ""
	btn.clip_contents = true
	var art := TextureRect.new()
	art.mouse_filter = Control.MOUSE_FILTER_IGNORE
	art.texture = tex
	art.stretch_mode = TextureRect.STRETCH_SCALE
	art.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	art.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	btn.add_child(art)

## Both cards slide in from off-screen and converge toward center, then the
## VS label punches in with an over-scaled elastic settle once they land --
## same "slam" beat a fighting-game character-select reveal uses.
func _animate_vs_entrance(left_card: Control, right_card: Control, vs_label: Label) -> void:
	var screen_w: float = get_viewport_rect().size.x
	var left_target := left_card.position
	var right_target := right_card.position
	left_card.position.x -= screen_w
	right_card.position.x += screen_w

	var tween := create_tween()
	tween.set_parallel(true)
	tween.tween_property(left_card, "position:x", left_target.x, 0.55).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tween.tween_property(right_card, "position:x", right_target.x, 0.55).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tween.chain().tween_property(vs_label, "scale", Vector2(1.35, 1.35), 0.18).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tween.chain().tween_property(vs_label, "scale", Vector2.ONE, 0.12).set_trans(Tween.TRANS_SINE)

## A jagged pixel-art diagonal splitting the two VS cards, matching the
## hand-drawn look of every other painted asset in the game rather than a
## single perfectly straight anti-aliased line.
class _DividerLine extends Control:
	func _ready() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func _draw() -> void:
		var w: float = size.x
		var h: float = size.y
		var cx := w * 0.5
		var rng := RandomNumberGenerator.new()
		rng.seed = 1337
		var segments := 14
		var points := PackedVector2Array()
		for i in segments + 1:
			var t := float(i) / float(segments)
			var jitter := rng.randf_range(-14.0, 14.0)
			points.append(Vector2(cx + jitter, t * h))
		var color := Color(0.95, 0.95, 0.98, 0.9)
		for i in points.size() - 1:
			draw_line(points[i], points[i + 1], color, 6.0)
			draw_line(points[i], points[i + 1], UIStyle.COLOR_RANKED, 2.0)
