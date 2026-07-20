extends Control

const UIStyle := preload("res://ui/ui_style.gd")
const ModeIconScene := preload("res://ui/mode_icon.gd")
const PlaylistCatalog := preload("res://net/playlist_catalog.gd")

@onready var playlist_grid: GridContainer = $VBox/PlaylistGrid
@onready var back_button: Button = $VBox/BackButton

func _ready() -> void:
	UIStyle.add_background(self, "ranked_queue")
	UIStyle.style_back_button(back_button)
	UIStyle.apply_bar_art(back_button, "action_bars", "back")
	back_button.pressed.connect(_on_back_pressed)

	for id in PlaylistCatalog.PLAYLIST_ORDER:
		playlist_grid.add_child(_build_card(id))

func _build_card(playlist_id: String) -> Button:
	var btn := Button.new()
	btn.text = ""
	btn.custom_minimum_size = Vector2(170, 150)
	btn.focus_mode = Control.FOCUS_ALL
	btn.clip_contents = true
	UIStyle.style_button(btn, UIStyle.COLOR_RANKED, 14, false)
	btn.pressed.connect(_on_playlist_pressed.bind(playlist_id))

	# A whole-card painting (see the Art Tool's Icons page "Playlist Card
	# Art" section) replaces the procedural icon/name/sub-label layout below
	# entirely -- same "never hard-fail on missing custom content" rule as
	# every other painted button, falls back to the plain layout when no art
	# exists for this playlist yet.
	if UIStyle.apply_bar_art(btn, "playlist_cards", playlist_id):
		return btn

	var layout := VBoxContainer.new()
	layout.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layout.set_anchors_preset(Control.PRESET_FULL_RECT)
	layout.alignment = BoxContainer.ALIGNMENT_CENTER
	layout.add_theme_constant_override("separation", 8)
	btn.add_child(layout)

	var icon_wrap := CenterContainer.new()
	icon_wrap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	icon_wrap.custom_minimum_size = Vector2(0, 34)
	layout.add_child(icon_wrap)
	var icon := ModeIconScene.new()
	icon.icon_type = "team" if PlaylistCatalog.is_team_mode(playlist_id) else "tag"
	icon.icon_color = UIStyle.COLOR_RANKED
	icon.custom_minimum_size = Vector2(30, 30)
	icon_wrap.add_child(icon)

	var name_label := Label.new()
	name_label.text = PlaylistCatalog.display_name(playlist_id)
	name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	name_label.add_theme_font_size_override("font_size", 22)
	layout.add_child(name_label)

	var sub_label := Label.new()
	sub_label.text = "Teams" if PlaylistCatalog.is_team_mode(playlist_id) else "Free-for-all"
	sub_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	sub_label.add_theme_font_size_override("font_size", 13)
	sub_label.add_theme_color_override("font_color", UIStyle.COLOR_NEUTRAL)
	layout.add_child(sub_label)

	return btn

func _on_playlist_pressed(playlist_id: String) -> void:
	GameSettings.selected_ranked_playlist = playlist_id
	get_tree().change_scene_to_file("res://main/ranked_queue.tscn")

func _on_back_pressed() -> void:
	get_tree().change_scene_to_file("res://main/online_menu.tscn")
