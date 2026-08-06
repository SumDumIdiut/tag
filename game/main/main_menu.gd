extends Control

const UIStyle := preload("res://ui/ui_style.gd")
const UpdateCheckerScript := preload("res://net/update_checker.gd")
const UpdatePromptScene := preload("res://ui/update_prompt.gd")
const GameAssetUpdaterScript := preload("res://net/game_asset_updater.gd")
const GameAssetUpdatePromptScene := preload("res://ui/game_asset_update_prompt.gd")
const MapsUpdatePromptScene := preload("res://ui/maps_update_prompt.gd")
const UILayoutUpdaterScript := preload("res://net/ui_layout_updater.gd")

# Two top-level destinations, each fanning out to its own related
# sub-screens instead of a flat list of unrelated modes: ONLINE covers
# everything network-related (quick play, ranked, browse/host/direct
# connect -- see online_menu.tscn), LOCAL is bot practice.
const MODES := [
	{"key": "online", "label": "ONLINE", "color": UIStyle.COLOR_ONLINE, "scene": "res://main/online_menu.tscn"},
	{"key": "local", "label": "LOCAL", "color": UIStyle.COLOR_LOCAL, "scene": "res://main/local_menu.tscn"},
]

const BAR_SIZE := Vector2(190, 360)

# main_menu.tscn isn't a singleton -- get_tree().change_scene_to_file() to
# it re-runs _ready() from scratch on every return here (after a match,
# every "back" button, from 20+ call sites across the game), which used to
# mean _check_for_update()/_check_for_asset_update() re-ran every single
# time too. Neither prompt persists a "you already answered this" anywhere
# (Skip just queue_free()s itself; a failed download just re-enables its
# own buttons), so the exact same "NEW ART AVAILABLE -- Download now?" card
# kept resurfacing after every match -- read as a stuck/stale popup that
# wouldn't go away. Static vars persist across scene reloads within one
# running process (same pattern TrainedPolicy._shared uses) without needing
# a whole new autoload just for two booleans -- this makes both checks
# genuinely "once per launch," matching what update_prompt.gd's own comment
# already claims ("the check runs again next launch") but nothing actually
# enforced.
static var _checked_for_update_this_session := false
static var _checked_for_asset_update_this_session := false
static var _checked_for_maps_this_session := false
static var _checked_for_layout_update_this_session := false

@onready var mode_bar: HBoxContainer = $VBox/ModeBar
@onready var title_label: Label = $VBox/Title
@onready var subtitle_label: Label = $VBox/Subtitle

func _ready() -> void:
	UIStyle.add_background(self, "main_menu")
	for mode in MODES:
		mode_bar.add_child(_build_bar(mode))
	_build_account_button()
	_build_achievements_button()
	UIStyle.apply_layout_override(title_label, "main_menu.title")
	UIStyle.apply_layout_override(subtitle_label, "main_menu.subtitle")
	_check_for_update()
	_check_for_asset_update()
	_check_for_maps_update()
	_check_for_layout_update()

func _check_for_update() -> void:
	if _checked_for_update_this_session:
		return
	_checked_for_update_this_session = true
	var checker := UpdateCheckerScript.new("TagSetup.exe")
	add_child(checker)
	checker.check_completed.connect(_on_update_check_completed)
	checker.check()

func _on_update_check_completed(result: Dictionary) -> void:
	if not result.get("available", false):
		return
	var prompt := UpdatePromptScene.new()
	add_child(prompt)
	prompt.setup(result.version, result.download_url)

## Separate from the whole-binary check above -- tiles/icons/mode-button-art
## published from the Art Tool (see game_asset_updater.gd) don't need a new
## release or a relaunch, just a couple small PNGs applied live.
func _check_for_asset_update() -> void:
	if _checked_for_asset_update_this_session:
		return
	_checked_for_asset_update_this_session = true
	var updater := GameAssetUpdaterScript.new()
	add_child(updater)
	updater.check_completed.connect(_on_asset_check_completed)
	updater.check()

func _on_asset_check_completed(result: Dictionary) -> void:
	if not result.get("available", false):
		return
	var prompt := GameAssetUpdatePromptScene.new()
	add_child(prompt)
	prompt.setup(result.categories, result.manifest)
	# A freshly downloaded chrome update only affects buttons built after the
	# download (see GameAssetOverrides) -- rebuild the bar so it doesn't need
	# leaving and coming back to the main menu to pick it up.
	prompt.applied.connect(_rebuild_mode_bar)

