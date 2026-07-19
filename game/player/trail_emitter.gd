extends Node2D
class_name TrailEmitter

# A purely cosmetic, client-rendered effect -- stamps a fading copy of the
# equipped trail's texture behind whichever Node2D this is a child of
# (Player for local/singleplayer, RemoteAvatar for everyone in a networked
# match) whenever it's moving fast enough. No netcode involvement at all:
# every peer picks its own trail_id locally the same way skin/hat textures
# already resolve (see SkinCatalog.get_trail_texture), so there's nothing to
# keep in sync beyond the id itself, which rides the roster the same way
# skin_id/hat_id do.

const SPAWN_INTERVAL_SEC := 0.05
const GHOST_LIFETIME_SEC := 0.4
const GHOST_START_ALPHA := 0.55
const MIN_SPEED_TO_EMIT := 60.0

var trail_id := "":
	set(value):
		trail_id = value
		_texture = SkinCatalog.get_trail_texture(value) if not value.is_empty() else null

var _texture: Texture2D
var _spawn_timer := 0.0

func _ready() -> void:
	SkinCatalog.trail_received.connect(_on_trail_received)

func _on_trail_received(id: String) -> void:
	if id == trail_id:
		_texture = SkinCatalog.get_trail_texture(id)

## Called every physics frame by the owner with its own current speed --
## decouples this from knowing whether it's attached to a CharacterBody2D
## (Player) or a purely-visual puppet (RemoteAvatar, no physics body of its
## own to read a velocity from directly).
func update(delta: float, speed: float) -> void:
	if trail_id.is_empty() or _texture == null:
		return
	_spawn_timer -= delta
	if speed >= MIN_SPEED_TO_EMIT and _spawn_timer <= 0.0:
		_spawn_timer = SPAWN_INTERVAL_SEC
		_spawn_ghost()

func _spawn_ghost() -> void:
	var scene := get_tree().current_scene
	if scene == null:
		return
	var ghost := Sprite2D.new()
	ghost.texture = _texture
	ghost.global_position = global_position
	ghost.z_index = -1
	ghost.modulate.a = GHOST_START_ALPHA
	scene.add_child(ghost)
	var tw := ghost.create_tween()
	tw.tween_property(ghost, "modulate:a", 0.0, GHOST_LIFETIME_SEC)
	tw.tween_callback(ghost.queue_free)
