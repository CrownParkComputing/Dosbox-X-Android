#!/usr/bin/env bash
#
# Build the DOSBox-X native core (libmain.so) for Android.
#
# Workflow (this is the "track upstream, patch on top, rebuild" pipeline):
#   1. Fetch upstream tags and check the submodule out to the LATEST STABLE
#      release tag  (dosbox-x-vYYYY.MM.DD), unless DBX_REF pins a specific ref.
#   2. Clean the tree and apply native/patches/*.patch in filename order,
#      failing loudly if any patch no longer applies (that is the signal to
#      refresh the patch against new upstream).
#   3. Cross-compile for each ABI in a HERMETIC environment (host pkg-config and
#      host libs are hidden so autotools can't false-positive on the dev box),
#      then link the objects as a shared library  libmain.so  exporting SDL_main
#      (SDLActivity dlopen()s it and looks up SDL_main).
#   4. Verify the artifact (exports SDL_main, sane NEEDED list) and install it to
#      app/src/main/jniLibs/<abi>/libmain.so.
#
# Usage:
#   export ANDROID_NDK=$HOME/Android/Sdk/ndk/<version>
#   ./native/build-android.sh                 # latest stable tag, all ABIs
#   DBX_REF=dosbox-x-v2026.06.02 ./native/build-android.sh   # pin a ref
#   DBX_ABIS="arm64-v8a" ./native/build-android.sh           # one ABI
#   DBX_NO_UPDATE=1 ./native/build-android.sh   # don't touch the submodule ref
#                                               # (use current checkout as-is)
#
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
SRC="$HERE/dosbox-x"
TMP="$HERE/build"                       # scratch: build trees + toolchain shims
API="${DBX_API:-36}"
read -r -a ABIS <<< "${DBX_ABIS:-arm64-v8a x86_64}"

note() { printf '\n\033[1;36m>> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m!! %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[1;31mxx %s\033[0m\n' "$*" >&2; exit 1; }

# --- prerequisites --------------------------------------------------------
: "${ANDROID_NDK:?Set ANDROID_NDK to your NDK path (e.g. \$HOME/Android/Sdk/ndk/<ver>)}"
TOOLCHAIN="$ANDROID_NDK/toolchains/llvm/prebuilt/linux-x86_64"
[ -d "$TOOLCHAIN" ] || die "NDK toolchain not found at $TOOLCHAIN"
[ -d "$SRC/.git" ] || [ -f "$SRC/.git" ] || die "Submodule missing — run: git submodule update --init native/dosbox-x"
for t in autoconf automake; do command -v "$t" >/dev/null || die "missing build tool: $t"; done
# nasm is optional for non-x86 or can be disabled
command -v nasm >/dev/null || warn "nasm not found — x86 optimizations will be disabled"

# --- 1. select upstream ref ----------------------------------------------
if [ "${DBX_NO_UPDATE:-0}" = "1" ]; then
  note "DBX_NO_UPDATE=1 — using current submodule checkout ($(git -C "$SRC" describe --tags --always))"
  REF="$(git -C "$SRC" describe --tags --always)"
else
  note "fetching upstream tags"
  git -C "$SRC" fetch --tags --force --quiet origin
  if [ -n "${DBX_REF:-}" ]; then
    REF="$DBX_REF"
  else
    # latest stable release tag: dosbox-x-vYYYY.MM.DD, excluding the -osfree variants
    REF="$(git -C "$SRC" tag -l 'dosbox-x-v*' --sort=-v:refname \
            | grep -E '^dosbox-x-v[0-9]{4}\.[0-9]{2}\.[0-9]{2}$' | head -n1)"
    [ -n "$REF" ] || die "could not resolve latest dosbox-x-v* release tag"
  fi
  note "checking out upstream ref: $REF"
  git -C "$SRC" checkout -q --force "$REF"
fi

