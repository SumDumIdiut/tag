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
# Reachability convention validated against the maps this replaced
# (staircase, scattered_islands): ~150-350px horizontal gaps and ~60-150px
# vertical steps are comfortably jump/dash-able; nothing here exceeds that.
const MAPS := {
	"pyramid_steps": {
		"name": "Pyramid Steps",
		"scene": "res://levels/local_maps/pyramid_steps.tscn",
		"theme_color": Color(0.82, 0.68, 0.42),
		"theme_shape": "triangle",
		"platforms": [
			{"x0": -1050, "y0": 420, "x1": 1050, "y1": 480},
			{"x0": -750, "y0": 340, "x1": -450, "y1": 420},
			{"x0": 450, "y0": 340, "x1": 750, "y1": 420},
			{"x0": -500, "y0": 260, "x1": -250, "y1": 340},
			{"x0": 250, "y0": 260, "x1": 500, "y1": 340},
			{"x0": -250, "y0": 180, "x1": 0, "y1": 260},
			{"x0": 0, "y0": 180, "x1": 250, "y1": 260},
			{"x0": -80, "y0": 100, "x1": 80, "y1": 180},
		],
	},
	"zigzag_canyon": {
		"name": "Zigzag Canyon",
		"scene": "res://levels/local_maps/zigzag_canyon.tscn",
		"theme_color": Color(0.78, 0.38, 0.22),
		"theme_shape": "rect",
		"platforms": [
			{"x0": -1000, "y0": 120, "x1": -750, "y1": 160},
			{"x0": -650, "y0": 220, "x1": -400, "y1": 260},
			{"x0": -300, "y0": 320, "x1": -50, "y1": 360},
			{"x0": 50, "y0": 220, "x1": 300, "y1": 260},
			{"x0": 400, "y0": 120, "x1": 650, "y1": 160},
			{"x0": 750, "y0": 320, "x1": 1000, "y1": 360},
			{"x0": -150, "y0": 420, "x1": 150, "y1": 460},
		],
	},
	"floating_rings": {
		"name": "Floating Rings",
		"scene": "res://levels/local_maps/floating_rings.tscn",
		"theme_color": Color(0.40, 0.70, 0.92),
		"theme_shape": "circle",
		"platforms": [
			{"x0": -1000, "y0": 420, "x1": 1000, "y1": 480},
			{"x0": -100, "y0": 340, "x1": 100, "y1": 380},
			{"x0": -400, "y0": 280, "x1": -220, "y1": 320},
			{"x0": 220, "y0": 280, "x1": 400, "y1": 320},
			{"x0": -320, "y0": 160, "x1": -160, "y1": 200},
			{"x0": 160, "y0": 160, "x1": 320, "y1": 200},
			{"x0": -80, "y0": 60, "x1": 80, "y1": 100},
		],
	},
	"the_spine": {
		"name": "The Spine",
		"scene": "res://levels/local_maps/the_spine.tscn",
		"theme_color": Color(0.72, 0.68, 0.62),
		"theme_shape": "rect",
		"platforms": [
			{"x0": -900, "y0": 280, "x1": 900, "y1": 320},
			{"x0": -1050, "y0": 420, "x1": -800, "y1": 460},
			{"x0": 800, "y0": 420, "x1": 1050, "y1": 460},
			{"x0": -650, "y0": 160, "x1": -450, "y1": 200},
			{"x0": 450, "y0": 160, "x1": 650, "y1": 200},
			{"x0": -100, "y0": 100, "x1": 100, "y1": 140},
		],
	},
	"double_helix": {
		"name": "Double Helix",
		"scene": "res://levels/local_maps/double_helix.tscn",
		"theme_color": Color(0.28, 0.75, 0.68),
		"theme_shape": "circle",
		"platforms": [
			{"x0": -950, "y0": 440, "x1": -700, "y1": 480},
			{"x0": -600, "y0": 380, "x1": -350, "y1": 420},
			{"x0": -250, "y0": 320, "x1": 0, "y1": 360},
			{"x0": 100, "y0": 260, "x1": 350, "y1": 300},
			{"x0": 450, "y0": 200, "x1": 700, "y1": 240},
			{"x0": 800, "y0": 140, "x1": 1050, "y1": 180},
			{"x0": -700, "y0": 200, "x1": -450, "y1": 240},
			{"x0": -350, "y0": 140, "x1": -100, "y1": 180},
			{"x0": 0, "y0": 380, "x1": 250, "y1": 420},
		],
	},
	"checkerboard": {
		"name": "Checkerboard",
		"scene": "res://levels/local_maps/checkerboard.tscn",
		"theme_color": Color(0.55, 0.40, 0.75),
		"theme_shape": "rect",
		"platforms": [
			{"x0": -1000, "y0": 200, "x1": -800, "y1": 240},
			{"x0": -750, "y0": 340, "x1": -550, "y1": 380},
			{"x0": -500, "y0": 200, "x1": -300, "y1": 240},
			{"x0": -250, "y0": 340, "x1": -50, "y1": 380},
			{"x0": 0, "y0": 200, "x1": 200, "y1": 240},
			{"x0": 250, "y0": 340, "x1": 450, "y1": 380},
			{"x0": 500, "y0": 200, "x1": 700, "y1": 240},
			{"x0": 750, "y0": 340, "x1": 950, "y1": 380},
			{"x0": -1050, "y0": 460, "x1": 1050, "y1": 500},
		],
	},
	"the_cross": {
		"name": "The Cross",
		"scene": "res://levels/local_maps/the_cross.tscn",
		"theme_color": Color(0.75, 0.22, 0.28),
		"theme_shape": "rect",
		"platforms": [
			{"x0": -150, "y0": 340, "x1": 150, "y1": 380},
			{"x0": -1000, "y0": 340, "x1": -700, "y1": 380},
			{"x0": 700, "y0": 340, "x1": 1000, "y1": 380},
			{"x0": -150, "y0": 40, "x1": 150, "y1": 80},
			{"x0": -150, "y0": 160, "x1": 150, "y1": 200},
			{"x0": -150, "y0": 480, "x1": 150, "y1": 520},
			{"x0": -400, "y0": 260, "x1": -250, "y1": 300},
			{"x0": 250, "y0": 260, "x1": 400, "y1": 300},
		],
	},
	"sky_bridge": {
		"name": "Sky Bridge",
		"scene": "res://levels/local_maps/sky_bridge.tscn",
		"theme_color": Color(0.50, 0.78, 0.95),
		"theme_shape": "circle",
		"platforms": [
			{"x0": -1050, "y0": 200, "x1": -850, "y1": 240},
			{"x0": -700, "y0": 200, "x1": -500, "y1": 240},
			{"x0": -350, "y0": 200, "x1": -150, "y1": 240},
			{"x0": 150, "y0": 200, "x1": 350, "y1": 240},
			{"x0": 500, "y0": 200, "x1": 700, "y1": 240},
			{"x0": 850, "y0": 200, "x1": 1050, "y1": 240},
			{"x0": -1050, "y0": 440, "x1": 1050, "y1": 480},
		],
	},
	"the_amphitheater": {
		"name": "The Amphitheater",
		"scene": "res://levels/local_maps/the_amphitheater.tscn",
		"theme_color": Color(0.85, 0.62, 0.22),
		"theme_shape": "circle",
		"platforms": [
			{"x0": -150, "y0": 420, "x1": 150, "y1": 460},
			{"x0": -450, "y0": 340, "x1": -250, "y1": 380},
			{"x0": 250, "y0": 340, "x1": 450, "y1": 380},
			{"x0": -750, "y0": 260, "x1": -550, "y1": 300},
			{"x0": 550, "y0": 260, "x1": 750, "y1": 300},
			{"x0": -1050, "y0": 180, "x1": -850, "y1": 220},
			{"x0": 850, "y0": 180, "x1": 1050, "y1": 220},
		],
	},
	"zigzag_tower": {
		"name": "Zigzag Tower",
		"scene": "res://levels/local_maps/zigzag_tower.tscn",
		"theme_color": Color(0.32, 0.42, 0.70),
		"theme_shape": "rect",
		"platforms": [
			{"x0": -1050, "y0": 440, "x1": 1050, "y1": 480},
			{"x0": -300, "y0": 360, "x1": -50, "y1": 400},
			{"x0": 50, "y0": 280, "x1": 300, "y1": 320},
			{"x0": -300, "y0": 200, "x1": -50, "y1": 240},
			{"x0": 50, "y0": 120, "x1": 300, "y1": 160},
			{"x0": -300, "y0": 40, "x1": -50, "y1": 80},
		],
	},
	"twin_peaks": {
		"name": "Twin Peaks",
		"scene": "res://levels/local_maps/twin_peaks.tscn",
		"theme_color": Color(0.68, 0.78, 0.88),
		"theme_shape": "triangle",
		"platforms": [
			{"x0": -1050, "y0": 420, "x1": 1050, "y1": 480},
			{"x0": -850, "y0": 300, "x1": -650, "y1": 420},
			{"x0": -750, "y0": 220, "x1": -600, "y1": 300},
			{"x0": 650, "y0": 300, "x1": 850, "y1": 420},
			{"x0": 600, "y0": 220, "x1": 750, "y1": 300},
			{"x0": -100, "y0": 360, "x1": 100, "y1": 400},
		],
	},
	"the_maze": {
		"name": "The Maze",
		"scene": "res://levels/local_maps/the_maze.tscn",
		"theme_color": Color(0.48, 0.55, 0.28),
		"theme_shape": "rect",
		"platforms": [
			{"x0": -1050, "y0": 460, "x1": -650, "y1": 500},
			{"x0": -750, "y0": 340, "x1": -350, "y1": 380},
			{"x0": -450, "y0": 220, "x1": -50, "y1": 260},
			{"x0": -150, "y0": 460, "x1": 250, "y1": 500},
			{"x0": 150, "y0": 340, "x1": 550, "y1": 380},
			{"x0": 450, "y0": 220, "x1": 850, "y1": 260},
			{"x0": 650, "y0": 460, "x1": 1050, "y1": 500},
			{"x0": -250, "y0": 100, "x1": 150, "y1": 140},
		],
	},
	"diamond_formation": {
		"name": "Diamond Formation",
		"scene": "res://levels/local_maps/diamond_formation.tscn",
		"theme_color": Color(0.85, 0.38, 0.68),
		"theme_shape": "triangle",
		"platforms": [
			{"x0": -100, "y0": 440, "x1": 100, "y1": 480},
			{"x0": -500, "y0": 320, "x1": -300, "y1": 360},
			{"x0": 300, "y0": 320, "x1": 500, "y1": 360},
			{"x0": -100, "y0": 200, "x1": 100, "y1": 240},
			{"x0": -800, "y0": 200, "x1": -600, "y1": 240},
			{"x0": 600, "y0": 200, "x1": 800, "y1": 240},
			{"x0": -100, "y0": 80, "x1": 100, "y1": 120},
		],
	},
	"the_ladder": {
		"name": "The Ladder",
		"scene": "res://levels/local_maps/the_ladder.tscn",
		"theme_color": Color(0.58, 0.42, 0.28),
		"theme_shape": "rect",
		"platforms": [
			{"x0": -1050, "y0": 460, "x1": -750, "y1": 500},
			{"x0": -700, "y0": 380, "x1": -400, "y1": 420},
			{"x0": -350, "y0": 300, "x1": -50, "y1": 340},
			{"x0": 0, "y0": 220, "x1": 300, "y1": 260},
			{"x0": 350, "y0": 140, "x1": 650, "y1": 180},
			{"x0": 700, "y0": 60, "x1": 1000, "y1": 100},
		],
	},
	"split_level": {
		"name": "Split Level",
		"scene": "res://levels/local_maps/split_level.tscn",
		"theme_color": Color(0.50, 0.55, 0.60),
		"theme_shape": "rect",
		"platforms": [
			{"x0": -1050, "y0": 220, "x1": 1050, "y1": 260},
			{"x0": -1050, "y0": 440, "x1": 1050, "y1": 480},
			{"x0": -300, "y0": 330, "x1": -100, "y1": 370},
			{"x0": 100, "y0": 330, "x1": 300, "y1": 370},
			{"x0": -800, "y0": 330, "x1": -600, "y1": 370},
			{"x0": 600, "y0": 330, "x1": 800, "y1": 370},
		],
	},
	"the_wave": {
		"name": "The Wave",
		"scene": "res://levels/local_maps/the_wave.tscn",
		"theme_color": Color(0.22, 0.52, 0.75),
		"theme_shape": "circle",
		"platforms": [
			{"x0": -1050, "y0": 280, "x1": -800, "y1": 320},
			{"x0": -700, "y0": 200, "x1": -450, "y1": 240},
			{"x0": -350, "y0": 320, "x1": -100, "y1": 360},
			{"x0": 0, "y0": 200, "x1": 250, "y1": 240},
			{"x0": 350, "y0": 320, "x1": 600, "y1": 360},
			{"x0": 700, "y0": 200, "x1": 950, "y1": 240},
		],
	},
	"corner_pockets": {
		"name": "Corner Pockets",
		"scene": "res://levels/local_maps/corner_pockets.tscn",
		"theme_color": Color(0.28, 0.58, 0.38),
		"theme_shape": "rect",
		"platforms": [
			{"x0": -1050, "y0": 440, "x1": 1050, "y1": 480},
			{"x0": -900, "y0": 260, "x1": -700, "y1": 300},
			{"x0": 700, "y0": 260, "x1": 900, "y1": 300},
			{"x0": -900, "y0": 100, "x1": -700, "y1": 140},
			{"x0": 700, "y0": 100, "x1": 900, "y1": 140},
			{"x0": -150, "y0": 340, "x1": 150, "y1": 380},
		],
	},
	"the_funnel": {
		"name": "The Funnel",
		"scene": "res://levels/local_maps/the_funnel.tscn",
		"theme_color": Color(0.50, 0.32, 0.65),
		"theme_shape": "triangle",
		"platforms": [
			{"x0": -1050, "y0": 80, "x1": -750, "y1": 120},
			{"x0": 750, "y0": 80, "x1": 1050, "y1": 120},
			{"x0": -750, "y0": 220, "x1": -450, "y1": 260},
			{"x0": 450, "y0": 220, "x1": 750, "y1": 260},
			{"x0": -450, "y0": 360, "x1": -150, "y1": 400},
			{"x0": 150, "y0": 360, "x1": 450, "y1": 400},
			{"x0": -150, "y0": 460, "x1": 150, "y1": 500},
		],
	},
	"rooftops": {
		"name": "Rooftops",
		"scene": "res://levels/local_maps/rooftops.tscn",
		"theme_color": Color(0.75, 0.42, 0.32),
		"theme_shape": "rect",
		"platforms": [
			{"x0": -1050, "y0": 460, "x1": 1050, "y1": 500},
			{"x0": -900, "y0": 300, "x1": -700, "y1": 340},
			{"x0": -550, "y0": 220, "x1": -350, "y1": 260},
			{"x0": -200, "y0": 340, "x1": 0, "y1": 380},
			{"x0": 150, "y0": 260, "x1": 350, "y1": 300},
			{"x0": 500, "y0": 340, "x1": 700, "y1": 380},
			{"x0": 850, "y0": 220, "x1": 1050, "y1": 260},
		],
	},
	"the_ring": {
		"name": "The Ring",
		"scene": "res://levels/local_maps/the_ring.tscn",
		"theme_color": Color(0.80, 0.68, 0.28),
		"theme_shape": "circle",
		"platforms": [
			{"x0": -900, "y0": 340, "x1": -600, "y1": 380},
			{"x0": 600, "y0": 340, "x1": 900, "y1": 380},
			{"x0": -300, "y0": 460, "x1": 300, "y1": 500},
			{"x0": -300, "y0": 100, "x1": 300, "y1": 140},
			{"x0": -900, "y0": 200, "x1": -700, "y1": 240},
			{"x0": 700, "y0": 200, "x1": 900, "y1": 240},
		],
	},
	"terraced_garden": {
		"name": "Terraced Garden",
		"scene": "res://levels/local_maps/terraced_garden.tscn",
		"theme_color": Color(0.52, 0.68, 0.48),
		"theme_shape": "rect",
		"platforms": [
			{"x0": -1050, "y0": 460, "x1": -50, "y1": 500},
			{"x0": -950, "y0": 360, "x1": -150, "y1": 400},
			{"x0": -850, "y0": 260, "x1": -250, "y1": 300},
			{"x0": 50, "y0": 460, "x1": 1050, "y1": 500},
			{"x0": 150, "y0": 360, "x1": 950, "y1": 400},
			{"x0": 250, "y0": 260, "x1": 850, "y1": 300},
			{"x0": -150, "y0": 160, "x1": 150, "y1": 200},
		],
	},
	"the_bowtie": {
		"name": "The Bowtie",
		"scene": "res://levels/local_maps/the_bowtie.tscn",
		"theme_color": Color(0.80, 0.48, 0.52),
		"theme_shape": "triangle",
		"platforms": [
			{"x0": -1050, "y0": 460, "x1": -650, "y1": 500},
			{"x0": -850, "y0": 340, "x1": -550, "y1": 380},
			{"x0": -650, "y0": 220, "x1": -450, "y1": 260},
			{"x0": -100, "y0": 340, "x1": 100, "y1": 380},
			{"x0": 450, "y0": 220, "x1": 650, "y1": 260},
			{"x0": 550, "y0": 340, "x1": 850, "y1": 380},
			{"x0": 650, "y0": 460, "x1": 1050, "y1": 500},
		],
	},
	"sky_islands": {
		"name": "Sky Islands",
		"scene": "res://levels/local_maps/sky_islands.tscn",
		"theme_color": Color(0.58, 0.85, 0.90),
		"theme_shape": "circle",
		"platforms": [
			{"x0": -1050, "y0": 200, "x1": -900, "y1": 240},
			{"x0": -750, "y0": 320, "x1": -600, "y1": 360},
			{"x0": -500, "y0": 140, "x1": -320, "y1": 180},
			{"x0": -200, "y0": 400, "x1": -50, "y1": 440},
			{"x0": 50, "y0": 260, "x1": 220, "y1": 300},
			{"x0": 300, "y0": 100, "x1": 460, "y1": 140},
			{"x0": 550, "y0": 380, "x1": 700, "y1": 420},
			{"x0": 800, "y0": 220, "x1": 950, "y1": 260},
			{"x0": -100, "y0": 40, "x1": 100, "y1": 80},
		],
	},
	"the_gauntlet": {
		"name": "The Gauntlet",
		"scene": "res://levels/local_maps/the_gauntlet.tscn",
		"theme_color": Color(0.62, 0.22, 0.22),
		"theme_shape": "rect",
		"platforms": [
			{"x0": -1050, "y0": 380, "x1": -850, "y1": 420},
			{"x0": -750, "y0": 260, "x1": -600, "y1": 300},
			{"x0": -500, "y0": 380, "x1": -350, "y1": 420},
			{"x0": -250, "y0": 260, "x1": -100, "y1": 300},
			{"x0": 0, "y0": 380, "x1": 150, "y1": 420},
			{"x0": 250, "y0": 260, "x1": 400, "y1": 300},
			{"x0": 500, "y0": 380, "x1": 650, "y1": 420},
			{"x0": 750, "y0": 260, "x1": 900, "y1": 300},
			{"x0": 950, "y0": 380, "x1": 1050, "y1": 420},
		],
	},
	"the_spiral": {
		"name": "The Spiral",
		"scene": "res://levels/local_maps/the_spiral.tscn",
		"theme_color": Color(0.45, 0.32, 0.72),
		"theme_shape": "circle",
		"platforms": [
			{"x0": -1050, "y0": 460, "x1": -700, "y1": 500},
			{"x0": -750, "y0": 340, "x1": -450, "y1": 380},
			{"x0": -500, "y0": 220, "x1": -200, "y1": 260},
			{"x0": -250, "y0": 100, "x1": 50, "y1": 140},
			{"x0": 100, "y0": 220, "x1": 400, "y1": 260},
			{"x0": 450, "y0": 340, "x1": 750, "y1": 380},
			{"x0": 700, "y0": 460, "x1": 1050, "y1": 500},
		],
	},
	"low_gravity_isles": {
		"name": "Low Gravity Isles",
		"scene": "res://levels/local_maps/low_gravity_isles.tscn",
		"theme_color": Color(0.32, 0.22, 0.55),
		"theme_shape": "circle",
		"platforms": [
			{"x0": -1050, "y0": 240, "x1": -800, "y1": 280},
			{"x0": -550, "y0": 160, "x1": -300, "y1": 200},
			{"x0": -100, "y0": 300, "x1": 100, "y1": 340},
			{"x0": 300, "y0": 160, "x1": 550, "y1": 200},
			{"x0": 800, "y0": 240, "x1": 1050, "y1": 280},
			{"x0": -1050, "y0": 440, "x1": -700, "y1": 480},
			{"x0": 700, "y0": 440, "x1": 1050, "y1": 480},
		],
	},
	"the_causeway": {
		"name": "The Causeway",
		"scene": "res://levels/local_maps/the_causeway.tscn",
		"theme_color": Color(0.32, 0.62, 0.62),
		"theme_shape": "rect",
		"platforms": [
			{"x0": -1050, "y0": 380, "x1": -600, "y1": 420},
			{"x0": -450, "y0": 380, "x1": -150, "y1": 420},
			{"x0": 0, "y0": 380, "x1": 300, "y1": 420},
			{"x0": 450, "y0": 380, "x1": 1050, "y1": 420},
			{"x0": -700, "y0": 240, "x1": -500, "y1": 280},
			{"x0": -50, "y0": 240, "x1": 150, "y1": 280},
			{"x0": 550, "y0": 240, "x1": 750, "y1": 280},
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
