extends Control

const UIStyle := preload("res://ui/ui_style.gd")
const LocalMapIconScene := preload("res://ui/local_map_icon.gd")
const LocalMapCatalog := preload("res://levels/local_maps/catalog.gd")

const MAP_THUMB_SIZE := Vector2(108, 82)
const MAP_GRID_COLUMNS := 4
const MAP_GRID_SEPARATION := 10
const MAP_GRID_VISIBLE_ROWS := 3
const MAP_NAME_BAR_HEIGHT := 18.0

@onready var map_box: VBoxContainer = $VBox/MainRow/MapPanel/MapBox
@onready var settings_box: VBoxContainer = $VBox/MainRow/SettingsPanel/SettingsBox
@onready var npc_count_slider: HSlider = $VBox/MainRow/SettingsPanel/SettingsBox/NpcCountRow/NpcCountSlider
@onready var npc_count_value: Label = $VBox/MainRow/SettingsPanel/SettingsBox/NpcCountRow/NpcCountValue
@onready var skill_slider: HSlider = $VBox/MainRow/SettingsPanel/SettingsBox/SkillRow/SkillSlider
@onready var skill_value: Label = $VBox/MainRow/SettingsPanel/SettingsBox/SkillRow/SkillValue
@onready var round_duration_slider: HSlider = $VBox/MainRow/SettingsPanel/SettingsBox/RoundDurationRow/RoundDurationSlider
@onready var round_duration_value: Label = $VBox/MainRow/SettingsPanel/SettingsBox/RoundDurationRow/RoundDurationValue
@onready var start_button: Button = $VBox/StartButton
@onready var back_button: Button = $VBox/BackButton

var _trained_ai_button: Button
var _map_grid: GridContainer
var _map_button_group: ButtonGroup

func _ready() -> void:
	UIStyle.add_background(self, "local_menu")
	$VBox/MainRow/MapPanel.add_theme_stylebox_override("panel", UIStyle.panel_box(UIStyle.COLOR_LOCAL))
	$VBox/MainRow/SettingsPanel.add_theme_stylebox_override("panel", UIStyle.panel_box(UIStyle.COLOR_LOCAL))
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
	_build_map_grid()
	_build_trained_ai_toggle()

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
## reached only after Play Tag -- now its own panel to the left of the
## settings sliders (see local_menu.tscn's MainRow) instead of squeezed in
## as just another settings row, so there's real room for a big, legible
## grid: 4 columns of much larger thumbnails than the old single-row strip
## ever fit, 3 rows visible at once with vertical scroll for the rest.
## Selection is a plain ButtonGroup of toggle buttons, each styled in that
## map's own theme_color (see _build_map_thumb) so the selected border
## itself reflects which map's theme you're looking at, not one generic
## accent shared by all 27. Play Tag starts the match directly with
## whichever map is selected here, same as the slider rows beside it.
func _build_map_grid() -> void:
	var scroll := ScrollContainer.new()
	var grid_h := MAP_THUMB_SIZE.y * MAP_GRID_VISIBLE_ROWS + MAP_GRID_SEPARATION * (MAP_GRID_VISIBLE_ROWS - 1)
	scroll.custom_minimum_size = Vector2(0, grid_h)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	map_box.add_child(scroll)

	_map_grid = GridContainer.new()
	_map_grid.columns = MAP_GRID_COLUMNS
	_map_grid.add_theme_constant_override("h_separation", MAP_GRID_SEPARATION)
	_map_grid.add_theme_constant_override("v_separation", MAP_GRID_SEPARATION)
	scroll.add_child(_map_grid)

	_map_button_group = ButtonGroup.new()
	for id in LocalMapCatalog.MAP_ORDER:
		_map_grid.add_child(_build_map_thumb(id))

func _build_map_thumb(id: String) -> Button:
	var def: Dictionary = LocalMapCatalog.MAPS[id]
	var theme_color: Color = def.get("theme_color", UIStyle.COLOR_LOCAL)

	var btn := Button.new()
	btn.text = ""
	btn.custom_minimum_size = MAP_THUMB_SIZE
	btn.toggle_mode = true
	btn.button_group = _map_button_group
	btn.button_pressed = id == GameSettings.selected_local_map
	btn.clip_contents = true
	btn.tooltip_text = String(def.get("name", id))
	UIStyle.style_button(btn, theme_color, 8, false)
	btn.pressed.connect(func(): GameSettings.selected_local_map = id)

	var preview := LocalMapIconScene.new()
	preview.map_id = id
	preview.accent_color = UIStyle.COLOR_LOCAL
	preview.mouse_filter = Control.MOUSE_FILTER_IGNORE
	preview.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT, Control.PRESET_MODE_MINSIZE, 6)
	btn.add_child(preview)

	# Name is always visible, not just on hover -- a dark backing bar keeps
	# it legible regardless of how bright that map's own theme_color ends
	# up being.
	var name_bar := ColorRect.new()
	name_bar.color = Color(0, 0, 0, 0.55)
	name_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	name_bar.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	name_bar.offset_top = -MAP_NAME_BAR_HEIGHT
	btn.add_child(name_bar)

	var name_label := Label.new()
	name_label.text = String(def.get("name", id))
	name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	name_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	name_label.clip_text = true
	name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	name_label.add_theme_font_size_override("font_size", 11)
	name_label.add_theme_color_override("font_color", Color(0.94, 0.95, 0.98))
	name_label.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	name_label.offset_top = -MAP_NAME_BAR_HEIGHT
	btn.add_child(name_label)

	return btn

## TEMPORARY -- see GameSettings.use_trained_ai's own comment. A plain
## toggle button, not a slider row like the others above -- this isn't a
## real settings option meant to stick around, just a quick way to actually
## reach the RL-trained NPC (game/npc/trained_policy.gd) in-game.
func _build_trained_ai_toggle() -> void:
	_trained_ai_button = Button.new()
	_trained_ai_button.toggle_mode = true
	_trained_ai_button.button_pressed = GameSettings.use_trained_ai
	_trained_ai_button.custom_minimum_size = Vector2(0, 36)
	UIStyle.style_button(_trained_ai_button, UIStyle.COLOR_LOCAL, 10, false)
	_update_trained_ai_label()
	_trained_ai_button.toggled.connect(func(_pressed: bool): _update_trained_ai_label())
	settings_box.add_child(_trained_ai_button)

func _update_trained_ai_label() -> void:
	_trained_ai_button.text = "AI (trained): %s [temporary]" % ("ON -- one bot uses it" if _trained_ai_button.button_pressed else "OFF")

func _on_start_pressed() -> void:
	GameSettings.npc_count = int(npc_count_slider.value)
	GameSettings.npc_skill = int(skill_slider.value)
	GameSettings.round_duration = round_duration_slider.value
	GameSettings.use_trained_ai = _trained_ai_button.button_pressed
	get_tree().change_scene_to_file("res://main/game.tscn")

func _on_back_pressed() -> void:
	get_tree().change_scene_to_file("res://main/main_menu.tscn")
