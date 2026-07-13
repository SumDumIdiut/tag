extends Node

# Built-in cosmetic skins (solid colors, shipped with the game) plus two
# shared catalogs -- skins and hats -- of custom images that live entirely
# on the server. New entries can arrive two ways: an admin running
# relay-server/add-skin.js directly on the machine (no HTTP exposure at
# all), or any player painting one with the in-shop drawing tool, which
# uploads it and makes it visible to everyone immediately (see
# add_drawn_skin/add_drawn_hat) -- deliberately scoped to fixed-size canvas
# strokes per rig part, not arbitrary file upload. The only thing that ever
# lives locally is an anonymous client id (there's no account/login system
# here) used to remember your selections across sessions/machines.

const VISUAL_WIDTH := 32
const VISUAL_HEIGHT := 48
const CLIENT_ID_PATH := "user://client_id.txt"
const API_BASE := "https://codecade.co.za/tag/api/skins"

const PART_NAMES := ["head", "torso", "left_arm", "right_arm", "left_leg", "right_leg"]

# Canvas-space (32x48, same space the old single-texture painter used) rect +
# pivot per rig part. `rect` is the tight crop for that part's own texture;
# `pivot` is the joint point the rig (player.tscn et al) positions/rotates
# that part's node around -- torso's pivot is its neck attach point (torso is
# the rig's parent node), each limb's pivot is where it actually attaches to
# the torso, head's pivot is its own neck.
const PART_DEFS := {
	"torso": {"rect": Rect2i(9, 17, 14, 21), "pivot": Vector2(16, 17)},
	"head": {"rect": Rect2i(7, 1, 18, 18), "pivot": Vector2(16, 19)},
	"left_arm": {"rect": Rect2i(3, 19, 6, 14), "pivot": Vector2(9, 19)},
	"right_arm": {"rect": Rect2i(23, 19, 6, 14), "pivot": Vector2(23, 19)},
	"left_leg": {"rect": Rect2i(11, 36, 4, 11), "pivot": Vector2(13, 36)},
	"right_leg": {"rect": Rect2i(17, 36, 4, 11), "pivot": Vector2(19, 36)},
}

const BUILTIN_SKINS := [
	{"id": "red", "name": "Red", "color": Color(0.85, 0.2, 0.2)},
	{"id": "blue", "name": "Blue", "color": Color(0.25, 0.45, 0.85)},
	{"id": "green", "name": "Green", "color": Color(0.25, 0.75, 0.35)},
	{"id": "yellow", "name": "Yellow", "color": Color(0.9, 0.8, 0.15)},
	{"id": "purple", "name": "Purple", "color": Color(0.6, 0.3, 0.8)},
	{"id": "teal", "name": "Teal", "color": Color(0.15, 0.75, 0.7)},
	{"id": "orange", "name": "Orange", "color": Color(0.9, 0.5, 0.15)},
	{"id": "pink", "name": "Pink", "color": Color(0.9, 0.45, 0.7)},
]

const HAT_API_BASE := "https://codecade.co.za/tag/api/hats"

# The head is a circle inscribed in its own 18x18 crop (touches all four
# edges -- see _paint_character_image's head ellipse), so there's no real
# headroom left *inside* that box for a hat to occupy without just sitting
# on top of the face. Hats get their own, taller canvas instead: the bottom
# HAT_OVERLAP rows deliberately overlap the head's own topmost rows (the
# Hat node, a child of Head, is offset further up than Head's own offset --
# see player.tscn) so a hat visually rests into the round top of the head,
# while the rest of the canvas is free space for it to stick up above the
# head's silhouette the way an actual hat does.
const HAT_WIDTH := 18
const HAT_HEIGHT := 16
const HAT_OVERLAP := 6

