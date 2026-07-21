extends Control
class_name MapVoteView

# Shared map-vote UI used by both lobby_room.gd (casual) and ranked_queue.gd
# (ranked) while waiting for a match to start -- fetches the same level
# catalog host_setup.gd's old per-host map dropdown used to (built-in
# "Classic Arena" plus any live-published custom levels), renders one vote
# button per map with a live tally, and reports the local player's choice
# via NetworkManager.submit_map_vote(). The server tallies every member's
# vote and does a weighted-random pick right before the match actually
# starts (see network_manager.gd's _pick_voted_level) -- this view only
# ever shows/sends votes, it never decides the outcome itself.

const UIStyle := preload("res://ui/ui_style.gd")
const LEVELS_CATALOG_URL := "https://codecade.co.za/tag/api/levels/catalog"

var _level_ids: Array[String] = [""] # index-matched to _level_names, "" = built-in default
var _level_names: Array[String] = ["Classic Arena"]
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
	_add_vote_button(0)
	_fetch_map_catalog()

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

## Custom levels are live-published (see the Art Tool's Level page) with no
## review step -- if the fetch fails, this just quietly stays at "Classic
## Arena" only, same fallback-to-default philosophy server_match.gd and
## net_game.gd already use if a chosen level can't be loaded.
func _fetch_map_catalog() -> void:
	var req := HTTPRequest.new()
	add_child(req)
	req.request_completed.connect(func(_result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray):
		req.queue_free()
		if response_code != 200:
			return
		var parsed = JSON.parse_string(body.get_string_from_utf8())
		if typeof(parsed) != TYPE_ARRAY:
			return
		for entry in parsed:
			if typeof(entry) != TYPE_DICTIONARY or not entry.has("id") or not entry.has("name"):
				continue
			_level_ids.append(String(entry.id))
			_level_names.append(String(entry.name))
			_add_vote_button(_level_ids.size() - 1)
	)
	req.request(LEVELS_CATALOG_URL)

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
