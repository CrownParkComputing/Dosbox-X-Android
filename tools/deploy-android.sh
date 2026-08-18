#!/usr/bin/env bash
# Build the DosboxMultiplatform Android app and install it on a connected
# Android device.
#
#   tools/deploy-android.sh                  # full pipeline: build, install, launch
#   tools/deploy-android.sh --no-build      # reuse the existing APK
#   tools/deploy-android.sh --launch        # only relaunch what's already installed
#   tools/deploy-android.sh --release       # build a release AAB instead of debug APK
#   tools/deploy-android.sh --with-core     # also build libdosboxcore.so first
#
# This is the Android sibling of tools/deploy-ios.sh. The native core
# (libdosboxcore.so) is built by native/dosbox_core/android/build.sh; with
# --with-core this script runs that build first, otherwise it assumes the
# .so files are already in jniLibs.
#
# The .so files are gitignored (build artifacts, large, rebuilt per machine
# -- see docs/NATIVE_BUILD.md). The deploy verifies they are present before
# invoking flutter, so a stale checkout with empty jniLibs fails loudly
# instead of shipping an APK that quietly falls back to the stub.
#
# RUN THIS FROM A REAL TERMINAL. The first time the device sees the host, it
# pops up a "Allow USB debugging?" dialog. The user must tap Allow; nothing
# the agent can do from a shell makes that decision.
#
# Requirements, all already set up on this machine:
#   - ANDROID_HOME / NDK 26+ with the prebuilt libSDL2.so and libpng16.so in
#     native/dosbox_core/android/.tmp/lib-<abi>/
#   - the device on USB with USB debugging enabled (Settings > Developer
#     options > USB debugging), or at a known TCP/IP adb endpoint
#   - `adb` in $PATH
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$REPO_ROOT/flutter_app"
OUT="$APP_DIR/build/app/outputs/flutter-apk"
APK="$OUT/app-debug.apk"
AAB="$APP_DIR/build/app/outputs/bundle/release/app-release.aab"
CORE_BUILD="$REPO_ROOT/native/dosbox_core/android/build.sh"

# The Gradle build picks the ABIs from build.gradle.kts. Keep this list in
# sync with whatever is declared there; a mismatch produces an APK that
# lacks .so files for the device's ABI.
DEFAULT_ABIS=("arm64-v8a" "x86_64")

DO_BUILD=1
DO_INSTALL=1
DO_LAUNCH=1
WITH_CORE=0
RELEASE=0

for arg in "$@"; do
    case "$arg" in
        --no-build) DO_BUILD=0 ;;
        --no-install) DO_INSTALL=0 ;;
        --launch) DO_BUILD=0; DO_INSTALL=0 ;;
        --with-core) WITH_CORE=1 ;;
        --release) RELEASE=1 ;;
        --help|-h)
            sed -n '2,20p' "${BASH_SOURCE[0]}"
            exit 0
            ;;
        *) echo "error: unknown option: $arg" >&2; exit 2 ;;
    esac
done

[ "$DO_BUILD" = 1 ] && [ ! -f "$APK" ] && [ ! -f "$AAB" ] && {
    echo "==> no APK found; building first"
    DO_BUILD=1
}
[ "$DO_BUILD" = 1 ] && DO_INSTALL=1

# ---------------------------------------------------------------- prerequisites
ADB="${ADB:-adb}"
command -v "$ADB" >/dev/null || { echo "error: adb not in PATH" >&2; exit 1; }
FLUTTER="${FLUTTER:-/home/jon/development/flutter/bin/flutter}"
[ -x "$FLUTTER" ] || { echo "error: flutter not at $FLUTTER" >&2; exit 1; }

# ---------------------------------------------------------------- adb connect
DEV="${RETROID_SERIAL:-${ANDROID_SERIAL:-}}"
if [ -n "$DEV" ]; then
    echo "==> connecting to $DEV"
    "$ADB" connect "$DEV" || true
fi

if ! "$ADB" devices -l | grep -E '\bdevice\b' >/dev/null; then
    echo "error: no Android device visible to adb." >&2
    echo "       Plug in the retroid over USB, enable Developer options +" >&2
    echo "       USB debugging, and tap Allow on the host prompt." >&2
    echo "       Or set RETROID_SERIAL=host:port for a TCP/IP adb." >&2
    exit 1
