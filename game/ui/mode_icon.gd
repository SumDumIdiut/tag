extends Control
class_name ModeIcon

# Small icons for the main menu's mode bars. Originally 100% procedural
# (drawn every _draw() call via CanvasItem primitives, no image assets in
# the project for this at all); now tries a paintable atlas first
# (game/assets/icons/tag_icons.png, baked by tools/build_icon_atlas.gd,
# editable via the Art Tool's Icons page) and falls back to the original
# procedural drawing if the atlas or this specific icon_type is missing --
# same "never hard-fail on missing custom content" rule the rest of the
# project already follows (DESIGN_SPEC.md), so this is safe to ship even
# before anyone paints anything, and stays safe if the atlas is ever
# deleted/corrupted.
#
# The atlas path renders via a child TextureRect + AtlasTexture rather than
# a manual draw_texture_rect_region() call in _draw() -- a first attempt
# using the latter reliably rendered as a solid modulate-colored block
# instead of the sliced region for any non-root Control (reproduced in
# isolation, cause not pinned down: identical parameters drawn directly
# from a scene root's own _draw() worked correctly). TextureRect sidesteps
# it entirely and is the more idiomatic tool for "display a texture region"
# anyway -- anchored to fill this control, so it never needs to know this
# control's final size up front the way the immediate-mode draw call did.
#
# The atlas is baked in solid white so one shared image still serves every
# usage's own icon_color -- the TextureRect's own modulate retints the
# loaded shape per instance, the same way the procedural version below
# already varies its drawn color per instance.
@export var icon_type: String = "bolt"
@export var icon_color: Color = Color.WHITE:
	set(value):
		icon_color = value
		if _atlas_rect:
			_atlas_rect.modulate = value
		queue_redraw()
@export var line_width: float = 3.0

const ATLAS_PATH := "res://assets/icons/tag_icons.png"
const ATLAS_ICON_SIZE := 64
# Same order build_icon_atlas.gd bakes in -- index here is the atlas-x slot
# for that icon_type, mirroring the tile/tileset index-order contract
# build_tileset.gd/tile_canvas.gd already use.
const ATLAS_ICON_ORDER := ["globe", "controller", "box", "bolt", "star", "tag"]
# "clock" isn't baked into the atlas (added after build_icon_atlas.gd's last
# bake) -- ATLAS_ICON_ORDER.find() returns -1 for it, so it always falls
# through to the procedural _draw() case below. Safe either way: baking it
# in later just needs appending it to this array and re-running the atlas
# builder, same as any other icon_type.

var _atlas_rect: TextureRect = null

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_try_setup_atlas()
	# Explicit, imperative sizing instead of relying on anchors: this runs in
	# _ready(), which fires before a freshly-added leaf Control's size has
	# necessarily settled to its final custom_minimum_size-driven value (the
	# procedural _draw() path never had this problem since it only ever
	# reads `size` later, at an actual redraw). resized re-syncs on every
	# future layout change too, so this stays correct regardless of when the
	# caller sets custom_minimum_size relative to when this node is added.
	resized.connect(_sync_atlas_rect_size)
	_sync_atlas_rect_size()

func _sync_atlas_rect_size() -> void:
	if _atlas_rect:
		_atlas_rect.position = Vector2.ZERO
		_atlas_rect.size = size

## Adds a child TextureRect sliced to this icon_type's atlas region if the
## atlas file and that icon_type are both available; leaves _atlas_rect null
## (so _draw()'s procedural fallback runs instead) otherwise. Checks a
## downloaded GameAssetOverrides atlas first (see game_asset_updater.gd),
## then the one baked into this build at CI time.
func _try_setup_atlas() -> void:
	var idx := ATLAS_ICON_ORDER.find(icon_type)
	if idx < 0:
		return
	var tex: Texture2D = GameAssetOverrides.load_override_texture(GameAssetOverrides.ICONS_OVERRIDE_PATH)
	if not tex:
		if not ResourceLoader.exists(ATLAS_PATH):
			return
		tex = load(ATLAS_PATH)
	if not tex:
		return
	var atlas_tex := AtlasTexture.new()
	atlas_tex.atlas = tex
	atlas_tex.region = Rect2(idx * ATLAS_ICON_SIZE, 0, ATLAS_ICON_SIZE, ATLAS_ICON_SIZE)

	_atlas_rect = TextureRect.new()
	_atlas_rect.texture = atlas_tex
	_atlas_rect.stretch_mode = TextureRect.STRETCH_SCALE
	# Without this, TextureRect reports the atlas region's native 64x64 size
	# as its own minimum size, which then propagates up and inflates this
	# control's (and its caller's badge_wrap's) computed size well past the
	# small custom_minimum_size every call site actually sets -- this was
	# the actual cause of icons rendering oversized/overflowing their
	# badges, not a sizing-order/timing issue.
	_atlas_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_atlas_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_atlas_rect.modulate = icon_color
	add_child(_atlas_rect)

