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

## Whether a party of `size` people could actually queue this playlist
## *together* -- a free-for-all playlist (team_size 1) has no team to share
## at all, so any real party (2+) would just end up fighting each other, not
## playing together; a team playlist only fits a party up to its own
## team_size. Used by both Ranked's and Casual's playlist pickers (and the
## top-level Casual/Ranked bars, which use the size-2 case as their own
## coarser "any party this big has nowhere at all to go" check) to grey out
## whichever cards a given party doesn't fit.
static func fits_party(playlist_id: String, size: int) -> bool:
	if size <= 1:
		return true
	return size <= team_size(playlist_id) and is_team_mode(playlist_id)

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

## Same contract and same caller shape as assign_teams() above (server at
## match start, client for the live waiting-room preview -- see
## team_lobby_view.gd's set_roster()), but keeps party members on one team
## instead of splitting them by raw round robin. Peers sharing a non-empty
## `peer_party_id` entry are one indivisible group (fits_party() already
## guarantees a party never exceeds a team's own size before it's ever
## allowed to queue here at all); everyone else is their own group of one.
## Bin-packs groups largest-first onto whichever team has the fewest
## players placed so far *and* still has room for the whole group (against
## the playlist's own fixed `p_team_size`, not however many happen to have
## joined so far -- stable during the live waiting-room preview, where that
## headcount is still climbing). With every group size 1 (no party in this
## lobby) this produces the exact same interleaved assignment assign_teams()
## itself would, so it's a strict superset, not a behavior change, for the
## no-party case.
static func assign_teams_grouped(ordered_peer_ids: Array, peer_party_id: Dictionary, p_team_count: int, p_team_size: int) -> Dictionary:
	var groups: Array = []
	var group_index_for_party := {}
	for peer_id in ordered_peer_ids:
		var party_id: String = peer_party_id.get(peer_id, "")
		if party_id.is_empty() or not group_index_for_party.has(party_id):
			if not party_id.is_empty():
				group_index_for_party[party_id] = groups.size()
			groups.append([peer_id])
		else:
			groups[group_index_for_party[party_id]].append(peer_id)
	groups.sort_custom(func(a, b): return a.size() > b.size())

	var team_count_clamped := maxi(p_team_count, 1)
	var fill := []
	fill.resize(team_count_clamped)
	fill.fill(0)
	var teams := {}
	for group in groups:
		var best_team := 0
		var best_fill := -1
		for t in team_count_clamped:
			if p_team_size > 0 and fill[t] + group.size() > p_team_size:
				continue
			if best_fill == -1 or fill[t] < best_fill:
				best_fill = fill[t]
				best_team = t
		for peer_id in group:
			teams[peer_id] = best_team
		fill[best_team] += group.size()
	return teams
