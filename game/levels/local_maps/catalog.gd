extends RefCounted
class_name LocalMapCatalog

## Single source of truth for every built-in Local (bot) map. Both the
## procedural generator (tools/generate_local_maps.gd) and local_menu.gd's
## inline map-picker row read the same `platforms` data here -- the
## generator to build the actual .tscn geometry, the picker to draw a
## matching preview icon (see ui/local_map_icon.gd) -- so a map's picker
## thumbnail can never drift out of sync with what it actually looks like
## in-game.

const CLASSIC_ID := "pyramid_steps"

# id -> {name, scene, platforms}. Platforms are {x0,y0,x1,y1} world-pixel
# rects, same format generate_local_maps.gd consumes directly. Every entry
# here is generator-built -- the old hand-built classic_arena/tag_arena.tscn
# has been removed entirely, online and local alike.
#
# Re-laid-out (from the original, much wider/shorter set) so each map's own
# bounding box aspect ratio is close to the fixed camera's viewport
# (1152/648 ~= 1.78, see levels/fixed_view.gd) instead of the old ~4-13:1 --
# those were built for a horizontally-panning follow camera, which the game
# no longer has, so a map that wide read as a tiny sliver of action in a
# mostly-empty fixed frame. Same reachability convention as before
# (~150-350px horizontal gaps, ~60-150px vertical steps are comfortably
# jump/dash-able), just arranged across more vertical tiers instead of one
# long horizontal line.
const MAPS := {
	"pyramid_steps": {
		"name": "Pyramid Steps",
		"scene": "res://levels/local_maps/pyramid_steps.tscn",
		"theme_color": Color(0.82, 0.68, 0.42),
		"theme_shape": "triangle",
		"platforms": [
			{"x0": -839, "y0": 392, "x1": 839, "y1": 434},
			{"x0": -202, "y0": 274, "x1": 202, "y1": 316},
			{"x0": -202, "y0": 156, "x1": 202, "y1": 198},
			{"x0": -169, "y0": 38, "x1": 169, "y1": 80},
			{"x0": -169, "y0": -80, "x1": 169, "y1": -38},
			{"x0": -169, "y0": -198, "x1": 169, "y1": -156},
			{"x0": -169, "y0": -316, "x1": 169, "y1": -274},
			{"x0": -108, "y0": -434, "x1": 108, "y1": -392},
		],
	},
	"zigzag_canyon": {
		"name": "Zigzag Canyon",
		"scene": "res://levels/local_maps/zigzag_canyon.tscn",
		"theme_color": Color(0.78, 0.38, 0.22),
		"theme_shape": "rect",
		"platforms": [
			{"x0": -438, "y0": -257, "x1": -100, "y1": -215},
			{"x0": 100, "y0": -257, "x1": 438, "y1": -215},
			{"x0": -169, "y0": -139, "x1": 169, "y1": -97},
			{"x0": -438, "y0": -21, "x1": -100, "y1": 21},
			{"x0": 100, "y0": -21, "x1": 438, "y1": 21},
			{"x0": -169, "y0": 97, "x1": 169, "y1": 139},
			{"x0": -202, "y0": 215, "x1": 202, "y1": 257},
		],
	},
	"floating_rings": {
		"name": "Floating Rings",
		"scene": "res://levels/local_maps/floating_rings.tscn",
		"theme_color": Color(0.40, 0.70, 0.92),
		"theme_shape": "circle",
		"platforms": [
			{"x0": -734, "y0": -375, "x1": 734, "y1": -333},
			{"x0": -135, "y0": -257, "x1": 135, "y1": -215},
			{"x0": -122, "y0": -139, "x1": 122, "y1": -97},
			{"x0": -122, "y0": -21, "x1": 122, "y1": 21},
			{"x0": -108, "y0": 97, "x1": 108, "y1": 139},
			{"x0": -108, "y0": 215, "x1": 108, "y1": 257},
			{"x0": -108, "y0": 333, "x1": 108, "y1": 375},
		],
	},
	"the_spine": {
		"name": "The Spine",
		"scene": "res://levels/local_maps/the_spine.tscn",
		"theme_color": Color(0.72, 0.68, 0.62),
		"theme_shape": "rect",
		"platforms": [
			{"x0": -629, "y0": -316, "x1": 629, "y1": -274},
			{"x0": -169, "y0": -198, "x1": 169, "y1": -156},
			{"x0": -169, "y0": -80, "x1": 169, "y1": -38},
			{"x0": -135, "y0": 38, "x1": 135, "y1": 80},
			{"x0": -135, "y0": 156, "x1": 135, "y1": 198},
			{"x0": -135, "y0": 274, "x1": 135, "y1": 316},
		],
	},
	"double_helix": {
		"name": "Double Helix",
		"scene": "res://levels/local_maps/double_helix.tscn",
		"theme_color": Color(0.28, 0.75, 0.68),
		"theme_shape": "circle",
		"platforms": [
			{"x0": -438, "y0": -257, "x1": -100, "y1": -215},
			{"x0": 100, "y0": -257, "x1": 438, "y1": -215},
			{"x0": -438, "y0": -139, "x1": -100, "y1": -97},
			{"x0": 100, "y0": -139, "x1": 438, "y1": -97},
			{"x0": -438, "y0": -21, "x1": -100, "y1": 21},
			{"x0": 100, "y0": -21, "x1": 438, "y1": 21},
			{"x0": -438, "y0": 97, "x1": -100, "y1": 139},
			{"x0": 100, "y0": 97, "x1": 438, "y1": 139},
			{"x0": -169, "y0": 215, "x1": 169, "y1": 257},
		],
	},
	"checkerboard": {
		"name": "Checkerboard",
		"scene": "res://levels/local_maps/checkerboard.tscn",
		"theme_color": Color(0.55, 0.40, 0.75),
		"theme_shape": "rect",
		"platforms": [
			{"x0": -135, "y0": -493, "x1": 135, "y1": -451},
			{"x0": -135, "y0": -375, "x1": 135, "y1": -333},
			{"x0": -135, "y0": -257, "x1": 135, "y1": -215},
			{"x0": -135, "y0": -139, "x1": 135, "y1": -97},
			{"x0": -135, "y0": -21, "x1": 135, "y1": 21},
			{"x0": -135, "y0": 97, "x1": 135, "y1": 139},
			{"x0": -135, "y0": 215, "x1": 135, "y1": 257},
			{"x0": -135, "y0": 333, "x1": 135, "y1": 375},
			{"x0": -944, "y0": 451, "x1": 944, "y1": 493},
		],
	},
	"the_cross": {
		"name": "The Cross",
		"scene": "res://levels/local_maps/the_cross.tscn",
		"theme_color": Color(0.75, 0.22, 0.28),
		"theme_shape": "rect",
		"platforms": [
			{"x0": -493, "y0": -257, "x1": -100, "y1": -215},
			{"x0": 100, "y0": -257, "x1": 493, "y1": -215},
			{"x0": -493, "y0": -139, "x1": -100, "y1": -97},
			{"x0": 100, "y0": -139, "x1": 493, "y1": -97},
			{"x0": -202, "y0": -21, "x1": 202, "y1": 21},
			{"x0": -404, "y0": 97, "x1": 1, "y1": 139},
			{"x0": 201, "y0": 97, "x1": 404, "y1": 139},
			{"x0": -101, "y0": 215, "x1": 101, "y1": 257},
		],
	},
	"sky_bridge": {
		"name": "Sky Bridge",
		"scene": "res://levels/local_maps/sky_bridge.tscn",
		"theme_color": Color(0.50, 0.78, 0.95),
		"theme_shape": "circle",
		"platforms": [
			{"x0": -135, "y0": -375, "x1": 135, "y1": -333},
			{"x0": -135, "y0": -257, "x1": 135, "y1": -215},
			{"x0": -135, "y0": -139, "x1": 135, "y1": -97},
			{"x0": -135, "y0": -21, "x1": 135, "y1": 21},
			{"x0": -135, "y0": 97, "x1": 135, "y1": 139},
			{"x0": -135, "y0": 215, "x1": 135, "y1": 257},
			{"x0": -734, "y0": 333, "x1": 734, "y1": 375},
		],
	},
	"the_amphitheater": {
		"name": "The Amphitheater",
		"scene": "res://levels/local_maps/the_amphitheater.tscn",
		"theme_color": Color(0.85, 0.62, 0.22),
		"theme_shape": "circle",
		"platforms": [
			{"x0": -438, "y0": -257, "x1": -32, "y1": -215},
			{"x0": 168, "y0": -257, "x1": 438, "y1": -215},
			{"x0": -135, "y0": -139, "x1": 135, "y1": -97},
			{"x0": -370, "y0": -21, "x1": -100, "y1": 21},
			{"x0": 100, "y0": -21, "x1": 370, "y1": 21},
			{"x0": -135, "y0": 97, "x1": 135, "y1": 139},
			{"x0": -135, "y0": 215, "x1": 135, "y1": 257},
		],
	},
	"zigzag_tower": {
		"name": "Zigzag Tower",
		"scene": "res://levels/local_maps/zigzag_tower.tscn",
		"theme_color": Color(0.32, 0.42, 0.70),
		"theme_shape": "rect",
		"platforms": [
			{"x0": -630, "y0": -316, "x1": 630, "y1": -274},
			{"x0": -169, "y0": -198, "x1": 169, "y1": -156},
			{"x0": -169, "y0": -80, "x1": 169, "y1": -38},
			{"x0": -169, "y0": 38, "x1": 169, "y1": 80},
			{"x0": -169, "y0": 156, "x1": 169, "y1": 198},
			{"x0": -169, "y0": 274, "x1": 169, "y1": 316},
		],
	},
	"twin_peaks": {
		"name": "Twin Peaks",
		"scene": "res://levels/local_maps/twin_peaks.tscn",
		"theme_color": Color(0.68, 0.78, 0.88),
		"theme_shape": "triangle",
		"platforms": [
			{"x0": -630, "y0": 274, "x1": 630, "y1": 316},
			{"x0": -135, "y0": 156, "x1": 135, "y1": 198},
			{"x0": -101, "y0": 38, "x1": 101, "y1": 80},
			{"x0": -135, "y0": -80, "x1": 135, "y1": -38},
			{"x0": -101, "y0": -198, "x1": 101, "y1": -156},
			{"x0": -135, "y0": -316, "x1": 135, "y1": -274},
		],
	},
	"the_maze": {
		"name": "The Maze",
		"scene": "res://levels/local_maps/the_maze.tscn",
		"theme_color": Color(0.48, 0.55, 0.28),
		"theme_shape": "rect",
		"platforms": [
			{"x0": -640, "y0": -375, "x1": -100, "y1": -333},
			{"x0": 100, "y0": -375, "x1": 640, "y1": -333},
			{"x0": -270, "y0": -257, "x1": 270, "y1": -215},
			{"x0": -270, "y0": -139, "x1": 270, "y1": -97},
			{"x0": -270, "y0": -21, "x1": 270, "y1": 21},
			{"x0": -270, "y0": 97, "x1": 270, "y1": 139},
			{"x0": -270, "y0": 215, "x1": 270, "y1": 257},
			{"x0": -270, "y0": 333, "x1": 270, "y1": 375},
		],
	},
	"diamond_formation": {
		"name": "Diamond Formation",
		"scene": "res://levels/local_maps/diamond_formation.tscn",
		"theme_color": Color(0.85, 0.38, 0.68),
		"theme_shape": "triangle",
		"platforms": [
			{"x0": -370, "y0": -198, "x1": -100, "y1": -156},
			{"x0": 100, "y0": -198, "x1": 370, "y1": -156},
			{"x0": -370, "y0": -80, "x1": -100, "y1": -38},
			{"x0": 100, "y0": -80, "x1": 370, "y1": -38},
			{"x0": -370, "y0": 38, "x1": -100, "y1": 80},
			{"x0": 100, "y0": 38, "x1": 370, "y1": 80},
			{"x0": -135, "y0": 156, "x1": 135, "y1": 198},
		],
	},
	"the_ladder": {
		"name": "The Ladder",
		"scene": "res://levels/local_maps/the_ladder.tscn",
		"theme_color": Color(0.58, 0.42, 0.28),
		"theme_shape": "rect",
		"platforms": [
			{"x0": -493, "y0": -257, "x1": -100, "y1": -215},
			{"x0": 100, "y0": -257, "x1": 493, "y1": -215},
			{"x0": -202, "y0": -139, "x1": 202, "y1": -97},
			{"x0": -202, "y0": -21, "x1": 202, "y1": 21},
			{"x0": -202, "y0": 97, "x1": 202, "y1": 139},
			{"x0": -202, "y0": 215, "x1": 202, "y1": 257},
		],
	},
	"split_level": {
		"name": "Split Level",
		"scene": "res://levels/local_maps/split_level.tscn",
		"theme_color": Color(0.50, 0.55, 0.60),
		"theme_shape": "rect",
		"platforms": [
			{"x0": -630, "y0": -316, "x1": 630, "y1": -274},
			{"x0": -630, "y0": -198, "x1": 630, "y1": -156},
			{"x0": -135, "y0": -80, "x1": 135, "y1": -38},
			{"x0": -135, "y0": 38, "x1": 135, "y1": 80},
			{"x0": -135, "y0": 156, "x1": 135, "y1": 198},
			{"x0": -135, "y0": 274, "x1": 135, "y1": 316},
		],
	},
	"the_wave": {
		"name": "The Wave",
		"scene": "res://levels/local_maps/the_wave.tscn",
		"theme_color": Color(0.22, 0.52, 0.75),
		"theme_shape": "circle",
		"platforms": [
			{"x0": -438, "y0": -257, "x1": -100, "y1": -215},
			{"x0": 100, "y0": -257, "x1": 438, "y1": -215},
			{"x0": -169, "y0": -139, "x1": 169, "y1": -97},
			{"x0": -169, "y0": -21, "x1": 169, "y1": 21},
			{"x0": -169, "y0": 97, "x1": 169, "y1": 139},
			{"x0": -169, "y0": 215, "x1": 169, "y1": 257},
		],
	},
	"corner_pockets": {
		"name": "Corner Pockets",
		"scene": "res://levels/local_maps/corner_pockets.tscn",
		"theme_color": Color(0.28, 0.58, 0.38),
		"theme_shape": "rect",
		"platforms": [
			{"x0": -630, "y0": -316, "x1": 630, "y1": -274},
			{"x0": -135, "y0": -198, "x1": 135, "y1": -156},
			{"x0": -135, "y0": -80, "x1": 135, "y1": -38},
			{"x0": -135, "y0": 38, "x1": 135, "y1": 80},
			{"x0": -135, "y0": 156, "x1": 135, "y1": 198},
			{"x0": -202, "y0": 274, "x1": 202, "y1": 316},
		],
	},
	"the_funnel": {
		"name": "The Funnel",
		"scene": "res://levels/local_maps/the_funnel.tscn",
		"theme_color": Color(0.50, 0.32, 0.65),
		"theme_shape": "triangle",
		"platforms": [
			{"x0": -493, "y0": -257, "x1": -100, "y1": -215},
			{"x0": 100, "y0": -257, "x1": 493, "y1": -215},
			{"x0": -202, "y0": -139, "x1": 202, "y1": -97},
			{"x0": -493, "y0": -21, "x1": -100, "y1": 21},
			{"x0": 100, "y0": -21, "x1": 493, "y1": 21},
			{"x0": -202, "y0": 97, "x1": 202, "y1": 139},
			{"x0": -202, "y0": 215, "x1": 202, "y1": 257},
		],
	},
	"rooftops": {
		"name": "Rooftops",
		"scene": "res://levels/local_maps/rooftops.tscn",
		"theme_color": Color(0.75, 0.42, 0.32),
		"theme_shape": "rect",
		"platforms": [
			{"x0": -734, "y0": -375, "x1": 734, "y1": -333},
			{"x0": -135, "y0": -257, "x1": 135, "y1": -215},
			{"x0": -135, "y0": -139, "x1": 135, "y1": -97},
			{"x0": -135, "y0": -21, "x1": 135, "y1": 21},
			{"x0": -135, "y0": 97, "x1": 135, "y1": 139},
			{"x0": -135, "y0": 215, "x1": 135, "y1": 257},
			{"x0": -135, "y0": 333, "x1": 135, "y1": 375},
		],
	},
	"the_ring": {
		"name": "The Ring",
		"scene": "res://levels/local_maps/the_ring.tscn",
		"theme_color": Color(0.80, 0.68, 0.28),
		"theme_shape": "circle",
		"platforms": [
			{"x0": -493, "y0": -257, "x1": -100, "y1": -215},
			{"x0": 100, "y0": -257, "x1": 493, "y1": -215},
			{"x0": -405, "y0": -139, "x1": 405, "y1": -97},
			{"x0": -405, "y0": -21, "x1": 405, "y1": 21},
			{"x0": -135, "y0": 97, "x1": 135, "y1": 139},
			{"x0": -135, "y0": 215, "x1": 135, "y1": 257},
		],
	},
	"terraced_garden": {
		"name": "Terraced Garden",
		"scene": "res://levels/local_maps/terraced_garden.tscn",
		"theme_color": Color(0.52, 0.68, 0.48),
		"theme_shape": "rect",
		"platforms": [
			{"x0": -675, "y0": -375, "x1": 675, "y1": -333},
			{"x0": -540, "y0": -257, "x1": 540, "y1": -215},
			{"x0": -405, "y0": -139, "x1": 405, "y1": -97},
			{"x0": -675, "y0": -21, "x1": 675, "y1": 21},
			{"x0": -540, "y0": 97, "x1": 540, "y1": 139},
			{"x0": -405, "y0": 215, "x1": 405, "y1": 257},
			{"x0": -202, "y0": 333, "x1": 202, "y1": 375},
		],
	},
	"the_bowtie": {
		"name": "The Bowtie",
		"scene": "res://levels/local_maps/the_bowtie.tscn",
		"theme_color": Color(0.80, 0.48, 0.52),
		"theme_shape": "triangle",
		"platforms": [
			{"x0": -572, "y0": -316, "x1": -32, "y1": -274},
			{"x0": 168, "y0": -316, "x1": 572, "y1": -274},
			{"x0": -135, "y0": -198, "x1": 135, "y1": -156},
			{"x0": -135, "y0": -80, "x1": 135, "y1": -38},
			{"x0": -135, "y0": 38, "x1": 135, "y1": 80},
			{"x0": -202, "y0": 156, "x1": 202, "y1": 198},
			{"x0": -270, "y0": 274, "x1": 270, "y1": 316},
		],
	},
	"sky_islands": {
		"name": "Sky Islands",
		"scene": "res://levels/local_maps/sky_islands.tscn",
		"theme_color": Color(0.58, 0.85, 0.90),
		"theme_shape": "circle",
		"platforms": [
			{"x0": -302, "y0": -257, "x1": -100, "y1": -215},
			{"x0": 100, "y0": -257, "x1": 302, "y1": -215},
			{"x0": -323, "y0": -139, "x1": -80, "y1": -97},
			{"x0": 120, "y0": -139, "x1": 323, "y1": -97},
			{"x0": -323, "y0": -21, "x1": -93, "y1": 21},
			{"x0": 107, "y0": -21, "x1": 323, "y1": 21},
			{"x0": -302, "y0": 97, "x1": -100, "y1": 139},
			{"x0": 100, "y0": 97, "x1": 302, "y1": 139},
			{"x0": -135, "y0": 215, "x1": 135, "y1": 257},
		],
	},
	"the_gauntlet": {
		"name": "The Gauntlet",
		"scene": "res://levels/local_maps/the_gauntlet.tscn",
		"theme_color": Color(0.62, 0.22, 0.22),
		"theme_shape": "rect",
		"platforms": [
			{"x0": -336, "y0": -257, "x1": -66, "y1": -215},
			{"x0": 134, "y0": -257, "x1": 336, "y1": -215},
			{"x0": -302, "y0": -139, "x1": -100, "y1": -97},
			{"x0": 100, "y0": -139, "x1": 302, "y1": -97},
			{"x0": -302, "y0": -21, "x1": -100, "y1": 21},
			{"x0": 100, "y0": -21, "x1": 302, "y1": 21},
			{"x0": -302, "y0": 97, "x1": -100, "y1": 139},
			{"x0": 100, "y0": 97, "x1": 302, "y1": 139},
			{"x0": -90, "y0": 215, "x1": 90, "y1": 257},
		],
	},
	"the_spiral": {
		"name": "The Spiral",
		"scene": "res://levels/local_maps/the_spiral.tscn",
		"theme_color": Color(0.45, 0.32, 0.72),
		"theme_shape": "circle",
		"platforms": [
			{"x0": -539, "y0": -316, "x1": -66, "y1": -274},
			{"x0": 134, "y0": -316, "x1": 539, "y1": -274},
			{"x0": -202, "y0": -198, "x1": 202, "y1": -156},
			{"x0": -202, "y0": -80, "x1": 202, "y1": -38},
			{"x0": -202, "y0": 38, "x1": 202, "y1": 80},
			{"x0": -202, "y0": 156, "x1": 202, "y1": 198},
			{"x0": -236, "y0": 274, "x1": 236, "y1": 316},
		],
	},
	"low_gravity_isles": {
		"name": "Low Gravity Isles",
		"scene": "res://levels/local_maps/low_gravity_isles.tscn",
		"theme_color": Color(0.32, 0.22, 0.55),
		"theme_shape": "circle",
		"platforms": [
			{"x0": -438, "y0": -257, "x1": -100, "y1": -215},
			{"x0": 100, "y0": -257, "x1": 438, "y1": -215},
			{"x0": -135, "y0": -139, "x1": 135, "y1": -97},
			{"x0": -438, "y0": -21, "x1": -100, "y1": 21},
			{"x0": 100, "y0": -21, "x1": 438, "y1": 21},
			{"x0": -236, "y0": 97, "x1": 236, "y1": 139},
			{"x0": -236, "y0": 215, "x1": 236, "y1": 257},
		],
	},
	"the_causeway": {
		"name": "The Causeway",
		"scene": "res://levels/local_maps/the_causeway.tscn",
		"theme_color": Color(0.32, 0.62, 0.62),
		"theme_shape": "rect",
		"platforms": [
			{"x0": -597, "y0": -316, "x1": -1, "y1": -274},
			{"x0": 199, "y0": -316, "x1": 597, "y1": -274},
			{"x0": -202, "y0": -198, "x1": 202, "y1": -156},
			{"x0": -405, "y0": -80, "x1": 405, "y1": -38},
			{"x0": -135, "y0": 38, "x1": 135, "y1": 80},
			{"x0": -135, "y0": 156, "x1": 135, "y1": 198},
			{"x0": -135, "y0": 274, "x1": 135, "y1": 316},
		],
	},
}

const MAP_ORDER := [
	"pyramid_steps", "zigzag_canyon", "floating_rings", "the_spine",
	"double_helix", "checkerboard", "the_cross", "sky_bridge",
	"the_amphitheater", "zigzag_tower", "twin_peaks", "the_maze",
	"diamond_formation", "the_ladder", "split_level", "the_wave",
	"corner_pockets", "the_funnel", "rooftops", "the_ring",
	"terraced_garden", "the_bowtie", "sky_islands", "the_gauntlet",
	"the_spiral", "low_gravity_isles", "the_causeway",
]

## Resolves a map id to its scene path, falling back to the first map for an
## unknown/missing id (deleted map, corrupt save, etc.) -- same "never
## hard-fail on missing content" rule the rest of the project follows.
static func scene_path_for(map_id: String) -> String:
	var def: Dictionary = MAPS.get(map_id, {})
	var path: String = def.get("scene", "")
	if not path.is_empty() and ResourceLoader.exists(path):
		return path
	return MAPS[CLASSIC_ID]["scene"]