## Unlike _check_for_asset_update() above, no player-facing prompt -- a
## button/label's position/size/text override (see UIStyle.
## apply_layout_override(), the website's UI Editor) is treated as part of
## the base game's own default look, same trust level as chrome/background
## art, just silently kept current instead of offered as optional content.
## Whatever this finds only affects screens built AFTER the download lands
## (same "next visit, not this instant" characteristic _check_for_asset_
## update() already has before its own prompt is answered) -- acceptable
## since this is a background check on every launch, not a one-time event.
func _check_for_layout_update() -> void:
	if _checked_for_layout_update_this_session:
		return
	_checked_for_layout_update_this_session = true
	var updater := UILayoutUpdaterScript.new()
	add_child(updater)
	updater.check_and_apply()

## CustomLevelCache.check() runs on its own at autoload boot (well before
## this screen even loads), so by the time this connects it may already
## have resolved -- check_done covers that race the same way is_ready
## itself already has to for every other consumer of this autoload.
func _check_for_maps_update() -> void:
	if _checked_for_maps_this_session:
		return
	_checked_for_maps_this_session = true
	if CustomLevelCache.check_done:
		_on_maps_check_completed(CustomLevelCache.catalog_count > 0, CustomLevelCache.catalog_count)
	else:
		CustomLevelCache.check_completed.connect(_on_maps_check_completed, CONNECT_ONE_SHOT)

func _on_maps_check_completed(available: bool, count: int) -> void:
	# `available` (backed by CustomLevelCache.catalog_count > 0) already means
	# "there's something genuinely new-or-edited still pending download" --
	# that's the whole point of the check, so it's sufficient on its own.
	# Deliberately NOT also gating on CustomLevelCache.is_ready: that used to
	# double as "nothing left to ask about" back when is_ready could only
	# become true once a check()/download cycle fully settled, but
	# _ready()'s disk-cache fast path can now set is_ready true immediately
	# at startup while a real pending entry still sits unfetched -- gating on
	# it here made this prompt silently never appear for exactly the case it
	# exists for (any level already cached, which is normal after the very
	# first download ever). _checked_for_maps_this_session (see the caller)
	# already prevents this from firing more than once per process anyway.
	if not available:
		return
	var prompt := MapsUpdatePromptScene.new()
	add_child(prompt)
	prompt.setup(count)

func _rebuild_mode_bar() -> void:
	for child in mode_bar.get_children():
		mode_bar.remove_child(child)
		child.queue_free()
	for mode in MODES:
		mode_bar.add_child(_build_bar(mode))

func _build_bar(mode: Dictionary) -> Button:
	var color: Color = mode["color"]
	var btn := Button.new()
	btn.text = mode["label"]
	btn.custom_minimum_size = BAR_SIZE
	btn.focus_mode = Control.FOCUS_ALL
	btn.clip_contents = true
	UIStyle.style_button(btn, color, 18)
	btn.add_theme_font_size_override("font_size", 20)
	btn.pressed.connect(_on_mode_pressed.bind(mode["scene"]))
	UIStyle.apply_layout_override(btn, "main_menu.%s_button" % mode["key"])
	return btn

## Mirrors the old Customize corner-button treatment, opposite corner --
## logging in is optional and never gates play (see login_screen.gd), so it
## gets the same "always available, doesn't compete with the three real
## mode bars" placement as Customize.
func _build_account_button() -> void:
	var btn := Button.new()
	btn.text = "  Account"
	btn.custom_minimum_size = Vector2(150, 44)
	btn.focus_mode = Control.FOCUS_ALL
	UIStyle.style_button(btn, UIStyle.COLOR_ONLINE, 10)
	btn.set_anchors_preset(Control.PRESET_TOP_LEFT)
	btn.position = Vector2(20, 24)
	btn.pressed.connect(_on_mode_pressed.bind("res://main/login_screen.tscn"))
	add_child(btn)
	UIStyle.apply_layout_override(btn, "main_menu.account_button")

## Opposite corner from Account -- same "always available, doesn't compete
## with the mode bars" placement, just top-right instead of top-left.
func _build_achievements_button() -> void:
	var btn := Button.new()
	btn.text = "Achievements  "
	btn.custom_minimum_size = Vector2(150, 44)
	btn.focus_mode = Control.FOCUS_ALL
	UIStyle.style_button(btn, UIStyle.COLOR_ACCENT, 10)
	btn.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	btn.position = Vector2(-170, 24)
	btn.pressed.connect(_on_mode_pressed.bind("res://main/achievements_menu.tscn"))
	add_child(btn)
	UIStyle.apply_layout_override(btn, "main_menu.achievements_button")

func _on_mode_pressed(scene_path: String) -> void:
	get_tree().change_scene_to_file(scene_path)
