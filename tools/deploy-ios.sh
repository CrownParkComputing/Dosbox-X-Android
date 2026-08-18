#!/usr/bin/env bash
# Build, sign, install and launch the iOS app on a connected device.
#
#   tools/deploy-ios.sh              build, install, launch, tail the log
#   tools/deploy-ios.sh --no-build   reuse the existing IPA
#   tools/deploy-ios.sh --launch     only relaunch what is already installed
#   tools/deploy-ios.sh --push-games ~/Downloads/dos-test-games/CKeen1
#
# RUN THIS FROM A REAL TERMINAL. The signing step prompts for the Apple ID
# password and a 2FA code by opening /dev/tty directly, so it cannot be driven
# from a pipe or from an agent's shell -- that is the one step nobody can
# automate away.
#
# Requirements, all already set up on this machine:
#   - docker, with the mobaiapp/iosbox image and the iosbox-sdk volume
#   - usbmuxd running (sudo pacman -S usbmuxd; sudo systemctl start usbmuxd)
#   - the MobAI desktop app running (it serves the API on 127.0.0.1:8686)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$REPO_ROOT/flutter_app"
OUT="$APP_DIR/build/iosbox"
IPA="$OUT/Runner.ipa"

IMAGE="${IOSBOX_IMAGE:-mobaiapp/iosbox:latest}"
SDK_VOLUME="${IOSBOX_SDK_VOLUME:-iosbox-sdk}"
ILOADER="${ILOADER:-$HOME/.mobai/bin/iloader-cli}"
MOBAI_API="${MOBAI_API:-http://127.0.0.1:8686}"
APPLE_ID="${APPLE_ID:-jonwhitt70@gmail.com}"

# The signed bundle id gets the team id appended by the signer.
BUNDLE_ID_BASE="com.dosboxmultiplatform.dosboxMultiplatform"
TEAM_ID="${TEAM_ID:-2U6QYSTQ2F}"
BUNDLE_ID="$BUNDLE_ID_BASE.$TEAM_ID"

DO_BUILD=1
DO_INSTALL=1
DO_LAUNCH=1
PUSH_GAMES=""

while [ $# -gt 0 ]; do
    case "$1" in
        --no-build)   DO_BUILD=0 ;;
        --no-install) DO_INSTALL=0 ;;
        --launch)     DO_BUILD=0; DO_INSTALL=0 ;;
        --push-games) PUSH_GAMES="$2"; shift ;;
        -h|--help)    sed -n '2,20p' "$0"; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
    shift
done

die() { echo "error: $*" >&2; exit 1; }

device_id() {
    "$ILOADER" devices 2>/dev/null \
        | awk 'NR>3 && $1 ~ /^[0-9A-F]{8}-/ {print $1; exit}'
}

DEVICE="${DEVICE:-$(device_id || true)}"
[ -n "$DEVICE" ] || die "no iOS device. Is usbmuxd running, and the iPad unlocked and trusted?"
echo "==> device $DEVICE"

# ---------------------------------------------------------------- build
if [ "$DO_BUILD" = 1 ]; then
    # An unparseable Info.plist does not warn: the plist just fails to load and
    # the app launches to a black screen with nothing in any log.
    echo "==> checking Info.plist"
    python3 -c 'import plistlib,sys; plistlib.load(open(sys.argv[1],"rb"))' \
        "$APP_DIR/ios/Runner/Info.plist" \
        || die "ios/Runner/Info.plist is not valid XML."

    docker volume inspect "$SDK_VOLUME" >/dev/null 2>&1 \
        || die "Docker volume '$SDK_VOLUME' not found - the iOS SDK is not registered."

    echo "==> building (iosbox)"
    docker run --rm \
        -v "$SDK_VOLUME:/root/.iosbox" \
        -v "$REPO_ROOT:/proj" \
        "$IMAGE" iosbox build /proj/flutter_app

    # The container runs as root and leaves everything it wrote root-owned,
    # which breaks the host Flutter and the repack below.
    echo "==> restoring file ownership"
    docker run --rm -v "$REPO_ROOT:/proj" alpine \
        chown -R "$(id -u):$(id -g)" /proj >/dev/null

    # iosbox ships native assets as bare .dylibs, which iOS refuses to install.
    "$REPO_ROOT/tools/fix-ipa-native-assets.sh"
fi

[ -f "$IPA" ] || die "no IPA at $IPA"

# ---------------------------------------------------------------- install
if [ "$DO_INSTALL" = 1 ]; then
    [ -t 0 ] || die "stdin is not a terminal; signing needs one for the Apple ID 2FA prompt."
    echo "==> signing and installing (Apple ID prompt follows)"
    # Free Apple IDs allow only 3 sideloaded apps per device and the profiles
    # last 7 days; ApplicationVerificationFailed here usually means that limit,
    # not a broken signature. Delete an app from the iPad and retry.
    "$ILOADER" sideload -i "$IPA" -e "$APPLE_ID" -d "$DEVICE"
fi

# ---------------------------------------------------------------- launch
if [ "$DO_LAUNCH" = 1 ]; then
    echo "==> launching via MobAI (debugger attached)"
    # These are debug/JIT Flutter builds: the Dart VM cannot start unless a
    # debugger is attached, so tapping the icon on the device always crashes
    # with "Could not call ptrace(PT_TRACE_ME)". MobAI's open_app with
    # debug:true is what attaches it.
    curl -sf "$MOBAI_API/api/v1/devices" >/dev/null \
        || die "MobAI API not responding at $MOBAI_API - start the MobAI app."

    python3 "$REPO_ROOT/tools/mobai_call.py" execute_dsl "$(cat <<JSON
{"device_id": "$DEVICE",
 "commands": "{\"version\":\"0.2\",\"steps\":[{\"action\":\"open_app\",\"bundle_id\":\"$BUNDLE_ID\",\"debug\":true,\"fresh\":true}]}"}
JSON
)"

    LOG="/tmp/mobai/debug/$BUNDLE_ID.log"
    echo "==> log: $LOG"
    sleep 5
    if [ -f "$LOG" ]; then
        grep -iE "Dart execution mode|VM service|EXCEPTION|overflow|FATAL|Terminating" "$LOG" | tail -20 || true
    fi
fi

if [ -n "$PUSH_GAMES" ]; then
    echo
    echo "==> games at $PUSH_GAMES"
    echo "    iOS has no command-line drop into an app container. Copy the folder"
    echo "    to the iPad through Files (On My iPad > Dosbox Multiplatform), which"
    echo "    exists only because Info.plist sets UIFileSharingEnabled."
fi

echo "==> done"
