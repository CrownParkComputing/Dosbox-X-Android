#!/usr/bin/env bash
# Build the Play Store bundle for com.dosboxx.app.
#
# The Flutter launcher IS the app now - the old Java module is gone. This
# script exists because three details are easy to get wrong and each one is
# only visible after upload:
#
#   * --target-platform: without it the bundle also carries an armeabi-v7a
#     variant that holds Flutter but no libmain.so, so the emulator would be
#     missing on 32-bit devices.
#   * the signing key: the SAME key as the store app, taken from the
#     environment. A different key cannot update the listing, and users'
#     game libraries live under the app's own storage.
#   * versionCode: must exceed what is published (4) and the last source
#     bump (5). It comes from pubspec.yaml's "version: x.y.z+N".
#
# Usage:
#   export ANDROID_KEYSTORE_PATH=/path/to/store.jks
#   export ANDROID_KEYSTORE_PASSWORD=... ANDROID_KEY_ALIAS=... ANDROID_KEY_PASSWORD=...
#   tools/release.sh
#
# Without those variables it still builds, but comes out UNSIGNED (Play will
# reject it) - deliberately, rather than silently debug-signed.
set -euo pipefail

here="$(cd "$(dirname "$0")/.." && pwd)"
cd "$here/flutter_app"

if [ -z "${ANDROID_KEYSTORE_PATH:-}" ]; then
    echo "!! ANDROID_KEYSTORE_PATH is not set - the bundle will be UNSIGNED."
    echo "   Set the four ANDROID_* variables to sign with the store key."
fi

flutter build appbundle --release --target-platform android-arm64,android-x64

aab="build/app/outputs/bundle/release/app-release.aab"
manifest=$(find build -path "*merged_manifests*release*" -name AndroidManifest.xml | head -1)

echo
echo "=== $aab"
grep -oE '(package|versionCode|versionName|minSdkVersion|targetSdkVersion)="[^"]*"' \
    "$manifest" | sort -u
echo "--- ABIs:"
unzip -l "$aab" | grep -oE "base/lib/[a-z0-9_-]+" | sort -u
echo "--- emulator core present:"
unzip -l "$aab" | grep -c "libmain.so" | xargs -I{} echo "  libmain.so x{}"
