#!/usr/bin/env bash
# Runs INSIDE the dosbox-iosbox container. Host entry point: ios/build-ios.sh
#
# Two stages:
#   1. SDL2 for arm64-ios, installed into a prefix in the build tree. Slow, and
#      only needs redoing when SDL_TAG changes -- pass SKIP_SDL=1 to skip.
#   2. DOSBox-X cross-configured against that SDL2, then the bridge linked
#      against the result as libdosboxcore.dylib.
#
# The toolchain incantations below are not guessable; they are the ones worked
# out for Amiga-Retro's core (uae4arm2026p/native/ios/build-core-ios.sh) and the
# comments explaining WHY each is needed are kept deliberately.
set -euo pipefail

PROJ="${PROJ:-/proj}"
CORE="$PROJ/native/dosbox_core"
BUILD="$CORE/ios/build"
PREFIX="$BUILD/prefix"

IOSBOX_ROOT="${IOSBOX_ROOT:-/root/.iosbox}"
IOS_SDK="${IOS_SDK:-$IOSBOX_ROOT/sdk/darwin.artifactbundle/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS.sdk}"
DEPLOYMENT_TARGET="${DEPLOYMENT_TARGET:-13.0}"
SDL_TAG="${SDL_TAG:-release-2.30.9}"
LIBPNG_TAG="${LIBPNG_TAG:-v1.6.44}"

# iosbox keeps its Apple binutil shims (install_name_tool, otool, libtool,
# dsymutil) out of the default PATH. CMake's Objective-C language check looks
# for install_name_tool by name and fails configure without it.
IOSBOX_SHIMS="${IOSBOX_SHIMS:-/usr/local/lib/iosbox/shims}"
export PATH="$IOSBOX_SHIMS:$PATH"

# Linking Mach-O needs ld64.lld, told the platform explicitly: the host default
# linker cannot produce iOS binaries at all, so without this every try_link
# probe fails and SDL concludes the platform has no threads and no dlopen.
IOS_LD="${IOS_LD:-$IOSBOX_ROOT/sdk/darwin.artifactbundle/toolset/bin/ld64.lld}"
# compiler-rt's iOS builtins carry __clear_cache and __isPlatformVersionAtLeast
# (the latter backs ObjC @available, which SDL's UIKit code uses). clang adds
# this automatically on a Mac; cross-compiling, it has to be named.
IOS_BUILTINS="${IOS_BUILTINS:-$IOSBOX_ROOT/sdk/darwin.artifactbundle/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/clang/17/lib/darwin/libclang_rt.ios.a}"
IOS_LINK_FLAGS="-fuse-ld=$IOS_LD -Wl,-arch,arm64 -Wl,-platform_version,ios,${DEPLOYMENT_TARGET}.0,16.0.0 -Wl,-adhoc_codesign $IOS_BUILTINS"

[ -d "$IOS_SDK" ] || {
    echo "error: no iOS SDK at $IOS_SDK" >&2
    echo "       the iosbox-sdk volume is not mounted, or the SDK was never registered" >&2
    exit 1
}

mkdir -p "$BUILD" "$PREFIX"

TRIPLE="arm64-apple-ios$DEPLOYMENT_TARGET"
IOS_CFLAGS="-target $TRIPLE -isysroot $IOS_SDK -fPIC -O2 -I$PREFIX/include"