const BUILTIN_HATS := [
	{"id": "cap", "name": "Cap", "shape": "cap", "color": Color(0.25, 0.45, 0.85)},
	{"id": "beanie", "name": "Beanie", "shape": "beanie", "color": Color(0.85, 0.2, 0.3)},
	{"id": "tophat", "name": "Top Hat", "shape": "tophat", "color": Color(0.32, 0.24, 0.42)},
	{"id": "crown", "name": "Crown", "shape": "crown", "color": Color(0.95, 0.8, 0.25)},
]

const CHARACTER_SHADE_AMOUNT := 0.18
const CHARACTER_HIGHLIGHT_AMOUNT := 0.12
const HAT_SHADE_AMOUNT := 0.2
const HAT_HIGHLIGHT_AMOUNT := 0.15

# Neutral marker tones used by the editable-template art pipeline (see
# paint_character_template/paint_hat_template below, tools/extract_templates.gd,
# and tools/bake_character_art.gd) -- these never appear in the actual game,
# they're symbolic roles a friend editing the template PNGs can recognize
# ("this whole region is the base color," "this is the shaded region," ...)
# that the bake script swaps back out for a real per-skin color.
const TEMPLATE_BASE := Color(0.65, 0.65, 0.65, 1.0)
const TEMPLATE_SHADE := Color(0.42, 0.42, 0.42, 1.0)
const TEMPLATE_HIGHLIGHT := Color(0.88, 0.88, 0.88, 1.0)

signal skin_selected(id: String)
signal hat_selected(id: String)
## Emitted once a custom skin's or hat's texture finishes arriving from the
## server -- listeners re-resolve anything they'd shown a placeholder for.
signal skin_received(id: String)
signal hat_received(id: String)
## Emitted once the initial fetch of the shared catalogs + your own
## selections completes -- the shop UI waits for this before its first real
## render, since get_all_skins()/selected_skin_id etc are unreliable before
## it fires.
signal catalog_loaded

var client_id := ""
var selected_skin_id := "red"
var selected_hat_id := "" # "" means no hat equipped
var _catalog_custom_skins := [] # [{id, name, ...}], the server's shared custom-skin catalog
var _catalog_hats := [] # [{id, name, ...}], the server's shared hat catalog
var _texture_cache := {} # id -> Texture2D
var _fetch_in_flight := {} # id -> true, de-dupes concurrent image fetches

func _ready() -> void:
	client_id = _load_or_create_client_id()
	_fetch_catalog()

## Built-in skins plus every custom skin in the server's shared catalog, in a
## shape the shop UI can list directly. Custom entries may be present here
## before their texture has finished fetching (see get_texture) -- that's
## expected, not an error.
func get_all_skins() -> Array:
	var out := []
	for s in BUILTIN_SKINS:
		out.append(s)
	for s in _catalog_custom_skins:
		out.append({"id": s.id, "name": s.name, "custom": true})
	return out

## Built-in hats plus every custom hat in the server's shared catalog, same
## shape as get_all_skins(). There's no built-in "none" entry here -- the
## shop represents "no hat" as its own explicit unequip action, not a
## catalog item.
func get_all_hats() -> Array:
	var out := []
	for h in BUILTIN_HATS:
		out.append(h)
	for h in _catalog_hats:
		out.append({"id": h.id, "name": h.name, "custom": true})
	return out

func is_builtin(id: String) -> bool:
	for s in BUILTIN_SKINS:
		if s.id == id:
			return true
	return false

func is_builtin_hat(id: String) -> bool:
	for h in BUILTIN_HATS:
		if h.id == id:
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
		var tex := _compose_whole_texture(id)
		_texture_cache[id] = tex
		return tex
	_fetch_custom_texture(id)
	return null

