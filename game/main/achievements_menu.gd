extends Control

# Shows every achievement in the catalog (see achievement_catalog.gd) as a
# Minecraft-advancement-style progression graph: plain square nodes
# connected by lines showing which achievement leads to which, rather than
# a flat list. No icons/pictures anywhere -- a node is just a colored box
# (bright when unlocked, dim gray when locked); the name sits below it and
# the description shows as a native hover tooltip. The server only ever
# reports which ids are unlocked (GET /api/progression/:clientId), so
# what's still locked is purely a client-side concept, rendered dim rather
# than omitted.

const UIStyle := preload("res://ui/ui_style.gd")
const AchievementCatalog := preload("res://cosmetics/achievement_catalog.gd")
const RankBadgeScene := preload("res://ui/rank_badge.gd")
const AchievementIconScene := preload("res://ui/achievement_icon.gd")
const ACCENT := UIStyle.COLOR_ACCENT
# Locked icons are tinted toward this (multiplicatively) instead of showing
# their real color -- cheap "grayed out" without needing a second baked
# copy of every icon, same trick a locked-out button elsewhere might use.
const LOCKED_ICON_TINT := Color(0.4, 0.41, 0.45)

const NODE_SIZE := Vector2(44, 44)
const COL_SPACING := 90.0
const ROW_SPACING := 80.0
const CANVAS_PADDING := 40.0

const UNLOCKED_COLOR := Color(0.65, 0.48, 0.98)
const LOCKED_COLOR := Color(0.3, 0.31, 0.36)
const LINE_COLOR_DONE := Color(0.65, 0.48, 0.98, 0.7)
const LINE_COLOR_PENDING := Color(1, 1, 1, 0.25)

# (col, row) per achievement id -- lays out 4 independent chains (win,
# endurance, rank, misc), same "separate advancement trees" idea Minecraft's
# own tabs use, just all on one scrollable canvas instead of separate tabs
# (19 achievements comfortably fits one screen's worth of scrolling).
const NODE_LAYOUT := {
	"first_win": Vector2(0, 0), "ten_wins": Vector2(1, 0), "fifty_wins": Vector2(2, 0),
	"untouchable": Vector2(0, 1),
	"veteran": Vector2(0, 2), "century": Vector2(1, 2), "marathon": Vector2(2, 2),
	"silver": Vector2(0, 3), "gold": Vector2(1, 3), "platinum": Vector2(2, 3),
	"diamond": Vector2(3, 3), "master": Vector2(4, 3), "grandmaster": Vector2(5, 3),
	"champion": Vector2(6, 3), "legend": Vector2(7, 3), "mythic": Vector2(8, 3),
	"immortal": Vector2(9, 3),
	"last_place": Vector2(0, 4),
}

# [parent_id, child_id] -- drawn as a line between them, bright once BOTH
# ends are unlocked (a completed step of the path), dim otherwise.
const CONNECTIONS := [
	["first_win", "ten_wins"], ["ten_wins", "fifty_wins"], ["first_win", "untouchable"],
	["veteran", "century"], ["century", "marathon"],
	["silver", "gold"], ["gold", "platinum"], ["platinum", "diamond"], ["diamond", "master"],
	["master", "grandmaster"], ["grandmaster", "champion"], ["champion", "legend"],
	["legend", "mythic"], ["mythic", "immortal"],
]

const PROGRESSION_API_BASE := "https://codecade.co.za/tag/api/progression"

var _status_label: Label
var _canvas: Control
var _nodes := {} # id -> {box: PanelContainer, icon: Control}
var _unlocked_set := {}

func _ready() -> void:
	UIStyle.add_background(self, "achievements_menu")

	var vbox := VBoxContainer.new()
	vbox.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT, Control.PRESET_MODE_MINSIZE, 32)
	vbox.add_theme_constant_override("separation", 14)
	add_child(vbox)

	vbox.add_child(UIStyle.title_label("Achievements", 32))

	_status_label = Label.new()
	_status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status_label.add_theme_color_override("font_color", Color(0.7, 0.72, 0.78))
	_status_label.text = "Loading..."
	vbox.add_child(_status_label)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vbox.add_child(scroll)

	var max_col := 0.0
	var max_row := 0.0
	for pos in NODE_LAYOUT.values():
		max_col = maxf(max_col, pos.x)
		max_row = maxf(max_row, pos.y)
	_canvas = Control.new()
	_canvas.custom_minimum_size = Vector2(
		max_col * COL_SPACING + NODE_SIZE.x + CANVAS_PADDING * 2.0,
		max_row * ROW_SPACING + NODE_SIZE.y + 24.0 + CANVAS_PADDING * 2.0,
	)
	_canvas.draw.connect(_draw_connections)
	scroll.add_child(_canvas)

	for id in NODE_LAYOUT.keys():
		var a := AchievementCatalog.find(id)
		if a.is_empty():
			continue
		_nodes[id] = _build_node(a)

	var back_btn := Button.new()
	back_btn.text = "Back"
	back_btn.custom_minimum_size = Vector2(0, 40)
	UIStyle.style_back_button(back_btn)
	back_btn.pressed.connect(_on_back_pressed)
	vbox.add_child(back_btn)

	_fetch_progression()

