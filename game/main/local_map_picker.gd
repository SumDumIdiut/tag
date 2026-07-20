extends Control

const UIStyle := preload("res://ui/ui_style.gd")
const LocalMapIconScene := preload("res://ui/local_map_icon.gd")
const LocalMapCatalog := preload("res://levels/local_maps/catalog.gd")

const CARD_SIZE := Vector2(240, 190)
const PREVIEW_SIZE := Vector2(208, 110)

@onready var map_grid: GridContainer = $VBox/MapGrid
@onready var back_button: Button = $VBox/BackButton

func _ready() -> void:
	UIStyle.add_background(self, "local_map_picker")
	UIStyle.style_back_button(back_button)
	back_button.pressed.connect(_on_back_pressed)

	for id in LocalMapCatalog.MAP_ORDER:
		map_grid.add_child(_build_card(id, LocalMapCatalog.MAPS[id]))

func _build_card(id: String, def: Dictionary) -> Button:
	var btn := Button.new()
	btn.text = ""
	btn.custom_minimum_size = CARD_SIZE
	btn.focus_mode = Control.FOCUS_ALL
	btn.clip_contents = true
	UIStyle.style_button(btn, UIStyle.COLOR_LOCAL, 14, false)
	btn.pressed.connect(_on_map_pressed.bind(id))

	var layout := VBoxContainer.new()
	layout.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layout.set_anchors_preset(Control.PRESET_FULL_RECT)
	layout.alignment = BoxContainer.ALIGNMENT_CENTER
	layout.add_theme_constant_override("separation", 10)
	btn.add_child(layout)

	var preview_wrap := CenterContainer.new()
	preview_wrap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	preview_wrap.custom_minimum_size = Vector2(0, PREVIEW_SIZE.y)
	layout.add_child(preview_wrap)
	var preview := LocalMapIconScene.new()
	preview.map_id = id
	preview.accent_color = UIStyle.COLOR_LOCAL
	preview.custom_minimum_size = PREVIEW_SIZE
	preview_wrap.add_child(preview)

	var label := Label.new()
	label.text = String(def.get("name", id))
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", 16)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layout.add_child(label)

	return btn

func _on_map_pressed(id: String) -> void:
	GameSettings.selected_local_map = id
	get_tree().change_scene_to_file("res://main/game.tscn")

func _on_back_pressed() -> void:
	get_tree().change_scene_to_file("res://main/local_menu.tscn")
