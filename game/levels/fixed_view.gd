class_name FixedView
extends RefCounted

# Single source of truth for "what does a fixed, non-following camera show
# for this map, and where do the death planes sit relative to it" -- used
# by both the map generator tools (to size MapBackground's bounds so the
# backdrop always exactly fills the screen, with no edge ever visible) and
# by the runtime match controllers (game.gd for local/bot play, net_game.gd
# for the online client's display, server_match.gd for the online server's
# authoritative death check). Every one of those reads the SAME computed
# Rect2 off the arena's own Background node rather than recomputing it
# independently, so the camera, the backdrop, and the death boundary can
# never drift out of sync with each other.

const VIEWPORT_SIZE := Vector2(1152, 648) # matches project.godot's display/window/size
# How far past the visible fixed-camera frame a player has to go before
# they're considered "off the map" -- small on purpose: the point is "off
# screen", not a second, larger invisible arena past what you can see.
const DEATH_MARGIN_PX := 80.0

## `platform_bounds` is the raw extent of a map's platform rects (see each
## catalog's own data); `margin` pads that before fitting -- extra breathing
## room around the actual level geometry, same role BG_MARGIN always played.
## The result is grown on whichever axis is needed so its aspect ratio
## matches VIEWPORT_SIZE exactly, so a camera fit to it fills the screen
## edge-to-edge with no letterboxing and no gap at any side.
static func compute(platform_bounds: Rect2, margin: float) -> Rect2:
	var padded := platform_bounds.grow(margin)
	var viewport_aspect := VIEWPORT_SIZE.x / VIEWPORT_SIZE.y
	var padded_aspect := padded.size.x / padded.size.y
	var view_size: Vector2
	if padded_aspect > viewport_aspect:
		view_size = Vector2(padded.size.x, padded.size.x / viewport_aspect)
	else:
		view_size = Vector2(padded.size.y * viewport_aspect, padded.size.y)
	var center := padded.position + padded.size * 0.5
	return Rect2(center - view_size * 0.5, view_size)

## A plain, static (non-follow) Camera2D framed exactly on `view_rect` --
## uniform zoom from VIEWPORT_SIZE fills the screen edge-to-edge since
## view_rect's aspect always already matches it (see compute() above).
static func make_camera(view_rect: Rect2) -> Camera2D:
	var cam := Camera2D.new()
	cam.global_position = view_rect.position + view_rect.size * 0.5
	cam.zoom = Vector2.ONE * (VIEWPORT_SIZE.x / view_rect.size.x)
	cam.enabled = true
	return cam

## Anything outside this is "off the map" -- just past what the fixed
## camera actually shows, not a separate, larger invisible boundary.
static func death_rect(view_rect: Rect2) -> Rect2:
	return view_rect.grow(DEATH_MARGIN_PX)
