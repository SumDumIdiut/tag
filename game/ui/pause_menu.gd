extends CanvasLayer

@onready var panel: Control = $Panel
@onready var resume_button: Button = $Panel/VBox/ResumeButton
@onready var menu_button: Button = $Panel/VBox/MenuButton

func _ready() -> void:
	# Needs to keep processing input (and stay visible/interactive) while the
	# tree itself is paused -- otherwise the menu that's supposed to unpause
	# the game would freeze along with everything else.
	process_mode = Node.PROCESS_MODE_ALWAYS
	panel.visible = false
	resume_button.pressed.connect(_on_resume_pressed)
	menu_button.pressed.connect(_on_main_menu_pressed)

func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		_set_paused(not get_tree().paused)
		get_viewport().set_input_as_handled()

func _set_paused(paused: bool) -> void:
	get_tree().paused = paused
	panel.visible = paused

func _on_resume_pressed() -> void:
	_set_paused(false)

func _on_main_menu_pressed() -> void:
	get_tree().paused = false
	# Harmless no-op in singleplayer/local Tag (never connected); in a
	# networked match this tears down the connection so it doesn't linger
	# into the main menu.
	if NetworkManager.is_online():
		NetworkManager.disconnect_from_server()
	get_tree().change_scene_to_file("res://main/main_menu.tscn")
