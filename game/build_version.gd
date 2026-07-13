class_name BuildVersion

# Stamped by .github/workflows/build.yml right before export -- it rewrites
# the 0 below to the current $GITHUB_RUN_NUMBER, which is also exactly what
# each GitHub Release is tagged as ("build-<run number>"), so a running
# client can compare this constant directly against the latest release's tag
# to know if it's out of date. Stays 0 in every local/dev build (never
# stamped outside CI), which UpdateChecker treats as "never offer to
# update a dev build".
const BUILD_NUMBER := 0
