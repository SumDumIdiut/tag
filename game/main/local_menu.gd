extends Control

const UIStyle := preload("res://ui/ui_style.gd")
const ModeIconScene := preload("res://ui/mode_icon.gd")

@onready var npc_count_row: HBoxContainer = $VBox/SettingsPanel/SettingsBox/NpcCountRow
@onready var npc_count_slider: HSlider = $VBox/SettingsPanel/SettingsBox/NpcCountRow/NpcCountSlider
@onready var npc_count_value: Label = $VBox/SettingsPanel/SettingsBox/NpcCountRow/NpcCountValue
@onready var skill_row: HBoxContainer = $VBox/SettingsPanel/SettingsBox/SkillRow
@onready var skill_slider: HSlider = $VBox/SettingsPanel/SettingsBox/SkillRow/SkillSlider
@onready var skill_value: Label = $VBox/SettingsPanel/SettingsBox/SkillRow/SkillValue
@onready var round_duration_row: HBoxContainer = $VBox/SettingsPanel/SettingsBox/RoundDurationRow
@onready var round_duration_slider: HSlider = $VBox/SettingsPanel/SettingsBox/RoundDurationRow/RoundDurationSlider
@onready var round_duration_value: Label = $VBox/SettingsPanel/SettingsBox/RoundDurationRow/RoundDurationValue
@onready var start_button: Button = $VBox/StartButton
@onready var back_button: Button = $VBox/BackButton

func _ready() -> void:
	UIStyle.add_background(self, "local_menu")
	$VBox/SettingsPanel.add_theme_stylebox_override("panel", UIStyle.panel_box(UIStyle.COLOR_LOCAL))
	# Same plain flat-color-no-glow bar treatment online_menu.gd's row uses --
	# Local only has the one real destination (there's nothing to arrange in
	# a row here), but it should still carry the same visual weight/boldness
	# as those bars rather than reading as a smaller, secondary action.
	UIStyle.style_button(start_button, UIStyle.COLOR_LOCAL, 18)
	start_button.add_theme_font_size_override("font_size", 18)
	UIStyle.style_back_button(back_button)
	_apply_bar_art(start_button, "play")
	_apply_bar_art(back_button, "back")
	UIStyle.style_slider(npc_count_slider, UIStyle.COLOR_LOCAL)
	UIStyle.style_slider(skill_slider, UIStyle.COLOR_LOCAL)
	UIStyle.style_slider(round_duration_slider, UIStyle.COLOR_LOCAL)
	_add_row_icon(npc_count_row, "controller")
	_add_row_icon(skill_row, "bolt")
	_add_row_icon(round_duration_row, "clock")

	npc_count_slider.value = GameSettings.npc_count
	skill_slider.value = GameSettings.npc_skill
	round_duration_slider.value = GameSettings.round_duration
	_update_npc_count_label(npc_count_slider.value)
	_update_skill_label(skill_slider.value)
	_update_round_duration_label(round_duration_slider.value)

	npc_count_slider.value_changed.connect(_update_npc_count_label)
	skill_slider.value_changed.connect(_update_skill_label)
	round_duration_slider.value_changed.connect(_update_round_duration_label)
	start_button.pressed.connect(_on_start_pressed)
	back_button.pressed.connect(_on_back_pressed)

## Prepends a small colored glyph to a settings row, matching the corner-
## button icon treatment main_menu.gd already uses (icon_wrap Control sized
## to just the glyph, inserted before the row's existing children).
func _add_row_icon(row: HBoxContainer, icon_type: String) -> void:
	var icon_wrap := Control.new()
	icon_wrap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	icon_wrap.custom_minimum_size = Vector2(22, 22)
	var icon := ModeIconScene.new()
	icon.icon_type = icon_type
	icon.icon_color = UIStyle.COLOR_LOCAL
	icon.set_anchors_preset(Control.PRESET_FULL_RECT)
	icon_wrap.add_child(icon)
	row.add_child(icon_wrap)
	row.move_child(icon_wrap, 0)

## Painted whole-button art for Play Tag / Back -- same fallback chain
## online_menu.gd's _style_bar() already uses (downloaded override, then
## baked-into-this-build), falling back to the plain styled button (already
## applied above) if neither exists.
func _apply_bar_art(btn: Button, key: String) -> void:
	var tex: Texture2D = GameAssetOverrides.load_override_texture(GameAssetOverrides.local_bar_override_path(key))
	if not tex:
		var path := "res://assets/icons/local_bars/%s.png" % key
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

func _update_npc_count_label(value: float) -> void:
	npc_count_value.text = str(int(value))

func _update_skill_label(value: float) -> void:
	skill_value.text = str(int(value))

func _update_round_duration_label(value: float) -> void:
	round_duration_value.text = "%ds" % int(value)

func _on_start_pressed() -> void:
	GameSettings.npc_count = int(npc_count_slider.value)
	GameSettings.npc_skill = int(skill_slider.value)
	GameSettings.round_duration = round_duration_slider.value
	get_tree().change_scene_to_file("res://main/local_map_picker.tscn")

func _on_back_pressed() -> void:
	get_tree().change_scene_to_file("res://main/main_menu.tscn")
