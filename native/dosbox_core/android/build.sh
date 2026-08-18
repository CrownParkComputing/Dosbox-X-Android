#!/usr/bin/env bash
# Build libdosboxcore.so for one Android ABI: the bridge, linked against a
# -fPIC DOSBox-X tree cross-compiled with the Android NDK.
#
#   native/dosbox_core/android/build.sh                      # arm64-v8a (retroid)
#   ANDROID_ABI=x86_64 native/dosbox_core/android/build.sh   # host-side smoke test
#   ANDROID_NDK=/path/to/ndk/30 .../build.sh                # pick the NDK
#
# Output: flutter_app/android/app/src/main/jniLibs/<abi>/libdosboxcore.so
#
# Prerequisite: native/dosbox_core/linux/build-core-pic.sh has produced
# ~/dosbox-x-pic against the host CFLAGS. That tree is the source: this
# script applies the bridge hook, applies the nine Android-specific
# patches from ./patches/, and reconfigures + cross-compiles for the NDK
# target. The bridge hook lets us publish finished frames through the same
# Game Link output the Java/SDL app uses, so the bridge needs the gamelink
# output enabled (the legacy build disabled it; we re-enable here).
#
# Layout mirrors the iOS/Linux scripts: a single host-side script that
# applies the source patches, builds, and copies the .so into the Flutter
# app's standard jniLibs directory so the next `flutter build apk` picks it
# up. The legacy Java/SDL app's jniLibs get a copy too, so the existing
# working app gets the new core.
#
# SDL2 and libpng are not built from source here -- they are already on the
# device as prebuilt .so files in the legacy app's jniLibs, and the Flutter
# app's libdosboxcore.so links against them by SONAME. The engine is built
# against their headers (vendored in dosbox-x-pic/vs/sdl2/include and
# /vs/libpng) and against the libs as -rpath-link inputs so the test links
# during configure succeed even though libpng transitively needs zlib.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../../.." && pwd)"
BRIDGE="$HERE/../bridge"
PIC="${DOSBOX_X_PIC:-$HOME/dosbox-x-pic}"
OUT="${OUT:-$HERE/build}"
TMP="${TMP:-$HERE/.tmp}"
APPDEST_FLUTTER="$REPO_ROOT/flutter_app/android/app/src/main/jniLibs"
APPDEST_LEGACY="$REPO_ROOT/../AndroidStudioProjects/DosBoxX/app/src/main/jniLibs"

# Defaults match the Retroid Pocket family (handhelds running Android on
# arm64-v8a) and a host emulator (x86_64). The Gradle build declares the
# same pair in build.gradle.kts:
#     abiFilters += listOf("arm64-v8a", "x86_64")
ANDROID_ABI="${ANDROID_ABI:-arm64-v8a}"
ANDROID_API="${ANDROID_API:-28}"
ANDROID_NDK="${ANDROID_NDK:-$HOME/Android/Sdk/ndk/30.0.14904198}"

case "$ANDROID_ABI" in
    arm64-v8a|aarch64-linux-android) TRIPLE="aarch64-linux-android${ANDROID_API}" ;;
    x86_64|x86_64-linux-android)    TRIPLE="x86_64-linux-android${ANDROID_API}" ;;
    armeabi-v7a|armv7a-linux-androideabi) TRIPLE="armv7a-linux-androideabi${ANDROID_API}" ;;
    x86|i686-linux-android)         TRIPLE="i686-linux-android${ANDROID_API}" ;;
    *) echo "error: unsupported ANDROID_ABI '$ANDROID_ABI'" >&2; exit 1 ;;
esac

[ -d "$PIC/src" ] || {
    echo "error: no -fPIC tree at $PIC. Run linux/build-core-pic.sh first." >&2
    exit 1
}
[ -x "$ANDROID_NDK/toolchains/llvm/prebuilt/linux-x86_64/bin/${TRIPLE}-clang++" ] || {
    echo "error: NDK $ANDROID_NDK does not have $TRIPLE-clang++" >&2; exit 1
}

