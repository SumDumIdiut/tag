extends VBoxContainer
class_name MapVoteView

# Shared map-vote UI used by both lobby_room.gd (casual) and ranked_queue.gd
# (ranked) while waiting for a match to start -- one square tile per map in
# OnlineMapCatalog (small, fully built-in) PLUS every live-published custom
# level (web Level Editor or the in-game Art Tool, both publish through the
# same relay endpoint), each showing a real preview of its layout with the
# vote tally and title beneath, reporting the local player's choice via
# NetworkManager.submit_map_vote(). Custom levels come from CustomLevelCache,
# downloaded once at game startup rather than fetched fresh by this screen
# every time it opens -- see that autoload's own header. A ballot row below
# the tiles shows every current voter's own pick as a small preview swatch,
# Mario-Kart-lobby style -- who's picked what, at a glance, before the
# server's own tally decides the outcome (see network_manager.gd's
# _pick_voted_level -- this view only ever shows/sends votes, it never
# decides the winner itself).

const UIStyle := preload("res://ui/ui_style.gd")
const OnlineMapCatalog := preload("res://levels/online_maps/catalog.gd")
const OnlineMapIconScene := preload("res://ui/online_map_icon.gd")
# A vote screen with dozens of tiles stops being usable -- caps how many of
# the (potentially many, across every player who's ever published one)
# live custom levels get offered per match, newest first so recent/active
# publishes stay in rotation rather than the oldest ones camping the slots
# forever. Nothing is ever deleted/uncached by this -- just not offered.
const MAX_CUSTOM_LEVELS_IN_VOTE := 10

# 7 tiles at the old 150px + 20px separation totaled 1170px -- wider than
# the game's own locked 1152px viewport (see project.godot's window/stretch
# settings), so the row overflowed off the edge of the screen with no way
# to reach the last tile or two. Shrunk to comfortably fit all 7 with
# margin to spare regardless of how many real online maps ever end up in
# OnlineMapCatalog.MAP_ORDER.
const TILE_SIZE := Vector2(136, 136)
const TILE_SEPARATION := 10
const PREVIEW_MARGIN := 8.0
const BALLOT_SIZE := Vector2(32, 32)

var _level_ids: Array[String] = OnlineMapCatalog.MAP_ORDER.duplicate()
var _level_names: Array[String] = []
var _vote_buttons: Array[Button] = []
var _tally_labels: Array[Label] = []
var _button_group := ButtonGroup.new()
var _tile_row: HBoxContainer
var _ballot_row: HBoxContainer
var _ballot_slots := {} # peer_id -> {box: PanelContainer, preview: OnlineMapIcon or null}
var _last_votes := {} # peer_id -> level_id, so set_votes() only rebuilds a ballot slot whose pick actually changed

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_PASS
	add_theme_constant_override("separation", 16)
	alignment = BoxContainer.ALIGNMENT_CENTER

	_tile_row = HBoxContainer.new()
	_tile_row.mouse_filter = Control.MOUSE_FILTER_PASS
	_tile_row.alignment = BoxContainer.ALIGNMENT_CENTER
	_tile_row.add_theme_constant_override("separation", TILE_SEPARATION)
	_tile_row.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	add_child(_tile_row)

	_ballot_row = HBoxContainer.new()
	_ballot_row.mouse_filter = Control.MOUSE_FILTER_PASS
	_ballot_row.alignment = BoxContainer.ALIGNMENT_CENTER
	_ballot_row.add_theme_constant_override("separation", 10)
	_ballot_row.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	add_child(_ballot_row)

	for id in _level_ids:
		_level_names.append(String(OnlineMapCatalog.MAPS[id].name))
	for i in _level_ids.size():
		_add_map_tile(i)
	_add_custom_level_tiles()

## Custom levels are downloaded once at game startup (see CustomLevelCache),
## not fetched fresh every time this screen opens -- by the time a player
## actually reaches a lobby/vote screen that startup fetch has virtually
## always already finished, but the not-yet-ready case (a very fast queue
## right after launch) is still handled correctly rather than assumed away.
func _add_custom_level_tiles() -> void:
	if CustomLevelCache.is_ready:
		_populate_custom_level_tiles()
	else:
		CustomLevelCache.levels_ready.connect(_populate_custom_level_tiles, CONNECT_ONE_SHOT)

func _populate_custom_level_tiles() -> void:
	for entry in CustomLevelCache.level_entries_newest_first().slice(0, MAX_CUSTOM_LEVELS_IN_VOTE):
		_level_ids.append(String(entry.id))
		_level_names.append(String(entry.name))
		_add_map_tile(_level_ids.size() - 1)