# ---------------------------------------------------------------- stage 1
if [ "${SKIP_SDL:-0}" != "1" ]; then
    echo "==> SDL2 $SDL_TAG for iOS"
    [ -d "$BUILD/SDL" ] || git clone --depth 1 --branch "$SDL_TAG" \
        https://github.com/libsdl-org/SDL.git "$BUILD/SDL"

    cmake -S "$BUILD/SDL" -B "$BUILD/sdl-build" -G Ninja \
        -DCMAKE_SYSTEM_NAME=iOS \
        -DCMAKE_OSX_ARCHITECTURES=arm64 \
        -DCMAKE_OSX_SYSROOT="$IOS_SDK" \
        -DCMAKE_OSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET" \
        -DCMAKE_C_COMPILER="$IOSBOX_SHIMS/clang" \
        -DCMAKE_CXX_COMPILER=/usr/bin/clang++ \
        -DCMAKE_C_COMPILER_TARGET="$TRIPLE" \
        -DCMAKE_CXX_COMPILER_TARGET="$TRIPLE" \
        -DCMAKE_OBJC_COMPILER="$IOSBOX_SHIMS/clang" \
        -DCMAKE_OBJC_COMPILER_TARGET="$TRIPLE" \
        -DCMAKE_EXE_LINKER_FLAGS="$IOS_LINK_FLAGS" \
        -DCMAKE_SHARED_LINKER_FLAGS="$IOS_LINK_FLAGS" \
        -DCMAKE_INSTALL_PREFIX="$PREFIX" \
        -DSDL_SHARED=OFF -DSDL_STATIC=ON \
        -DCMAKE_BUILD_TYPE=Release \
        `# The ARC probe compiles fine (exitCode 0) but CMake scores it as a` \
        `# failure: check_c_compiler_flag fails on matching output, and this` \
        `# cross-linker prints "Option '-ios_version_min' is not yet` \
        `# implemented" on EVERY link. Pre-seeding the cache skips the probe;` \
        `# the flag itself is genuinely supported, so this asserts a fact` \
        `# rather than hiding a problem.` \
        -DCOMPILER_SUPPORTS_FOBJC_ARC=1

    cmake --build "$BUILD/sdl-build"
    cmake --install "$BUILD/sdl-build"
fi

[ -f "$PREFIX/lib/libSDL2.a" ] || { echo "error: SDL2 did not install" >&2; exit 1; }

# libpng is NOT optional for DOSBox-X, whatever --disable-screenshots suggests:
# configure hard-errors with "Can't find libpng" when the header and library are
# missing, before it ever consults enable_screenshots. zlib comes from the iOS
# SDK itself (libz.tbd), so only png needs building.
if [ "${SKIP_SDL:-0}" != "1" ] || [ ! -f "$PREFIX/lib/libpng16.a" ]; then
    echo "==> libpng $LIBPNG_TAG for iOS"
    [ -d "$BUILD/libpng" ] || git clone --depth 1 --branch "$LIBPNG_TAG" \
        https://github.com/pnggroup/libpng.git "$BUILD/libpng"

    cmake -S "$BUILD/libpng" -B "$BUILD/png-build" -G Ninja \
        -DCMAKE_SYSTEM_NAME=iOS \
        -DCMAKE_OSX_ARCHITECTURES=arm64 \
        -DCMAKE_OSX_SYSROOT="$IOS_SDK" \
        -DCMAKE_OSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET" \
        -DCMAKE_C_COMPILER="$IOSBOX_SHIMS/clang" \
        -DCMAKE_C_COMPILER_TARGET="$TRIPLE" \
        -DCMAKE_EXE_LINKER_FLAGS="$IOS_LINK_FLAGS" \
        -DCMAKE_INSTALL_PREFIX="$PREFIX" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_SHARED_LINKER_FLAGS="$IOS_LINK_FLAGS" \
        -DPNG_SHARED=OFF -DPNG_STATIC=ON \
        -DPNG_TESTS=OFF -DPNG_TOOLS=OFF \
        `# PNG_FRAMEWORK builds an Apple .framework as well as the static lib,` \
        `# and that target picked up the HOST linker (/usr/bin/ld: unrecognised` \
        `# emulation mode: llvm) after the static lib had already linked fine.` \
        `# Only the static lib is wanted here, so the target just goes away.` \
        -DPNG_FRAMEWORK=OFF \
        `# The ARM NEON check runs a probe that cannot execute here.` \
        -DPNG_ARM_NEON=off

    cmake --build "$BUILD/png-build"
    cmake --install "$BUILD/png-build"
fi

[ -f "$PREFIX/lib/libpng16.a" ] || { echo "error: libpng did not install" >&2; exit 1; }

# ---------------------------------------------------------------- stage 2
# DOSBox-X is autotools, not CMake, so cross-compiling it means convincing
# `configure` rather than setting a toolchain file. The source is mounted at
# /dosbox-src (read-only) and cloned here so the host checkout is never touched.
DBX="$BUILD/dosbox-x"
if [ ! -d "$DBX" ]; then
    echo "==> cloning DOSBox-X source"
    # The mount is owned by the host user, not root, and git refuses to read a
    # repository it considers foreign ("detected dubious ownership"). The mount
    # is read-only and came from this machine, so the exception is safe.
    git config --global --add safe.directory /dosbox-src
    git config --global --add safe.directory /dosbox-src/.git
    git clone -q /dosbox-src "$DBX"
fi

cd "$DBX"

