extends Control

const UIStyle := preload("res://ui/ui_style.gd")
const CasualMatchmakerScene := preload("res://net/casual_matchmaker.gd")
const ModeIconScene := preload("res://ui/mode_icon.gd")

@onready var bar_row: HBoxContainer = $VBox/BarRow
@onready var casual_button: Button = $VBox/BarRow/CasualButton
@onready var ranked_button: Button = $VBox/BarRow/RankedButton
@onready var private_button: Button = $VBox/BarRow/PrivateButton
@onready var direct_connect_button: Button = $VBox/DirectConnectButton
@onready var back_button: Button = $VBox/BackButton

var _matchmaker: CasualMatchmaker
var _overlay: Control
var _overlay_panel: PanelContainer
var _overlay_status_label: Label

func _ready() -> void:
	UIStyle.add_background(self, "online_menu")
	_style_bar(casual_button, UIStyle.COLOR_QUICKPLAY, "Casual")
	_style_bar(ranked_button, UIStyle.COLOR_RANKED, "Ranked")
	_style_bar(private_button, UIStyle.COLOR_ONLINE, "Private")
	UIStyle.style_back_button(back_button)
	UIStyle.style_button(direct_connect_button, UIStyle.COLOR_NEUTRAL, 12)

	casual_button.pressed.connect(_on_casual_pressed)
	ranked_button.pressed.connect(_on_ranked_pressed)
	private_button.pressed.connect(_on_private_pressed)
	direct_connect_button.pressed.connect(_on_direct_connect_pressed)
	back_button.pressed.connect(_on_back_pressed)
	_build_friends_bar()

func _style_bar(btn: Button, color: Color, label_text: String) -> void:
	btn.text = label_text
	UIStyle.style_button(btn, color, 18)
	btn.add_theme_font_size_override("font_size", 18)

## Built in code rather than added to the .tscn -- appended as a 4th bar
## in BarRow, same "extend an existing hand-authored screen without
## touching its node tree" approach the Art Tool's later pages already
## used.
func _build_friends_bar() -> void:
	var friends_button := Button.new()
	friends_button.custom_minimum_size = casual_button.custom_minimum_size
	friends_button.clip_contents = true
	friends_button.pressed.connect(func(): get_tree().change_scene_to_file("res://main/friends_menu.tscn"))
	bar_row.add_child(friends_button)
	_style_bar(friends_button, UIStyle.COLOR_SHOP, "Friends")

func _on_ranked_pressed() -> void:
	get_tree().change_scene_to_file("res://main/ranked_playlist_select.tscn")

func _on_direct_connect_pressed() -> void:
	get_tree().change_scene_to_file("res://main/multiplayer_connect.tscn")

func _on_back_pressed() -> void:
	get_tree().change_scene_to_file("res://main/main_menu.tscn")

func _on_casual_pressed() -> void:
	_start_matchmaking(false)

## Private always hosts a fresh, unlisted server rather than offering a
## host-or-join choice -- joining someone else's private match happens via
## Direct Connect (their shared address) or a friend's Join button, never
## through this bar. See casual_matchmaker.gd.
func _on_private_pressed() -> void:
	_start_matchmaking(true)

func _start_matchmaking(private: bool) -> void:
	_show_overlay(private)
	_matchmaker = CasualMatchmakerScene.new()
	add_child(_matchmaker)
	_matchmaker.status_changed.connect(_on_matchmaker_status)
	_matchmaker.entered_lobby.connect(_on_matchmaker_entered_lobby)
	_matchmaker.start(GameSettings.saved_username, private)

func _on_matchmaker_status(text: String) -> void:
	_overlay_status_label.text = text

func _on_matchmaker_entered_lobby() -> void:
	get_tree().change_scene_to_file("res://main/lobby_room.tscn")

func _on_overlay_cancel_pressed() -> void:
	if _matchmaker:
		_matchmaker.cancel()
		_matchmaker.queue_free()
		_matchmaker = null
	_hide_overlay()

## Quick Play/Private's "searching, then maybe hosting" wait used to be its
## own dedicated screen (quick_play.tscn, now retired) -- folded in here as
## a full-screen overlay instead, same "extend this screen in code" pattern
## every other runtime-built panel in this app already uses, so the bar row
## underneath doesn't need its own separate scene to show a wait state in.
func _show_overlay(private: bool) -> void:
	if not _overlay:
		_build_overlay()
	var icon_color := UIStyle.COLOR_ONLINE if private else UIStyle.COLOR_QUICKPLAY
	_overlay_panel.add_theme_stylebox_override("panel", UIStyle.panel_box(icon_color))
	_overlay_status_label.text = "Starting a private match..." if private else "Finding a match..."
	_overlay.visible = true

func _hide_overlay() -> void:
	if _overlay:
		_overlay.visible = false

func _build_overlay() -> void:
	_overlay = Control.new()
	_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_overlay)

	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.6)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	_overlay.add_child(dim)

	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_overlay.add_child(center)

	var panel := PanelContainer.new()
	panel.name = "Panel"
	panel.custom_minimum_size = Vector2(340, 200)
	center.add_child(panel)
	_overlay_panel = panel

	var box := VBoxContainer.new()
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	box.add_theme_constant_override("separation", 16)
	panel.add_child(box)

	var icon_slot := Control.new()
	icon_slot.custom_minimum_size = Vector2(0, 48)
	box.add_child(icon_slot)
	var icon = ModeIconScene.new()
	icon.icon_type = "bolt"
	icon.icon_color = UIStyle.COLOR_QUICKPLAY
	icon.custom_minimum_size = Vector2(40, 48)
	icon.set_anchors_preset(Control.PRESET_CENTER_TOP)
	icon.position = Vector2(-20, 0)
	icon_slot.add_child(icon)
	var tween := create_tween().set_loops()
	tween.tween_property(icon, "modulate:a", 0.4, 0.6).set_trans(Tween.TRANS_SINE)
	tween.tween_property(icon, "modulate:a", 1.0, 0.6).set_trans(Tween.TRANS_SINE)

	_overlay_status_label = Label.new()
	_overlay_status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_overlay_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD
	_overlay_status_label.custom_minimum_size = Vector2(280, 0)
	box.add_child(_overlay_status_label)

	var cancel_button := Button.new()
	cancel_button.text = "Cancel"
	cancel_button.custom_minimum_size = Vector2(0, 40)
	UIStyle.style_button(cancel_button, UIStyle.COLOR_NEUTRAL)
	cancel_button.pressed.connect(_on_overlay_cancel_pressed)
	box.add_child(cancel_button)

	_overlay.visible = false
