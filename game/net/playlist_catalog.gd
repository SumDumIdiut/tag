extends RefCounted
class_name PlaylistCatalog

## Shared source of truth for every matchmaking playlist (ranked and casual
## both read this). A playlist is just {team_size, team_count} -- free-for-
## all is team_size=1 (every player is their own team of one, so tag_mode.gd's
## team-immunity check never blocks anything), real team play is
## team_size>1 (players sharing a team index can never tag each other).
##
## relay-server/server.js does NOT mirror this catalog -- it only ever sees
## a playlist id string as a storage-bucket key for per-playlist ELO, never
## team_size/team_count, since the Godot dedicated server is already the
## trusted authority for match composition (same trust model report-result
## already documents).

const PLAYLISTS := {
	"1v1": {"name": "1v1", "team_size": 1, "team_count": 2},
	"2v2": {"name": "2v2", "team_size": 2, "team_count": 2},
	"1v1v1": {"name": "1v1v1", "team_size": 1, "team_count": 3},
	"1v1v1v1": {"name": "1v1v1v1", "team_size": 1, "team_count": 4},
}
const PLAYLIST_ORDER := ["1v1", "2v2", "1v1v1", "1v1v1v1"]

static func team_size(playlist_id: String) -> int:
	return int(PLAYLISTS.get(playlist_id, {}).get("team_size", 1))

static func team_count(playlist_id: String) -> int:
	return int(PLAYLISTS.get(playlist_id, {}).get("team_count", 1))

static func total_players(playlist_id: String) -> int:
	return team_size(playlist_id) * team_count(playlist_id)

static func is_team_mode(playlist_id: String) -> bool:
	return team_size(playlist_id) > 1

static func display_name(playlist_id: String) -> String:
	return String(PLAYLISTS.get(playlist_id, {}).get("name", playlist_id))

## Round-robin by join order -- a pure, deterministic function of already-
## synced data (the lobby's `members` dict, which every client already
## receives in full via _send_lobby_state and which GDScript keeps in
## insertion order). Both the server (at match start, authoritative) and a
## client (for a live "who's on which side" waiting-room preview) call this
## exact same function on the same peer_id list, so the preview can never
## drift from what the server actually assigns -- no extra network state
## needed just to keep a preview in sync.
static func assign_teams(ordered_peer_ids: Array, p_team_count: int) -> Dictionary:
	var teams := {}
	for i in ordered_peer_ids.size():
		teams[ordered_peer_ids[i]] = i % maxi(p_team_count, 1)
	return teams
