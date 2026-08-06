extends Node2D
class_name MapBackground

# Plain flat backdrop -- no per-map gradient/silhouette art anymore (reverted
# per explicit request; theme_color/theme_shape are kept as exported fields
# only because every generated map scene already carries baked values for
# them and other systems still legitimately use those two independently of
# this node -- see catalog.gd's own theme_color/theme_shape driving
# local_map_icon.gd's picker thumbnails and _build_map_thumb()'s selected-
# border tint. This node's own _draw() just ignores them now. z_index keeps
# this behind the Tiles layer and every player regardless of node order in
# the scene tree.

@export var theme_color: Color = Color(0.5, 0.5, 0.55)
@export var theme_shape: String = "rect" # "triangle" | "circle" | "rect"
# Exactly the world-space rect the match's fixed camera shows (see
# FixedView.compute(), which is what generate_local_maps.gd/
# generate_online_maps.gd actually set this to) -- not just "loosely around
# the platforms." Since the camera never pans or zooms past this rect, the
# flat fill below always covers the whole screen with no edge ever visible,
# same as if it extended infinitely. Also the source of truth the fixed
# camera and death-plane boundary (see fixed_view.gd) are built from --
# keep this in sync even though the art itself is gone.
@export var bounds: Rect2 = Rect2(-1100, -100, 2200, 700)

# A custom level's own uploaded backdrop (see CustomLevelCache/LevelData.
# build_arena_from_data), stretched to fill `bounds` exactly -- null (every
# built-in map, and any custom level that didn't upload one) just means the
# flat FILL_COLOR below is all that shows, same as before this existed.
@export var background_texture: Texture2D = null

const FILL_COLOR := Color(0.11, 0.115, 0.145)

func _ready() -> void:
	z_index = -10
	z_as_relative = false

func _draw() -> void:
	draw_rect(bounds, FILL_COLOR)
	if background_texture != null:
		draw_texture_rect(background_texture, bounds, false)
