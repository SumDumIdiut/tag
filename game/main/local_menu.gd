extends Control

const UIStyle := preload("res://ui/ui_style.gd")
const LocalMapIconScene := preload("res://ui/local_map_icon.gd")

const MAP_THUMB_SIZE := Vector2(108, 82)
const MAP_GRID_COLUMNS := 4
const MAP_GRID_SEPARATION := 10
const MAP_GRID_VISIBLE_ROWS := 3
const MAP_NAME_BAR_HEIGHT := 18.0

@onready var vbox: VBoxContainer = $VBox
@onready var title_label: Label = $VBox/Title
@onready var subtitle_label: Label = $VBox/Subtitle
@onready var map_box: VBoxContainer = $VBox/MainRow/MapPanel/MapBox
@onready var settings_box: VBoxContainer = $VBox/MainRow/SettingsPanel/SettingsBox
@onready var npc_count_slider: HSlider = $VBox/MainRow/SettingsPanel/SettingsBox/NpcCountRow/NpcCountSlider
@onready var npc_count_value: Label = $VBox/MainRow/SettingsPanel/SettingsBox/NpcCountRow/NpcCountValue
@onready var skill_slider: HSlider = $VBox/MainRow/SettingsPanel/SettingsBox/SkillRow/SkillSlider
@onready var skill_value: Label = $VBox/MainRow/SettingsPanel/SettingsBox/SkillRow/SkillValue
@onready var round_duration_slider: HSlider = $VBox/MainRow/SettingsPanel/SettingsBox/RoundDurationRow/RoundDurationSlider
@onready var round_duration_value: Label = $VBox/MainRow/SettingsPanel/SettingsBox/RoundDurationRow/RoundDurationValue
@onready var start_button: Button = $VBox/StartButton
@onready var back_button: Button = $VBox/BackButton

var _trained_ai_button: Button
var _map_grid: GridContainer
var _map_button_group: ButtonGroup
var _download_label: Label
var _map_scroll: ScrollContainer

func _ready() -> void:
	UIStyle.add_background(self, "local_menu")
	$VBox/MainRow/MapPanel.add_theme_stylebox_override("panel", UIStyle.panel_box(UIStyle.COLOR_LOCAL))
	$VBox/MainRow/SettingsPanel.add_theme_stylebox_override("panel", UIStyle.panel_box(UIStyle.COLOR_LOCAL))
	# Same plain flat-color-no-glow bar treatment online_menu.gd's row uses --
	# Local only has the one real destination (there's nothing to arrange in
	# a row here), but it should still carry the same visual weight/boldness
	# as those bars rather than reading as a smaller, secondary action.
	UIStyle.style_button(start_button, UIStyle.COLOR_LOCAL, 18)
	start_button.add_theme_font_size_override("font_size", 18)
	# Re-enabled once a real map is actually selected (see _populate_map_grid())
	# -- there's nothing to play against bots with until at least one
	# published level has finished downloading.
	start_button.disabled = true
	UIStyle.style_back_button(back_button)
	UIStyle.style_slider(npc_count_slider, UIStyle.COLOR_LOCAL)
	UIStyle.style_slider(skill_slider, UIStyle.COLOR_LOCAL)
	UIStyle.style_slider(round_duration_slider, UIStyle.COLOR_LOCAL)
	_build_map_grid()
	_build_trained_ai_toggle()

	npc_count_slider.value = GameSettings.npc_count
	skill_slider.value = GameSettings.npc_skill
	round_duration_slider.value = GameSettings.round_duration
	_update_npc_count_label(npc_count_slider.value)
	_update_skill_label(skill_slider.value)
	_update_round_duration_label(round_duration_slider.value)

	npc_count_slider.value_changed.connect(_update_npc_count_label)
	skill_slider.value_changed.connect(_update_skill_label)
	round_duration_slider.value_changed.connect(_update_round_duration_label)
	start_button.pressed.connect(_on_start_pressed)
	back_button.pressed.connect(_on_back_pressed)
	UIStyle.apply_layout_override(title_label, "local_menu.title")
	UIStyle.apply_layout_override(subtitle_label, "local_menu.subtitle")
	UIStyle.apply_layout_override(start_button, "local_menu.start_button")
	UIStyle.apply_layout_override(back_button, "local_menu.back_button")
	_recenter_vbox()