NDK_BIN="$ANDROID_NDK/toolchains/llvm/prebuilt/linux-x86_64/bin"
CLANG="$NDK_BIN/${TRIPLE}-clang"
CLANGXX="$NDK_BIN/${TRIPLE}-clang++"
NDK_SYSROOT="$ANDROID_NDK/toolchains/llvm/prebuilt/linux-x86_64/sysroot"

# ---------------------------------------------------------------- shim
# A scratch dir that holds a sdl2-config shim, a libpng/SDL2 symlink farm,
# and a clean pkg-config search path. The legacy app's jniLibs already
# carry libpng16.so and libSDL2.so (built against NDK 28c then NDK 30), and
# the engine is configured to use those by SONAME. The shim is rerun-safe:
# every invocation rebuilds it from scratch so the symlink targets stay in
# step with whatever's at $APPDEST_LEGACY.
SHIM="$TMP/shim"
mkdir -p "$SHIM/bin" "$TMP/lib-$ANDROID_ABI" "$TMP/empty-pkgconfig"

# The legacy app's jniLibs is the only place on the host that has the
# prebuilt libSDL2.so and libpng16.so. If the legacy app hasn't been built
# yet, the user has to point $APPDEST_LEGACY at a directory that has them.
[ -d "$APPDEST_LEGACY/$ANDROID_ABI" ] || {
    echo "error: $APPDEST_LEGACY/$ANDROID_ABI is missing." >&2
    echo "       Build the legacy app first (or symlink a directory that" >&2
    echo "       holds libSDL2.so and libpng16.so for $ANDROID_ABI)." >&2
    exit 1
}
[ -f "$APPDEST_LEGACY/$ANDROID_ABI/libSDL2.so" ] || {
    echo "error: $APPDEST_LEGACY/$ANDROID_ABI/libSDL2.so missing." >&2
    exit 1
}
[ -f "$APPDEST_LEGACY/$ANDROID_ABI/libpng16.so" ] || {
    echo "error: $APPDEST_LEGACY/$ANDROID_ABI/libpng16.so missing." >&2
    exit 1
}

# Symlink the legacy jniLibs .so into the build dir under the SONAME the
# engine will -l-link. dosbox-x configure asks for -lpng and -lSDL2; the
# prebuilts are libpng16.so and libSDL2.so. The symlinks let -L and -l
# resolve without renaming the prebuilts.
ln -sf "$APPDEST_LEGACY/$ANDROID_ABI/libpng16.so" "$TMP/lib-$ANDROID_ABI/libpng.so"
ln -sf "$APPDEST_LEGACY/$ANDROID_ABI/libSDL2.so"  "$TMP/lib-$ANDROID_ABI/libSDL2.so"

# sdl2-config shim. dosbox-x calls `sdl2-config --cflags --libs --version`
# in its configure script; the values below point it at the vendored SDL2
# headers in the dosbox-x tree and the lib symlink farm.
cat > "$SHIM/bin/sdl2-config" <<EOF
#!/bin/sh
SDLINC="$PIC/vs/sdl2/include"
LIBDIR="$TMP/lib-$ANDROID_ABI"
case "\$1" in
  --cflags)        echo "-I\$SDLINC -D_REENTRANT" ;;
  --libs|--static-libs) echo "-L\$LIBDIR -lSDL2" ;;
  --version)       echo "2.32.10" ;;
esac
EOF
chmod +x "$SHIM/bin/sdl2-config"

# ---------------------------------------------------------------- patches
# Apply the bridge hook. The Android build reads the bridge .cpp from this
# same tree, so the patched output_gamelink.cpp and sdlmain.cpp must be
# present and rebuilt.
python3 "$HERE/../linux/apply-bridge-hook.py" "$PIC"