# configure.ac cannot tell iOS from macOS on its own; both are *-*-darwin*.
# Must run BEFORE autogen, which is what turns configure.ac into configure.
echo "==> teaching configure.ac about iOS"
python3 "$CORE/ios/apply-ios-configure.py" "$DBX"
python3 "$CORE/ios/apply-ios-source.py" "$DBX"

# The same frame-publish hook and dosbox_x_main entry point the Linux core
# uses. Not iOS-specific, which is why it lives under linux/ -- but it is just
# as required here: without it there is no way into the mainloop and no way for
# a finished frame to reach the bridge.
python3 "$CORE/linux/apply-bridge-hook.py" "$DBX"

[ -f configure ] || ./autogen.sh

export PATH="$PREFIX/bin:$PATH"          # so sdl2-config is found
# GNU ar/ranlib cannot index Mach-O: the archives build fine and then the link
# fails on every one of them with "archive has no index; run ranlib to add one".
# The LLVM tools understand Mach-O and are already in the image.
export AR="${AR:-llvm-ar}"
export RANLIB="${RANLIB:-llvm-ranlib}"
export NM="${NM:-llvm-nm}"
export CC="$IOSBOX_SHIMS/clang"
export CXX=/usr/bin/clang++
export CFLAGS="$IOS_CFLAGS"
export CXXFLAGS="$IOS_CFLAGS -std=gnu++14"
# Objective-C++ needs the same target and sysroot. automake compiles .mm through
# OBJCXX/OBJCXXFLAGS, which configure.ac sets independently of CXXFLAGS -- so
# without this every .mm is built for the HOST. That is not a loud failure: with
# __APPLE__ undefined, physfs_platform_apple.mm compiles to an EMPTY object and
# the problem only appears at link as ___PHYSFS_platformCalcBaseDir undefined.
export OBJCXX="$IOSBOX_SHIMS/clang"
export OBJCXXFLAGS="$IOS_CFLAGS -std=gnu++14"
export OBJC="$IOSBOX_SHIMS/clang"
export OBJCFLAGS="$IOS_CFLAGS"
export LDFLAGS="$IOS_LINK_FLAGS -L$PREFIX/lib"
export SDL2_CONFIG="$PREFIX/bin/sdl2-config"
# configure's SDL2 test is literally `test -n "$SDL2_LIBS"`, filled in normally
# by pkg-config. Setting the precious variables directly from our own
# sdl2-config is the supported override and skips the probe entirely -- which
# also dodges any link-probe false negative from the cross-linker's warnings.
# sdl2-config resolves its prefix from its own location, so run the copy inside
# the container to get container paths.
export SDL2_CFLAGS="$(sh "$SDL2_CONFIG" --cflags)"
export SDL2_LIBS="$(sh "$SDL2_CONFIG" --static-libs)"
export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig"
export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig"   # nothing from the host

if [ ! -f config.h ]; then
    echo "==> cross-configuring DOSBox-X for iOS"
    # --host is what puts autoconf in cross mode: it stops running the
    # binaries it builds, which on this host would fail instantly.
    #
    # Everything optional is off. On iOS none of ffmpeg/fluidsynth/slirp/glib/
    # ncurses/X11 exists, and letting configure hunt for them only produces
    # confusing half-detections against HOST libraries -- hence the empty
    # PKG_CONFIG_LIBDIR above.
    ./configure \
        --host=aarch64-apple-darwin \
        `# Without this C_SDL2 is never defined and the build compiles the` \
        `# SDL1 CD-ROM path, whose SDL_CD type SDL2 removed -- 15 errors that` \
        `# look like source rot but are just the wrong API selected.` \
        --enable-sdl2 \
        --disable-opengl \
        --disable-printer \
        --disable-mt32 \
        --disable-screenshots \
        --disable-alsatest \
        `# iOS forbids JIT. Both dynamic cores must go: the interpreter is the` \
        `# only core that can run in a shipping app, and these builds already` \
        `# only launch under an attached debugger.` \
        --disable-dynrec \
        --disable-dynamic-core \
        || { echo "error: configure failed - see config.log" >&2; exit 1; }
fi

echo "==> building DOSBox-X objects"
# The final executable link fails on purpose and is not an error: SDL2 on iOS
# #defines main -> SDL_main, so the real main() would come from libSDL2main.a.
# We do not want an executable at all; we want the archives, and a dylib whose
# entry point is dosbox_x_main. Everything up to that link is what matters, so
# the archives are verified explicitly below rather than trusting make's status.
make -j"$(nproc)" || true

