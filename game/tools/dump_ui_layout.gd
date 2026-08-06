extends Node

# One-off tool: instantiates every screen the website UI Editor's Layout tab
# lets you edit, lets each one's real container layout settle, then reads
# UIStyle's dump-mode recording (see ui_style.gd's begin_layout_dump()/
# apply_layout_override()) of every registered element's REAL on-screen
# rect -- replacing ui-editor.html's hand-guessed 4-column grid defaults
# with the actual Godot-computed positions/sizes. Output is a flat
# {"screen.key": {x,y,w,h}, ...} JSON written directly to
# relay-server/public/layout-reference.json (not stdout -- the windowed
# win64.exe build doesn't reliably attach to a parent console's stdout even
# under --headless, and writing straight to the file this is actually for
# is simpler than round-tripping through a log anyway).
#
# Run via (the plain win64.exe, not _console.exe -- same reasoning as this
# session's own e2e screenshot tool):
#   Godot_v4.7-stable_win64.exe --headless --path game res://tools/dump_ui_layout.tscn
#
# Needs re-running (then redeploying relay-server/public/layout-reference.json)
# any time a screen's registered elements or their surrounding layout
# actually change -- this is a baked snapshot, not something computed live
# by the website.

const OUTPUT_PATH := "res://../relay-server/public/layout-reference.json"

const UIStyle := preload("res://ui/ui_style.gd")

const SCREENS := [
	{"path": "res://main/main_menu.tscn", "key": "main_menu"},
	{"path": "res://main/online_menu.tscn", "key": "online_menu"},
	{"path": "res://main/local_menu.tscn", "key": "local_menu"},
	{"path": "res://main/casual_playlist_select.tscn", "key": "casual_playlist_select"},
	{"path": "res://main/ranked_playlist_select.tscn", "key": "ranked_playlist_select"},
	{"path": "res://main/casual_queue.tscn", "key": "casual_queue"},
	{"path": "res://main/ranked_queue.tscn", "key": "ranked_queue"},
	{"path": "res://main/lobby_room.tscn", "key": "lobby_room"},
	{"path": "res://main/achievements_menu.tscn", "key": "achievements_menu"},
	{"path": "res://main/friends_menu.tscn", "key": "friends_menu"},
	{"path": "res://main/login_screen.tscn", "key": "login_screen"},
	{"path": "res://main/match_intro.tscn", "key": "match_intro"},
	{"path": "res://main/match_results.tscn", "key": "match_results"},
	{"path": "res://ui/pause_menu.tscn", "key": "pause_menu"},
]

func _ready() -> void:
	UIStyle.begin_layout_dump()
	for entry in SCREENS:
		await _dump_screen(entry["path"], entry["key"])

	var data := UIStyle.layout_dump_data()
	var f := FileAccess.open(OUTPUT_PATH, FileAccess.WRITE)
	if f == null:
		print("ERROR: could not open ", OUTPUT_PATH, " for writing (", FileAccess.get_open_error(), ")")
		get_tree().quit(1)
		return
	f.store_string(JSON.stringify(data, "\t"))
	f.close()
	print("Wrote ", data.size(), " entries to ", OUTPUT_PATH)
	get_tree().quit()

func _dump_screen(scene_path: String, screen_key: String) -> void:
	if not ResourceLoader.exists(scene_path):
		print("WARN: missing scene for ", screen_key, ": ", scene_path)
		return
	var node: Node = load(scene_path).instantiate()
	# call_deferred, not a direct add_child() -- this tool's own root is
	# still mid-setup on the very first call (same "Parent node is busy
	# setting up children" gotcha this session already hit and fixed for
	# the e2e screenshot tool), which silently dropped main_menu entirely
	# (it's first in SCREENS) until this was deferred.
	get_tree().root.add_child.call_deferred(node)
	await get_tree().process_frame

	# pause_menu.gd's own _ready() hides its card panel by default (a real
	# player only sees it after pressing the pause key) -- force it visible
	# so its layout actually settles/reads the same as every other screen.
	if screen_key == "pause_menu":
		var panel := node.get_node_or_null("Panel")
		if panel:
			panel.visible = true

	# Generous settle window: apply_layout_override()'s own dump recording
	# already awaits 2 frames per element, plus whatever frames each
	# screen's own _ready() needs for its container sort pass -- 6 frames
	# comfortably covers every screen's worst case with room to spare.
	for i in 6:
		await get_tree().process_frame

	print("dumped ", screen_key)
	node.queue_free()
	# One more frame so queue_free() actually leaves the tree before the
	# next screen is instantiated -- keeps each screen's autoload-driven
	# side effects (background music, connection state, etc.) from
	# overlapping with the next one's.
	await get_tree().process_frame