# Apply Android-specific source patches. 0001 changes configure.ac, which
# means re-autogen is required before configure: otherwise the new
# *-*-android* case never runs and the build ends up using the host's
# LINUX/X11 defines. The patch set is idempotent.
python3 "$HERE/apply-android-source.py" "$PIC"

# ---------------------------------------------------------------- configure
# Reconfigure the PIC tree to build for the NDK target. We blow away the
# host config so the new flags actually take effect: a second ./configure
# with the same prefix leaves the old values in place.
rm -f "$PIC/config.h" "$PIC/config.status" "$PIC/src/Makefile"
(
    cd "$PIC"
    # autogen.sh has to run after the patches (0001 changes configure.ac)
    # and before configure.
    ./autogen.sh >/dev/null 2>&1

    # The legacy app keeps a successful build at ~/.mobai -- but we still
    # force the configure to find what we want here, so the test links
    # resolve. The pieces that matter:
    #   -I vs/sdl2/include + vs/libpng  -- vendored headers
    #   -L /tmp/lib-<abi>               -- the symlink farm
    #   -Wl,--allow-shlib-undefined     -- libpng transitively needs zlib
    #                                     symbols that resolve at runtime
    #   -Wl,-rpath-link                 -- so configure's prober can find
    #                                     the .so for shared-lib path tests
    #   ac_cv_lib_png_png_get_io_ptr=yes-- skip the broken link probe
    #                                     (libpng.so unsats without zlib)
    #   -lz -lm -lSDL2 -lpng            -- the libs we are claiming to use
    # --disable-sdlnet/--disable-x11/--disable-libslirp/--disable-libfluidsynth
    #   /--disable-alsa-midi/--disable-opengl: optional deps not present on
    #   Android. We keep --enable-gamelink turnED ON (the legacy build
    #   disabled it because it uses SDL2 directly; the bridge depends on
    #   gamelink being built).
    CC="$CLANG" CXX="$CLANGXX" \
    CPPFLAGS="-I$PIC/vs/sdl2/include -I$PIC/vs/libpng -D_REENTRANT" \
    CFLAGS="-g -O2 -fPIC -fvisibility=hidden" \
    CXXFLAGS="-g -O2 -fPIC -fvisibility=hidden -std=gnu++17" \
    LDFLAGS="-fuse-ld=lld -static-libstdc++ -static-libgcc -L$TMP/lib-$ANDROID_ABI -Wl,-rpath-link,$TMP/lib-$ANDROID_ABI -Wl,--allow-shlib-undefined" \
    SDL2_CONFIG="$SHIM/bin/sdl2-config" \
    PKG_CONFIG_PATH="$TMP/empty-pkgconfig" \
    PKG_CONFIG_LIBDIR="$TMP/empty-pkgconfig" \
    PATH="$SHIM/bin:$PATH" \
    LIBS="-lpng -lz -lSDL2 -lm" \
    ac_cv_lib_png_png_get_io_ptr=yes \
    ./configure --host="$TRIPLE" \
                --enable-sdl2 \
                --disable-opengl \
                --disable-freetype \
                --disable-sdlnet \
                --disable-x11 \
                --disable-libslirp \
                --disable-libfluidsynth \
                --disable-alsa-midi \
                --disable-screenshots \
                --disable-avcodec \
                --prefix=/usr \
        >/dev/null 2>&1 \
        || { echo "error: configure failed for $TRIPLE" >&2; exit 1; }
)

# ---------------------------------------------------------------- build
# Build the engine objects and archives, but not the dosbox-x executable.
# Patch 0003 exposes SDL_main instead of main on Android, so linking the normal
# executable necessarily fails in the NDK CRT at `_start_main`; the shared
# library link below is the real Android product and supplies its own bridge
# entry point. Building the exact LDADD archive set still gives us the same
# engine object graph without attempting that invalid executable link.
#
# -Werror would make unrelated upstream warnings fail the build, so we keep
# -Wno-error. Some warnings show up under -std=gnu++17 that do not under
# -std=gnu++14, so we are explicit.
echo "==> building the engine for $ANDROID_ABI (this takes a while)"
LDADD_RAW="$(make -C "$PIC/src" -s \
    --eval='__print_ldadd:; @echo $(dosbox_x_LDADD)' __print_ldadd 2>/dev/null)"
