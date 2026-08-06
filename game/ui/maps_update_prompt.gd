extends Control
class_name MapsUpdatePrompt

# A small "custom maps are available" card -- same shape as
# GameAssetUpdatePrompt (see that file), but for live-published custom
# levels (see CustomLevelCache) rather than built-in art. Download fetches
# every level's tiles/spawns/textures; Skip (this session's version of
# Cancel -- there's nothing partway through to actually abort once Download
# has started, same as GameAssetUpdatePrompt) leaves CustomLevelCache at
# zero cached levels, which every consumer (map_vote_view.gd/local_menu.gd)
# already treats as a normal empty state, not a broken one.

const UIStyle := preload("res://ui/ui_style.gd")

var _count := 0
var _status_label: Label
var _download_button: Button
var _skip_button: Button

## Safe to call either before or after this node enters the tree.
func setup(count: int) -> void:
	_count = count
	if _status_label:
		_status_label.text = _initial_text()

func _initial_text() -> String:
	if _count == 1:
		return "1 custom map is available. Download now?"
	return "%d custom maps are available. Download now?" % _count

func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP

	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.55)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(dim)

	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(center)

	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", UIStyle.panel_box(UIStyle.COLOR_NEUTRAL, 0.12, 0.3))
	panel.custom_minimum_size = Vector2(320, 0)
	center.add_child(panel)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 12)
	panel.add_child(box)

	box.add_child(UIStyle.title_label("MAPS AVAILABLE", 18))

	_status_label = UIStyle.subtitle_label(_initial_text())
	_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD
	box.add_child(_status_label)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	box.add_child(row)

	_skip_button = Button.new()
	_skip_button.text = "Skip"
	_skip_button.custom_minimum_size = Vector2(100, 40)
	UIStyle.style_back_button(_skip_button)
	_skip_button.pressed.connect(_on_skip_pressed)
	row.add_child(_skip_button)

	_download_button = Button.new()
	_download_button.text = "Download"
	_download_button.custom_minimum_size = Vector2(140, 40)
	UIStyle.style_button(_download_button, UIStyle.COLOR_ONLINE)
	_download_button.pressed.connect(_on_download_pressed)
	row.add_child(_download_button)

func _on_skip_pressed() -> void:
	CustomLevelCache.skip_download()
	queue_free()

func _on_download_pressed() -> void:
	_download_button.disabled = true
	_skip_button.disabled = true
	_status_label.text = "Downloading..."

	# Always go through download_all() -- this prompt is only ever shown when
	# CustomLevelCache.catalog_count > 0 (see main_menu.gd's own comment), so
	# there's always real work pending here even if is_ready already happens
	# to be true (the disk-cache fast path can set that early while a
	# new-or-edited entry is still unfetched). download_all() itself is a
	# cheap no-op if it's ever wrong about that.
	CustomLevelCache.levels_ready.connect(_on_download_finished, CONNECT_ONE_SHOT)
	CustomLevelCache.download_all()

func _on_download_finished() -> void:
	_status_label.text = "Updated -- new maps are live now."
	await get_tree().create_timer(1.2).timeout
	queue_free()
