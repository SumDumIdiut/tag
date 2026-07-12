extends Node

# Built-in cosmetic skins (solid colors, shipped with the game -- every
# client already has these, so they're guaranteed to render correctly for
# everyone) plus support for a player adding their own image as a custom
# skin. A custom skin only exists locally until its owner is actually seen
# in a match: at that point its (small, already-downscaled) image gets sent
# to everyone else present -- see NetworkManager's skin registration -- so
# they can render it too. There's no server-side asset hosting, so a custom
# skin is only ever as visible as the peer connection carrying it.

const VISUAL_WIDTH := 20
const VISUAL_HEIGHT := 32
const CUSTOM_SKIN_DIR := "user://custom_skins"
const SETTINGS_PATH := "user://settings.cfg"

const BUILTIN_SKINS := [
	{"id": "red", "name": "Red", "color": Color(0.85, 0.2, 0.2)},
	{"id": "blue", "name": "Blue", "color": Color(0.25, 0.45, 0.85)},
	{"id": "green", "name": "Green", "color": Color(0.25, 0.75, 0.35)},
	{"id": "yellow", "name": "Yellow", "color": Color(0.9, 0.8, 0.15)},
	{"id": "purple", "name": "Purple", "color": Color(0.6, 0.3, 0.8)},
	{"id": "orange", "name": "Orange", "color": Color(0.9, 0.5, 0.15)},
	{"id": "teal", "name": "Teal", "color": Color(0.15, 0.75, 0.7)},
	{"id": "pink", "name": "Pink", "color": Color(0.9, 0.45, 0.7)},
]

signal skin_selected(id: String)
## Emitted once a remote peer's custom skin image finishes arriving --
## net_game.gd listens for this to re-apply the real texture to any avatar
## it had to show with a placeholder in the meantime.
signal skin_received(id: String)

var selected_skin_id := "red"
var _custom_skins := {} # id -> {"name": String, "path": String (user:// path to the saved image)}
var _texture_cache := {} # id -> Texture2D

func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(CUSTOM_SKIN_DIR)
	_load_settings()

## Built-in skins plus every custom skin added on this machine, in a shape
## the shop UI can list directly.
func get_all_skins() -> Array:
	var out := []
	for s in BUILTIN_SKINS:
		out.append(s)
	for id in _custom_skins:
		out.append({"id": id, "name": _custom_skins[id].name, "custom": true})
	return out

func is_builtin(id: String) -> bool:
	for s in BUILTIN_SKINS:
		if s.id == id:
			return true
	return false

func get_texture(id: String) -> Texture2D:
	if _texture_cache.has(id):
		return _texture_cache[id]
	var tex: Texture2D = null
	if is_builtin(id):
		tex = _make_solid_texture(_builtin_color(id))
	elif _custom_skins.has(id):
		tex = _load_texture_from_path(_custom_skins[id].path)
	if tex:
		_texture_cache[id] = tex
	return tex

func select_skin(id: String) -> void:
	selected_skin_id = id
	_save_settings()
	skin_selected.emit(id)

## Copies an arbitrary image file (from a native file-picker dialog) into
## this game's own user:// storage and registers it as a new custom skin --
## copying rather than referencing the original path directly means the
## skin keeps working even if the source file is later moved or deleted.
## Downscales to the same small size every skin renders at, both to keep
## in-game appearance consistent and to keep the eventual network payload
## (see get_custom_skin_bytes) small.
func add_custom_skin(source_path: String, skin_name: String) -> String:
	var img := Image.new()
	if img.load(source_path) != OK:
		return ""
	img.resize(VISUAL_WIDTH, VISUAL_HEIGHT, Image.INTERPOLATE_LANCZOS)
	var id := "custom_%d" % Time.get_ticks_usec()
	var save_path := CUSTOM_SKIN_DIR.path_join(id + ".png")
	img.save_png(save_path)
	_custom_skins[id] = {"name": skin_name, "path": save_path}
	_save_settings()
	return id

func remove_custom_skin(id: String) -> void:
	if not _custom_skins.has(id):
		return
	DirAccess.remove_absolute(_custom_skins[id].path)
	_custom_skins.erase(id)
	_texture_cache.erase(id)
	if selected_skin_id == id:
		select_skin(BUILTIN_SKINS[0].id)
	else:
		_save_settings()

## Raw PNG bytes for a custom skin (already downscaled to VISUAL_WIDTH x
## VISUAL_HEIGHT) -- what actually gets sent over the network so other
## players can render it too.
func get_custom_skin_bytes(id: String) -> PackedByteArray:
	if not _custom_skins.has(id):
		return PackedByteArray()
	var f := FileAccess.open(_custom_skins[id].path, FileAccess.READ)
	if not f:
		return PackedByteArray()
	return f.get_buffer(f.get_length())

## Registers a skin received from a remote peer (id chosen by them, e.g.
## "custom_<peer_id>_<ticks>") from raw PNG bytes -- lets this client render
## another player's custom skin without ever touching their filesystem.
func register_remote_skin(id: String, png_bytes: PackedByteArray) -> void:
	if _texture_cache.has(id) or is_builtin(id) or png_bytes.is_empty():
		return
	var img := Image.new()
	if img.load_png_from_buffer(png_bytes) != OK:
		return
	_texture_cache[id] = ImageTexture.create_from_image(img)
	skin_received.emit(id)

func _builtin_color(id: String) -> Color:
	for s in BUILTIN_SKINS:
		if s.id == id:
			return s.color
	return Color.WHITE

func _make_solid_texture(color: Color) -> ImageTexture:
	var img := Image.create(VISUAL_WIDTH, VISUAL_HEIGHT, false, Image.FORMAT_RGBA8)
	img.fill(color)
	return ImageTexture.create_from_image(img)

func _load_texture_from_path(path: String) -> Texture2D:
	var img := Image.new()
	if img.load(path) != OK:
		return null
	return ImageTexture.create_from_image(img)

func _save_settings() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("skins", "selected", selected_skin_id)
	var custom_arr := []
	for id in _custom_skins:
		custom_arr.append({"id": id, "name": _custom_skins[id].name, "path": _custom_skins[id].path})
	cfg.set_value("skins", "custom", custom_arr)
	cfg.save(SETTINGS_PATH)

func _load_settings() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(SETTINGS_PATH) != OK:
		return
	selected_skin_id = cfg.get_value("skins", "selected", "red")
	var custom_arr: Array = cfg.get_value("skins", "custom", [])
	for raw_entry in custom_arr:
		var entry: Dictionary = raw_entry
		if FileAccess.file_exists(entry.path):
			_custom_skins[entry.id] = {"name": entry.name, "path": entry.path}
