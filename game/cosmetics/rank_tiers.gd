extends Node

# Client-side mirror of relay-server/server.js's RANK_TIERS/tierForElo --
# kept in sync by hand (same tradeoff already accepted for the rig's
# PART_DEFS being duplicated server-side for upload validation). Lets rank
# badges render locally from an already-fetched elo number without a round
# trip just to look up a tier name.

const TIERS := [
	{"name": "Bronze", "min_elo": 0, "color": Color(0.72, 0.45, 0.2)},
	{"name": "Silver", "min_elo": 1100, "color": Color(0.75, 0.75, 0.78)},
	{"name": "Gold", "min_elo": 1300, "color": Color(0.95, 0.8, 0.25)},
	{"name": "Platinum", "min_elo": 1550, "color": Color(0.4, 0.85, 0.75)},
	{"name": "Diamond", "min_elo": 1850, "color": Color(0.55, 0.75, 0.98)},
]

static func tier_for_elo(elo: int) -> Dictionary:
	var tier: Dictionary = TIERS[0]
	for t in TIERS:
		if elo >= t.min_elo:
			tier = t
	return tier
