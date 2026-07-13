extends Control
class_name UpdatePrompt

# A small "a new build is available" card, shown over whatever screen calls
# setup() when UpdateChecker reports one. Update Now downloads the release
# asset for this exe and hands off to a tiny generated .bat (Windows-only,
# matching this project's only export target) that waits for this process to
# exit, swaps the new exe into place, and relaunches it -- the standard
# workaround for "a running exe can't overwrite itself." Skip just frees this
# node; the check runs again next launch.

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

	var exe_path := OS.get_executable_path()
	var dir := exe_path.get_base_dir()
	var exe_file := exe_path.get_file()
	var tmp_path := dir.path_join(exe_file + ".update")
	var f := FileAccess.open(tmp_path, FileAccess.WRITE)
	if f == null:
		_status_label.text = "Couldn't save the update -- try again later."
		_update_button.disabled = false
		_skip_button.disabled = false
		return
	f.store_buffer(body)
	f.close()

	if not _spawn_swap_and_relaunch(exe_path, tmp_path):
		_status_label.text = "Couldn't apply the update -- try again later."
		_update_button.disabled = false
		_skip_button.disabled = false
		return

	get_tree().quit()

## Writes and launches a one-shot batch script that waits for this process
## to exit, replaces the running exe with the freshly-downloaded one, then
## relaunches it and deletes itself.
func _spawn_swap_and_relaunch(exe_path: String, tmp_path: String) -> bool:
	var pid := OS.get_process_id()
	var win_exe := exe_path.replace("/", "\\")
	var win_tmp := tmp_path.replace("/", "\\")
	var bat_path := exe_path.get_base_dir().path_join(exe_path.get_file() + ".updater.bat")

	var lines := [
		"@echo off",
		":wait",
		"tasklist /FI \"PID eq %d\" 2>NUL | find \"%d\" >NUL" % [pid, pid],
		"if not errorlevel 1 (",
		"  timeout /t 1 /nobreak >NUL",
		"  goto wait",
		")",
		"move /Y \"%s\" \"%s\" >NUL" % [win_tmp, win_exe],
		"start \"\" \"%s\"" % win_exe,
		"del \"%~f0\"",
	]
	var bf := FileAccess.open(bat_path, FileAccess.WRITE)
	if bf == null:
		return false
	bf.store_string("\r\n".join(lines) + "\r\n")
	bf.close()

	return OS.create_process(bat_path.replace("/", "\\"), []) != -1
