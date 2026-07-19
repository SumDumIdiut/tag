extends RefCounted
class_name GameAssetOverrides

# Where GameAssetUpdater (see game_asset_updater.gd) saves whatever it
# downloads from the relay's built-in-art manifest, and where every
# relevant runtime loader checks FIRST before falling back to whatever got
# baked into this build at CI time (see art_tool.gd's Export Edits button
# and relay-server/server.js's "HTTP: game assets" section for how these
# get published in the first place). Same "never hard-fail on missing
# custom content" rule the rest of the project already follows -- a
# missing or corrupt override file just means "nothing overridden," never
# a crash.

const TILES_OVERRIDE_PATH := "user://game_assets/tiles.png"
const ICONS_OVERRIDE_PATH := "user://game_assets/icons.png"

static func mode_button_override_path(key: String) -> String:
	return "user://game_assets/mode_buttons/%s.png" % key

## Loads a downloaded override PNG straight off disk (not through
## ResourceLoader -- these are raw files GameAssetUpdater wrote directly,
## never imported into the project) as a ready-to-use Texture2D, or null if
## there's no override at that path or it fails to decode.
static func load_override_texture(path: String) -> Texture2D:
	if not FileAccess.file_exists(path):
		return null
	var img := Image.new()
	if img.load(path) != OK:
		return null
	return ImageTexture.create_from_image(img)

## Applies the tiles override (if any) onto the one shared TileSet resource
## every arena -- built-in or custom, see level_data.gd -- renders through.
## Call once at startup, before any arena has been built. Purely cosmetic:
## this only ever swaps the atlas's pixels, never its custom-data behavior
## layer (Ice/Bouncy friction etc, see player.gd), so it can never desync
## client/server gameplay logic -- only ever changes what a tile looks
## like, never how it behaves.
static func apply_tile_texture_override() -> void:
	var tex := load_override_texture(TILES_OVERRIDE_PATH)
	if not tex:
		return
	var tile_set: TileSet = load("res://levels/tag_tileset.tres")
	var source := tile_set.get_source(0) as TileSetAtlasSource
	if source:
		source.texture = tex
