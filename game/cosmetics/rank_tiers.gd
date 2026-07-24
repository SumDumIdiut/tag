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
	{"name": "Master", "min_elo": 2200, "color": Color(0.75, 0.35, 0.95)},
	{"name": "Grandmaster", "min_elo": 2800, "color": Color(0.95, 0.25, 0.25)},
	{"name": "Champion", "min_elo": 3600, "color": Color(1.0, 0.55, 0.15)},
	{"name": "Legend", "min_elo": 4800, "color": Color(0.3, 0.95, 0.85)},
	{"name": "Mythic", "min_elo": 6500, "color": Color(0.95, 0.2, 0.65)},
	{"name": "Immortal", "min_elo": 9000, "color": Color(1.0, 0.92, 0.55)},
	{"name": "GOAT", "min_elo": 10000, "color": Color(1.0, 0.65, 0.0)},
]

static func tier_for_elo(elo: int) -> Dictionary:
	var tier: Dictionary = TIERS[0]
	for t in TIERS:
		if elo >= t.min_elo:
			tier = t
	return tier