## Per-rig-part version of get_texture() -- {part_name -> Texture2D}, empty
## if a custom skin's image hasn't finished fetching yet (same async-fetch/
## skin_received pattern as get_texture: treat {} as "show a placeholder,
## try again on skin_received", not a real failure). Built-in skins load the
## art a friend may have painted over (see tools/bake_character_art.gd,
## game/assets/character/<skin>_<part>.png), falling back to the original
## procedural paint only if that file is missing -- keeps this unbreakable
## even if the bake step was never run. A fetched custom (whole-image) skin
## is sliced into the same PART_DEFS regions on first request, so older
## whole-image custom skins render correctly on the per-part rig with no
## server-side changes needed.
func get_part_textures(id: String) -> Dictionary:
	var cache_key := "parts:" + id
	if _texture_cache.has(cache_key):
		return _texture_cache[cache_key]
	if is_builtin(id):
		var parts := _load_or_paint_character_parts(id)
		_texture_cache[cache_key] = parts
		return parts
	if _texture_cache.has(id):
		var parts := _slice_whole_image(_texture_cache[id])
		_texture_cache[cache_key] = parts
		return parts
	_fetch_custom_texture(id) # de-duped internally; emits skin_received once the whole image lands
	return {}

## Composited from get_part_textures() (baked-art-or-procedural, whichever
## that resolves to) rather than a separate whole-image paint, so the flat
## preview thumbnail (shop cards, roster previews) always matches whatever
## the live rig actually renders.
func _compose_whole_texture(id: String) -> ImageTexture:
	var parts := get_part_textures(id)
	var whole := Image.create(VISUAL_WIDTH, VISUAL_HEIGHT, false, Image.FORMAT_RGBA8)
	whole.fill(Color(0, 0, 0, 0))
	for part_name in PART_NAMES:
		if not parts.has(part_name):
			continue
		var rect: Rect2i = PART_DEFS[part_name].rect
		var part_img: Image = parts[part_name].get_image()
		whole.blit_rect(part_img, Rect2i(Vector2i.ZERO, rect.size), rect.position)
	return ImageTexture.create_from_image(whole)

func _load_or_paint_character_parts(id: String) -> Dictionary:
	var parts := {}
	for part_name in PART_NAMES:
		var path := "res://assets/character/%s_%s.png" % [id, part_name]
		if ResourceLoader.exists(path):
			parts[part_name] = load(path)
		else:
			return _make_character_parts(_builtin_color(id))
	return parts

func select_skin(id: String) -> void:
	selected_skin_id = id
	skin_selected.emit(id)
	_post_selection(id)

## A hat is a second, independent cosmetic slot -- id == "" unequips it
## without touching the current skin selection.
func select_hat(id: String) -> void:
	selected_hat_id = id
	hat_selected.emit(id)
	_post_hat_selection(id)

## Returns the cached hat texture if we already have it, kicking off an
## async fetch (skin_received-style, see hat_received) otherwise. Empty id
## means "no hat" and always returns null -- callers should treat that as
## "don't render a hat sprite", not an error. Built-in hats load the baked
## art (game/assets/character/hats/<hat>.png) if present, same
## load-or-fall-back-to-procedural pattern as get_part_textures.
func get_hat_texture(id: String) -> Texture2D:
	if id.is_empty():
		return null
	var cache_key := "hat:" + id
	if _texture_cache.has(cache_key):
		return _texture_cache[cache_key]
	if is_builtin_hat(id):
		var tex := _load_or_paint_hat(id)
		_texture_cache[cache_key] = tex
		return tex
	_fetch_hat_texture(id)
	return null

func _load_or_paint_hat(id: String) -> Texture2D:
	var path := "res://assets/character/hats/%s.png" % id
	if ResourceLoader.exists(path):
		return load(path)
	var def := {}
	for h in BUILTIN_HATS:
		if h.id == id:
			def = h
			break
	return ImageTexture.create_from_image(_paint_hat_image(def.get("shape", "cap"), def.get("color", Color.WHITE)))

func _builtin_color(id: String) -> Color:
	for s in BUILTIN_SKINS:
		if s.id == id:
			return s.color
	return Color.WHITE