## `vbox` is a plain Control (not itself inside a parent container), sized
## via a fixed-looking offset rect around its center anchor point -- except
## the HEIGHT half of that rect isn't actually fixed, it's recomputed here
## from vbox's own real content height, because that varies (MainRow's
## height depends on how many maps _populate_map_grid() ends up showing, 1
## row vs up to MAP_GRID_VISIBLE_ROWS). A single static offset box can only
## ever be correct for one specific content height -- confirmed live as the
## whole title/panels/buttons cluster sitting visibly off-center (riding up
## in its own invisible box, with a dead gap below Back) the moment the map
## grid's own height became dynamic instead of always-maximal.
##
## Width (offset_left/offset_right) is deliberately left untouched, unlike
## height -- SettingsPanel's own custom_minimum_size.x=260 already floors
## it, but recomputing width too (an earlier version of this fix did) would
## still shrink-wrap the row down to whatever's actually needed right now,
## which looks fine for MapPanel today only because it happens to need
## about that much anyway. The original hand-picked width is the real
## intended layout size, just like lobby_room.gd/casual_playlist_select.gd's
## own identical fix -- only height genuinely needs to react to content.
##
## Called once after initial setup and again whenever _populate_map_grid()
## changes MainRow's height (including the background-refresh case).
func _recenter_vbox() -> void:
	await get_tree().process_frame
	var content_height := vbox.get_combined_minimum_size().y
	vbox.offset_top = -content_height / 2.0
	vbox.offset_bottom = content_height / 2.0

func _update_npc_count_label(value: float) -> void:
	npc_count_value.text = str(int(value))

func _update_skill_label(value: float) -> void:
	skill_value.text = str(int(value))

func _update_round_duration_label(value: float) -> void:
	round_duration_value.text = "%ds" % int(value)

## Map choice used to be its own screen (local_map_picker.tscn, now retired)
## reached only after Play Tag -- now its own panel to the left of the
## settings sliders (see local_menu.tscn's MainRow) instead of squeezed in
## as just another settings row, so there's real room for a big, legible
## grid: 4 columns of thumbnails, 3 rows visible at once with vertical
## scroll for the rest. Every map is a live-published custom level (see
## CustomLevelCache) -- there's no more built-in set, so this grid starts
## empty behind a download prompt until that startup fetch actually
## resolves, rather than assuming it's already done by the time a player
## reaches this screen. Selection is a plain ButtonGroup of toggle buttons;
## Play Tag starts the match directly with whichever map is selected here,
## same as the slider rows beside it.
func _build_map_grid() -> void:
	_download_label = Label.new()
	_download_label.text = "Downloading maps..."
	_download_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_download_label.add_theme_color_override("font_color", UIStyle.COLOR_NEUTRAL)
	map_box.add_child(_download_label)

	_map_scroll = ScrollContainer.new()
	# No custom_minimum_size set here -- _populate_map_grid() sizes this to
	# however many rows the real entry count actually needs (capped at
	# MAP_GRID_VISIBLE_ROWS) once that's known, rather than always reserving
	# the full 3-row height up front regardless of how many maps exist.
	# Invisible until then anyway, so it contributes nothing to MapPanel's
	# size during the brief loading state.
	_map_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_map_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	_map_scroll.visible = false
	map_box.add_child(_map_scroll)

	_map_grid = GridContainer.new()
	_map_grid.columns = MAP_GRID_COLUMNS
	_map_grid.add_theme_constant_override("h_separation", MAP_GRID_SEPARATION)
	_map_grid.add_theme_constant_override("v_separation", MAP_GRID_SEPARATION)
	_map_scroll.add_child(_map_grid)

	_map_button_group = ButtonGroup.new()
	if CustomLevelCache.is_ready:
		_populate_map_grid()
	# Always (re)connect + call ensure_loaded(), even when already ready from
	# disk cache -- there may still be a genuinely new or edited level sitting
	# unfetched (see CustomLevelCache._on_catalog_response()'s updatedAt
	# staleness check); ensure_loaded() is a cheap no-op if there truly isn't
	# one. Without this, a level edited (e.g. a new thumbnail/background
	# added via the web Level Editor) after this client already had it cached
	# would never get re-fetched here -- confirmed live as "thumbnail shows
	# in the editor but not in game" for an already-downloaded level.
	CustomLevelCache.levels_ready.connect(_populate_map_grid, CONNECT_ONE_SHOT)
	CustomLevelCache.ensure_loaded()

