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

const ICONS_OVERRIDE_PATH := "user://game_assets/icons.png"

static func mode_button_override_path(key: String) -> String:
	return "user://game_assets/mode_buttons/%s.png" % key

static func background_override_path(key: String) -> String:
	return "user://game_assets/backgrounds/%s.png" % key

static func online_bar_override_path(key: String) -> String:
	return "user://game_assets/online_bars/%s.png" % key

static func local_bar_override_path(key: String) -> String:
	return "user://game_assets/local_bars/%s.png" % key

static func ranked_bar_override_path(key: String) -> String:
	return "user://game_assets/ranked_bars/%s.png" % key

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