## A simple procedural humanoid -- head, body, arms, legs, eyes -- rather
## than a flat color block. Used for the shop's flat preview thumbnail; the
## in-game rig uses _make_character_parts (below) instead, cropped from this
## same painted image so both stay visually identical.
func _make_character_texture(color: Color) -> ImageTexture:
	return ImageTexture.create_from_image(_paint_character_image(color))

## Same painted humanoid as above, but returned as {part_name -> Texture2D}
## (see PART_DEFS) instead of one whole-body texture -- the rig
## (player.tscn et al) needs each part as its own Sprite2D so it can be
## posed/animated independently.
func _make_character_parts(color: Color) -> Dictionary:
	return _slice_whole_image(ImageTexture.create_from_image(_paint_character_image(color)))

func _slice_whole_image(whole: Texture2D) -> Dictionary:
	var img := whole.get_image()
	var parts := {}
	for part_name in PART_NAMES:
		var rect: Rect2i = PART_DEFS[part_name].rect
		parts[part_name] = ImageTexture.create_from_image(img.get_region(rect))
	return parts

func _paint_character_image(color: Color) -> Image:
	var img := Image.create(VISUAL_WIDTH, VISUAL_HEIGHT, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))

	var shade := color.darkened(CHARACTER_SHADE_AMOUNT)
	var highlight := color.lightened(CHARACTER_HIGHLIGHT_AMOUNT)
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

	return img

