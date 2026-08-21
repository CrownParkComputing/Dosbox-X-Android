#!/usr/bin/env bash
# Build a -fPIC DOSBox-X object tree, which is what libdosboxcore.so links against.
#
# The tree at ~/dosbox-x-src is built for an executable, so its objects are not
# position-independent and cannot go into a shared library:
#
#   relocation R_X86_64_PC32 against `last_callback' can not be used when
#   making a shared object; recompile with -fPIC
#
# Rather than rebuild that tree in place (it is a working checkout), this clones
# it -- git clone -l hardlinks the objects, so the copy is nearly free -- and
# rebuilds there with -fPIC added to the flags the original configure used.
set -euo pipefail

SRC="${DOSBOX_X_SRC:-$HOME/dosbox-x-src}"
DEST="${DOSBOX_X_PIC:-$HOME/dosbox-x-pic}"
JOBS="${JOBS:-$(nproc)}"

[ -d "$SRC/.git" ] || { echo "error: $SRC is not a git checkout" >&2; exit 1; }

if [ ! -d "$DEST" ]; then
    echo "==> cloning $SRC -> $DEST"
    git clone -l "$SRC" "$DEST"
fi

cd "$DEST"

if [ ! -f configure ]; then
    echo "==> autogen"
    ./autogen.sh
fi

# The tree is shared with the Android build, which reconfigures it in place
# for the NDK target (android/build.sh blows away config.h and runs
# ./configure --host=<triple>). A plain `make` after that compiles host
# objects with the Android toolchain and fails at the dosbox-x executable
# link with "undefined symbol: main". Detect the cross config and force a
# host reconfigure instead of trusting that an existing config.h is ours.
CONFIGURED_HOST=""
if [ -f config.status ]; then
    CONFIGURED_HOST=$(sed -n "s/.*--host=\([^ ']*\).*/\1/p" config.status | head -1)
fi
HOST_CPU=$(gcc -dumpmachine | cut -d- -f1)

# A cross config is any explicit --host that is not the host's own triple.
# Compare loosely rather than exactly (vendor fields differ), but DO match on
# the OS part too: x86_64-linux-android has the host's CPU, and an arch-only
# compare would wave an Android-configured tree through to a host build.
CROSS_CONFIG=0
if [ -n "$CONFIGURED_HOST" ]; then
    case "$CONFIGURED_HOST" in
        *android*|*apple*|*darwin*) CROSS_CONFIG=1 ;;
        "$HOST_CPU"*) CROSS_CONFIG=0 ;;
        *) CROSS_CONFIG=1 ;;
    esac
fi

if [ ! -f config.h ] || [ "$CROSS_CONFIG" = 1 ]; then
    if [ -n "$CONFIGURED_HOST" ]; then
        echo "==> tree was configured for $CONFIGURED_HOST; reconfiguring for the host"
        # Mirrors android/build.sh: a second ./configure over an old
        # config.status leaves stale values, so clear them first.
        rm -f config.h config.status src/Makefile
    fi
    # Same options the original tree was configured with (from its config.log),
    # plus -fPIC. -fPIC must be in CFLAGS/CXXFLAGS at configure time so every
    # sub-Makefile inherits it.
    echo "==> configure (with -fPIC)"
    ./configure --enable-debug --prefix=/usr --enable-sdl2 \
        CFLAGS="-g -std=gnu11 -O2 -fPIC" \
        CXXFLAGS="-g -std=gnu++14 -O2 -msse -fPIC"

    # A reconfigured tree keeps the previous target's objects: make only
    # rebuilds what is newer than the .o, and the Android build's aarch64
    # objects are all newer than their sources, so the host link then fails
    # with "Relocations in generic ELF (EM: 183)". Clean them out.
    echo "==> make clean (dropping the previous target's objects)"
    make clean >/dev/null 2>&1 || true
fi

# The same staleness survives when the PREVIOUS run already reconfigured for
# the host (this run then skips configure, and with it the clean above), and
# in a fresh clone, whose hardlinked objects come from the non-PIC source
# tree. Check what is actually on disk rather than what this run did: any
# object whose arch is not the host's poisons the link, so drop them all.
# `file` names arches differently from gcc -dumpmachine (x86-64 vs x86_64).
case "$HOST_CPU" in
    x86_64)  FILE_CPU="x86-64" ;;
    aarch64) FILE_CPU="AArch64" ;;
    *)       FILE_CPU="$HOST_CPU" ;;
esac
SAMPLE_O=$(find src -name '*.o' -print -quit 2>/dev/null)
if [ -n "$SAMPLE_O" ] && ! file "$SAMPLE_O" | grep -q "$FILE_CPU"; then
    echo "==> stale objects for a different arch ($(file -b "$SAMPLE_O" | cut -d, -f2 | xargs)); make clean"
    make clean >/dev/null 2>&1 || true
fi

echo "==> building with $JOBS jobs (this takes a while)"
make -j"$JOBS"

echo "==> verifying the tree is PIC-clean"
echo 'void _probe(void){}' > /tmp/pic_probe.c
gcc -shared -fPIC -o /tmp/pic_probe.so /tmp/pic_probe.c \
    -Wl,--whole-archive src/cpu/libcpu.a -Wl,--no-whole-archive \
    2>&1 | grep -E "recompile with -fPIC" && {
        echo "error: still not PIC" >&2; exit 1; }

echo "==> done: $DEST"
