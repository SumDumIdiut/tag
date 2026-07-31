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
		"theme_color": Color(0.55, 0.58, 0.62),
		"theme_shape": "rect",
		"platforms": [
			{"x0": -420, "y0": -198, "x1": 420, "y1": -156},
			{"x0": -135, "y0": -80, "x1": 135, "y1": -38},
			{"x0": -135, "y0": 38, "x1": 135, "y1": 80},
			{"x0": -162, "y0": 156, "x1": 162, "y1": 198},
		],
	},
	"floating_platforms": {
		"name": "Floating Platforms",
		"scene": "res://levels/online_maps/floating_platforms.tscn",
		"theme_color": Color(0.45, 0.68, 0.85),
		"theme_shape": "circle",
		"platforms": [
			{"x0": -420, "y0": -198, "x1": 420, "y1": -156},
			{"x0": -122, "y0": -80, "x1": 122, "y1": -38},
			{"x0": -122, "y0": 38, "x1": 122, "y1": 80},
			{"x0": -135, "y0": 156, "x1": 135, "y1": 198},
		],
	},
	"split_level": {
		"name": "Split Level",
		"scene": "res://levels/local_maps/split_level.tscn",
		"theme_color": LocalMapCatalog.MAPS["split_level"]["theme_color"],
		"theme_shape": LocalMapCatalog.MAPS["split_level"]["theme_shape"],
		"platforms": LocalMapCatalog.MAPS["split_level"]["platforms"],
	},
	"twin_peaks": {
		"name": "Twin Peaks",
		"scene": "res://levels/local_maps/twin_peaks.tscn",
		"theme_color": LocalMapCatalog.MAPS["twin_peaks"]["theme_color"],
		"theme_shape": LocalMapCatalog.MAPS["twin_peaks"]["theme_shape"],
		"platforms": LocalMapCatalog.MAPS["twin_peaks"]["platforms"],
	},
	"the_ladder": {
		"name": "The Ladder",
		"scene": "res://levels/local_maps/the_ladder.tscn",
		"theme_color": LocalMapCatalog.MAPS["the_ladder"]["theme_color"],
		"theme_shape": LocalMapCatalog.MAPS["the_ladder"]["theme_shape"],
		"platforms": LocalMapCatalog.MAPS["the_ladder"]["platforms"],
	},
	"sky_islands": {
		"name": "Sky Islands",
		"scene": "res://levels/local_maps/sky_islands.tscn",
		"theme_color": LocalMapCatalog.MAPS["sky_islands"]["theme_color"],
		"theme_shape": LocalMapCatalog.MAPS["sky_islands"]["theme_shape"],
		"platforms": LocalMapCatalog.MAPS["sky_islands"]["platforms"],
	},
	"corner_pockets": {
		"name": "Corner Pockets",
		"scene": "res://levels/local_maps/corner_pockets.tscn",
		"theme_color": LocalMapCatalog.MAPS["corner_pockets"]["theme_color"],
		"theme_shape": LocalMapCatalog.MAPS["corner_pockets"]["theme_shape"],
		"platforms": LocalMapCatalog.MAPS["corner_pockets"]["platforms"],
	},
}

## Maps not carried over from LocalMapCatalog (square_arena, floating_platforms)
## get their own dedicated tile-atlas slots, appended after every local map's
## own slot -- see tools/build_tileset.gd. Anything reused from local instead
## shares that map's existing slot (index into LocalMapCatalog.MAP_ORDER), so
## the SAME map looks the same whether played online or offline.
const ONLINE_ONLY_MAP_ORDER := ["square_arena", "floating_platforms"]

## Explicitly typed (not just := inferring from the literal) -- an untyped
## Array here silently failed to assign into map_vote_view.gd's
## Array[String]-typed _level_ids (Godot's static typing doesn't coerce a
## plain Array into a typed one just because its contents happen to match,
## even for an all-string literal), leaving it permanently empty with no
## error surfaced anywhere -- confirmed live as the actual cause of the
## vote popup never showing any map choices at all.
const MAP_ORDER: Array[String] = [
	"square_arena", "floating_platforms",
	"split_level", "twin_peaks", "the_ladder", "sky_islands", "corner_pockets",
]

## Tile-atlas column for a map id, valid for BOTH local and online ids (see
## ONLINE_ONLY_MAP_ORDER's own comment). Every map shares one plain flat
## tile now (see build_tileset.gd -- reverted from a per-map theme_color'd
## one), so every known id resolves to that same single atlas slot; -1 for
## an unknown id (caller's problem -- every id actually in either catalog
## resolves). Kept as a function (not a bare constant) so every call site
## from before this revert -- and any future one -- still asks "what tile
## does this map use" rather than assuming 0 directly.
static func tile_index_for(map_id: String) -> int:
	if LocalMapCatalog.MAP_ORDER.find(map_id) != -1:
		return 0
	if ONLINE_ONLY_MAP_ORDER.find(map_id) != -1:
		return 0
	return -1

## Resolves a map id (including "" -- the "no vote yet"/legacy default) to
## its scene path, falling back to the default map for anything unknown.
static func scene_path_for(map_id: String) -> String:
	var id := map_id if not map_id.is_empty() else DEFAULT_ID
	var def: Dictionary = MAPS.get(id, {})
	var path: String = def.get("scene", "")
	if not path.is_empty() and ResourceLoader.exists(path):
		return path
	return MAPS[DEFAULT_ID]["scene"]
