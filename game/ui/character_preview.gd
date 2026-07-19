extends SubViewportContainer
class_name CharacterPreview

# A genuine live character portrait for menu buttons, instead of a flat
# vector icon -- renders the actual in-game rig (same RemoteAvatar puppet
# used for every other player on screen) in its own SubViewport, isolated
# from the rest of the UI's 2D world. Nearest filtering on the container
# keeps the pixel art crisp when blown up to
# button size, matching every other piece of character art in the game.

const REMOTE_AVATAR_SCENE := preload("res://player/remote_avatar.tscn")
const VIEWPORT_SIZE := Vector2i(56, 72)
# Where the character's own origin (feet/collision-capsule center) sits
# within that viewport -- tuned so the whole rig, including a tall hat,
# fits with a little breathing room top and bottom.
const AVATAR_OFFSET := Vector2(28, 50)

@export var skin_id: String = "red"
@export var hat_id: String = ""
@export var zoom: float = 2.0
# Multiplies the SubViewport's actual pixel resolution (and the camera's
## effective zoom right along with it) without changing what's framed --
# VIEWPORT_SIZE (56x72) is tuned for the small menu-bar portraits, where
# it's displayed at close to its native size. Blown up much larger (e.g.
# the Art Tool's big preview, ~260x340), a non-integer stretch factor from
# that small a source produces visibly uneven, jagged-blocky scaling even
# with nearest filtering -- rendering more real pixels for the same framing
# fixes that at the source instead of just stretching harder. World-space
# framing (AVATAR_OFFSET et al) is unaffected: only pixel density changes.
@export var render_scale: float = 1.0

var _avatar: RemoteAvatar

func _ready() -> void:
	stretch = true
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	mouse_filter = Control.MOUSE_FILTER_IGNORE

	var viewport := SubViewport.new()
	viewport.size = Vector2i(Vector2(VIEWPORT_SIZE) * render_scale)
	viewport.transparent_bg = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	# Each preview needs its own isolated 2D canvas/camera space -- without
	# this, every CharacterPreview on screen shares one World2D and their
	# Camera2Ds fight over which is "current," making every portrait show
	# the same (usually wrong) character.
	viewport.world_2d = World2D.new()
	add_child(viewport)

	_avatar = REMOTE_AVATAR_SCENE.instantiate()
	viewport.add_child(_avatar)
	_avatar.global_position = AVATAR_OFFSET
	_avatar.set_skin(skin_id)
	if not hat_id.is_empty():
		_avatar.set_hat(hat_id)
	_avatar.set_state(AVATAR_OFFSET, Vector2.ZERO, 1, false, false, true, "", 0, false)
	if _avatar.name_label:
		_avatar.name_label.visible = false
	if _avatar.camera:
		_avatar.camera.position_smoothing_enabled = false
		_avatar.camera.zoom = Vector2(zoom, zoom) * render_scale
		_avatar.camera.global_position = AVATAR_OFFSET + Vector2(0, -20)
		_avatar.camera.enabled = true
		_avatar.camera.make_current()

## Overrides one part's texture directly, bypassing SkinCatalog -- used by
## the Art Tool to preview an in-progress edit live. Pass null to clear the
## override and let set_skin's own cached texture show again.
func set_part_override(part_name: String, tex: Texture2D) -> void:
	if _avatar:
		_avatar.set_part_texture_override(part_name, tex)

## Same idea, for the hat slot.
func set_hat_override(tex: Texture2D) -> void:
	if _avatar:
		_avatar.set_hat_texture_override(tex)
