#!/usr/bin/env bash
# Build the minimal FreeDOS review image from the official, verified release.
set -euo pipefail
export TZ=UTC

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEMO_DIR="$REPO_ROOT/flutter_app/assets/demo"
BUILD_DIR="$(mktemp -d)"
trap 'rm -rf "$BUILD_DIR"' EXIT

FD_ZIP="$BUILD_DIR/FD14-FloppyEdition.zip"
FD_URL="https://download.freedos.org/1.4/FD14-FloppyEdition.zip"
FD_SHA256="45b1fa7c52dd996c3bfa5e352ffcd410781b952a6ad629f15a4c9ec4bbaefc5a"
IMAGE="$DEMO_DIR/FREEDOS.IMG"

"$REPO_ROOT/tools/build-homebrew-demo.sh"

curl --fail --location --silent --show-error --output "$FD_ZIP" "$FD_URL"
echo "$FD_SHA256  $FD_ZIP" | sha256sum --check --status

unzip -j -q "$FD_ZIP" 144m/x86BOOT.img -d "$BUILD_DIR"
cp "$BUILD_DIR/x86BOOT.img" "$IMAGE"

# Preserve only the two official FreeDOS binaries the demo needs. Everything
# else on the distribution's installer floppy has its own package/licence and
# would enlarge both the image and the compliance surface for no benefit.
mcopy -i "$IMAGE" ::FREEDOS/BIN/COMMAND.COM "$BUILD_DIR/COMMAND.COM"
mdeltree -i "$IMAGE" ::FREEDOS
mdel -i "$IMAGE" ::SETUP.BAT ::FDAUTO.BAT ::FDCONFIG.SYS

printf '%s\r\n' \
  '!FILES=20' \
  '!BUFFERS=20' \
  '!LASTDRIVE=Z' \
  '!SHELL=\COMMAND.COM /E:1024 /P=\AUTOEXEC.BAT' \
  > "$BUILD_DIR/FDCONFIG.SYS"

printf '%s\r\n' \
  '@ECHO OFF' \
  'CLS' \
  'ECHO FreeDOS 1.4 - Retro-DosBox legal homebrew environment' \
  'RETRODEM.COM' \
  'ECHO.' \
  'ECHO Demo ended. Type RETRODEM to run it again.' \
  > "$BUILD_DIR/AUTOEXEC.BAT"

# Copy every injected file through the temporary directory and give it a
# fixed timestamp. With mcopy -m this keeps the derived FAT image identical
# across rebuilds instead of embedding the wall clock time.
for name in RETRODEM.COM README.txt FREEDOS.txt LICENSE.txt GPL-2.0.txt; do
  cp "$DEMO_DIR/$name" "$BUILD_DIR/$name"
done
touch -t 202504050000 "$BUILD_DIR"/*

mcopy -m -o -i "$IMAGE" \
  "$BUILD_DIR/COMMAND.COM" \
  "$BUILD_DIR/FDCONFIG.SYS" \
  "$BUILD_DIR/AUTOEXEC.BAT" \
  "$BUILD_DIR/RETRODEM.COM" \
  "$BUILD_DIR/README.txt" \
  "$BUILD_DIR/FREEDOS.txt" \
  "$BUILD_DIR/LICENSE.txt" \
  "$BUILD_DIR/GPL-2.0.txt" \
  ::

echo "Built $IMAGE"
mdir -i "$IMAGE" ::
