#!/usr/bin/env bash
#
# Build the DOSBox-X native core (libmain.so) for Android from the pinned
# upstream submodule + our patches, and drop it into app/src/main/jniLibs/.
#
#   export ANDROID_NDK=$HOME/Android/Sdk/ndk/<version>
#   ./native/build-android.sh
#
# STATUS: framework. The toolchain setup, patch application and per-ABI configure
# are wired up below. Upstream DOSBox-X has no Android target (configure.ac has no
# Android references), so the remaining custom work is linking its main() as an
# SDL2 `libmain.so` shared library (SDL_main) rather than an executable — see the
# BUILD step near the bottom. Until that's done this script prepares the tree and
# stops with a clear message rather than producing a broken artifact.

set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
SRC="$HERE/dosbox-x"
ABIS=("arm64-v8a" "x86_64")
API=28

# --- prerequisites ---
: "${ANDROID_NDK:?Set ANDROID_NDK to your NDK path (e.g. \$HOME/Android/Sdk/ndk/<ver>)}"
[ -d "$SRC" ] || { echo "Submodule missing — run: git submodule update --init native/dosbox-x"; exit 1; }
TOOLCHAIN="$ANDROID_NDK/toolchains/llvm/prebuilt/linux-x86_64"
[ -d "$TOOLCHAIN" ] || { echo "NDK toolchain not found at $TOOLCHAIN"; exit 1; }

# --- 1. clean upstream working tree, apply our patches on top ---
echo ">> resetting submodule to the pinned commit"
git -C "$SRC" checkout -q .
git -C "$SRC" clean -qfdx
shopt -s nullglob
for p in "$HERE"/patches/*.patch; do
  echo ">> applying $(basename "$p")"
  git -C "$SRC" apply "$p"
done

# --- 2. per-ABI cross-build ---
abi_triple() { case "$1" in
  arm64-v8a) echo "aarch64-linux-android" ;;
  x86_64)    echo "x86_64-linux-android" ;;
  *) echo "unknown" ;;
esac; }

for ABI in "${ABIS[@]}"; do
  TRIPLE="$(abi_triple "$ABI")"
  export CC="$TOOLCHAIN/bin/${TRIPLE}${API}-clang"
  export CXX="$TOOLCHAIN/bin/${TRIPLE}${API}-clang++"
  export AR="$TOOLCHAIN/bin/llvm-ar"
  export RANLIB="$TOOLCHAIN/bin/llvm-ranlib"
  export STRIP="$TOOLCHAIN/bin/llvm-strip"
  BUILD="$HERE/build/$ABI"
  mkdir -p "$BUILD"
  echo ">> configuring DOSBox-X for $ABI ($TRIPLE)"

  # SDL2 headers come from the bundled copy in the submodule; link against the
  # SDL2 already shipped in jniLibs so versions match the Java SDLActivity glue.
  SDL2_INC="$SRC/vs/sdl2/include"
  JNILIBS="$ROOT/app/src/main/jniLibs/$ABI"

  ( cd "$SRC" && [ -x ./configure ] || ./autogen.sh ) || true
  ( cd "$BUILD" && "$SRC/configure" \
      --host="$TRIPLE" \
      --disable-sdltest \
      CPPFLAGS="-I$SDL2_INC -fPIC" \
      LDFLAGS="-L$JNILIBS -Wl,-rpath-link,$JNILIBS" \
      LIBS="-lSDL2 -lpng16 -lc++_shared" ) \
    || { echo "!! configure for $ABI failed — see $BUILD/config.log"; exit 1; }

  # --- 3. BUILD (the remaining custom step) ---------------------------------
  # `make` here builds the DOSBox-X *executable*. Android/SDL2 needs a *shared
  # library* libmain.so that exports SDL_main (SDLActivity dlopen's it). That
  # requires compiling src/main with SDL_MAIN_HANDLED off and linking with
  # `-shared -Wl,-soname,libmain.so` plus the SDL2 Android `main` shim. Wire
  # that up (a small Makefile override / link rule), then:
  #
  #   make -C "$BUILD" -j"$(nproc)"
  #   "$STRIP" "$BUILD/src/libmain.so" -o "$JNILIBS/libmain.so"
  #
  echo "!! $ABI: configure ok; libmain.so link step not yet automated (see comments)."
done

echo
echo "Framework prepared. Finish the libmain.so shared-lib link rule above to emit"
echo "app/src/main/jniLibs/<abi>/libmain.so, then commit the refreshed binaries."
