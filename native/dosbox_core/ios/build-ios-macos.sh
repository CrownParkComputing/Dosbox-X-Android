#!/usr/bin/env bash
# Builds libdosboxcore for iOS arm64, natively on macOS, and installs it as
# flutter_app/ios/Frameworks/libdosboxcore.framework -- the path
# RetroDosboxNativePaths._iosFrameworkLibrary dlopens at runtime.
#
#   native/dosbox_core/ios/build-ios-macos.sh              # everything
#   SKIP_SDL=1 native/dosbox_core/ios/build-ios-macos.sh   # relink the core
#
# WHY THIS EXISTS, alongside build-ios.sh. That script cross-builds from Linux
# through the mobaiapp/iosbox container, which needs Docker and an iOS SDK
# extracted by hand into a named volume. Neither exists on a Mac, and neither
# can exist in Xcode Cloud -- so on the two machines that actually ship this
# app, the core could not be built at all.
#
# Everything long about the container script is Linux not being a Mac: clang
# shims on a private PATH, ld64.lld told its platform explicitly, a named
# libclang_rt.ios.a, llvm-ar because GNU ar cannot index Mach-O. A Mac has
# Apple's own toolchain, so all of that simply goes away. What is kept is the
# hard-won part: WHICH configure flags DOSBox-X needs, and why.
#
# Requires the DOSBox-X source (default ~/dosbox-x-src):
#   git clone --depth 1 https://github.com/joncampbell123/dosbox-x.git ~/dosbox-x-src
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../../.." && pwd)"
CORE="$REPO_ROOT/native/dosbox_core"
BUILD="$CORE/ios/build-macos"
PREFIX="$BUILD/prefix"
DOSBOX_X_SRC="${DOSBOX_X_SRC:-$HOME/dosbox-x-src}"

DEPLOYMENT_TARGET="${DEPLOYMENT_TARGET:-13.0}"
SDL_TAG="${SDL_TAG:-release-2.30.9}"
LIBPNG_TAG="${LIBPNG_TAG:-v1.6.44}"
JOBS="${JOBS:-$(sysctl -n hw.ncpu)}"

for tool in cmake ninja autoconf automake; do
    command -v "$tool" >/dev/null 2>&1 || {
        echo "error: $tool not found -- brew install cmake ninja autoconf automake libtool" >&2
        exit 1
    }
done

[ -d "$DOSBOX_X_SRC" ] || {
    echo "error: no DOSBox-X source at $DOSBOX_X_SRC" >&2
    echo "       git clone --depth 1 https://github.com/joncampbell123/dosbox-x.git $DOSBOX_X_SRC" >&2
    exit 1
}

IOS_SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
TRIPLE="arm64-apple-ios$DEPLOYMENT_TARGET"
IOS_CFLAGS="-target $TRIPLE -isysroot $IOS_SDK -fPIC -O2 -I$PREFIX/include"

echo "==> SDK: $IOS_SDK"
mkdir -p "$BUILD" "$PREFIX"

