extends Control

const UIStyle := preload("res://ui/ui_style.gd")
const PlaylistCatalog := preload("res://net/playlist_catalog.gd")

@onready var vbox: VBoxContainer = $VBox
@onready var title_label: Label = $VBox/Title
@onready var subtitle_label: Label = $VBox/Subtitle
@onready var playlist_grid: GridContainer = $VBox/PlaylistGrid
@onready var back_button: Button = $VBox/BackButton

var _cards := {} # playlist_id -> Button

func _ready() -> void:
	UIStyle.add_background(self, "ranked_queue")
	UIStyle.style_back_button(back_button)
	back_button.pressed.connect(_on_back_pressed)
	UIStyle.apply_layout_override(title_label, "ranked_playlist_select.title")
	UIStyle.apply_layout_override(subtitle_label, "ranked_playlist_select.subtitle")
	UIStyle.apply_layout_override(back_button, "ranked_playlist_select.back_button")

	for id in PlaylistCatalog.PLAYLIST_ORDER:
		var card := _build_card(id)
		_cards[id] = card
		playlist_grid.add_child(card)

	PartyManager.party_updated.connect(_update_restrictions)
	_update_restrictions(PartyManager.current_party)

	# `vbox`'s height (not width -- see below) sits in a fixed-looking offset
	# rect sized generously enough for PLAYLIST_ORDER's max realistic length
	# -- PlaylistGrid used to force-expand to fill that whole rect
	# (size_flags_vertical = 3), which just left BackButton stranded at the
	# very bottom with a big dead gap above it instead of sitting close to
	# the actual playlist list. Recomputed here from the real content once
	# populated, same fix/reasoning as local_menu.gd's own _recenter_vbox().
	#
	# Width (offset_left/offset_right) is deliberately left untouched --
	# recomputing it too would shrink-wrap the whole card down to just a
	# playlist button's own text width (confirmed live: ~135px instead of
	# the original, intentionally roomy 460px), losing the actual designed
	# card width for no reason tied to the dead-space bug this is fixing.
	await get_tree().process_frame
	var content_height := vbox.get_combined_minimum_size().y
	vbox.offset_top = -content_height / 2.0
	vbox.offset_bottom = content_height / 2.0

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

	# An uploaded thumbnail (see the website's UI Editor) replaces the plain
	# color fill -- a dark scrim sits between it and the labels so the name/
	# mode text stays legible regardless of how bright the art is, same
	# "readable text over arbitrary uploaded art" treatment local_menu.gd's
	# map thumbnails already use.
	var thumb := GameAssetOverrides.load_override_texture(GameAssetOverrides.playlist_thumbnail_override_path(playlist_id))
	if thumb:
		var thumb_rect := TextureRect.new()
		thumb_rect.texture = thumb
		thumb_rect.stretch_mode = TextureRect.STRETCH_SCALE
		thumb_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		thumb_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
		thumb_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
		btn.add_child(thumb_rect)
		var scrim := ColorRect.new()
		scrim.color = Color(0, 0, 0, 0.4)
		scrim.mouse_filter = Control.MOUSE_FILTER_IGNORE
		scrim.set_anchors_preset(Control.PRESET_FULL_RECT)
		btn.add_child(scrim)

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

	UIStyle.apply_layout_override(btn, "ranked_playlist_select.card_%s" % playlist_id)
	UIStyle.apply_layout_override(name_label, "ranked_playlist_select.card_%s_name" % playlist_id)
	UIStyle.apply_layout_override(sub_label, "ranked_playlist_select.card_%s_sub" % playlist_id)
	return btn

func _on_playlist_pressed(playlist_id: String) -> void:
	GameSettings.selected_ranked_playlist = playlist_id
	get_tree().change_scene_to_file("res://main/ranked_queue.tscn")

func _on_back_pressed() -> void:
	get_tree().change_scene_to_file("res://main/online_menu.tscn")
