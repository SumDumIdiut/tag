extends RefCounted
class_name UILayoutOverrides

# Where UILayoutUpdater (see ui_layout_updater.gd) saves whatever it
# downloads from the relay's UI-layout manifest, and where UIStyle.
# apply_layout_override() reads it back at render time. Same "never
# hard-fail on missing custom content" rule GameAssetOverrides already
# follows -- a missing or corrupt override file just means "nothing
# overridden," never a crash. Deliberately a plain static-method class
# (not an autoload) matching GameAssetOverrides's own shape exactly --
# neither of these hold live state beyond a file on disk, so there's
# nothing an autoload instance would give either that a static lookup
# doesn't already.

const OVERRIDES_PATH := "user://ui_layout_overrides.json"

## {layout_key: {x, y, w, h, text}}, all fields optional per key -- loaded
## fresh on every call rather than cached in a static var, since this is
## only ever called a handful of times per screen at _ready() (never in a
## hot path), and staying file-backed means a fresh download mid-session
## (see UILayoutUpdater) is picked up by the next screen opened without
## needing an explicit cache-invalidation step anywhere.
static func _load_all() -> Dictionary:
	if not FileAccess.file_exists(OVERRIDES_PATH):
		return {}
	var f := FileAccess.open(OVERRIDES_PATH, FileAccess.READ)
	if f == null:
		return {}
	var parsed = JSON.parse_string(f.get_as_text())
	return parsed if typeof(parsed) == TYPE_DICTIONARY else {}

## The override dict for one element, or {} if this key has never been
## published/overridden -- every caller (UIStyle.apply_layout_override())
## already treats an empty/partial dict as "nothing to change" for
## whichever fields are missing.
static func get_override(layout_key: String) -> Dictionary:
	var all := _load_all()
	var entry = all.get(layout_key, {})
	return entry if typeof(entry) == TYPE_DICTIONARY else {}