# ---------------------------------------------------------------- stage 1
# No compiler/linker overrides: CMAKE_SYSTEM_NAME + CMAKE_OSX_SYSROOT is all
# Apple's clang needs, and the ARC probe that had to be pre-seeded for the
# cross-linker passes honestly here.
if [ "${SKIP_SDL:-0}" != "1" ]; then
    echo "==> SDL2 $SDL_TAG for iOS"
    [ -d "$BUILD/SDL" ] || git clone --depth 1 --branch "$SDL_TAG" \
        https://github.com/libsdl-org/SDL.git "$BUILD/SDL"
    cmake -S "$BUILD/SDL" -B "$BUILD/sdl-build" -G Ninja \
        -DCMAKE_SYSTEM_NAME=iOS \
        -DCMAKE_OSX_ARCHITECTURES=arm64 \
        -DCMAKE_OSX_SYSROOT=iphoneos \
        -DCMAKE_OSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET" \
        -DCMAKE_INSTALL_PREFIX="$PREFIX" \
        -DSDL_SHARED=OFF -DSDL_STATIC=ON \
        -DCMAKE_BUILD_TYPE=Release
    cmake --build "$BUILD/sdl-build" -j "$JOBS"
    cmake --install "$BUILD/sdl-build"

    # libpng is NOT optional, whatever --disable-screenshots suggests:
    # configure hard-errors with "Can't find libpng" before it ever consults
    # enable_screenshots. zlib comes from the SDK itself (libz.tbd).
    echo "==> libpng $LIBPNG_TAG for iOS"
    [ -d "$BUILD/libpng" ] || git clone --depth 1 --branch "$LIBPNG_TAG" \
        https://github.com/pnggroup/libpng.git "$BUILD/libpng"
    cmake -S "$BUILD/libpng" -B "$BUILD/png-build" -G Ninja \
        -DCMAKE_SYSTEM_NAME=iOS \
        -DCMAKE_OSX_ARCHITECTURES=arm64 \
        -DCMAKE_OSX_SYSROOT=iphoneos \
        -DCMAKE_OSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET" \
        -DCMAKE_INSTALL_PREFIX="$PREFIX" \
        -DPNG_SHARED=OFF -DPNG_STATIC=ON \
        -DPNG_TESTS=OFF -DPNG_TOOLS=OFF \
        -DPNG_FRAMEWORK=OFF -DPNG_ARM_NEON=off \
        -DCMAKE_BUILD_TYPE=Release
    cmake --build "$BUILD/png-build" -j "$JOBS"
    cmake --install "$BUILD/png-build"
fi

[ -f "$PREFIX/lib/libSDL2.a" ] || { echo "error: SDL2 did not install" >&2; exit 1; }
[ -f "$PREFIX/lib/libpng16.a" ] || { echo "error: libpng did not install" >&2; exit 1; }

# ---------------------------------------------------------------- stage 2
DBX="$BUILD/dosbox-x"
if [ ! -d "$DBX" ]; then
    echo "==> cloning DOSBox-X source (the checkout is never modified)"
    git clone -q "$DOSBOX_X_SRC" "$DBX"
fi
cd "$DBX"

# configure.ac cannot tell iOS from macOS on its own -- both are *-*-darwin* --
# so this must run BEFORE autogen turns configure.ac into configure.
echo "==> teaching configure.ac about iOS"
python3 "$CORE/ios/apply-ios-configure.py" "$DBX"
python3 "$CORE/ios/apply-ios-source.py" "$DBX"
# The frame-publish hook and dosbox_x_main entry the Linux core uses. Not
# iOS-specific, but just as required: without it there is no way into the
# mainloop and no way for a finished frame to reach the bridge.
python3 "$CORE/linux/apply-bridge-hook.py" "$DBX"

[ -f configure ] || ./autogen.sh

export PATH="$PREFIX/bin:$PATH"          # so sdl2-config is found
export CC="$(xcrun --sdk iphoneos -f clang)"
export CXX="$(xcrun --sdk iphoneos -f clang++)"
export AR="$(xcrun --sdk iphoneos -f ar)"
export RANLIB="$(xcrun --sdk iphoneos -f ranlib)"
export NM="$(xcrun --sdk iphoneos -f nm)"
export CFLAGS="$IOS_CFLAGS"
export CXXFLAGS="$IOS_CFLAGS -std=gnu++14"
# automake compiles .mm through OBJCXX/OBJCXXFLAGS, which configure.ac sets
# independently of CXXFLAGS. Without these every .mm builds for the HOST, and
# that is not a loud failure: with __APPLE__ undefined,
# physfs_platform_apple.mm compiles to an EMPTY object and the problem only
# surfaces at link as ___PHYSFS_platformCalcBaseDir undefined.
export OBJCXX="$CXX"
export OBJCXXFLAGS="$IOS_CFLAGS -std=gnu++14"
export OBJC="$CC"
export OBJCFLAGS="$IOS_CFLAGS"
export LDFLAGS="-target $TRIPLE -isysroot $IOS_SDK -L$PREFIX/lib"
export SDL2_CONFIG="$PREFIX/bin/sdl2-config"
# configure's SDL2 test is literally `test -n "$SDL2_LIBS"`, normally filled in
# by pkg-config. Setting the precious variables from our own sdl2-config is the
# supported override and skips the probe entirely.
export SDL2_CFLAGS="$(sh "$SDL2_CONFIG" --cflags)"
export SDL2_LIBS="$(sh "$SDL2_CONFIG" --static-libs)"
export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig"
export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig"   # nothing from the host

