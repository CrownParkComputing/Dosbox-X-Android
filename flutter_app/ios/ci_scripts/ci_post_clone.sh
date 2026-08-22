#!/bin/sh
# Xcode Cloud post-clone step.
#
# Xcode Cloud's images have Xcode and CocoaPods but no Flutter, and it does not
# run `flutter build` -- it invokes xcodebuild on the Runner scheme directly.
# That only works if Flutter has already generated ios/Flutter/Generated.xcconfig,
# because the Runner target's "Thin Binary" build phase calls
# "$FLUTTER_ROOT/packages/flutter_tools/bin/xcode_backend.sh" and FLUTTER_ROOT is
# defined in that file. So: install Flutter, resolve packages, and let
# `--config-only` write the config the Xcode build needs.
#
# Apple runs this from the ci_scripts directory, which must sit next to the
# Xcode project -- hence ios/ci_scripts/ rather than the repo root.
set -e

# Pinned rather than tracking stable. A newer Flutter resolves newer transitive
# packages and rewrites pubspec.lock mid-build, so an untracked toolchain makes
# cloud builds differ from CI for reasons that have nothing to do with the
# commit being built. Same version Retro-C64 and Retro-Saturn pin.
FLUTTER_VERSION="${FLUTTER_VERSION:-3.47.1}"
FLUTTER_HOME="$HOME/flutter"

echo "--- installing Flutter $FLUTTER_VERSION"
git clone --depth 1 -b "$FLUTTER_VERSION" https://github.com/flutter/flutter.git "$FLUTTER_HOME"
export PATH="$FLUTTER_HOME/bin:$PATH"
flutter --version

APP_DIR="$CI_PRIMARY_REPOSITORY_PATH/flutter_app"
cd "$APP_DIR"

# The emulator core cannot be rebuilt here. It is DOSBox-X cross-configured
# with autotools against an SDL2 and libpng built for iOS -- minutes of work,
# from a source tree that lives outside this repository. It is committed for
# exactly that reason, so fail clearly if it is absent rather than producing an
# app that installs and then reports "Stub core: libdosboxcore not found".
#
# It is embedded by Xcode's Embed Frameworks phase, NOT injected into the IPA
# afterwards. Post-build repacking cannot work here: Xcode Cloud builds the IPA
# and uploads it with nothing in between.
CORE="ios/Frameworks/libdosboxcore.framework/libdosboxcore"
if [ ! -f "$CORE" ]; then
  echo "error: missing $CORE -- build it with" >&2
  echo "       native/dosbox_core/ios/build-ios-macos.sh and commit the result" >&2
  exit 1
fi

echo "--- resolving packages"
flutter precache --ios
flutter pub get

echo "--- generating the Xcode config Flutter's build phases rely on"
flutter build ios --release --no-codesign --config-only

cd ios
if [ -f Podfile ]; then
  echo "--- pod install"
  pod install --repo-update
else
  echo "note: no Podfile -- plugins resolve via Swift Package Manager"
fi

echo "--- ready for xcodebuild"
