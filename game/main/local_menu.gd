extends Control

const UIStyle := preload("res://ui/ui_style.gd")
const LocalMapIconScene := preload("res://ui/local_map_icon.gd")
const LocalMapCatalog := preload("res://levels/local_maps/catalog.gd")

const MAP_THUMB_SIZE := Vector2(80, 64)

@onready var settings_box: VBoxContainer = $VBox/SettingsPanel/SettingsBox
@onready var npc_count_slider: HSlider = $VBox/SettingsPanel/SettingsBox/NpcCountRow/NpcCountSlider
@onready var npc_count_value: Label = $VBox/SettingsPanel/SettingsBox/NpcCountRow/NpcCountValue
@onready var skill_slider: HSlider = $VBox/SettingsPanel/SettingsBox/SkillRow/SkillSlider
@onready var skill_value: Label = $VBox/SettingsPanel/SettingsBox/SkillRow/SkillValue
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
	UIStyle.style_slider(npc_count_slider, UIStyle.COLOR_LOCAL)
	UIStyle.style_slider(skill_slider, UIStyle.COLOR_LOCAL)
	UIStyle.style_slider(round_duration_slider, UIStyle.COLOR_LOCAL)
	_build_map_row()

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

func _update_npc_count_label(value: float) -> void:
	npc_count_value.text = str(int(value))

func _update_skill_label(value: float) -> void:
	skill_value.text = str(int(value))

func _update_round_duration_label(value: float) -> void:
	round_duration_value.text = "%ds" % int(value)

## Map choice used to be its own screen (local_map_picker.tscn, now retired)
## reached only after Play Tag -- folded in here as a 4th settings row, a
## horizontally scrollable strip of the same LocalMapIcon preview widget the
## old picker's cards used, just smaller. Selection is a plain ButtonGroup
## of toggle buttons (see UIStyle.style_button's "pressed" stylebox for what
## marks the selected one) rather than immediately navigating anywhere --
## Play Tag now starts the match directly with whichever map is selected
## here, same as the 3 slider rows above it.
func _build_map_row() -> void:
	var header := HBoxContainer.new()
	settings_box.add_child(header)
	var label := Label.new()
	label.text = "Map"
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(label)

	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(0, MAP_THUMB_SIZE.y + 12)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	settings_box.add_child(scroll)
	var strip := HBoxContainer.new()
	strip.add_theme_constant_override("separation", 8)
	scroll.add_child(strip)

	var group := ButtonGroup.new()
	for id in LocalMapCatalog.MAP_ORDER:
		strip.add_child(_build_map_thumb(id, group))

func _build_map_thumb(id: String, group: ButtonGroup) -> Button:
	var btn := Button.new()
	btn.text = ""
	btn.custom_minimum_size = MAP_THUMB_SIZE
	btn.toggle_mode = true
	btn.button_group = group
	btn.button_pressed = id == GameSettings.selected_local_map
	btn.clip_contents = true
	btn.tooltip_text = String(LocalMapCatalog.MAPS[id].get("name", id))
	UIStyle.style_button(btn, UIStyle.COLOR_LOCAL, 8, false)
	btn.pressed.connect(func(): GameSettings.selected_local_map = id)

	var preview := LocalMapIconScene.new()
	preview.map_id = id
	preview.accent_color = UIStyle.COLOR_LOCAL
	preview.mouse_filter = Control.MOUSE_FILTER_IGNORE
	preview.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT, Control.PRESET_MODE_MINSIZE, 6)
	btn.add_child(preview)
	return btn

func _on_start_pressed() -> void:
	GameSettings.npc_count = int(npc_count_slider.value)
	GameSettings.npc_skill = int(skill_slider.value)
	GameSettings.round_duration = round_duration_slider.value
	get_tree().change_scene_to_file("res://main/game.tscn")

func _on_back_pressed() -> void:
	get_tree().change_scene_to_file("res://main/main_menu.tscn")