if [ ! -f config.h ]; then
    echo "==> cross-configuring DOSBox-X for iOS"
    # --host is what puts autoconf in cross mode: it stops running the binaries
    # it builds, which are iOS and cannot execute here.
    #
    # Everything optional is off. None of ffmpeg/fluidsynth/slirp/glib/ncurses/
    # X11 exists on iOS, and letting configure hunt for them only produces
    # half-detections against HOST libraries -- hence the empty
    # PKG_CONFIG_LIBDIR above.
    ./configure \
        --host=aarch64-apple-darwin \
        `# --build must DIFFER from --host or autoconf decides this is a` \
        `# native build and runs the iOS binaries it compiles. On Linux the` \
        `# build triple was x86_64-linux so that never came up; on an Apple` \
        `# Silicon Mac the build machine IS aarch64-apple-darwin, cross mode` \
        `# never engaged, and configure hung forever on "checking whether we` \
        `# are cross compiling".` \
        --build=x86_64-apple-darwin \
        --enable-sdl2 \
        --disable-sdl \
        --disable-opengl \
        `# iOS forbids the JIT these need, and refuses to build them anyway:` \
        `# dynamic_alloc_common.h calls mach_vm_remap through <mach/mach_vm.h>,` \
        `# which the iPhoneOS SDK ships purely to say "mach_vm.h unsupported".` \
        `# The interpreter is the only core iOS can run.` \
        --disable-dynamic-core \
        --disable-dynamic-x86 \
        --disable-dynrec \
        --disable-printer \
        --disable-libfluidsynth \
        --disable-libslirp \
        --disable-avcodec \
        --without-x \
        --prefix="$PREFIX"
fi

echo "==> building DOSBox-X"
# `|| true` on purpose. We do not want an executable at all -- the bridge hook
# renames main to dosbox_x_main so the emulator can be a library, so linking
# dosbox-x necessarily fails with "_main undefined". Everything up to that link
# is what matters, and the archives are verified below rather than trusting
# make's exit status.
make -j "$JOBS" || true

# ---------------------------------------------------------------- stage 3
ARCHIVES="$(find "$DBX/src" -name '*.a' | sort | tr '\n' ' ')"
ARCHIVE_COUNT="$(find "$DBX/src" -name '*.a' | wc -l | tr -d ' ')"
echo "==> $ARCHIVE_COUNT archives"
[ "$ARCHIVE_COUNT" -ge 20 ] || {
    echo "error: only $ARCHIVE_COUNT archives built -- the emulator did not compile" >&2
    exit 1
}

OUT="$CORE/ios/build-macos/out"
mkdir -p "$OUT"

echo "==> compiling the bridge"
"$CXX" -c $IOS_CFLAGS -std=gnu++14 \
    -o "$OUT/dosbox_bridge.o" \
    "$CORE/bridge/dosbox_bridge.cpp" \
    -I"$CORE/bridge" -I"$DBX" -I"$DBX/include" -I"$DBX/src" \
    -I"$PREFIX/include" -I"$PREFIX/include/SDL2" -D_REENTRANT