func _node_center(id: String) -> Vector2:
	var pos: Vector2 = NODE_LAYOUT[id]
	return Vector2(
		CANVAS_PADDING + pos.x * COL_SPACING + NODE_SIZE.x * 0.5,
		CANVAS_PADDING + pos.y * ROW_SPACING + NODE_SIZE.y * 0.5,
	)

func _draw_connections() -> void:
	for conn in CONNECTIONS:
		var a: String = conn[0]
		var b: String = conn[1]
		if not (NODE_LAYOUT.has(a) and NODE_LAYOUT.has(b)):
			continue
		var done: bool = _unlocked_set.has(a) and _unlocked_set.has(b)
		_canvas.draw_line(_node_center(a), _node_center(b), LINE_COLOR_DONE if done else LINE_COLOR_PENDING, 3.0)

func _build_node(a: Dictionary) -> Dictionary:
	var pos: Vector2 = NODE_LAYOUT[a.id]

	var col := VBoxContainer.new()
	col.mouse_filter = Control.MOUSE_FILTER_PASS
	col.alignment = BoxContainer.ALIGNMENT_CENTER
	col.add_theme_constant_override("separation", 4)
	col.position = Vector2(CANVAS_PADDING + pos.x * COL_SPACING, CANVAS_PADDING + pos.y * ROW_SPACING)
	col.size = Vector2(NODE_SIZE.x, NODE_SIZE.y + 24.0)
	_canvas.add_child(col)

	var box := PanelContainer.new()
	box.custom_minimum_size = NODE_SIZE
	box.tooltip_text = String(a.desc)
	box.mouse_filter = Control.MOUSE_FILTER_STOP
	col.add_child(box)

	# The 10 "reach this rank" achievements reuse RankBadge directly -- same
	# art a ranked VS screen already shows for that exact tier, not a
	# second, different icon meaning the same thing. Everything else gets
	# its own small themed icon (see achievement_icon.gd).
	var icon: Control
	if String(a.get("category", "")) == "tier":
		icon = RankBadgeScene.new()
		icon.tier = String(a.get("tier", ""))
	else:
		icon = AchievementIconScene.new()
		icon.achievement_id = String(a.id)
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	icon.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT, Control.PRESET_MODE_MINSIZE, 4)
	box.add_child(icon)

	var name_label := Label.new()
	name_label.text = String(a.name)
	name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	name_label.autowrap_mode = TextServer.AUTOWRAP_WORD
	name_label.custom_minimum_size = Vector2(NODE_SIZE.x + 30.0, 0)
	name_label.add_theme_font_size_override("font_size", 10)
	col.add_child(name_label)

	return {"box": box, "icon": icon}

func _fetch_progression() -> void:
	if PlayerIdentity.client_id.is_empty():
		_status_label.text = "Log in to track achievements."
		return
	var req := HTTPRequest.new()
	add_child(req)
	req.request_completed.connect(func(_result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray):
		req.queue_free()
		if response_code != 200:
			_status_label.text = "Couldn't reach the server."
			return
		var parsed = JSON.parse_string(body.get_string_from_utf8())
		if typeof(parsed) != TYPE_DICTIONARY:
			_status_label.text = "Couldn't reach the server."
			return
		var unlocked_ids: Array = []
		for a in parsed.get("achievements", []):
			unlocked_ids.append(String(a.get("id", "")))
		_render(unlocked_ids)
	)
	req.request("%s/%s" % [PROGRESSION_API_BASE, PlayerIdentity.client_id])

func _render(unlocked_ids: Array) -> void:
	_unlocked_set.clear()
	for id in unlocked_ids:
		_unlocked_set[id] = true
	_status_label.text = "%d / %d unlocked" % [unlocked_ids.size(), AchievementCatalog.ACHIEVEMENTS.size()]
	for id in _nodes.keys():
		var box: PanelContainer = _nodes[id]["box"]
		var icon: Control = _nodes[id]["icon"]
		var unlocked: bool = _unlocked_set.has(id)
		# The icon itself now carries the achievement's real identity/color --
		# the panel is just a subtle frame around it, unlocked vs locked shown
		# by that frame's border plus the icon's own modulate (full color vs
		# grayed toward LOCKED_ICON_TINT) rather than a big flat color fill
		# behind it.
		var style := StyleBoxFlat.new()
		style.bg_color = Color(0, 0, 0, 0.25)
		style.border_width_left = 2
		style.border_width_top = 2
		style.border_width_right = 2
		style.border_width_bottom = 2
		style.border_color = UNLOCKED_COLOR.lightened(0.2) if unlocked else Color(0.4, 0.41, 0.46)
		style.corner_radius_top_left = 6
		style.corner_radius_top_right = 6
		style.corner_radius_bottom_right = 6
		style.corner_radius_bottom_left = 6
		box.add_theme_stylebox_override("panel", style)
		icon.modulate = Color.WHITE if unlocked else LOCKED_ICON_TINT
	_canvas.queue_redraw()

func _on_back_pressed() -> void:
	get_tree().change_scene_to_file("res://main/main_menu.tscn")
