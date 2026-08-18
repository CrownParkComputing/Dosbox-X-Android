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

if [ ! -f config.h ]; then
    # Same options the original tree was configured with (from its config.log),
    # plus -fPIC. -fPIC must be in CFLAGS/CXXFLAGS at configure time so every
    # sub-Makefile inherits it.
    echo "==> configure (with -fPIC)"
    ./configure --enable-debug --prefix=/usr --enable-sdl2 \
        CFLAGS="-g -std=gnu11 -O2 -fPIC" \
        CXXFLAGS="-g -std=gnu++14 -O2 -msse -fPIC"
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