[ -n "$LDADD_RAW" ] || { echo "error: could not read dosbox_x_LDADD" >&2; exit 1; }
ENGINE_TARGETS="dosbox.o"
for target in $LDADD_RAW; do
    case "$target" in
        *.a) ENGINE_TARGETS="$ENGINE_TARGETS $target" ;;
    esac
done
make -C "$PIC/src" -j"$(nproc)" $ENGINE_TARGETS \
    WARN_CFLAGS="-Wno-error" \
    WARN_CXXFLAGS="-Wno-error" \
    >/dev/null 2>&1

# ---------------------------------------------------------------- link
# Pull the engine's own archive list and link flags. Same whole-archive
# ploy as the Linux build: nothing in the bridge references most of DOSBox-X
# directly, the engine's mainloop pulls it in at runtime, and without
# --whole-archive the linker discards almost the entire emulator as unused.
LIBS="$(sed -n 's/^LIBS = //p' "$PIC/src/Makefile" | head -1)"
[ -n "$LIBS" ] || echo "warning: no LIBS found in $PIC/src/Makefile" >&2
ARCHIVES=""
seen=" "
for a in $LDADD_RAW; do
    case "$a" in
        *.a)
            case "$seen" in *"$a "*) continue ;; esac
            seen="$seen$a "
            ARCHIVES="$ARCHIVES $PIC/src/$a"
            ;;
        -l*|-L*) EXTRA_LIBS="${EXTRA_LIBS:-} $a" ;;
    esac
done
EXTRA_LIBS="${EXTRA_LIBS:-}"

mkdir -p "$OUT"

# Compile the bridge. The bridge does not call SDL2 directly: every SDL2
# dependency is on the host application's side. We still pass -I for the
# SDL2 headers because the bridge does include <SDL.h> for SDL_Scancode,
# SDL_Event and SDL_SetMainReady; those are headers-only and resolve at
# compile time.
echo "==> compiling bridge for $ANDROID_ABI"
"$CLANGXX" -c -O2 -fPIC -std=gnu++17 \
    -fvisibility=default \
    -target "$TRIPLE" \
    --sysroot "$NDK_SYSROOT" \
    -o "$OUT/dosbox_bridge.o" \
    "$BRIDGE/dosbox_bridge.cpp" \
    -I"$BRIDGE" \
    -I"$PIC" -I"$PIC/include" -I"$PIC/src" \
    -I"$PIC/vs/sdl2/include" \
    -D__ANDROID__=1 -DANDROID=1 \
    -D_POSIX_C_SOURCE=200809L

