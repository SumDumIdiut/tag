extends Node

# Carries the main menu's chosen match settings into the game scene --
# an autoload survives the scene change that Start triggers.
var npc_count: int = 3
var npc_skill: int = 3

const USERNAME_PATH := "user://username.txt"
const DEFAULT_USERNAME := "Player"

var saved_username := DEFAULT_USERNAME

func _ready() -> void:
	saved_username = _load_username()

func save_username(name: String) -> void:
	var trimmed := name.strip_edges()
	if trimmed.is_empty() or trimmed == saved_username:
		return
	saved_username = trimmed
	var f := FileAccess.open(USERNAME_PATH, FileAccess.WRITE)
	f.store_string(trimmed)

func _load_username() -> String:
	if FileAccess.file_exists(USERNAME_PATH):
		var f := FileAccess.open(USERNAME_PATH, FileAccess.READ)
		var existing := f.get_as_text().strip_edges()
		if not existing.is_empty():
			return existing
	return DEFAULT_USERNAME
