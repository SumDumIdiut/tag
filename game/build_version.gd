class_name BuildVersion

# The version this release represents -- bumped by hand as part of whatever
# commit ships a release-worthy change, not auto-generated. How many
# segments change (not just the last one) signals how big the change is:
#   - tiny/small fix:  bump the 4th segment   (0.1.1   -> 0.1.1.1)
#   - normal build:    bump the 3rd segment   (0.1.1   -> 0.1.2)   <- default
#   - large update:    bump the 2nd, drop the rest (0.1.2 -> 0.2)
#   - final release:   MAJOR alone            ("1")
# UpdateChecker compares this against release tags component-wise (missing
# trailing segments count as 0), so any of those forms sort correctly
# against each other regardless of length.
const VERSION := "0.1.2"

# Flipped true -> false by CI (see .github/workflows/build.yml's "Stamp
# build" step) on every real release build. Stays true in every local/dev
# export (never touched outside CI), which UpdateChecker treats as "never
# offer to update a dev build" -- kept separate from VERSION itself so a
# local build doesn't need its own fake version number just to get that
# behavior.
const IS_DEV_BUILD := true

## Parses "0.1.2" (1-4 dot-separated segments, extra segments ignored) into
## exactly 4 ints, missing trailing segments treated as 0 -- lets "0.2" and
## "0.1.9.9" compare correctly against each other despite different lengths.
static func parse(version: String) -> Array:
	var parts := version.split(".")
	var result := [0, 0, 0, 0]
	for i in range(mini(parts.size(), 4)):
		if parts[i].is_valid_int():
			result[i] = int(parts[i])
	return result

## 1 if a > b, -1 if a < b, 0 if equal.
static func compare(a: String, b: String) -> int:
	var pa := parse(a)
	var pb := parse(b)
	for i in range(4):
		if pa[i] != pb[i]:
			return 1 if pa[i] > pb[i] else -1
	return 0