func _draw() -> void:
	if _atlas_rect:
		return
	var s: Vector2 = size
	var c: Vector2 = s * 0.5
	match icon_type:
		"clock":
			draw_arc(c, s.x * 0.42, 0.0, TAU, 40, icon_color, line_width)
			draw_line(c, c + Vector2(0, -s.y * 0.28), icon_color, line_width * 0.8)
			draw_line(c, c + Vector2(s.x * 0.2, s.y * 0.12), icon_color, line_width * 0.8)
		"bolt":
			var pts := PackedVector2Array([
				Vector2(0.58, 0.0), Vector2(0.18, 0.56), Vector2(0.46, 0.56),
				Vector2(0.38, 1.0), Vector2(0.86, 0.4), Vector2(0.56, 0.4),
			])
			for i in pts.size():
				pts[i] = pts[i] * s
			draw_colored_polygon(pts, icon_color)
		"star":
			var pts := PackedVector2Array()
			var outer := s.x * 0.5
			var inner := outer * 0.42
			for i in 10:
				var ang := -PI / 2.0 + i * PI / 5.0
				var r := outer if i % 2 == 0 else inner
				pts.append(c + Vector2(cos(ang), sin(ang)) * r)
			draw_colored_polygon(pts, icon_color)
		"controller":
			var body := Rect2(s.x * 0.08, s.y * 0.32, s.x * 0.84, s.y * 0.4)
			draw_rect(body, icon_color, true, -1.0)
			draw_circle(Vector2(s.x * 0.08, s.y * 0.52), s.x * 0.14, icon_color)
			draw_circle(Vector2(s.x * 0.92, s.y * 0.52), s.x * 0.14, icon_color)
			var dpad_c := Vector2(s.x * 0.27, s.y * 0.52)
			draw_line(dpad_c + Vector2(-0.07, 0) * s.x, dpad_c + Vector2(0.07, 0) * s.x, icon_color.darkened(0.5), line_width)
			draw_line(dpad_c + Vector2(0, -0.07) * s.y, dpad_c + Vector2(0, 0.07) * s.y, icon_color.darkened(0.5), line_width)
			draw_circle(Vector2(s.x * 0.73, s.y * 0.44), s.x * 0.05, icon_color.darkened(0.5))
			draw_circle(Vector2(s.x * 0.8, s.y * 0.58), s.x * 0.05, icon_color.darkened(0.5))
		"globe":
			var r := s.x * 0.42
			draw_arc(c, r, 0.0, TAU, 40, icon_color, line_width)
			draw_arc(c, r * 0.55, 0.0, TAU, 32, icon_color, line_width * 0.8)
			draw_line(Vector2(c.x, c.y - r), Vector2(c.x, c.y + r), icon_color, line_width * 0.8)
			draw_line(Vector2(c.x - r, c.y), Vector2(c.x + r, c.y), icon_color, line_width * 0.8)
		"tag":
			var pts := PackedVector2Array([
				Vector2(0.06, 0.42), Vector2(0.5, 0.02), Vector2(0.94, 0.42),
				Vector2(0.7, 1.0), Vector2(0.3, 1.0),
			])
			for i in pts.size():
				pts[i] = pts[i] * s
			draw_colored_polygon(pts, icon_color)
			draw_circle(Vector2(0.5, 0.34) * s, s.x * 0.07, icon_color.darkened(0.6))
		"box":
			# An isometric crate -- three shaded quads (top/left/right faces)
			# read as a single 3D box at a glance, standing in for "a place
			# to play around/test things" the way a physical sandbox would.
			var top := PackedVector2Array([
				Vector2(0.5, 0.05), Vector2(0.85, 0.25), Vector2(0.5, 0.45), Vector2(0.15, 0.25),
			])
			var left := PackedVector2Array([
				Vector2(0.15, 0.25), Vector2(0.5, 0.45), Vector2(0.5, 0.92), Vector2(0.15, 0.72),
			])
			var right := PackedVector2Array([
				Vector2(0.85, 0.25), Vector2(0.5, 0.45), Vector2(0.5, 0.92), Vector2(0.85, 0.72),
			])
			for i in top.size():
				top[i] *= s
			for i in left.size():
				left[i] *= s
			for i in right.size():
				right[i] *= s
			draw_colored_polygon(top, icon_color.lightened(0.25))
			draw_colored_polygon(left, icon_color.darkened(0.15))
			draw_colored_polygon(right, icon_color.darkened(0.35))
		_:
			draw_circle(c, s.x * 0.4, icon_color)