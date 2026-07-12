extends Node

# Built-in cosmetic skins (solid colors, shipped with the game -- every
# client already has these, so they're guaranteed to render correctly for
# everyone) plus support for a player adding their own image as a custom
# skin. Skin selection and custom images are stored server-side (the relay
# service at codecade.co.za/tag/api/skins) rather than on this machine's own
# disk -- the only thing that ever lives locally is an anonymous client id
# (there's no account/login system here) used to look your own data back up,
# so switching machines or wiping local data doesn't lose your skins the way
# storing them in user:// would have.

const VISUAL_WIDTH := 32
const VISUAL_HEIGHT := 48
const CLIENT_ID_PATH := "user://client_id.txt"
const API_BASE := "https://codecade.co.za/tag/api/skins"

const BUILTIN_SKINS := [
	{"id": "red", "name": "Red", "color": Color(0.85, 0.2, 0.2), "rarity": "common"},
	{"id": "blue", "name": "Blue", "color": Color(0.25, 0.45, 0.85), "rarity": "common"},
	{"id": "green", "name": "Green", "color": Color(0.25, 0.75, 0.35), "rarity": "uncommon"},
	{"id": "yellow", "name": "Yellow", "color": Color(0.9, 0.8, 0.15), "rarity": "uncommon"},
	{"id": "purple", "name": "Purple", "color": Color(0.6, 0.3, 0.8), "rarity": "rare"},
	{"id": "teal", "name": "Teal", "color": Color(0.15, 0.75, 0.7), "rarity": "rare"},
	{"id": "orange", "name": "Orange", "color": Color(0.9, 0.5, 0.15), "rarity": "epic"},
	{"id": "pink", "name": "Pink", "color": Color(0.9, 0.45, 0.7), "rarity": "legendary"},
]

# Fortnite-style rarity color coding for the shop's card borders/banners --
# purely a visual flourish, doesn't affect gameplay. Custom (player-uploaded)
# skins always read as their own distinct "custom" tier.
const RARITY_COLORS := {
	"common": Color(0.62, 0.65, 0.68),
	"uncommon": Color(0.3, 0.82, 0.42),
	"rare": Color(0.28, 0.56, 0.95),
	"epic": Color(0.66, 0.32, 0.92),
	"legendary": Color(0.95, 0.58, 0.12),
	"custom": Color(0.15, 0.85, 0.85),
}

signal skin_selected(id: String)
## Emitted once a skin's texture finishes arriving from the server -- either
## your own custom skin's image after upload, or another player's after a
## fetch. Listeners re-resolve anything they'd shown a placeholder for.
signal skin_received(id: String)
## Emitted once the initial fetch of your own selection + custom skin list
## completes -- the shop UI waits for this before its first real render,
## since get_all_skins()/selected_skin_id are unreliable before it fires.
signal catalog_loaded

var client_id := ""
var selected_skin_id := "red"
var _known_custom_skins := [] # [{id, name}], from the server's record of what you've uploaded
var _texture_cache := {} # id -> Texture2D
var _fetch_in_flight := {} # id -> true, de-dupes concurrent image fetches

func _ready() -> void:
	client_id = _load_or_create_client_id()
	_fetch_catalog()

## Built-in skins plus every custom skin the server has on record for you,
## in a shape the shop UI can list directly. Custom entries may be present
## here before their texture has finished fetching (see get_texture) --
## that's expected, not an error.
func get_all_skins() -> Array:
	var out := []
	for s in BUILTIN_SKINS:
		out.append(s)
	for s in _known_custom_skins:
		out.append({"id": s.id, "name": s.name, "rarity": "custom", "custom": true})
	return out

func is_builtin(id: String) -> bool:
	for s in BUILTIN_SKINS:
		if s.id == id:
			return true
	return false

## Returns the cached texture if we already have it. Built-in skins are
## generated on first request and cached forever. A custom skin not yet
## cached kicks off an async fetch and returns null for now -- skin_received
## fires once it lands, so callers should treat null as "show a placeholder,
## try again on skin_received" rather than a real failure.
func get_texture(id: String) -> Texture2D:
	if _texture_cache.has(id):
		return _texture_cache[id]
	if is_builtin(id):
		var tex := _make_character_texture(_builtin_color(id))
		_texture_cache[id] = tex
		return tex
	_fetch_custom_texture(id)
	return null

func select_skin(id: String) -> void:
	selected_skin_id = id
	skin_selected.emit(id)
	_post_selection(id)

## Reads, downscales, and uploads an arbitrary image file (from a native
## file-picker dialog) as a new custom skin. Async -- callers need `await`.
## Returns the new skin's server-assigned id, or "" on failure.
func add_custom_skin(source_path: String, skin_name: String) -> String:
	var img := Image.new()
	if img.load(source_path) != OK:
		return ""
	img.resize(VISUAL_WIDTH, VISUAL_HEIGHT, Image.INTERPOLATE_LANCZOS)
	var png_bytes := img.save_png_to_buffer()

	var req := HTTPRequest.new()
	add_child(req)
	var body := JSON.stringify({"name": skin_name, "imageBase64": Marshalls.raw_to_base64(png_bytes)})
	var err := req.request(
		"%s/%s/upload" % [API_BASE, client_id], ["Content-Type: application/json"], HTTPClient.METHOD_POST, body
	)
	if err != OK:
		req.queue_free()
		return ""
	var response: Array = await req.request_completed
	req.queue_free()
	var response_code: int = response[1]
	if response_code != 200:
		return ""
	var parsed = JSON.parse_string(response[3].get_string_from_utf8())
	if typeof(parsed) != TYPE_DICTIONARY or not parsed.has("id"):
		return ""
	var id: String = parsed.id
	# We already have the (downscaled) image in hand locally -- no need to
	# immediately re-fetch what we just uploaded.
	_texture_cache[id] = ImageTexture.create_from_image(img)
	_known_custom_skins.append({"id": id, "name": skin_name})
	return id

