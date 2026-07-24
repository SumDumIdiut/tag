extends Control

# Shows every achievement in the catalog (see achievement_catalog.gd), not
# just whichever ones this player has -- the server only ever reports
# unlocked ids (GET /api/progression/:clientId), so what's still locked is
# entirely a client-side concept, rendered dimmed with a padlock badge
# (achievement_badge.gd) rather than left off the list. Built entirely in
# code, same pattern friends_menu.gd already established.

const UIStyle := preload("res://ui/ui_style.gd")
const AchievementCatalog := preload("res://cosmetics/achievement_catalog.gd")
const AchievementBadgeScene := preload("res://ui/achievement_badge.gd")
const PROGRESSION_API_BASE := "https://codecade.co.za/tag/api/progression"
const ACCENT := UIStyle.COLOR_ACCENT

var _status_label: Label
var _list_box: VBoxContainer

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
	_list_box = VBoxContainer.new()
	_list_box.add_theme_constant_override("separation", 8)
	_list_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_list_box)

	# Placeholder rows (all locked) until the real unlocked set arrives.
	_render([])

	var back_btn := Button.new()
	back_btn.text = "Back"
	back_btn.custom_minimum_size = Vector2(0, 40)
	UIStyle.style_back_button(back_btn)
	back_btn.pressed.connect(_on_back_pressed)
	vbox.add_child(back_btn)

	_fetch_progression()

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
	for child in _list_box.get_children():
		_list_box.remove_child(child)
		child.queue_free()
	var unlocked_set := {}
	for id in unlocked_ids:
		unlocked_set[id] = true
	_status_label.text = "%d / %d unlocked" % [unlocked_ids.size(), AchievementCatalog.ACHIEVEMENTS.size()]
	for a in AchievementCatalog.ACHIEVEMENTS:
		_list_box.add_child(_build_row(a, unlocked_set.has(a.id)))

func _build_row(a: Dictionary, unlocked: bool) -> Control:
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", UIStyle.panel_box(ACCENT if unlocked else UIStyle.COLOR_NEUTRAL, 0.05 if unlocked else 0.02))

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	panel.add_child(row)

	var badge := AchievementBadgeScene.new()
	badge.category = String(a.category)
	badge.tier = String(a.get("tier", ""))
	badge.unlocked = unlocked
	badge.achievement_id = String(a.id)
	badge.custom_minimum_size = Vector2(44, 44)
	row.add_child(badge)

	var text_box := VBoxContainer.new()
	text_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	text_box.add_theme_constant_override("separation", 2)
	row.add_child(text_box)

	var name_label := Label.new()
	name_label.text = String(a.name)
	name_label.add_theme_font_size_override("font_size", 16)
	if not unlocked:
		name_label.add_theme_color_override("font_color", Color(0.55, 0.57, 0.62))
	text_box.add_child(name_label)

	var desc_label := Label.new()
	desc_label.text = String(a.desc)
	desc_label.add_theme_font_size_override("font_size", 12)
	desc_label.add_theme_color_override("font_color", Color(0.6, 0.63, 0.72))
	text_box.add_child(desc_label)

	return panel

func _on_back_pressed() -> void:
	get_tree().change_scene_to_file("res://main/main_menu.tscn")
