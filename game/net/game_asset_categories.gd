extends RefCounted
class_name GameAssetCategories

# Single source of truth for every paintable-art category's key list.
# Before this file existed, each list below was hand-copied verbatim
# across three places with nothing enforcing they stayed in sync:
# game/tools/art_tool.gd (the editor), game/net/game_asset_updater.gd (the
# client-side live-download checker), and relay-server/server.js (the
# publish/manifest server). Both GDScript sides now preload this file
# instead of keeping their own copy, collapsing that to 2-way duplication
# -- GDScript here vs. relay-server/server.js, which can't share a literal
# source file across languages. server.js's own copies are marked with a
# `// SYNC: mirrors game/net/game_asset_categories.gd` comment as the one
# remaining manual handoff point; keep both sides updated together.

# Every button/panel/slider's own 9-patch box art (see UIStyle.button_box()/
# panel_box()/style_slider() and tools/build_chrome_art.gd) -- the app's
# shared visual chrome, reused everywhere at once.
const CHROME_KEYS := ["button", "panel", "slider_groove", "slider_fill"]

# The 3 tiles a MovingPlatform assembles itself from left-to-right (see
# levels/moving_platform.gd) -- always exactly 3 cells wide (its collision
# shape is fixed at 3 tiles, see PLATFORM_SIZE), so no auto-tiling/terrain
# matching is needed, just one fixed piece per position.
const PLATFORM_KEYS := ["left", "middle", "right"]

# One thumbnail per official matchmaking playlist (see
# net/playlist_catalog.gd's own PLAYLIST_ORDER, the actual source of truth
# this just mirrors the id list of) -- shown in casual_playlist_select.gd/
# ranked_playlist_select.gd's cards in place of the plain color fill once
# uploaded.
const PLAYLIST_THUMBNAIL_KEYS := ["1v1", "2v2", "1v1v1", "1v1v1v1"]

# One background per menu screen that calls UIStyle.add_background()/
# add_glow_background() -- see that file's own header for why this list
# exists (screen_key used to be a no-op). casual_playlist_select.gd/
# ranked_playlist_select.gd deliberately reuse "casual_queue"/"ranked_queue"
# rather than getting their own keys, matching add_background(self,
# "casual_queue")/"ranked_queue" already being called from those two files.
const BACKGROUND_KEYS := [
	"main_menu", "online_menu", "local_menu", "casual_queue", "ranked_queue",
	"lobby_room", "achievements_menu", "friends_menu", "login_screen",
	"match_intro", "match_intro_ranked", "match_results",
]