func remove_custom_skin(id: String) -> void:
	for i in _known_custom_skins.size():
		if _known_custom_skins[i].id == id:
			_known_custom_skins.remove_at(i)
			break
	_texture_cache.erase(id)
	if selected_skin_id == id:
		select_skin(BUILTIN_SKINS[0].id)
	_delete_remote(id)

func _builtin_color(id: String) -> Color:
	for s in BUILTIN_SKINS:
		if s.id == id:
			return s.color
	return Color.WHITE

## A simple procedural humanoid -- head, body, arms, legs, eyes -- rather
## than a flat color block. Only built-in skins get this treatment; a
## custom (uploaded) skin keeps showing the player's own image as-is rather
## than forcing it into a silhouette they didn't choose.
func _make_character_texture(color: Color) -> ImageTexture:
	var w := VISUAL_WIDTH
	var h := VISUAL_HEIGHT
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))

	var shade := color.darkened(0.18)
	var highlight := color.lightened(0.12)
	var eye_color := Color(0.05, 0.05, 0.08)

	# Legs
	_fill_rect(img, 11, 36, 15, 47, shade)
	_fill_rect(img, 17, 36, 21, 47, shade)
	# Arms (drawn before the body so the body's edge overlaps the shoulder
	# seam instead of leaving a gap)
	_fill_rect(img, 3, 19, 9, 33, shade)
	_fill_rect(img, 23, 19, 29, 33, shade)
	# Body/torso
	_fill_rect(img, 9, 17, 23, 38, color)
	# Head
	_fill_ellipse(img, 16.0, 10.0, 9.0, 9.0, highlight)
	# Eyes
	_fill_ellipse(img, 12.0, 9.0, 1.6, 1.6, eye_color)
	_fill_ellipse(img, 20.0, 9.0, 1.6, 1.6, eye_color)

	return ImageTexture.create_from_image(img)

func _fill_rect(img: Image, x0: int, y0: int, x1: int, y1: int, color: Color) -> void:
	for y in range(maxi(y0, 0), mini(y1, img.get_height())):
		for x in range(maxi(x0, 0), mini(x1, img.get_width())):
			img.set_pixel(x, y, color)

func _fill_ellipse(img: Image, cx: float, cy: float, rx: float, ry: float, color: Color) -> void:
	var x0 := maxi(int(cx - rx - 1.0), 0)
	var x1 := mini(int(cx + rx + 1.0), img.get_width())
	var y0 := maxi(int(cy - ry - 1.0), 0)
	var y1 := mini(int(cy + ry + 1.0), img.get_height())
	for y in range(y0, y1):
		for x in range(x0, x1):
			var dx := (x + 0.5 - cx) / rx
			var dy := (y + 0.5 - cy) / ry
			if dx * dx + dy * dy <= 1.0:
				img.set_pixel(x, y, color)

func _fetch_custom_texture(id: String) -> void:
	if _fetch_in_flight.has(id):
		return
	_fetch_in_flight[id] = true
	var req := HTTPRequest.new()
	add_child(req)
	req.request_completed.connect(func(_result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray):
		req.queue_free()
		_fetch_in_flight.erase(id)
		if response_code == 200 and body.size() > 0:
			var img := Image.new()
			if img.load_png_from_buffer(body) == OK:
				_texture_cache[id] = ImageTexture.create_from_image(img)
				skin_received.emit(id)
	)
	req.request("%s/image/%s" % [API_BASE, id])

func _fetch_catalog() -> void:
	var req := HTTPRequest.new()
	add_child(req)
	req.request_completed.connect(func(_result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray):
		req.queue_free()
		if response_code != 200:
			catalog_loaded.emit() # still emit -- fall back to defaults (red, no custom skins) rather than hang forever
			return
		var parsed = JSON.parse_string(body.get_string_from_utf8())
		if typeof(parsed) == TYPE_DICTIONARY:
			selected_skin_id = parsed.get("selected", "red")
			_known_custom_skins = parsed.get("custom", [])
		catalog_loaded.emit()
	)
	req.request("%s/%s" % [API_BASE, client_id])

func _post_selection(id: String) -> void:
	var req := HTTPRequest.new()
	add_child(req)
	req.request_completed.connect(func(_r, _c, _h, _b): req.queue_free())
	var body := JSON.stringify({"skinId": id})
	req.request("%s/%s/select" % [API_BASE, client_id], ["Content-Type: application/json"], HTTPClient.METHOD_POST, body)

func _delete_remote(id: String) -> void:
	var req := HTTPRequest.new()
	add_child(req)
	req.request_completed.connect(func(_r, _c, _h, _b): req.queue_free())
	req.request("%s/%s/%s" % [API_BASE, client_id, id], [], HTTPClient.METHOD_DELETE)

func _load_or_create_client_id() -> String:
	if FileAccess.file_exists(CLIENT_ID_PATH):
		var f := FileAccess.open(CLIENT_ID_PATH, FileAccess.READ)
		var existing := f.get_as_text().strip_edges()
		if existing.length() >= 8:
			return existing
	var chars := "0123456789abcdef"
	var id := ""
	for i in 32:
		id += chars[randi() % chars.length()]
	var f := FileAccess.open(CLIENT_ID_PATH, FileAccess.WRITE)
	f.store_string(id)
	return id
