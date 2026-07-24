extends Control
class_name MapVotePopup

# Shared "match is starting" pop-up used by both lobby_room.gd (casual) and
# ranked_queue.gd (ranked) -- map selection is a timed moment right before
# the match begins, not a passive panel players could ignore indefinitely
# (see network_manager.gd's _begin_match_sequence/_on_map_vote_timeout).
# Hidden by default; the owning screen calls start_voting() when
# NetworkManager.map_vote_phase_started fires and show_result() when
# map_vote_phase_ended fires. match_started (already handled by the owning
# screen exactly as before) fires shortly after the countdown ends and
# transitions the scene away, so this never needs to hide itself.

const UIStyle := preload("res://ui/ui_style.gd")
const MapVoteViewScene := preload("res://ui/map_vote_view.gd")

var _vote_view: MapVoteView
var _countdown_label: Label
var _time_left := 0.0
var _phase := "" # "voting" or "countdown"

func _ready() -> void:
	visible = false
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP

	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.72)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(dim)

	# A CenterContainer, not a hand-computed position offset sized for one
	# specific content height -- the square map tiles (see map_vote_view.gd)
	# made this panel taller/wider than the old text-only version, and a
	# fixed pixel offset calibrated for the old size would center the wrong
	# box once content grew past it (the exact class of bug the VS badge's
	# label had -- see team_lobby_view.gd). A CenterContainer re-centers
	# correctly at whatever size its child actually ends up.
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_PASS
	add_child(center)

	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", UIStyle.panel_box(UIStyle.COLOR_QUICKPLAY, 0.9, 1.0))
	panel.custom_minimum_size = Vector2(520, 200)
	center.add_child(panel)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 12)
	panel.add_child(box)

	var title := Label.new()
	title.text = "MATCH FOUND"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 24)
	box.add_child(title)

	_countdown_label = Label.new()
	_countdown_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_countdown_label.add_theme_font_size_override("font_size", 16)
	# White (not COLOR_NEUTRAL's grayish tone) -- this popup's panel_box is
	# rendered near-opaque at whatever bright accent color the screen picks
	# (COLOR_QUICKPLAY here), and a muted gray reads poorly against that;
	# white stays legible against every accent color this app uses.
	_countdown_label.add_theme_color_override("font_color", Color(1, 1, 1, 0.85))
	box.add_child(_countdown_label)

	_vote_view = MapVoteViewScene.new()
	box.add_child(_vote_view)

func start_voting(duration: float) -> void:
	_phase = "voting"
	_time_left = duration
	for btn in _vote_view._vote_buttons:
		btn.disabled = false
	visible = true

func show_result(_chosen_level_id: String, countdown: float) -> void:
	_phase = "countdown"
	_time_left = countdown
	for btn in _vote_view._vote_buttons:
		btn.disabled = true
	visible = true

func set_votes(votes: Dictionary) -> void:
	_vote_view.set_votes(votes)

func set_roster(roster: Dictionary) -> void:
	_vote_view.set_roster(roster)

func _process(delta: float) -> void:
	if not visible or _phase.is_empty():
		return
	_time_left = maxf(_time_left - delta, 0.0)
	if _phase == "voting":
		_countdown_label.text = "Vote for a map -- %ds left" % ceili(_time_left)
	else:
		_countdown_label.text = "Starting in %d..." % ceili(_time_left)
