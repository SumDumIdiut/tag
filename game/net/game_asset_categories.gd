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