fi

# ---------------------------------------------------------------- core build
# With --with-core, run native/dosbox_core/android/build.sh first. That
# script patches the DOSBox-X source, configures, builds, and copies
# libdosboxcore.so into flutter_app/android/app/src/main/jniLibs/<abi>/.
# Without --with-core, we just verify the .so files are already there.
if [ "$WITH_CORE" = 1 ]; then
    [ -x "$CORE_BUILD" ] || { echo "error: $CORE_BUILD not executable" >&2; exit 1; }
    echo "==> building native core"
    (cd "$REPO_ROOT" && "$CORE_BUILD")
fi

if [ "$DO_BUILD" = 1 ]; then
    # The .so files live in jniLibs/<abi>/ and are gitignored -- see
    # .gitignore: "flutter_app/android/app/src/main/jniLibs/**/*.so". A
    # fresh checkout has none, and shipping without them puts the app in
    # the stub fallback path. Fail loudly instead so the user sees the
    # cause rather than a confusing "stub core" banner on the device.
    #
    # Only require the ABIs that are actually populated in jniLibs. A
    # developer who built only arm64-v8a (the retroid) should not need
    # x86_64 to ship. The Gradle build's abiFilters still has to match
    # jniLibs -- build.gradle.kts declares arm64-v8a + x86_64, and if
    # those don't align the linker silently drops the missing ABI rather
    # than failing.
    present_abis=()
    for abi in "${DEFAULT_ABIS[@]}"; do
        if [ -d "$APP_DIR/android/app/src/main/jniLibs/$abi" ] \
           && [ -n "$(ls "$APP_DIR/android/app/src/main/jniLibs/$abi"/*.so 2>/dev/null)" ]; then
            present_abis+=("$abi")
        fi
    done
    if [ "${#present_abis[@]}" = 0 ]; then
        echo "error: no .so files in flutter_app/android/app/src/main/jniLibs/" >&2
        echo "       Re-run with --with-core to build them, or copy them in" >&2
        echo "       manually from native/dosbox_core/android/build/." >&2
        exit 1
    fi
    missing=0
    for abi in "${present_abis[@]}"; do
        for lib in libdosboxcore.so libSDL2.so libpng16.so; do
            if [ ! -f "$APP_DIR/android/app/src/main/jniLibs/$abi/$lib" ]; then
                echo "error: missing $APP_DIR/android/app/src/main/jniLibs/$abi/$lib" >&2
                missing=1
            fi
        done
    done
    if [ "$missing" = 1 ]; then
        echo "       Re-run with --with-core to build them, or copy them in" >&2
        echo "       manually from native/dosbox_core/android/build/." >&2
        exit 1
    fi
    echo "==> jniLibs ABIs: ${present_abis[*]}"
fi

# ---------------------------------------------------------------- build
if [ "$DO_BUILD" = 1 ]; then
    if [ "$RELEASE" = 1 ]; then
        echo "==> building release AAB"
        (cd "$APP_DIR" && "$FLUTTER" build appbundle --release)
        [ -f "$AAB" ] || { echo "error: build did not produce $AAB" >&2; exit 1; }
    else
        echo "==> building debug APK"
        (cd "$APP_DIR" && "$FLUTTER" build apk --debug)
        [ -f "$APK" ] || { echo "error: build did not produce $APK" >&2; exit 1; }
    fi
fi

# ---------------------------------------------------------------- install
if [ "$DO_INSTALL" = 1 ]; then
    PKG="com.dosboxmultiplatform.dosbox_multiplatform"
    if [ -f "$APK" ]; then
        echo "==> installing $APK"
        "$ADB" install -r "$APK"
    elif [ -f "$AAB" ]; then
        # AABs need bundle install. The host has bundletool?
        echo "warning: AAB install is not scripted here; sideload via Play Console" >&2
    fi
fi

# ---------------------------------------------------------------- launch
if [ "$DO_LAUNCH" = 1 ]; then
    PKG="com.dosboxmultiplatform.dosbox_multiplatform"
    echo "==> launching $PKG"
    "$ADB" shell am start -n "$PKG/.MainActivity"
fi

echo "==> done"
