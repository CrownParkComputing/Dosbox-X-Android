#!/usr/bin/env bash
# Rebuild the original store-review demo as a 16-bit DOS .COM executable.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEMO_DIR="$REPO_ROOT/flutter_app/assets/demo"
BUILD_DIR="$(mktemp -d)"
trap 'rm -rf "$BUILD_DIR"' EXIT

as --32 -mx86-used-note=no \
    -o "$BUILD_DIR/retro_demo.o" "$DEMO_DIR/retro_demo.S"
ld -m elf_i386 -Ttext 0x100 --oformat binary \
    -o "$DEMO_DIR/RETRODEM.COM" "$BUILD_DIR/retro_demo.o"

size="$(wc -c < "$DEMO_DIR/RETRODEM.COM")"
echo "Built $DEMO_DIR/RETRODEM.COM ($size bytes)"
