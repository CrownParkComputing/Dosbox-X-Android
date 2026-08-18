#!/usr/bin/env bash
# Host entry point: build the iOS core from Linux, with no Mac involved.
#
#   native/dosbox_core/ios/build-ios.sh              # everything (slow first time)
#   SKIP_SDL=1 native/dosbox_core/ios/build-ios.sh   # skip the dependency stage
#
# Uses the mobaiapp/iosbox cross toolchain (clang targeting arm64-apple-ios,
# ld64.lld) against an iOS SDK in the `iosbox-sdk` Docker volume.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../../.." && pwd)"
IMAGE="${DOSBOX_IOS_IMAGE:-dosbox-iosbox:latest}"
SDK_VOLUME="${IOSBOX_SDK_VOLUME:-iosbox-sdk}"
DOSBOX_X_SRC="${DOSBOX_X_SRC:-$HOME/dosbox-x-src}"

docker volume inspect "$SDK_VOLUME" >/dev/null 2>&1 \
    || { echo "error: Docker volume '$SDK_VOLUME' not found - the iOS SDK is not registered." >&2; exit 1; }
[ -d "$DOSBOX_X_SRC" ] \
    || { echo "error: no DOSBox-X source at $DOSBOX_X_SRC" >&2; exit 1; }

docker image inspect "$IMAGE" >/dev/null 2>&1 || {
    echo "==> building $IMAGE"
    docker build -t "$IMAGE" "$HERE"
}

# The container runs as root and leaves everything it wrote into the bind mount
# root-owned, which breaks the host Flutter afterwards AND makes the next run's
# own cleanup fail with a wall of "rm: Permission denied". Hand ownership back
# whatever happens, including on failure -- otherwise a broken build is also an
# unfixable one.
restore_ownership() {
    docker run --rm -v "$REPO_ROOT:/proj" alpine \
        chown -R "$(id -u):$(id -g)" /proj/native/dosbox_core >/dev/null 2>&1 || true
}
trap restore_ownership EXIT

# The source is mounted read-only: the container clones from it and never
# writes to the host checkout.
docker run --rm \
    -e "SKIP_SDL=${SKIP_SDL:-0}" \
    -v "$SDK_VOLUME:/root/.iosbox" \
    -v "$REPO_ROOT:/proj" \
    -v "$DOSBOX_X_SRC:/dosbox-src:ro" \
    "$IMAGE" bash -lc "/proj/native/dosbox_core/ios/build-core-ios.sh"
