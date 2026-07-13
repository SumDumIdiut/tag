extends Control

# Shown once a ranked round ends (see NetworkManager.match_ended) -- final
# placements by time spent as "it" (least = best), plus this player's own
# freshly-updated rank fetched straight from the relay (the ELO math itself
# only ever runs server-side, see relay-server/server.js's applyEloUpdates).

const RANKED_API_BASE := "https://codecade.co.za/tag/api/ranked"

@onready var placements_box: VBoxContainer = $VBox/PlacementsBox
@onready var rank_label: Label = $VBox/RankLabel
@onready var continue_button: Button = $VBox/ContinueButton

var _ranking := []
var _my_peer_id := -1

func setup(ranking: Array, my_peer_id: int) -> void:
	_ranking = ranking
	_my_peer_id = my_peer_id

func _ready() -> void:
	continue_button.pressed.connect(_on_continue_pressed)
	for entry in _ranking:
		placements_box.add_child(_build_row(entry))
	rank_label.text = "Fetching your updated rank..."
	_fetch_my_rank()

func _build_row(entry: Dictionary) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)

	var place_label := Label.new()
	place_label.text = "#%d" % int(entry.place)
	place_label.custom_minimum_size = Vector2(40, 0)
	place_label.add_theme_font_size_override("font_size", 18)
	row.add_child(place_label)

	var is_me: bool = entry.peer_id == _my_peer_id
	var name_label := Label.new()
	name_label.text = "%s%s" % [entry.username, "  (you)" if is_me else ""]
	name_label.size_flags_horizontal = SIZE_EXPAND_FILL
	name_label.add_theme_font_size_override("font_size", 18)
	if is_me:
		name_label.add_theme_color_override("font_color", Color(0.5, 0.85, 1.0))
	row.add_child(name_label)

	var time_label := Label.new()
	time_label.text = "%.1fs as it" % float(entry.it_time)
	time_label.add_theme_font_size_override("font_size", 14)
	time_label.add_theme_color_override("font_color", Color(0.7, 0.72, 0.78))
	row.add_child(time_label)

	return row

func _fetch_my_rank() -> void:
	if SkinCatalog.client_id.is_empty():
		rank_label.text = ""
		return
	var req := HTTPRequest.new()
	add_child(req)
	req.request_completed.connect(func(_result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray):
		req.queue_free()
		if response_code != 200:
			rank_label.text = ""
			return
		var parsed = JSON.parse_string(body.get_string_from_utf8())
		if typeof(parsed) != TYPE_DICTIONARY:
			rank_label.text = ""
			return
		var elo: int = int(parsed.get("elo", 1000))
		var tier: String = str(parsed.get("tier", "Bronze"))
		rank_label.text = "%s -- %d ELO" % [tier, elo]
	)
	req.request("%s/%s" % [RANKED_API_BASE, SkinCatalog.client_id])

func _on_continue_pressed() -> void:
	NetworkManager.disconnect_from_server()
	get_tree().change_scene_to_file("res://main/main_menu.tscn")
