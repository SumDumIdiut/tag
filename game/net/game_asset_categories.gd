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

const MODE_BUTTON_KEYS := ["online", "local"]
# Every menu screen with a paintable background (see UIStyle.add_background).
const BACKGROUND_KEYS := [
	"main_menu", "online_menu", "local_menu", "shop", "friends_menu",
	"lobby_room", "host_setup", "login_screen", "match_intro", "match_results",
	"multiplayer_connect", "quick_play", "ranked_queue", "server_browser",
]
# Mirrors online_menu.gd's 5 bars -- see tools/generate_menu_art.gd. No Art
# Tool section paints these yet (only the generator does); listed here so
# one exists when that gap gets closed.
const ONLINE_BAR_KEYS := ["quick_play", "ranked", "browse_servers", "host_server", "friends"]
# Mirrors local_menu.gd's Play Tag button (Back moved to ACTION_BAR_KEYS,
# shared with every other screen's Back). Same "no Art Tool section yet" gap.
const LOCAL_BAR_KEYS := ["play"]
# Mirrors match_intro.gd's ranked VS reveal "Ready!" button. Same gap.
const RANKED_BAR_KEYS := ["ready"]
# One shared image per key reused across every screen that has that
# button (see ui/ui_style.gd's apply_bar_art).
const ACTION_BAR_KEYS := ["back", "connect", "watch", "host_server", "ready", "start_match", "login", "create_account", "logout"]
# ranked_playlist_select.gd's whole-bar art check.
const PLAYLIST_CARD_KEYS := ["1v1", "2v2", "1v1v1", "1v1v1v1"]
# One shared background image reused by every LineEdit in the app.
const FIELD_ART_KEYS := ["field"]
# Every button/panel/slider's own 9-patch box art (see UIStyle.button_box()/
# panel_box()/style_slider() and tools/build_chrome_art.gd) -- the app's
# shared visual chrome, reused everywhere at once.
const CHROME_KEYS := ["button", "panel", "slider_groove", "slider_fill"]