# Not optional: the bridge calls audio_backend_get_level() directly
# (dosbox_core_get_audio_level), so the link fails on the undefined symbol
# without this object. The mixer's own hooks are weak and would tolerate its
# absence; the bridge's call is not.
echo "==> compiling the audio backend (ios/CoreAudio)"
"$CC" -c $IOS_CFLAGS -fobjc-arc \
    -o "$OUT/audio_backend_ios.o" \
    "$CORE/bridge/audio_backend_ios.m" \
    -I"$CORE/bridge"

echo "==> linking libdosboxcore"
# -all_load for the same reason as on Linux: nothing in the bridge references
# most of the emulator directly, so without it the linker discards nearly all
# of it. The install name must match where the app loads it from -- a framework
# inside the bundle, because iOS validates every nested Mach-O in Frameworks/
# and rejects a bare dylib at install (ApplicationVerificationFailed).
"$CC" -dynamiclib \
    -target "$TRIPLE" -isysroot "$IOS_SDK" \
    -install_name "@rpath/libdosboxcore.framework/libdosboxcore" \
    -o "$OUT/libdosboxcore" \
    "$OUT/dosbox_bridge.o" "$OUT/audio_backend_ios.o" \
    -Wl,-all_load $ARCHIVES "$DBX"/src/*.o \
    "$PREFIX/lib/libSDL2.a" "$PREFIX/lib/libpng16.a" -lz \
    -framework CoreFoundation -framework CoreMIDI -framework AudioToolbox \
    -framework UIKit -framework Foundation -framework CoreGraphics \
    -framework CoreVideo -framework CoreAudio -framework AVFoundation \
    -framework CoreBluetooth -framework CoreMotion -framework Metal \
    -framework OpenGLES -framework QuartzCore \
    -weak_framework GameController -weak_framework CoreHaptics \
    -lpthread -lm \
    -lc++ -lc++abi -liconv

echo "==> checking the ABI is exported"
"$NM" --defined-only "$OUT/libdosboxcore" > "$OUT/exported.syms"
missing=0
for sym in $(grep -oE '\bdosbox_core_[a-z_]+\(' "$CORE/bridge/dosbox_bridge.h" \
             | tr -d '(' | sed 's/^/_/' | sort -u); do
    grep -q " $sym\$" "$OUT/exported.syms" || { echo "    MISSING: $sym"; missing=1; }
done
[ "$missing" = 0 ] || { echo "error: the C ABI is incomplete" >&2; exit 1; }

# ---------------------------------------------------------------- stage 4
# Installed as a framework, committed, and embedded by Xcode -- NOT injected
# into the IPA afterwards. Post-build repacking cannot work under Xcode Cloud,
# which builds and uploads the IPA itself with nothing in between.
DEST="$REPO_ROOT/flutter_app/ios/Frameworks/libdosboxcore.framework"
echo "==> installing $DEST"
rm -rf "$DEST"
mkdir -p "$DEST"
cp "$OUT/libdosboxcore" "$DEST/libdosboxcore"
cat > "$DEST/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key><string>en</string>
	<key>CFBundleExecutable</key><string>libdosboxcore</string>
	<key>CFBundleIdentifier</key><string>com.crownpark.libdosboxcore</string>
	<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
	<key>CFBundleName</key><string>libdosboxcore</string>
	<key>CFBundlePackageType</key><string>FMWK</string>
	<key>CFBundleShortVersionString</key><string>1.0</string>
	<key>CFBundleVersion</key><string>1</string>
	<key>CFBundleSupportedPlatforms</key><array><string>iPhoneOS</string></array>
	<key>MinimumOSVersion</key><string>$DEPLOYMENT_TARGET</string>
</dict>
PLIST
echo "</plist>" >> "$DEST/Info.plist"
plutil -lint "$DEST/Info.plist" >/dev/null

echo "==> done"
ls -lh "$DEST/libdosboxcore"
vtool -show-build "$DEST/libdosboxcore" | grep -E "platform|minos"
