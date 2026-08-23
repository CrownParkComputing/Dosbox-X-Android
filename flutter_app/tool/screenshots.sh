#!/usr/bin/env bash
# Captures the App Store screenshots from a booted simulator.
#
#   [SHOT_SEED=<dir>] tool/screenshots.sh [udid] [outdir]
#
# The images come out at the simulator's own pixel size, so run it on a device
# whose size Apple accepts -- iPhone 17 Pro Max (1320x2868) covers the 6.9"
# slot, and an iPad Pro 13" covers the tablet one.
set -euo pipefail

cd "$(dirname "$0")/.."

UDID="${1:-$(xcrun simctl list devices booted -j \
  | /usr/bin/python3 -c 'import json,sys
d=json.load(sys.stdin)["devices"]
for rt in d.values():
    for dev in rt:
        if dev.get("state")=="Booted": print(dev["udid"]); raise SystemExit')}"
OUT="${2:-$(pwd)/build/screenshots}"
BUNDLE_ID="${SHOT_BUNDLE_ID:-com.crownparkcomputing.dosboxretro}"
SEED="${SHOT_SEED:-}"

[ -n "$UDID" ] || { echo "no booted simulator, and no udid given" >&2; exit 1; }
mkdir -p "$OUT"
echo "simulator $UDID -> $OUT"

# --- Fixtures ---------------------------------------------------------------
# The BIOS is Sega copyright and is never bundled, so the screenshots that show
# a booted machine need it staged into the app's container at run time.
#
# It has to be staged by a SEPARATE PROCESS, running alongside the test, and
# that is not a style choice. `flutter drive` installs the app, and an install
# hands it a brand new data container -- so anything staged beforehand is gone,
# and the container's name is not known until it exists. Doing it from the
# driver does not work either: the driver receives its callbacks only after the
# test method has finished, so a seed triggered that way lands after every
# screenshot has already been taken.
#
# So: poll for the container, and copy the moment it appears. The test waits
# for the files rather than assuming them.
#
# Note it is the CONTENTS of SHOT_SEED that land in Documents -- point it at
# the folder CONTAINING Retro-Saturn/, not at Retro-Saturn/ itself.
seeder() {
  local last="" deadline=$((SECONDS + 600))
  while [ "$SECONDS" -lt "$deadline" ]; do
    local c
    c=$(xcrun simctl get_app_container "$UDID" "$BUNDLE_ID" data 2>/dev/null || true)
    if [ -n "$c" ] && [ "$c" != "$last" ]; then
      mkdir -p "$c/Documents"
      # ditto, not `cp -R`. The app creates Documents/<App>/{BIOS,Games} on
      # startup, so the destination usually exists already, and `cp -R src dst/`
      # NESTS into an existing directory rather than merging -- producing
      # Documents/<App>/<App>/BIOS while the app's own empty folders sit next
      # to it. The scan then finds nothing while a listing looks correct.
      local e
      for e in "$SEED"/*; do
        [ -e "$e" ] || continue
        ditto "$e" "$c/Documents/$(basename "$e")"
      done
      echo "seeded $c/Documents"
      last="$c"
    fi
    sleep 1
  done
}

if [ -n "$SEED" ] && [ -d "$SEED" ]; then
  seeder & SEEDER_PID=$!
  trap 'kill "$SEEDER_PID" 2>/dev/null || true' EXIT
else
  echo "no SHOT_SEED -- the app will come up with nothing staged"
fi

DEFINES=()
[ -n "${SHOT_SKIP_RUNNING:-}" ] && DEFINES+=(--dart-define=SKIP_RUNNING=true)

SHOT_UDID="$UDID" SHOT_DIR="$OUT" flutter drive \
  --driver=test_driver/screenshot_driver.dart \
  --target=integration_test/screenshots_test.dart \
  "${DEFINES[@]+"${DEFINES[@]}"}" \
  -d "$UDID"

echo
for f in "$OUT"/*.png; do
  [ -e "$f" ] || continue
  printf '%s %s\n' "$(sips -g pixelWidth -g pixelHeight "$f" \
    | awk '/pixelWidth|pixelHeight/{printf "%sx", $2}' | sed 's/x$//')" "$(basename "$f")"
done