# Link. Two things to know:
#
# 1. DOSBox-X's own Makefile links an *executable* (dosbox-x) from one
#    object set. We reuse that EXACT command, guaranteeing we pick up every
#    object/archive/lib in the right order, and only swap the output to a
#    shared library. This is what the legacy Java/SDL app does.
#
# 2. The engine's link command lists gui/libgui.a twice and dos/libdos.a
#    twice. That is harmless in an executable link, but under --whole-archive
#    each duplicate is pulled in wholesale and every symbol in it collides
#    with itself. Dedup the list before passing it to the linker.
#
# `make -n` prints the canonical link line without running it.
echo "==> linking libdosboxcore.so for $ANDROID_ABI"
(
    cd "$PIC/src"
    LINK_CMD="$(make -n dosbox-x 2>/dev/null | grep -E ' -o dosbox-x dosbox\.o' | tail -1)"
    [ -n "$LINK_CMD" ] || { echo "error: could not extract dosbox-x link command" >&2; exit 1; }

    # Swap executable -> shared library, and chain bridge.o before the
    # whole-archive group. dosbox.o goes INSIDE the whole-archive group so
    # its symbols (notably `control`) are pulled in even when the linker
    # would otherwise decide no one outside libdosboxcore.so references them.
    SHARED_LINK="${LINK_CMD/ -o dosbox-x / -shared -Wl,-soname,libdosboxcore.so -o libdosboxcore.so }"
    SHARED_LINK="${SHARED_LINK/ dosbox.o / $OUT/dosbox_bridge.o -Wl,--whole-archive dosbox.o }"
    SHARED_LINK="${SHARED_LINK/ libs\/decoders\/internal\/libopusint.a / libs/decoders/internal/libopusint.a -Wl,--no-whole-archive }"

    # Deduplicate .a archives. Walk the tokens, drop any .a we have seen
    # before. The order of remaining flags is preserved.
    SHARED_LINK="$(echo "$SHARED_LINK" | python3 -c '
import sys
tokens = sys.stdin.read().split()
seen = set()
out = []
for tok in tokens:
    if tok.endswith(".a") and not tok.startswith("-"):
        full = tok.lstrip("./")
        if full in seen:
            continue
        seen.add(full)
    out.append(tok)
print(" ".join(out))
')"

    # shellcheck disable=SC2086
    eval "$SHARED_LINK"
) 2>&1 | tail -10
[ -f "$PIC/src/libdosboxcore.so" ] || { echo "error: link failed" >&2; exit 1; }
mv "$PIC/src/libdosboxcore.so" "$OUT/libdosboxcore.so"

# ---------------------------------------------------------------- verify
# Verify the public ABI is exported. Same approach as the linux script:
# dump nm once, then check every symbol the header declares.
nm -D --defined-only "$OUT/libdosboxcore.so" > "$OUT/exported.syms"
missing=0
for sym in $(grep -oE '\bdosbox_core_[a-z_]+\(' "$BRIDGE/dosbox_bridge.h" | tr -d '(' | sort -u); do
    grep -q " $sym\$" "$OUT/exported.syms" \
        || { echo "    MISSING: $sym"; missing=1; }
done
[ "$missing" = 0 ] || { echo "error: the C ABI is incomplete" >&2; exit 1; }

# Confirm the internal entry point the bridge needs: dosbox_x_main. The engine
# is intentionally compiled with -fvisibility=hidden, so this should resolve
# inside libdosboxcore.so but must not be required as part of the public Dart
# FFI ABI checked above.
if ! nm --defined-only "$OUT/libdosboxcore.so" | grep -q " dosbox_x_main\$"; then
    echo "error: dosbox_x_main is missing -- the bridge hook did not apply" >&2
    exit 1
fi

# ---------------------------------------------------------------- install
# Copy into the Flutter app's jniLibs so the next `flutter build apk` ships it.
JLIBS="$APPDEST_FLUTTER/$ANDROID_ABI"
mkdir -p "$JLIBS"
cp "$OUT/libdosboxcore.so" "$JLIBS/libdosboxcore.so"

# Also drop it into the legacy Java/SDL app's jniLibs if that tree exists,
# so the predecessor app gets the new core too. Useful for the Retroid
# smoke test: the Java app is a known working shell, while the Flutter one
# is brand new.
mkdir -p "$TMP/lib-$ANDROID_ABI"
if [ -d "$APPDEST_LEGACY" ]; then
    mkdir -p "$APPDEST_LEGACY/$ANDROID_ABI/libmain.so.placeholder"
    cp "$OUT/libdosboxcore.so" "$APPDEST_LEGACY/$ANDROID_ABI/libdosboxcore.so"
    rmdir "$APPDEST_LEGACY/$ANDROID_ABI/libmain.so.placeholder"
fi

echo "==> done"
ls -lh "$JLIBS/libdosboxcore.so"
file "$JLIBS/libdosboxcore.so"

