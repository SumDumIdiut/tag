extends Control
class_name MapVoteView

# Shared map-vote UI used by both lobby_room.gd (casual) and ranked_queue.gd
# (ranked) while waiting for a match to start -- one vote button per map in
# OnlineMapCatalog (small, fully built-in, no network fetch -- see that
# catalog's own header for why this replaced a live-published custom level
# fetch), with a live tally, reporting the local player's choice via
# NetworkManager.submit_map_vote(). The server tallies every member's vote
# and does a weighted-random pick right before the match actually starts
# (see network_manager.gd's _pick_voted_level) -- this view only ever
# shows/sends votes, it never decides the outcome itself.

const UIStyle := preload("res://ui/ui_style.gd")
const OnlineMapCatalog := preload("res://levels/online_maps/catalog.gd")

var _level_ids: Array[String] = OnlineMapCatalog.MAP_ORDER.duplicate()
var _level_names: Array[String] = []
var _vote_buttons: Array[Button] = []
var _button_group := ButtonGroup.new()
var _row: HFlowContainer

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_row = HFlowContainer.new()
	_row.mouse_filter = Control.MOUSE_FILTER_PASS
	_row.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_row.add_theme_constant_override("h_separation", 8)
	_row.add_theme_constant_override("v_separation", 8)
	add_child(_row)
	for id in _level_ids:
		_level_names.append(String(OnlineMapCatalog.MAPS[id].name))
	for i in _level_ids.size():
		_add_vote_button(i)

func _add_vote_button(index: int) -> void:
	var btn := Button.new()
	btn.toggle_mode = true
	btn.button_group = _button_group
	btn.custom_minimum_size = Vector2(130, 40)
	UIStyle.style_button(btn, UIStyle.COLOR_QUICKPLAY, 8, false)
	btn.pressed.connect(_on_vote_pressed.bind(index))
	_row.add_child(btn)
	_vote_buttons.append(btn)
	_update_button_text(index, 0)

func _on_vote_pressed(index: int) -> void:
	NetworkManager.submit_map_vote(_level_ids[index])

## Called by the owning screen every time lobby state updates (see
## lobby_room.gd/ranked_queue.gd's _on_lobby_state_updated) -- `votes` is
## the lobby dict's raw `map_votes` (peer_id -> level_id), tallied here into
## a per-button count and used to keep the local player's own toggle in
## sync (e.g. after reconnecting mid-vote).
func set_votes(votes: Dictionary) -> void:
	var tally := {}
	for voted_id in votes.values():
		tally[voted_id] = int(tally.get(voted_id, 0)) + 1
	for i in _level_ids.size():
		_update_button_text(i, int(tally.get(_level_ids[i], 0)))
	var my_vote = votes.get(NetworkManager.my_peer_id, null)
	if my_vote != null:
		var idx := _level_ids.find(my_vote)
		if idx != -1 and idx < _vote_buttons.size():
			_vote_buttons[idx].button_pressed = true

func _update_button_text(index: int, count: int) -> void:
	if index >= _vote_buttons.size():
		return
	var map_name: String = _level_names[index]
	_vote_buttons[index].text = "%s (%d)" % [map_name, count] if count > 0 else map_name
