extends RefCounted
class_name OnlineMapCatalog

## Single source of truth for the built-in maps real online matches (ranked/
## casual/private) pick between -- both the generator
## (tools/generate_online_maps.gd) and ui/map_vote_view.gd's vote buttons
## read the same `platforms` data here, same "one source, never drifts"
## reasoning as levels/local_maps/catalog.gd.
##
## Replaces the old setup where every real match used a single hand-built
## tag_arena.tscn plus whatever a live-published custom level catalog fetch
## happened to return -- that fetch was unreliable (confirmed: only "Classic
## Arena" ever actually showed up in the vote popup), so online play now
## picks from a small, fully built-in set instead, no network dependency.
##
## Every Local map (see LocalMapCatalog) is also playable online -- both
## conventions build the exact same node shape (Arena/SpawnPoints/Waypoints/
## Tiles, 8 spawn points, more than any real playlist needs), so this just
## points straight at the same .tscn files and reuses the same `platforms`
## rects rather than duplicating either. Their vote-popup preview thumbnails
## (see ui/map_vote_view.gd) are the exact same baked PNGs Local's own
## picker uses too (see tools/build_procedural_sprites.gd) -- copied
## byte-for-byte into online_map_icons/, not regenerated in a different
## accent color.
const LocalMapCatalog := preload("res://levels/local_maps/catalog.gd")

const DEFAULT_ID := "square_arena"

# id -> {name, scene, platforms}. Platforms are {x0,y0,x1,y1} world-pixel
# rects, same format tools/generate_online_maps.gd (itself a copy of
# tools/generate_local_maps.gd's proven approach) consumes directly to
# build the actual .tscn -- boundary walls, waypoints, and spawn points are
# all derived automatically from this list, nothing hand-placed.
const MAPS := {
	"square_arena": {
		"name": "Square Arena",
		"scene": "res://levels/online_maps/square_arena.tscn",
		"platforms": [
			{"x0": -450, "y0": 420, "x1": 450, "y1": 480},
			{"x0": -300, "y0": 220, "x1": -100, "y1": 240},
			{"x0": 100, "y0": 220, "x1": 300, "y1": 240},
			{"x0": -120, "y0": 40, "x1": 120, "y1": 60},
		],
	},
	"floating_platforms": {
		"name": "Floating Platforms",
		"scene": "res://levels/online_maps/floating_platforms.tscn",
		"platforms": [
			{"x0": -500, "y0": 420, "x1": 500, "y1": 480},
			{"x0": -400, "y0": 260, "x1": -220, "y1": 280},
			{"x0": 220, "y0": 260, "x1": 400, "y1": 280},
			{"x0": -100, "y0": 100, "x1": 100, "y1": 120},
		],
	},
	"classic_arena": {
		"name": "Classic Arena",
		"scene": "res://levels/tag_arena.tscn",
	},
	"wide_open": {
		"name": "Wide Open",
		"scene": "res://levels/local_maps/wide_open.tscn",
		"platforms": LocalMapCatalog.MAPS["wide_open"]["platforms"],
	},
	"twin_towers": {
		"name": "Twin Towers",
		"scene": "res://levels/local_maps/twin_towers.tscn",
		"platforms": LocalMapCatalog.MAPS["twin_towers"]["platforms"],
	},
	"staircase": {
		"name": "Staircase",
		"scene": "res://levels/local_maps/staircase.tscn",
		"platforms": LocalMapCatalog.MAPS["staircase"]["platforms"],
	},
	"scattered_islands": {
		"name": "Scattered Islands",
		"scene": "res://levels/local_maps/scattered_islands.tscn",
		"platforms": LocalMapCatalog.MAPS["scattered_islands"]["platforms"],
	},
	"pillars_and_ledges": {
		"name": "Pillars & Ledges",
		"scene": "res://levels/local_maps/pillars_and_ledges.tscn",
		"platforms": LocalMapCatalog.MAPS["pillars_and_ledges"]["platforms"],
	},
}

## Explicitly typed (not just := inferring from the literal) -- an untyped
## Array here silently failed to assign into map_vote_view.gd's
## Array[String]-typed _level_ids (Godot's static typing doesn't coerce a
## plain Array into a typed one just because its contents happen to match,
## even for an all-string literal), leaving it permanently empty with no
## error surfaced anywhere -- confirmed live as the actual cause of the
## vote popup never showing any map choices at all.
const MAP_ORDER: Array[String] = [
	"square_arena", "floating_platforms",
	"classic_arena", "wide_open", "twin_towers", "staircase", "scattered_islands", "pillars_and_ledges",
]

## Resolves a map id (including "" -- the "no vote yet"/legacy default) to
## its scene path, falling back to the default map for anything unknown.
static func scene_path_for(map_id: String) -> String:
	var id := map_id if not map_id.is_empty() else DEFAULT_ID
	var def: Dictionary = MAPS.get(id, {})
	var path: String = def.get("scene", "")
	if not path.is_empty() and ResourceLoader.exists(path):
		return path
	return MAPS[DEFAULT_ID]["scene"]
