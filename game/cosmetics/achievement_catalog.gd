extends RefCounted
class_name AchievementCatalog

# Client-side mirror of relay-server/server.js's ACHIEVEMENTS -- same
# hand-synced tradeoff rank_tiers.gd already accepts for RANK_TIERS. The
# server only ever reports which ids a player has *unlocked* (see
# GET /api/progression/:clientId); this catalog is what lets the
# achievements menu also show the ones they haven't gotten yet, grayed out,
# rather than only ever showing an ever-growing unlocked list with no sense
# of what's left. `category` picks the badge art/color (see
# achievement_badge.gd) -- "tier" ones reuse their real rank tier's own
# color (RankTiers.TIERS), tying the badge directly to the rank ladder
# instead of an arbitrary one.
const ACHIEVEMENTS := [
	{"id": "first_win", "name": "First Blood", "desc": "Win your first match", "category": "win"},
	{"id": "ten_wins", "name": "Perfect Ten", "desc": "Win 10 matches", "category": "win"},
	{"id": "fifty_wins", "name": "Half a Century", "desc": "Win 50 matches", "category": "win"},
	{"id": "untouchable", "name": "Untouchable", "desc": "Win a match without ever being it", "category": "win"},
	{"id": "veteran", "name": "Veteran", "desc": "Play 50 matches", "category": "endurance"},
	{"id": "century", "name": "Century Club", "desc": "Play 100 matches", "category": "endurance"},
	{"id": "marathon", "name": "Marathon Runner", "desc": "Play 200 matches", "category": "endurance"},
	{"id": "silver", "name": "Silver League", "desc": "Reach Silver rank", "category": "tier", "tier": "Silver"},
	{"id": "gold", "name": "Gold League", "desc": "Reach Gold rank", "category": "tier", "tier": "Gold"},
	{"id": "platinum", "name": "Platinum League", "desc": "Reach Platinum rank", "category": "tier", "tier": "Platinum"},
	{"id": "diamond", "name": "Diamond League", "desc": "Reach Diamond rank", "category": "tier", "tier": "Diamond"},
	{"id": "master", "name": "Master League", "desc": "Reach Master rank", "category": "tier", "tier": "Master"},
	{"id": "grandmaster", "name": "Grandmaster League", "desc": "Reach Grandmaster rank", "category": "tier", "tier": "Grandmaster"},
	{"id": "champion", "name": "Champion League", "desc": "Reach Champion rank", "category": "tier", "tier": "Champion"},
	{"id": "legend", "name": "Legend League", "desc": "Reach Legend rank", "category": "tier", "tier": "Legend"},
	{"id": "mythic", "name": "Mythic League", "desc": "Reach Mythic rank", "category": "tier", "tier": "Mythic"},
	{"id": "immortal", "name": "Immortal League", "desc": "Reach Immortal rank", "category": "tier", "tier": "Immortal"},
	{"id": "creator", "name": "Creator League", "desc": "???", "category": "tier", "tier": "Creator"},
	{"id": "last_place", "name": "Tag, You're It", "desc": "Place last in a match", "category": "misc"},
]

static func find(id: String) -> Dictionary:
	for a in ACHIEVEMENTS:
		if a.id == id:
			return a
	return {}