## Same shapes as _paint_character_image, but with the three tintable
## regions (torso/arms+legs/head) marked with TEMPLATE_BASE/SHADE/HIGHLIGHT
## instead of a real color -- eyes stay their real fixed near-black, since
## that region is never tinted by skin color anyway (see bake's multiply
## fallback below, which keeps near-black near-black for any skin color).
## tools/extract_templates.gd calls this once to produce the editable files
## under game/assets/character_templates/; tools/bake_character_art.gd
## reverses the substitution per skin color to produce what the game loads.
func paint_character_template() -> Image:
	var img := Image.create(VISUAL_WIDTH, VISUAL_HEIGHT, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var eye_color := Color(0.05, 0.05, 0.08)

	_fill_rect(img, 11, 36, 15, 47, TEMPLATE_SHADE)
	_fill_rect(img, 17, 36, 21, 47, TEMPLATE_SHADE)
	_fill_rect(img, 3, 19, 9, 33, TEMPLATE_SHADE)
	_fill_rect(img, 23, 19, 29, 33, TEMPLATE_SHADE)
	_fill_rect(img, 9, 17, 23, 38, TEMPLATE_BASE)
	_fill_ellipse(img, 16.0, 10.0, 9.0, 9.0, TEMPLATE_HIGHLIGHT)
	_fill_ellipse(img, 12.0, 9.0, 1.6, 1.6, eye_color)
	_fill_ellipse(img, 20.0, 9.0, 1.6, 1.6, eye_color)

	return img

## Built-in hats, painted into the HAT_WIDTH x HAT_HEIGHT canvas (see the
## comment above HAT_WIDTH for why it's taller than the head's own crop).
## Each shape keeps its "resting" silhouette (brim/band/cuff) in the bottom
## HAT_OVERLAP rows, which is what actually lands over the head, with the
## rest of the shape free to rise above it.
func _make_hat_texture(id: String) -> ImageTexture:
	var def := {}
	for h in BUILTIN_HATS:
		if h.id == id:
			def = h
			break
	return ImageTexture.create_from_image(_paint_hat_image(def.get("shape", "cap"), def.get("color", Color.WHITE)))

func _paint_hat_image(shape: String, color: Color) -> Image:
	var img := Image.create(HAT_WIDTH, HAT_HEIGHT, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var shade := color.darkened(HAT_SHADE_AMOUNT)
	var highlight := color.lightened(HAT_HIGHLIGHT_AMOUNT)

	match shape:
		"cap":
			# Rounded dome resting into the head, plus a brim sticking out to
			# one side -- the whole rig (including this hat) mirrors via the
			# root Visual's scale.x sign when facing flips, so a one-sided
			# brim automatically flips with it.
			_fill_ellipse(img, 9.0, 10.0, 6.5, 6.5, color)
			_fill_rect(img, 9, 13, 17, 15, shade)
		"beanie":
			# Snugger and pulled down further than the cap, with a folded
			# cuff band spanning the full width near the bottom.
			_fill_ellipse(img, 9.0, 10.0, 7.0, 7.0, color)
			_fill_rect(img, 1, 12, 17, 15, shade)
		"tophat":
			_fill_rect(img, 5, 0, 13, 10, color) # crown/cylinder
			_fill_rect(img, 5, 6, 13, 8, highlight) # ribbon band
			_fill_rect(img, 1, 10, 17, 13, shade) # brim
		"crown":
			_fill_rect(img, 2, 10, 16, 14, color) # base band
			_fill_rect(img, 3, 4, 7, 10, color) # left spike
			_fill_rect(img, 8, 0, 11, 10, color) # center spike (tallest)
			_fill_rect(img, 12, 4, 16, 10, color) # right spike
			_fill_ellipse(img, 9.0, 3.0, 1.3, 1.3, Color(0.85, 0.2, 0.25)) # jewel

	return img

## Same shapes as _paint_hat_image, marker-substituted the same way as
## paint_character_template -- the crown's jewel keeps its real fixed color
## since it's never tinted by the hat's own color either (see _paint_hat_image).
func paint_hat_template(shape: String) -> Image:
	var img := Image.create(HAT_WIDTH, HAT_HEIGHT, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))

	match shape:
		"cap":
			_fill_ellipse(img, 9.0, 10.0, 6.5, 6.5, TEMPLATE_BASE)
			_fill_rect(img, 9, 13, 17, 15, TEMPLATE_SHADE)
		"beanie":
			_fill_ellipse(img, 9.0, 10.0, 7.0, 7.0, TEMPLATE_BASE)
			_fill_rect(img, 1, 12, 17, 15, TEMPLATE_SHADE)
		"tophat":
			_fill_rect(img, 5, 0, 13, 10, TEMPLATE_BASE)
			_fill_rect(img, 5, 6, 13, 8, TEMPLATE_HIGHLIGHT)
			_fill_rect(img, 1, 10, 17, 13, TEMPLATE_SHADE)
		"crown":
			_fill_rect(img, 2, 10, 16, 14, TEMPLATE_BASE)
			_fill_rect(img, 3, 4, 7, 10, TEMPLATE_BASE)
			_fill_rect(img, 8, 0, 11, 10, TEMPLATE_BASE)
			_fill_rect(img, 12, 4, 16, 10, TEMPLATE_BASE)
			_fill_ellipse(img, 9.0, 3.0, 1.3, 1.3, Color(0.85, 0.2, 0.25))

	return img

## Turns an edited template into a real, per-color image: marker regions
## (base/shade/highlight) get the exact same transform the original
## procedural painter used (color / darkened / lightened) for pixel-parity
## with the pre-template look; anything else -- eyes, hat accents, or a
## friend's own custom paint -- gets a generic multiply tint instead, which
## keeps already-dark accent colors (eyes, the crown's jewel) visually close
## to unchanged across every skin color while still giving a friend's own
## additions a reasonable per-skin recolor rather than staying frozen in
## whatever color they drew. Shared by tools/bake_character_art.gd (the CI
## bake step) and the Art Tool's live preview panel, so both use identical
## math.
func tint_template(template: Image, color: Color, shade_amount: float, highlight_amount: float) -> Image:
	var w := template.get_width()
	var h := template.get_height()
	var out := Image.create(w, h, false, Image.FORMAT_RGBA8)
	var shade := color.darkened(shade_amount)
	var highlight := color.lightened(highlight_amount)
	const TOLERANCE := 0.05
	for y in h:
		for x in w:
			var px := template.get_pixel(x, y)
			if px.a <= 0.001:
				continue
			var out_color: Color
			if _color_close(px, TEMPLATE_BASE, TOLERANCE):
				out_color = color
			elif _color_close(px, TEMPLATE_SHADE, TOLERANCE):
				out_color = shade
			elif _color_close(px, TEMPLATE_HIGHLIGHT, TOLERANCE):
				out_color = highlight
			else:
				out_color = Color(px.r * color.r, px.g * color.g, px.b * color.b, 1.0)
			out_color.a = px.a
			out.set_pixel(x, y, out_color)
	return out

func _color_close(a: Color, b: Color, tolerance: float) -> bool:
	return absf(a.r - b.r) < tolerance and absf(a.g - b.g) < tolerance and absf(a.b - b.b) < tolerance

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

func _fetch_hat_texture(id: String) -> void:
	var cache_key := "hat:" + id
	if _fetch_in_flight.has(cache_key):
		return
	_fetch_in_flight[cache_key] = true
	var req := HTTPRequest.new()
	add_child(req)
	req.request_completed.connect(func(_result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray):
		req.queue_free()
		_fetch_in_flight.erase(cache_key)
		if response_code == 200 and body.size() > 0:
			var img := Image.new()
			if img.load_png_from_buffer(body) == OK:
				_texture_cache[cache_key] = ImageTexture.create_from_image(img)
				hat_received.emit(id)
	)
	req.request("%s/image/%s" % [HAT_API_BASE, id])

# Four independent fetches -- the shared skin catalog, the shared hat
# catalog, and this client's own current skin + hat selections -- that all
# have to land before catalog_loaded fires. `pending` is a single-element
# array (not a plain int) so every request callback can share and mutate the
# same counter -- GDScript lambdas capture locals by value, so a plain int
# wouldn't be shared between separate closures.
func _fetch_catalog() -> void:
	var pending := [4]
	var on_one_done := func():
		pending[0] -= 1
		if pending[0] == 0:
			catalog_loaded.emit()

	var catalog_req := HTTPRequest.new()
	add_child(catalog_req)
	catalog_req.request_completed.connect(func(_result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray):
		catalog_req.queue_free()
		if response_code == 200:
			var parsed = JSON.parse_string(body.get_string_from_utf8())
			if typeof(parsed) == TYPE_ARRAY:
				_catalog_custom_skins = parsed
		on_one_done.call()
	)
	catalog_req.request("%s/catalog" % API_BASE)

	var selection_req := HTTPRequest.new()
	add_child(selection_req)
	selection_req.request_completed.connect(func(_result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray):
		selection_req.queue_free()
		if response_code == 200:
			var parsed = JSON.parse_string(body.get_string_from_utf8())
			if typeof(parsed) == TYPE_DICTIONARY:
				selected_skin_id = parsed.get("selected", "red")
		on_one_done.call()
	)
	selection_req.request("%s/%s" % [API_BASE, client_id])

	var hat_catalog_req := HTTPRequest.new()
	add_child(hat_catalog_req)
	hat_catalog_req.request_completed.connect(func(_result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray):
		hat_catalog_req.queue_free()
		if response_code == 200:
			var parsed = JSON.parse_string(body.get_string_from_utf8())
			if typeof(parsed) == TYPE_ARRAY:
				_catalog_hats = parsed
		on_one_done.call()
	)
	hat_catalog_req.request("%s/catalog" % HAT_API_BASE)

	var hat_selection_req := HTTPRequest.new()
	add_child(hat_selection_req)
	hat_selection_req.request_completed.connect(func(_result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray):
		hat_selection_req.queue_free()
		if response_code == 200:
			var parsed = JSON.parse_string(body.get_string_from_utf8())
			if typeof(parsed) == TYPE_DICTIONARY:
				selected_hat_id = str(parsed.get("selected", "") if parsed.get("selected") != null else "")
		on_one_done.call()
	)
	hat_selection_req.request("%s/%s" % [HAT_API_BASE, client_id])

## Re-runs the catalog + selection fetches and emits catalog_loaded again
## once they land -- used by the drawing tool so a freshly-uploaded skin/hat
## shows up in the shop immediately, without needing an app restart.
func refresh_catalog() -> void:
	_fetch_catalog()

func _post_selection(id: String) -> void:
	var req := HTTPRequest.new()
	add_child(req)
	req.request_completed.connect(func(_r, _c, _h, _b): req.queue_free())
	var body := JSON.stringify({"skinId": id})
	req.request("%s/%s/select" % [API_BASE, client_id], ["Content-Type: application/json"], HTTPClient.METHOD_POST, body)

func _post_hat_selection(id: String) -> void:
	var req := HTTPRequest.new()
	add_child(req)
	req.request_completed.connect(func(_r, _c, _h, _b): req.queue_free())
	var body := JSON.stringify({"hatId": id if not id.is_empty() else null})
	req.request("%s/%s/select" % [HAT_API_BASE, client_id], ["Content-Type: application/json"], HTTPClient.METHOD_POST, body)

## Uploads a freshly-drawn skin -- one small Image per rig part (see
## PART_DEFS), already painted by the drawing tool. Async, callers need
## `await`. Returns the new skin's server-assigned id, or "" on failure.
func add_drawn_skin(part_images: Dictionary, skin_name: String) -> String:
	var parts_json := {}
	for part_name in PART_NAMES:
		if not part_images.has(part_name):
			return ""
		parts_json[part_name] = Marshalls.raw_to_base64(part_images[part_name].save_png_to_buffer())

	var req := HTTPRequest.new()
	add_child(req)
	var body := JSON.stringify({"name": skin_name, "parts": parts_json})
	var err := req.request(
		"%s/%s/upload" % [API_BASE, client_id], ["Content-Type: application/json"], HTTPClient.METHOD_POST, body
	)
	if err != OK:
		req.queue_free()
		return ""
	var response: Array = await req.request_completed
	req.queue_free()
	if response[1] != 200:
		return ""
	var parsed = JSON.parse_string(response[3].get_string_from_utf8())
	if typeof(parsed) != TYPE_DICTIONARY or not parsed.has("id"):
		return ""
	var id: String = parsed.id
	# Already have the painted parts in hand locally -- no need to
	# immediately re-fetch what was just uploaded.
	var cached_parts := {}
	for part_name in PART_NAMES:
		cached_parts[part_name] = ImageTexture.create_from_image(part_images[part_name])
	_texture_cache["parts:" + id] = cached_parts
	_catalog_custom_skins.append({"id": id, "name": skin_name})
	return id

## Uploads a freshly-drawn hat -- a single small Image (see HAT dimensions,
## same size as the head part). Async, callers need `await`. Returns the
## new hat's server-assigned id, or "" on failure.
func add_drawn_hat(hat_image: Image, hat_name: String) -> String:
	var req := HTTPRequest.new()
	add_child(req)
	var body := JSON.stringify({"name": hat_name, "imageBase64": Marshalls.raw_to_base64(hat_image.save_png_to_buffer())})
	var err := req.request(
		"%s/%s/upload" % [HAT_API_BASE, client_id], ["Content-Type: application/json"], HTTPClient.METHOD_POST, body
	)
	if err != OK:
		req.queue_free()
		return ""
	var response: Array = await req.request_completed
	req.queue_free()
	if response[1] != 200:
		return ""
	var parsed = JSON.parse_string(response[3].get_string_from_utf8())
	if typeof(parsed) != TYPE_DICTIONARY or not parsed.has("id"):
		return ""
	var id: String = parsed.id
	_texture_cache["hat:" + id] = ImageTexture.create_from_image(hat_image)
	_catalog_hats.append({"id": id, "name": hat_name})
	return id

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
