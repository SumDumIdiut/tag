extends AnimatableBody2D
class_name MovingPlatform

# Deterministic ping-pong motion between two tile-grid points -- both the
# dedicated server (authoritative collision, server_match.gd) and every
# client (rendering only, net_game.gd) instantiate this exact same scene
# from the exact same level data (see level_data.gd's "platforms" array)
# and let it free-run locally from the moment it enters the tree. No
# position is ever sent over the network for this: there's nothing to
# desync, since both sides evaluate the same formula against elapsed
# physics time since their own copy spawned, not a value either side could
# disagree about. A real player standing on this rides along for free --
# AnimatableBody2D is Godot's purpose-built "moving platform" body, and
# CharacterBody2D.move_and_slide() (already how Player moves) already knows
# how to carry a rider standing on one, with zero extra code on the
# player's side.

const Categories := preload("res://net/game_asset_categories.gd")
const GameAssetOverrides := preload("res://net/game_asset_overrides.gd")

const TILE_SIZE := 10.0
# A few tiles wide so there's a real surface to stand on, not a knife-edge --
# fixed rather than per-instance configurable, keeping the level-data schema
# to exactly {start, end, period_sec} as specified. Exactly 3 tiles
# (Categories.PLATFORM_KEYS.size()) wide, matching the fixed left/middle/
# right tile set below -- no auto-tiling/terrain matching needed since a
# platform is never any other width.
const PLATFORM_SIZE := Vector2(30, 10)

@export var start_cell := Vector2i.ZERO
@export var end_cell := Vector2i.ZERO
@export var period_sec := 4.0

var _start_pos: Vector2
var _end_pos: Vector2
var _start_frame := 0

func _ready() -> void:
	_start_pos = Vector2(start_cell) * TILE_SIZE
	_end_pos = Vector2(end_cell) * TILE_SIZE
	_start_frame = Engine.get_physics_frames()
	global_position = _start_pos
	_build_visual()

## Assembles the platform's own left/middle/right tiles into a small
## TileMapLayer built once here rather than a static .tscn TileSet resource
## -- each tile's texture is resolved through the same 3-tier lookup
## ui_style.gd's _chrome_stylebox() already uses (live-published override ->
## baked res://assets art -> a flat-color fallback matching the old plain
## ColorRect this replaces), so painting/uploading real tile art via the Art
## Tool's Platform section (or a live game-asset publish) never needs a
## rebuild or a resource regeneration step here.
func _build_visual() -> void:
	var tile_set := TileSet.new()
	tile_set.tile_size = Vector2i(TILE_SIZE, TILE_SIZE)
	for i in Categories.PLATFORM_KEYS.size():
		var source := TileSetAtlasSource.new()
		source.texture = _load_tile_texture(Categories.PLATFORM_KEYS[i])
		source.texture_region_size = Vector2i(TILE_SIZE, TILE_SIZE)
		source.create_tile(Vector2i.ZERO)
		tile_set.add_source(source, i)

	var layer := TileMapLayer.new()
	layer.name = "Visual"
	layer.tile_set = tile_set
	# Centered on the platform's own origin, matching the old ColorRect's
	# offset_left=-15/offset_top=-5 footprint exactly (3 tiles * 10px = 30
	# wide, 10 tall).
	layer.position = Vector2(-TILE_SIZE * Categories.PLATFORM_KEYS.size() * 0.5, -TILE_SIZE * 0.5)
	for i in Categories.PLATFORM_KEYS.size():
		layer.set_cell(Vector2i(i, 0), i, Vector2i.ZERO)
	add_child(layer)

static func _load_tile_texture(key: String) -> Texture2D:
	var override_tex := GameAssetOverrides.load_override_texture(GameAssetOverrides.platform_override_path(key))
	if override_tex:
		return override_tex
	var path := "res://assets/icons/platform/%s.png" % key
	if ResourceLoader.exists(path):
		return load(path)
	# Same flat color the old ColorRect Visual used -- only reached if the
	# bake tool has never been run at all (see build_chrome_art.gd), never
	# in a normal shipped build.
	var img := Image.create(int(TILE_SIZE), int(TILE_SIZE), false, Image.FORMAT_RGBA8)
	img.fill(Color(0.85, 0.55, 0.2, 1))
	return ImageTexture.create_from_image(img)

func _physics_process(_delta: float) -> void:
	if period_sec <= 0.0 or _start_pos == _end_pos:
		return
	var elapsed := float(Engine.get_physics_frames() - _start_frame) / 60.0
	var phase := fmod(elapsed, period_sec) / period_sec # 0..1 over one period
	# Triangle wave (0 -> 1 -> 0 across one period) -- a smooth reversal at
	# both endpoints rather than a snap-back sawtooth would give.
	var t := 1.0 - absf(phase * 2.0 - 1.0)
	global_position = _start_pos.lerp(_end_pos, t)
