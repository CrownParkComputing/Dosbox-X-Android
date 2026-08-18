#!/usr/bin/env bash
# Build libdosboxcore.so: the bridge, linked against a -fPIC DOSBox-X tree.
#
#   native/dosbox_core/linux/build.sh
#
# Prerequisite: build-core-pic.sh has produced ~/dosbox-x-pic, and
# apply-bridge-hook.py has patched it. Both are idempotent, and this script
# runs the patch step itself.
#
# The engine is linked in whole: --whole-archive is required because nothing in
# the bridge references most of DOSBox-X directly. The engine's own mainloop
# pulls it in at runtime, so without it the linker would discard almost the
# entire emulator as unused.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BRIDGE="$HERE/../bridge"
PIC="${DOSBOX_X_PIC:-$HOME/dosbox-x-pic}"
OUT="${OUT:-$HERE/build}"

[ -d "$PIC/src" ] || { echo "error: no -fPIC tree at $PIC. Run build-core-pic.sh first." >&2; exit 1; }

python3 "$HERE/apply-bridge-hook.py" "$PIC"

# Rebuild whatever the patch just touched. Without this the archives still hold
# the pre-patch sdlmain.o and output_gamelink.o, the link succeeds anyway, and
# the failure appears at dlopen as "undefined symbol: dosbox_x_main" -- or,
# worse, links clean and simply never publishes a frame.
echo "==> rebuilding patched engine sources"
make -C "$PIC" -j"$(nproc)" >/dev/null

# The engine's own link line. Pulling LIBS from its Makefile rather than
# hard-coding it means a configure change (slirp, freetype, png...) does not
# silently break this build.
LIBS="$(sed -n 's/^LIBS = //p' "$PIC/src/Makefile" | head -1)"
[ -n "$LIBS" ] || echo "warning: no LIBS found in $PIC/src/Makefile" >&2

# The engine's own archive list, in its own order, rather than a glob: a glob
# over src/*/lib*.a silently misses the nested ones (libs/gui_tk, hardware/mame,
# hardware/reSID and friends), and the failure surfaces only at dlopen time as
# an undefined symbol like _ZTIN3GUI6WindowE. LDADD also repeats libgui.a
# deliberately, which matters for static-archive resolution order.
# Expanded by make, not by parsing the Makefile text: the list ends in
# $(am__append_1)...$(am__append_10), the automake conditionals that carry
# aviwriter, fluidsynth, mt32, xBRZ and gamelink. Reading the raw text silently
# drops all of them, and the failure only shows up at dlopen time as an
# undefined symbol like _Z18avi_writer_destroyP10avi_writer.
LDADD_RAW="$(make -C "$PIC/src" -s \
    --eval='__print_ldadd:; @echo $(dosbox_x_LDADD)' __print_ldadd 2>/dev/null)"
[ -n "$LDADD_RAW" ] || { echo "error: could not read dosbox_x_LDADD from $PIC/src/Makefile" >&2; exit 1; }

# Deduplicated, keeping first-occurrence order. LDADD lists some archives more
# than once (libgui.a twice), which is harmless in a normal link -- the linker
# just rescans for unresolved symbols -- but under --whole-archive every copy is
# pulled in wholesale and every symbol in it collides with itself:
#   multiple definition of `ElTorito_ChecksumRecord(unsigned char*)'
# Whole-archive needs each archive exactly once.
ARCHIVES=""
seen=" "
for a in $LDADD_RAW; do
    case "$a" in
        *.a)
            case "$seen" in
                *" $a "*) continue ;;
            esac
            seen="$seen$a "
            ARCHIVES="$ARCHIVES $PIC/src/$a"
            ;;
        -l*|-L*)
            # LDADD carries linker flags too, not only archives -- -lduktape
            # arrives this way and appears nowhere in $LIBS. Dropping them
            # surfaces at dlopen as an undefined symbol like duk_pcall.
            EXTRA_LIBS="${EXTRA_LIBS:-} $a"
            ;;
        *) ;;
    esac
done
EXTRA_LIBS="${EXTRA_LIBS:-}"

mkdir -p "$OUT"

echo "==> compiling bridge"
g++ -c -O2 -fPIC -std=gnu++14 \
    -o "$OUT/dosbox_bridge.o" \
    "$BRIDGE/dosbox_bridge.cpp" \
    -I"$BRIDGE" \
    -I"$PIC" -I"$PIC/include" -I"$PIC/src" \
    $(sdl2-config --cflags) \
    -D_XOPEN_SOURCE=700 -D_POSIX_C_SOURCE=200809L

echo "==> linking libdosboxcore.so"
# shellcheck disable=SC2086
g++ -shared -fPIC -o "$OUT/libdosboxcore.so" \
    "$OUT/dosbox_bridge.o" \
    -Wl,--whole-archive \
        $ARCHIVES \
        "$PIC"/src/*.o \
    -Wl,--no-whole-archive \
    $(sdl2-config --libs) $LIBS $EXTRA_LIBS -lpthread

echo "==> checking the ABI is actually exported"
# Symbols are dumped once rather than piped into `grep -q` per symbol: grep -q
# exits at the first match, nm then dies of SIGPIPE (141), and under
# `set -o pipefail` the pipeline reports failure even though the symbol was
# found -- which reads exactly like a missing symbol.
nm -D --defined-only "$OUT/libdosboxcore.so" > "$OUT/exported.syms"
# Every symbol the header declares, not a hand-picked subset: the Dart bindings
# resolve ALL of them at load, so one missing function fails the whole load with
# a message about that symbol and nothing else. A subset check passed happily
# while dosbox_core_config_section_properties was unimplemented.
missing=0
for sym in $(grep -oE '\bdosbox_core_[a-z_]+\(' "$BRIDGE/dosbox_bridge.h" | tr -d '(' | sort -u); do
    grep -q " $sym\$" "$OUT/exported.syms" \
        || { echo "    MISSING: $sym"; missing=1; }
done
[ "$missing" = 0 ] || { echo "error: the C ABI is incomplete" >&2; exit 1; }

echo "==> done"
ls -lh "$OUT/libdosboxcore.so"
