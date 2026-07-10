extends Control

@onready var npc_count_slider: HSlider = $VBox/NpcCountRow/NpcCountSlider
@onready var npc_count_value: Label = $VBox/NpcCountRow/NpcCountValue
@onready var skill_slider: HSlider = $VBox/SkillRow/SkillSlider
@onready var skill_value: Label = $VBox/SkillRow/SkillValue
@onready var start_button: Button = $VBox/StartButton
@onready var sandbox_button: Button = $VBox/SandboxButton
@onready var multiplayer_button: Button = $VBox/MultiplayerButton

func _ready() -> void:
	npc_count_slider.value = GameSettings.npc_count
	skill_slider.value = GameSettings.npc_skill
	_update_npc_count_label(npc_count_slider.value)
	_update_skill_label(skill_slider.value)

	npc_count_slider.value_changed.connect(_update_npc_count_label)
	skill_slider.value_changed.connect(_update_skill_label)
	start_button.pressed.connect(_on_start_pressed)
	sandbox_button.pressed.connect(_on_sandbox_pressed)
	multiplayer_button.pressed.connect(_on_multiplayer_pressed)

func _update_npc_count_label(value: float) -> void:
	npc_count_value.text = str(int(value))

func _update_skill_label(value: float) -> void:
	skill_value.text = str(int(value))

func _on_start_pressed() -> void:
	GameSettings.npc_count = int(npc_count_slider.value)
	GameSettings.npc_skill = int(skill_slider.value)
	get_tree().change_scene_to_file("res://main/game.tscn")

func _on_sandbox_pressed() -> void:
	get_tree().change_scene_to_file("res://main/movement_test.tscn")

func _on_multiplayer_pressed() -> void:
	get_tree().change_scene_to_file("res://main/multiplayer_connect.tscn")