## A big square preview (the map's real platform layout, see
## online_map_icon.gd), with the map's title and current vote tally stacked
## beneath it -- previously just a bare text button, which gave no sense of
## what a player was actually voting for.
func _add_map_tile(index: int) -> void:
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 6)
	col.alignment = BoxContainer.ALIGNMENT_CENTER
	_tile_row.add_child(col)

	var btn := Button.new()
	btn.toggle_mode = true
	btn.button_group = _button_group
	btn.custom_minimum_size = TILE_SIZE
	UIStyle.style_button(btn, UIStyle.COLOR_QUICKPLAY, 10, false)
	btn.pressed.connect(_on_vote_pressed.bind(index))
	col.add_child(btn)

	var preview := OnlineMapIconScene.new()
	preview.map_id = _level_ids[index]
	preview.mouse_filter = Control.MOUSE_FILTER_IGNORE
	preview.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	preview.offset_left = PREVIEW_MARGIN
	preview.offset_top = PREVIEW_MARGIN
	preview.offset_right = -PREVIEW_MARGIN
	preview.offset_bottom = -PREVIEW_MARGIN
	btn.add_child(preview)

	var title := Label.new()
	title.text = _level_names[index]
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 16)
	col.add_child(title)

	var tally := Label.new()
	tally.text = "0 votes"
	tally.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	tally.add_theme_font_size_override("font_size", 12)
	tally.add_theme_color_override("font_color", UIStyle.COLOR_NEUTRAL)
	col.add_child(tally)

	_vote_buttons.append(btn)
	_tally_labels.append(tally)

func _on_vote_pressed(index: int) -> void:
	NetworkManager.submit_map_vote(_level_ids[index])

## Called whenever the lobby's member/bot roster changes (see lobby_room.gd/
## ranked_queue.gd's _on_lobby_state_updated's lobby.members + lobby.bots) --
## rebuilds the ballot row's slots (one per current voter) from scratch,
## since headcount can change (players join, bots get added) right up until
## voting actually starts.
func set_roster(roster: Dictionary) -> void:
	if roster.keys() == _ballot_slots.keys():
		return
	for child in _ballot_row.get_children():
		child.queue_free()
	_ballot_slots.clear()
	_last_votes.clear()
	for peer_id in roster.keys():
		_add_ballot_slot(peer_id, roster[peer_id])

func _add_ballot_slot(peer_id: int, info: Dictionary) -> void:
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 3)
	col.alignment = BoxContainer.ALIGNMENT_CENTER
	_ballot_row.add_child(col)

	var box := PanelContainer.new()
	box.custom_minimum_size = BALLOT_SIZE
	var style := StyleBoxFlat.new()
	style.bg_color = Color(1, 1, 1, 0.05)
	style.border_width_left = 1
	style.border_width_top = 1
	style.border_width_right = 1
	style.border_width_bottom = 1
	style.border_color = Color(1, 1, 1, 0.18)
	style.corner_radius_top_left = 5
	style.corner_radius_top_right = 5
	style.corner_radius_bottom_right = 5
	style.corner_radius_bottom_left = 5
	box.add_theme_stylebox_override("panel", style)
	col.add_child(box)

	var name_label := Label.new()
	name_label.text = String(info.get("username", "?")).left(8)
	name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	name_label.clip_text = true
	name_label.custom_minimum_size = Vector2(BALLOT_SIZE.x + 10.0, 0)
	name_label.add_theme_font_size_override("font_size", 10)
	name_label.add_theme_color_override("font_color", UIStyle.COLOR_NEUTRAL)
	col.add_child(name_label)

	_ballot_slots[peer_id] = box

## `votes` is the lobby dict's raw `map_votes` (peer_id -> level_id) --
## tallied here into each tile's own vote count, keeps the local player's
## toggle in sync (e.g. after reconnecting mid-vote), and fills in each
## voter's ballot slot with a tiny preview of whichever map they picked.
func set_votes(votes: Dictionary) -> void:
	var tally := {}
	for voted_id in votes.values():
		tally[voted_id] = int(tally.get(voted_id, 0)) + 1
	for i in _level_ids.size():
		var count: int = int(tally.get(_level_ids[i], 0))
		_tally_labels[i].text = "1 vote" if count == 1 else "%d votes" % count
	var my_vote = votes.get(NetworkManager.my_peer_id, null)
	if my_vote != null:
		var idx := _level_ids.find(my_vote)
		if idx != -1 and idx < _vote_buttons.size():
			_vote_buttons[idx].button_pressed = true

	for peer_id in _ballot_slots.keys():
		var voted = votes.get(peer_id, null)
		if voted == _last_votes.get(peer_id, null):
			continue
		_last_votes[peer_id] = voted
		var box: PanelContainer = _ballot_slots[peer_id]
		for child in box.get_children():
			child.queue_free()
		if voted == null:
			continue
		var mini_preview := OnlineMapIconScene.new()
		mini_preview.map_id = String(voted)
		mini_preview.mouse_filter = Control.MOUSE_FILTER_IGNORE
		mini_preview.custom_minimum_size = BALLOT_SIZE - Vector2(6, 6)
		box.add_child(mini_preview)