## Runs once CustomLevelCache's startup download has actually finished --
## immediately if it already had by the time this screen opened, otherwise
## as soon as it does (possibly a SECOND time, if the first render was the
## disk-cache fast path and a background refresh for an edited level then
## completes -- see _build_map_grid()'s own comment). Swaps the download
## prompt for either the real grid or, if genuinely nothing has ever been
## published, a plain empty-state message rather than a silently-unusable
## blank panel.
func _populate_map_grid() -> void:
	var entries := CustomLevelCache.level_entries_newest_first()
	# Rebuilding from scratch each call (rather than assuming this only ever
	# runs once) is what makes the background-refresh case above safe --
	# without this, a second call would just pile a duplicate row of thumbs
	# on top of the first. Done before the empty check too, on the (very
	# unlikely, but now structurally possible) chance every custom level got
	# deleted from the relay between this screen's first render and a
	# second one.
	for child in _map_grid.get_children():
		_map_grid.remove_child(child)
		child.queue_free()
	if entries.is_empty():
		_download_label.text = "No maps published yet -- publish one from the website's Level Editor."
		_download_label.visible = true
		_map_scroll.visible = false
		start_button.disabled = true
		_recenter_vbox()
		return
	_download_label.visible = false
	_map_scroll.visible = true

	# Only reserve as much scroll height as the real entry count needs (1
	# row for anywhere from 1-4 maps, up to the MAP_GRID_VISIBLE_ROWS cap for
	# a large catalog) -- confirmed live as the main source of the awkward
	# dead space below a sparse map list: a single published level used to
	# still get the full 3-row-tall box regardless.
	var rows_needed := clampi(ceili(entries.size() / float(MAP_GRID_COLUMNS)), 1, MAP_GRID_VISIBLE_ROWS)
	_map_scroll.custom_minimum_size = Vector2(0, MAP_THUMB_SIZE.y * rows_needed + MAP_GRID_SEPARATION * (rows_needed - 1))

	var have_valid_selection := false
	for entry in entries:
		var id := String(entry.id)
		_map_grid.add_child(_build_map_thumb(id, String(entry.name)))
		if id == GameSettings.selected_local_map:
			have_valid_selection = true
	# A previous session's selection may no longer be cached (relay restart,
	# level deleted, etc.) -- fall back to the newest map rather than leaving
	# Start enabled against an id nothing will actually resolve.
	if not have_valid_selection:
		GameSettings.selected_local_map = String(entries[0].id)
		(_map_grid.get_child(0) as Button).button_pressed = true
	start_button.disabled = false
	_recenter_vbox()

func _build_map_thumb(id: String, level_name: String) -> Button:
	var btn := Button.new()
	btn.text = ""
	btn.custom_minimum_size = MAP_THUMB_SIZE
	btn.toggle_mode = true
	btn.button_group = _map_button_group
	btn.button_pressed = id == GameSettings.selected_local_map
	btn.clip_contents = true
	btn.tooltip_text = level_name
	UIStyle.style_button(btn, UIStyle.COLOR_LOCAL, 8, false)
	btn.pressed.connect(func(): GameSettings.selected_local_map = id)

	var preview := LocalMapIconScene.new()
	preview.map_id = id
	preview.accent_color = UIStyle.COLOR_LOCAL
	preview.mouse_filter = Control.MOUSE_FILTER_IGNORE
	preview.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT, Control.PRESET_MODE_MINSIZE, 6)
	btn.add_child(preview)

	# Name is always visible, not just on hover -- a dark backing bar keeps
	# it legible regardless of the thumbnail underneath.
	var name_bar := ColorRect.new()
	name_bar.color = Color(0, 0, 0, 0.55)
	name_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	name_bar.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	name_bar.offset_top = -MAP_NAME_BAR_HEIGHT
	btn.add_child(name_bar)

	var name_label := Label.new()
	name_label.text = level_name
	name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	name_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	name_label.clip_text = true
	name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	name_label.add_theme_font_size_override("font_size", 11)
	name_label.add_theme_color_override("font_color", Color(0.94, 0.95, 0.98))
	name_label.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	name_label.offset_top = -MAP_NAME_BAR_HEIGHT
	btn.add_child(name_label)

	return btn

## TEMPORARY -- see GameSettings.use_trained_ai's own comment. A plain
## toggle button, not a slider row like the others above -- this isn't a
## real settings option meant to stick around, just a quick way to actually
## reach the RL-trained NPC (game/npc/trained_policy.gd) in-game.
func _build_trained_ai_toggle() -> void:
	_trained_ai_button = Button.new()
	_trained_ai_button.toggle_mode = true
	_trained_ai_button.button_pressed = GameSettings.use_trained_ai
	_trained_ai_button.custom_minimum_size = Vector2(0, 36)
	UIStyle.style_button(_trained_ai_button, UIStyle.COLOR_LOCAL, 10, false)
	# "[temporary]" used to be baked into the visible label itself -- moved to
	# just this tooltip so the button reads like a normal option in the list
	# instead of leftover debug text, while still flagging (to anyone who
	# hovers) that this isn't meant to be a permanent settings surface.
	_trained_ai_button.tooltip_text = "Experimental -- may be removed or reworked later."
	_update_trained_ai_label()
	_trained_ai_button.toggled.connect(func(_pressed: bool): _update_trained_ai_label())
	settings_box.add_child(_trained_ai_button)

func _update_trained_ai_label() -> void:
	_trained_ai_button.text = "Trained AI: %s" % ("ON -- one bot uses it" if _trained_ai_button.button_pressed else "OFF")

func _on_start_pressed() -> void:
	GameSettings.npc_count = int(npc_count_slider.value)
	GameSettings.npc_skill = int(skill_slider.value)
	GameSettings.round_duration = round_duration_slider.value
	GameSettings.use_trained_ai = _trained_ai_button.button_pressed
	get_tree().change_scene_to_file("res://main/game.tscn")

func _on_back_pressed() -> void:
	get_tree().change_scene_to_file("res://main/main_menu.tscn")
