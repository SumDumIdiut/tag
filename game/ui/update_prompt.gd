extends Control
class_name UpdatePrompt

# A small "a new build is available" card, shown over whatever screen calls
# setup() when UpdateChecker reports one. Update Now downloads TagSetup.exe
# (see installer/tag.iss -- a proper per-user Inno Setup installer, not a
# bare exe) and runs it silently with /CLOSEAPPLICATIONS /RESTARTAPPLICATIONS,
# which closes this running process, replaces the installed files, and
# relaunches it -- the installer itself now owns the whole "a running exe
# can't overwrite itself" dance that a hand-rolled wait-for-exit .bat script
# used to (see git history: this file used to write/launch one directly).
# Skip just frees this node; the check runs again next launch.

const UIStyle := preload("res://ui/ui_style.gd")

var _download_url := ""
var _version := 0
var _status_label: Label
var _update_button: Button
var _skip_button: Button

## Safe to call either before or after this node enters the tree -- callers
## typically do `add_child(prompt); prompt.setup(...)`, but nothing here
## depends on that order.
func setup(version: int, download_url: String) -> void:
	_version = version
	_download_url = download_url
	if _status_label:
		_status_label.text = "Build %d is available." % version

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

	var title := UIStyle.title_label("UPDATE AVAILABLE", 20)
	box.add_child(title)

	var initial_text := "Build %d is available." % _version if _version > 0 else "A newer build is available."
	_status_label = UIStyle.subtitle_label(initial_text)
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
	_skip_button.pressed.connect(func(): queue_free())
	row.add_child(_skip_button)

	_update_button = Button.new()
	_update_button.text = "Update Now"
	_update_button.custom_minimum_size = Vector2(140, 40)
	UIStyle.style_button(_update_button, UIStyle.COLOR_ONLINE)
	_update_button.pressed.connect(_on_update_pressed)
	row.add_child(_update_button)

func _on_update_pressed() -> void:
	_update_button.disabled = true
	_skip_button.disabled = true
	_status_label.text = "Downloading update..."

	var req := HTTPRequest.new()
	add_child(req)
	req.request_completed.connect(_on_download_completed)
	var err := req.request(_download_url)
	if err != OK:
		_status_label.text = "Couldn't start the download -- try again later."
		_update_button.disabled = false
		_skip_button.disabled = false

func _on_download_completed(result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	if result != HTTPRequest.RESULT_SUCCESS or response_code != 200 or body.is_empty():
		_status_label.text = "Update download failed -- try again later."
		_update_button.disabled = false
		_skip_button.disabled = false
		return

	var installer_path := OS.get_cache_dir().path_join("TagSetup.exe")
	var f := FileAccess.open(installer_path, FileAccess.WRITE)
	if f == null:
		_status_label.text = "Couldn't save the update -- try again later."
		_update_button.disabled = false
		_skip_button.disabled = false
		return
	f.store_buffer(body)
	f.close()

	# /CLOSEAPPLICATIONS makes the installer itself close this running
	# Tag.exe (it holds its own exe file open, which Inno's RestartManager
	# check detects) so its file can actually be overwritten -- see
	# installer/tag.iss's CloseApplications directive, which is what
	# enables this switch to do anything under /VERYSILENT. The relaunch
	# after that is the installer's own unconditional [Run] entry, not
	# RestartApplications (confirmed live that doesn't reliably relaunch a
	# plain exe -- see the .iss file's own comment).
	var pid := OS.create_process(installer_path, [
		"/VERYSILENT", "/SUPPRESSMSGBOXES", "/NORESTART", "/CLOSEAPPLICATIONS",
	])
	if pid == -1:
		_status_label.text = "Couldn't start the update -- try again later."
		_update_button.disabled = false
		_skip_button.disabled = false
		return

	get_tree().quit()