ARCHIVES="$(find "$DBX/src" -name '*.a' | sort)"
ARCHIVE_COUNT="$(echo "$ARCHIVES" | grep -c . || true)"
[ "$ARCHIVE_COUNT" -ge 20 ] || {
    echo "error: only $ARCHIVE_COUNT archives built - the emulator did not compile" >&2
    exit 1
}
echo "    $ARCHIVE_COUNT archives"

# ---------------------------------------------------------------- stage 3
echo "==> compiling the bridge"
OUT="$CORE/ios/build/out"
mkdir -p "$OUT"

"$IOSBOX_SHIMS/clang" -c -x c++ $IOS_CFLAGS -std=gnu++14 \
    -o "$OUT/dosbox_bridge.o" \
    "$CORE/bridge/dosbox_bridge.cpp" \
    -I"$CORE/bridge" -I"$DBX" -I"$DBX/include" -I"$DBX/src" \
    -I"$PREFIX/include" -I"$PREFIX/include/SDL2" -D_REENTRANT

# The CoreAudio backend is not optional: the bridge calls
# audio_backend_get_level() directly (dosbox_core_get_audio_level), so the
# dylib link fails on the undefined symbol without this object. The mixer's
# own hooks are weak and would tolerate its absence; the bridge's call is not.
echo "==> compiling the audio backend (ios/CoreAudio)"
"$IOSBOX_SHIMS/clang" -c $IOS_CFLAGS -fobjc-arc \
    -o "$OUT/audio_backend_ios.o" \
    "$CORE/bridge/audio_backend_ios.m" \
    -I"$CORE/bridge"

echo "==> linking libdosboxcore.dylib"
# ld64 has no --whole-archive; -all_load is the equivalent, and it is required
# for the same reason as on Linux: nothing in the bridge references most of the
# emulator directly, so without it the linker discards nearly all of it.
#
# The install name must match where the app will actually load it from -- a
# framework inside the bundle. A bare .dylib in Frameworks/ is rejected by iOS
# at install time (see tools/fix-ipa-native-assets.sh for that same trap).
"$IOSBOX_SHIMS/clang" -dynamiclib \
    -target "$TRIPLE" -isysroot "$IOS_SDK" \
    -install_name "@rpath/libdosboxcore.framework/libdosboxcore" \
    -o "$OUT/libdosboxcore" \
    "$OUT/dosbox_bridge.o" \
    "$OUT/audio_backend_ios.o" \
    -Wl,-all_load $ARCHIVES "$DBX"/src/*.o \
    "$PREFIX/lib/libSDL2.a" "$PREFIX/lib/libpng16.a" -lz \
    -framework CoreFoundation -framework CoreMIDI -framework AudioToolbox \
    -framework UIKit -framework Foundation -framework CoreGraphics \
    -framework CoreVideo -framework CoreAudio -framework AVFoundation \
    -framework CoreBluetooth -framework CoreMotion -framework Metal \
    -framework OpenGLES -framework QuartzCore \
    -weak_framework GameController -weak_framework CoreHaptics \
    -lpthread -lm \
    `# The C++ runtime: linked through the clang (C) driver, not clang++, so` \
    `# libc++ is not implicit. Without it every exception path is undefined` \
    `# (___cxa_allocate_exception, __ZTVSt12length_error).` \
    -lc++ -lc++abi -liconv \
    -fuse-ld="$IOS_LD" -Wl,-arch,arm64 \
    -Wl,-platform_version,ios,${DEPLOYMENT_TARGET}.0,16.0.0 \
    -Wl,-adhoc_codesign "$IOS_BUILTINS"

echo "==> checking the ABI is exported"
${NMTOOL:-llvm-nm-18} --defined-only "$OUT/libdosboxcore" > "$OUT/exported.syms"
# Every symbol the header declares (Mach-O prefixes them with an underscore),
# not a hand-picked subset -- the Dart bindings resolve all of them at load.
missing=0
for sym in $(grep -oE '\bdosbox_core_[a-z_]+\(' "$CORE/bridge/dosbox_bridge.h" | tr -d '(' | sed 's/^/_/' | sort -u); do
    grep -q " $sym\$" "$OUT/exported.syms" || { echo "    MISSING: $sym"; missing=1; }
done
[ "$missing" = 0 ] || { echo "error: the C ABI is incomplete" >&2; exit 1; }

echo "==> done"
ls -lh "$OUT/libdosboxcore"
file "$OUT/libdosboxcore"
