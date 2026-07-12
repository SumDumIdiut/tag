extends Control

# Lets a player pick from the built-in skins or add their own image as a
# custom one. Selection is purely cosmetic and persists via SkinCatalog
# (user://settings.cfg); a custom skin's image gets sent to other players
# the first time they're seen together in a match (see NetworkManager),
# since there's no server-side asset hosting to fetch it from otherwise.

@onready var skin_grid: GridContainer = $VBox/ScrollContainer/SkinGrid
@onready var add_custom_button: Button = $VBox/HBox/AddCustomButton
@onready var remove_button: Button = $VBox/HBox/RemoveButton
@onready var status_label: Label = $VBox/StatusLabel
@onready var back_button: Button = $VBox/BackButton
@onready var file_picker: FileDialog = $FilePicker

var _button_group := ButtonGroup.new()

func _ready() -> void:
	add_custom_button.pressed.connect(_on_add_custom_pressed)
	remove_button.pressed.connect(_on_remove_pressed)
	back_button.pressed.connect(_on_back_pressed)
	file_picker.file_selected.connect(_on_file_selected)
	_refresh_grid()

func _refresh_grid() -> void:
	for child in skin_grid.get_children():
		child.queue_free()
	var selected_id := SkinCatalog.selected_skin_id
	for skin in SkinCatalog.get_all_skins():
		var btn := Button.new()
		btn.custom_minimum_size = Vector2(84, 104)
		btn.icon = SkinCatalog.get_texture(skin.id)
		btn.expand_icon = true
		btn.text = skin.name
		btn.toggle_mode = true
		btn.button_group = _button_group
		btn.button_pressed = (skin.id == selected_id)
		btn.pressed.connect(_on_skin_pressed.bind(skin.id))
		skin_grid.add_child(btn)
	remove_button.disabled = SkinCatalog.is_builtin(selected_id)

func _on_skin_pressed(id: String) -> void:
	SkinCatalog.select_skin(id)
	status_label.text = ""
	_refresh_grid()

func _on_add_custom_pressed() -> void:
	file_picker.popup_centered()

func _on_file_selected(path: String) -> void:
	var id := SkinCatalog.add_custom_skin(path, path.get_file().get_basename())
	if id.is_empty():
		status_label.text = "Couldn't load that image."
		return
	SkinCatalog.select_skin(id)
	_refresh_grid()

func _on_remove_pressed() -> void:
	var selected_id := SkinCatalog.selected_skin_id
	if SkinCatalog.is_builtin(selected_id):
		return
	SkinCatalog.remove_custom_skin(selected_id)
	_refresh_grid()

func _on_back_pressed() -> void:
	get_tree().change_scene_to_file("res://main/main_menu.tscn")
