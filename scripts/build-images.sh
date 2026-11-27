#!/usr/bin/env bash
# Builds the xless image from this checkout (scripts/docker-images.sh image, with the xless compiled from this checkout's
# sources), for each architecture given: xless:<short commit>[-dirty]-<arch>. It holds no Xcode: the Xcode is an Xcode pack,
# which `xless setup` prepares (xless setup --docker --xcode <Xcode .xip or .app>). The kits on top of it: `xless setup
# --docker --with tauri,react-native` (make kits), or the first xless run that needs one.
# Usage: scripts/build-images.sh [arch ...]        (or: make images [ARCHS="arm64"])
#   arch: arm64 and/or amd64 (default: both).
#   Docker: DOCKER_CONTEXT, default colima-xless when that context exists.
set -euo pipefail

die() { echo "build-images: $*" >&2; exit 2; }
repo="$(cd "$(dirname "$0")/.." && pwd)"
archs=("$@"); [[ ${#archs[@]} -gt 0 ]] || archs=(arm64 amd64)
for a in "${archs[@]}"; do
  case "$a" in
    arm64|amd64) ;;
    *.xip|*.app|*.app/|*/*) die "an image holds no Xcode any more: '$a' goes into an Xcode pack, which xless setup prepares (xless setup --docker --xcode $a)" ;;
    *) die "unknown architecture '$a' (use arm64 or amd64)" ;;
  esac
done

if [[ -z "${DOCKER_CONTEXT:-}" ]] && docker context ls --format '{{.Name}}' 2>/dev/null | grep -qx colima-xless; then
  export DOCKER_CONTEXT=colima-xless
fi
echo "==> the xless image of this checkout for ${archs[*]}; docker context: ${DOCKER_CONTEXT:-(current)}" >&2
start=$(date +%s)
for a in "${archs[@]}"; do "$repo/scripts/docker-images.sh" image --arch "$a"; done
echo "==> done in $(( ($(date +%s) - start) / 60 )) min" >&2
