extends RefCounted
class_name AchievementTracker

# Tracks which achievement ids this client has already seen unlocked, purely
# locally (user://) -- the server (GET /api/progression/:clientId) only ever
# reports the current full unlocked set, never a "here's what's new," so
# there's nothing server-side to diff against. Comparing a fresh fetch
# against this local record is what lets match_results.gd tell "you already
# had this" apart from "you just earned this" to decide what's worth a
# notification for.

const SAVE_PATH := "user://seen_achievements.txt"

static func load_seen() -> Dictionary:
	var seen := {}
	if not FileAccess.file_exists(SAVE_PATH):
		return seen
	var f := FileAccess.open(SAVE_PATH, FileAccess.READ)
	if not f:
		return seen
	while not f.eof_reached():
		var line := f.get_line().strip_edges()
		if not line.is_empty():
			seen[line] = true
	return seen

static func save_seen(ids: Array) -> void:
	var f := FileAccess.open(SAVE_PATH, FileAccess.WRITE)
	if not f:
		return
	for id in ids:
		f.store_line(String(id))

## Returns whichever of `current_ids` weren't in the locally-saved seen set,
## then updates that saved set to include all of `current_ids` -- call once
## per fetch, not speculatively, or a caller that checks without persisting
## would see the same "new" ids again on the next fetch.
static func diff_and_mark_seen(current_ids: Array) -> Array:
	var seen := load_seen()
	var new_ids := []
	for id in current_ids:
		if not seen.has(id):
			new_ids.append(id)
	save_seen(current_ids)
	return new_ids
