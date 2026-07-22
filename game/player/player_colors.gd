extends RefCounted
class_name PlayerColors

# Flat colors assigned automatically per player -- no shop, no selection UI,
# no custom/fetched cosmetics. Same 8 hues the old built-in skin list used.

const COLORS := {
	"red": Color(0.85, 0.2, 0.2),
	"blue": Color(0.25, 0.45, 0.85),
	"green": Color(0.25, 0.75, 0.35),
	"yellow": Color(0.9, 0.8, 0.15),
	"purple": Color(0.6, 0.3, 0.8),
	"teal": Color(0.15, 0.75, 0.7),
	"orange": Color(0.9, 0.5, 0.15),
	"pink": Color(0.9, 0.45, 0.7),
}
const IDS := ["red", "blue", "green", "yellow", "purple", "teal", "orange", "pink"]
const DEFAULT_ID := "red"

static func color_for(id: String) -> Color:
	return COLORS.get(id, COLORS[DEFAULT_ID])

## Deterministic, no server-side state needed to track who has which color --
## the same peer_id always resolves to the same color for the life of a
## connection, and two players just happening to collide on the same one
## (peer_id count exceeds IDS.size()) is a harmless cosmetic coincidence,
## not a bug worth avoiding with extra bookkeeping.
static func id_for_peer(peer_id: int) -> String:
	return IDS[((peer_id % IDS.size()) + IDS.size()) % IDS.size()]
