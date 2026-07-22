extends Control

const UIStyle := preload("res://ui/ui_style.gd")
const PlaylistCatalog := preload("res://net/playlist_catalog.gd")

@onready var playlist_grid: GridContainer = $VBox/PlaylistGrid
@onready var back_button: Button = $VBox/BackButton

var _cards := {} # playlist_id -> Button

func _ready() -> void:
	UIStyle.add_background(self, "ranked_queue")
	UIStyle.style_back_button(back_button)
	back_button.pressed.connect(_on_back_pressed)

	for id in PlaylistCatalog.PLAYLIST_ORDER:
		var card := _build_card(id)
		_cards[id] = card
		playlist_grid.add_child(card)

	PartyManager.party_updated.connect(_update_restrictions)
	_update_restrictions(PartyManager.current_party)

func _update_restrictions(_party: Dictionary) -> void:
	var size := PartyManager.party_size()
	for id in _cards.keys():
		UIStyle.set_disabled_overlay(_cards[id], not PlaylistCatalog.fits_party(id, size))

func _build_card(playlist_id: String) -> Button:
	var btn := Button.new()
	btn.text = ""
	btn.custom_minimum_size = Vector2(0, 54)
	btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	btn.focus_mode = Control.FOCUS_ALL
	btn.clip_contents = true
	UIStyle.style_button(btn, UIStyle.COLOR_RANKED, 10, false)
	btn.pressed.connect(_on_playlist_pressed.bind(playlist_id))

	var text_box := VBoxContainer.new()
	text_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	text_box.set_anchors_preset(Control.PRESET_FULL_RECT)
	text_box.alignment = BoxContainer.ALIGNMENT_CENTER
	btn.add_child(text_box)

	var name_label := Label.new()
	name_label.text = PlaylistCatalog.display_name(playlist_id)
	name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_label.add_theme_font_size_override("font_size", 20)
	text_box.add_child(name_label)

	var sub_label := Label.new()
	sub_label.text = "Teams" if PlaylistCatalog.is_team_mode(playlist_id) else "Free-for-all"
	sub_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	sub_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sub_label.add_theme_font_size_override("font_size", 12)
	sub_label.add_theme_color_override("font_color", UIStyle.COLOR_NEUTRAL)
	text_box.add_child(sub_label)

	return btn

func _on_playlist_pressed(playlist_id: String) -> void:
	GameSettings.selected_ranked_playlist = playlist_id
	get_tree().change_scene_to_file("res://main/ranked_queue.tscn")

func _on_back_pressed() -> void:
	get_tree().change_scene_to_file("res://main/online_menu.tscn")