# --- 2. clean tree + apply our patches -----------------------------------
note "resetting submodule working tree"
git -C "$SRC" reset -q --hard
git -C "$SRC" clean -qfdx
shopt -s nullglob
PATCHES=("$HERE"/patches/*.patch)
if [ ${#PATCHES[@]} -eq 0 ]; then
  warn "no patches in native/patches/ — building pristine upstream"
else
  for p in "${PATCHES[@]}"; do
    note "applying $(basename "$p")"
    git -C "$SRC" apply --whitespace=nowarn "$p" \
      || die "patch failed to apply: $(basename "$p")
       Upstream ($REF) has moved under this patch. Refresh it:
         cd $SRC && git apply --3way $p   # resolve, then:
         git diff > $p                     # (or use native/regen-patch.sh)"
  done
fi

# autogen regenerates ./configure (our patches touch configure.ac)
note "running autogen.sh"
( cd "$SRC" && ./autogen.sh ) >/dev/null 2>&1 || die "autogen.sh failed"

# --- toolchain shims (hermetic) ------------------------------------------
# A fake sdl2-config so DOSBox-X's configure uses the bundled SDL2 fork headers
# and links the libSDL2.so we already ship in jniLibs (matching SDLActivity).
SHIM="$TMP/shim"; mkdir -p "$SHIM/bin" "$TMP/empty-pkgconfig"
SDLINC="$SRC/vs/sdl2/include"
PNGINC="$SRC/vs/libpng"

abi_triple() { case "$1" in
  arm64-v8a) echo aarch64-linux-android ;;
  x86_64)    echo x86_64-linux-android ;;
  armeabi-v7a) echo armv7a-linux-androideabi ;;
  x86)       echo i686-linux-android ;;
  *) echo unknown ;;
esac; }

build_abi() {
  local ABI="$1" TRIPLE BUILD JNI LIBDIR
  TRIPLE="$(abi_triple "$ABI")"; [ "$TRIPLE" != unknown ] || die "unknown ABI $ABI"
  JNI="$ROOT/app/src/main/jniLibs/$ABI"
  [ -f "$JNI/libSDL2.so" ]   || die "$JNI/libSDL2.so missing (need the prebuilt SDL2)"
  [ -f "$JNI/libpng16.so" ]  || die "$JNI/libpng16.so missing (need the prebuilt libpng)"
  BUILD="$TMP/$ABI"; rm -rf "$BUILD"; mkdir -p "$BUILD"

  # symlink farm so -lpng / -lSDL2 resolve to the sonamed prebuilts in jniLibs
  LIBDIR="$TMP/lib-$ABI"; mkdir -p "$LIBDIR"
  ln -sf "$JNI/libpng16.so" "$LIBDIR/libpng.so"
  ln -sf "$JNI/libSDL2.so"  "$LIBDIR/libSDL2.so"

  cat > "$SHIM/bin/sdl2-config" <<EOF
#!/bin/sh
case "\$1" in
  --cflags) echo "-I$SDLINC -D_REENTRANT" ;;
  --libs|--static-libs) echo "-L$LIBDIR -lSDL2" ;;
  --version) echo "2.32.10" ;;
esac
EOF
  chmod +x "$SHIM/bin/sdl2-config"

  local CC="$TOOLCHAIN/bin/${TRIPLE}${API}-clang"
  local CXX="$TOOLCHAIN/bin/${TRIPLE}${API}-clang++"
  export CC CXX
  export AR="$TOOLCHAIN/bin/llvm-ar" RANLIB="$TOOLCHAIN/bin/llvm-ranlib" STRIP="$TOOLCHAIN/bin/llvm-strip"
  export SDL2_CONFIG="$SHIM/bin/sdl2-config"
  export PKG_CONFIG_LIBDIR="$TMP/empty-pkgconfig" PKG_CONFIG_PATH=""
  export PATH="$SHIM/bin:$PATH"

  note "[$ABI] configuring ($TRIPLE, API $API)"
  ( cd "$BUILD" && "$SRC/configure" \
      --host="$TRIPLE" \
      --enable-sdl2 --disable-sdl2test --disable-sdltest \
      --disable-sdlnet --disable-x11 --disable-libslirp --disable-libfluidsynth \
      --disable-alsa-midi --disable-opengl --disable-gamelink \
      ac_cv_lib_asound_snd_pcm_open=no \
      ac_cv_lib_curses_initscr=no ac_cv_lib_ncurses_initscr=no \
      ac_cv_lib_pdcurses_initscr=no ac_cv_lib_tinfo_nodelay=no \
      ac_cv_lib_rt_main=no \
      CPPFLAGS="-I$SDLINC -I$PNGINC -fPIC" \
      CFLAGS="-fPIC -O2" CXXFLAGS="-fPIC -O2" \
      LDFLAGS="-L$JNI -L$LIBDIR -Wl,-rpath-link,$JNI -Wl,--allow-shlib-undefined -static-libstdc++" \
      LIBS="-lz -lm" ) \
    > "$BUILD/configure.log" 2>&1 \
    || { tail -20 "$BUILD/configure.log"; die "[$ABI] configure failed (see $BUILD/configure.log)"; }

  note "[$ABI] compiling (this takes a while)"
  # -k: build every object/archive even though the final *executable* link will
  # fail. That failure is EXPECTED: SDL renames main()->SDL_main on Android, so
  # the executable's C runtime has no main. We only need the objects; we link our
  # own shared library below. So: tolerate the make failure, but reject any real
  # *source* compile error.
  ( cd "$BUILD" && make -k -j"$(nproc)" ) > "$BUILD/make.log" 2>&1 || true
  if grep -qE '\.(cpp|cc|c|h):[0-9]+:[0-9]+: error:' "$BUILD/make.log"; then
      warn "[$ABI] source compile errors — first failures:"
      grep -m20 -E '\.(cpp|cc|c|h):[0-9]+:[0-9]+: error:' "$BUILD/make.log" >&2 || true
      die "[$ABI] compile failed. Fix the source for Android and capture it as a
       new native/patches/NNNN-*.patch (see native/regen-patch.sh), then re-run."
  fi

  note "[$ABI] linking libmain.so"
  link_shared "$ABI" "$BUILD" "$JNI"

  verify_so "$ABI" "$JNI/libmain.so"
}

# DOSBox-X's Makefile links an *executable* (dosbox-x) from one object set. We
# reuse that EXACT command — guaranteeing we pick up every object/archive/lib in
# the right order — and only swap the output for a shared library that keeps
# SDL_main exported. `make -n` prints the canonical link line without running it.
link_shared() {
  local ABI="$1" BUILD="$2" JNI="$3" linkcmd shared
  linkcmd="$( ( cd "$BUILD/src" && make -n dosbox-x 2>/dev/null ) \
              | grep -E ' -o dosbox-x dosbox\.o' | tail -1 )"
  [ -n "$linkcmd" ] || die "[$ABI] could not find the dosbox-x link command (did the build change?)"
  # The host API lives in libgui.a with nothing referencing it - a static
  # archive member no one needs is a member the linker silently drops, and
  # the .so ships without the very exports the front end dlsyms. Anchoring
  # one symbol pulls the whole object in, functions and all.
  shared="${linkcmd/ -o dosbox-x / -shared -Wl,-soname,libmain.so -Wl,-u,dosboxx_host_quit -o libmain.so }"
  ( cd "$BUILD/src" && eval "$shared" ) 2> "$BUILD/link.log" \
    || { tail -30 "$BUILD/link.log"; die "[$ABI] link failed (see $BUILD/link.log)"; }
  "$STRIP" --strip-unneeded "$BUILD/src/libmain.so" -o "$JNI/libmain.so"
  note "[$ABI] installed -> ${JNI#$ROOT/}/libmain.so"
}

verify_so() {
  local ABI="$1" SO="$2" syms needed
  [ -f "$SO" ] || die "[$ABI] libmain.so was not produced"
  # Capture, then match with bash globs — NO pipe to grep. `grep -q` short-circuits
  # and SIGPIPEs its producer, which `set -o pipefail` reports as a failed pipeline
  # (a false negative even when the symbol is present).
  syms="$("$TOOLCHAIN/bin/llvm-nm" -D --defined-only "$SO")"
  [[ "$syms" == *" T SDL_main"* ]] \
    || die "[$ABI] libmain.so does not export SDL_main — SDLActivity cannot run it"
  needed="$("$TOOLCHAIN/bin/llvm-readelf" -d "$SO")"
  if [[ "$needed" =~ NEEDED.*lib(rt|asound|curses|ncurses)\.so ]]; then
    die "[$ABI] libmain.so NEEDs a host-only library — Android will fail to load it"
  fi
  note "[$ABI] verify OK ($(du -h "$SO" | cut -f1), exports SDL_main)"
}

for ABI in "${ABIS[@]}"; do build_abi "$ABI"; done
note "done — refreshed: ${ABIS[*]}"
echo "Commit the refreshed app/src/main/jniLibs/<abi>/libmain.so (and the submodule"
echo "ref + any new native/patches/*.patch) to ship this build."
