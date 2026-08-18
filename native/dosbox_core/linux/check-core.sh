#!/usr/bin/env bash
# Boot the core on the host and prove it renders. Run this before any device build.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="$HERE/build"
LIB="$OUT/libdosboxcore.so"
PIC="${DOSBOX_X_PIC:-$HOME/dosbox-x-pic}"

[ -f "$LIB" ] || { echo "error: no $LIB - run build.sh first." >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# output=gamelink is the whole point: it is the offscreen renderer the bridge
# hooks. Any other output tries to open a window and publishes nothing.
cat > "$WORK/dosbox-x.conf" <<CONF
[sdl]
output=gamelink
# Required. Without it OUTPUT_GAMELINK_Select() refuses and silently falls back
# to output=surface -- the engine still boots and renders, it just renders into
# a window surface the bridge cannot see, so the framebuffer stays null.
gamelink master=true
autolock=false
waitonerror=false
[dosbox]
memsize=16
title=bridge-check
[cpu]
cycles=fixed 3000
[autoexec]
echo BRIDGE CHECK
CONF

echo "==> conf: $WORK/dosbox-x.conf"
gcc -O1 -o "$WORK/check-core" "$HERE/check-core.c" -ldl
cd "$WORK"   # DOSBox-X writes stray files (mapper, logs) next to the cwd
"$WORK/check-core" "$LIB" "$WORK/dosbox-x.conf" "$PIC"
