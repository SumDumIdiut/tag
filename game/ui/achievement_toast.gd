extends Control
class_name AchievementToast

# A small "Achievement Unlocked" popup, top-center, that slides down in,
# holds, then slides back out -- queued one at a time so multiple unlocks
# in the same fetch (e.g. catching up on several at once) don't all pile up
# illegibly on top of each other. A caller just calls queue() per id; this
# handles its own timing entirely. Text only -- no icon/badge.

const UIStyle := preload("res://ui/ui_style.gd")
const AchievementCatalog := preload("res://cosmetics/achievement_catalog.gd")

const HOLD_DURATION_SEC := 2.6
const SLIDE_DURATION_SEC := 0.35

var _queue: Array = []
var _showing := false
var _panel: PanelContainer
var _name_label: Label

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	custom_minimum_size = Vector2(0, 90)

	_panel = PanelContainer.new()
	_panel.add_theme_stylebox_override("panel", UIStyle.panel_box(UIStyle.COLOR_ACCENT, 0.92, 1.0))
	_panel.set_anchors_preset(Control.PRESET_CENTER_TOP)
	_panel.custom_minimum_size = Vector2(280, 56)
	_panel.position = Vector2(-140, -70) # off-screen above, slides down into view
	add_child(_panel)

	var text_box := VBoxContainer.new()
	text_box.add_theme_constant_override("separation", 1)
	_panel.add_child(text_box)

	var title := Label.new()
	title.text = "ACHIEVEMENT UNLOCKED"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 10)
	title.add_theme_color_override("font_color", Color(1, 1, 1, 0.75))
	text_box.add_child(title)

	_name_label = Label.new()
	_name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_name_label.add_theme_font_size_override("font_size", 16)
	text_box.add_child(_name_label)

func queue(achievement_id: String) -> void:
	var a := AchievementCatalog.find(achievement_id)
	if a.is_empty():
		return
	_queue.append(a)
	if not _showing:
		_show_next()

func _show_next() -> void:
	if _queue.is_empty():
		_showing = false
		return
	_showing = true
	var a: Dictionary = _queue.pop_front()
	_name_label.text = String(a.name)

	var tween := create_tween()
	tween.tween_property(_panel, "position:y", 16.0, SLIDE_DURATION_SEC).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tween.tween_interval(HOLD_DURATION_SEC)
	tween.tween_property(_panel, "position:y", -70.0, SLIDE_DURATION_SEC).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN)
	tween.tween_callback(_show_next)
