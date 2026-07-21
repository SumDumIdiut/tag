extends Node

# Builds the game's one project-wide font by duplicating Godot's own
# built-in default font (ThemeDB.fallback_font -- already embedded in every
# Godot binary, so nothing external needs to be bundled or licensed) and
# forcing it to rasterize at a small fixed pixel size with antialiasing and
# hinting off, then only ever integer-upscaling from there
# (FIXED_SIZE_SCALE_INTEGER_ONLY) -- the standard Godot 4 technique for
# genuinely blocky "pixel font" rendering without hand-authoring a bitmap
# glyph set, while keeping full Unicode/mixed-case glyph coverage (a
# hand-drawn charset risks missing/garbled glyphs on any text it didn't
# cover; this can't miss a glyph since it's still the same underlying font
# data, just rasterized differently). Matches this session's chosen
# "flashy pixel art" direction for every OTHER visual element already
# painted by hand. Run via:
#   godot --path . res://tools/generate_pixel_font.tscn
# NOT --headless -- ResourceSaver.save() on a font here still works
# headless, but the project's other generators establish non-headless as
# the norm for anything touching ThemeDB/rendering state.

const OUT_DIR := "res://assets/fonts"
const OUT_PATH := "res://assets/fonts/pixel_font.tres"
const FIXED_PX_SIZE := 13

func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))
	var base: Font = ThemeDB.fallback_font
	var custom: FontFile
	if base is FontFile:
		custom = (base as FontFile).duplicate()
	else:
		custom = FontFile.new()
	custom.antialiasing = TextServer.FONT_ANTIALIASING_NONE
	custom.hinting = TextServer.HINTING_NONE
	custom.subpixel_positioning = TextServer.SUBPIXEL_POSITIONING_DISABLED
	custom.oversampling = 1.0
	custom.fixed_size = FIXED_PX_SIZE
	custom.fixed_size_scale_mode = TextServer.FIXED_SIZE_SCALE_INTEGER_ONLY
	var err := ResourceSaver.save(custom, OUT_PATH)
	print("PIXEL_FONT_SAVE=%d" % err)
	print("GENERATE_DONE")
	get_tree().quit()
