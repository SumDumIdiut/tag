extends Node

const LocalMapCatalog := preload("res://levels/local_maps/catalog.gd")
const PlaylistCatalog := preload("res://net/playlist_catalog.gd")

# Carries the main menu's chosen match settings into the game scene --
# an autoload survives the scene change that Start triggers.
var npc_count: int = 3
var npc_skill: int = 3
var round_duration: float = 180.0
# Set by local_menu.gd's inline map row, read right before change_scene_to_file
# to game.tscn -- see LocalMapCatalog for what this id resolves to.
var selected_local_map: String = LocalMapCatalog.CLASSIC_ID
# Set by ranked_playlist_select.gd right before change_scene_to_file to
# ranked_queue.tscn -- see PlaylistCatalog for what this id resolves to.
var selected_ranked_playlist: String = PlaylistCatalog.PLAYLIST_ORDER[0]

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
