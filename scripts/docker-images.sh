#!/usr/bin/env bash
# The docker recipe of the xless image (docker/Dockerfile), for a Mac checkout and a Linux install alike: the Makefile,
# scripts/build-images.sh and `xless setup --docker` all build through it. (The kits on top of it are ordinary Dockerfiles:
# docker/tauri, docker/react-native.)
# Usage: scripts/docker-images.sh image --arch <arm64|amd64> [--xless-bin <file>]
#   Builds xless:<version>-<arch>: one image per xless version and architecture, with nothing of an Xcode in it (no Apple
#   file, so it may be published). The Xcode is an Xcode pack, which `xless setup` prepares (in a container of this image
#   for `xless setup --docker`) and builds mount read-only. The version is the share's VERSION file's (a release), else
#   versions.env's XLESS_VERSION; in a git checkout the tag is xless:<short commit>[-dirty]-<arch> instead.
#   --xless-bin <file named xless>: a linux xless of the same arch (its ELF machine is checked against --arch) goes into the
#   image instead of one compiled from source (XLESS_FROM=prebuilt).
#   It runs `docker buildx build --load`. Pins come from versions.env next to this script's directory (the repository, or the
#   installed share/xless), which is the build context. XLESS_IMAGE_ID names the image for `xless prepare`'s fingerprint: the
#   commit (with -dirty) in a git checkout, else v<version>, then the first 12 hex of the sha256 of versions.env.
#   DOCKER: the docker command (default docker); DOCKER_CONTEXT applies as usual.
set -euo pipefail

die() { echo "docker-images: $*" >&2; exit 2; }
usage="usage: $0 image --arch <arm64|amd64> [--xless-bin <file>]"
gone="an image holds no Xcode any more: xless setup prepares the Xcode as an Xcode pack (xless setup --docker --xcode <Xcode .xip or .app>)"
[[ $# -ge 1 ]] || die "$usage"
what="$1"; shift
case "$what" in
  image) ;;
  tools) die "there is no tools image: xtool is in the xless image, and $gone" ;;
  base|sdk|tauri|rn) die "there is one image now, and its kits (xless setup --docker --with …): $usage" ;;
  *) die "unknown image '$what' ($usage)" ;;
esac
arch=""; xless_bin=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --xcode|--xcode-build|--sdk-dir) die "$1: $gone" ;;
  esac
  [[ $# -ge 2 ]] || die "$1 needs a value"
  case "$1" in
    --arch) arch="$2" ;;
    --xless-bin) xless_bin="$2" ;;
    *) die "unknown option $1 ($usage)" ;;
  esac
  shift 2
done
[[ "$arch" == arm64 || "$arch" == amd64 ]] || die "--arch arm64 or amd64 is required"
if [[ -n "$xless_bin" ]]; then
  [[ -f "$xless_bin" ]] || die "$xless_bin does not exist"
  [[ "$(basename "$xless_bin")" == xless ]] || die "--xless-bin must be a file named xless (its directory is the build context)"
  # Its ELF e_machine (offset 18) must be --arch's: 183 aarch64 (arm64), 62 x86-64 (amd64).
  [[ "$(od -An -t x1 -N 4 "$xless_bin" | tr -d ' \n')" == 7f454c46 ]] || die "$xless_bin is not a Linux (ELF) binary"
  machine="$(od -An -t u2 -j 18 -N 2 "$xless_bin" | tr -d ' ')"
  case "$machine" in 183) bin_arch=arm64; bin_name=aarch64 ;; 62) bin_arch=amd64; bin_name=x86-64 ;; *) bin_arch=""; bin_name="ELF machine $machine" ;; esac
  [[ "$bin_arch" == "$arch" ]] || die "$xless_bin is a $bin_name binary, not $arch: pass the linux-$arch xless"
fi

root="$(cd "$(dirname "$0")/.." && pwd)"
docker_cmd="${DOCKER:-docker}"
set -a
# shellcheck disable=SC1091
. "$root/versions.env"
set +a
cd "$root"

version="$XLESS_VERSION"
[[ ! -s VERSION ]] || version="$(tr -d '[:space:]' < VERSION)"
if [[ "$(git -C "$root" rev-parse --show-toplevel 2>/dev/null || true)" == "$root" ]]; then
  id="$(git -C "$root" rev-parse --short=12 HEAD)"
  git -C "$root" diff --quiet HEAD 2>/dev/null || id+="-dirty"
  tag="xless:$id-$arch"
else
  id="v$version"
  tag="xless:$version-$arch"
fi
if command -v sha256sum >/dev/null 2>&1; then vsum="$(sha256sum versions.env | cut -d' ' -f1)"; else vsum="$(shasum -a 256 versions.env | cut -d' ' -f1)"; fi

# No provenance: the same layers are the same image, with the same ID, however often it is built.
args=(buildx build --platform "linux/$arch" --load --provenance=false -t "$tag" -f docker/Dockerfile)
pins=(SWIFT_IMAGE XTOOL_VERSION RCODESIGN_VERSION XTOOL_SHA256_AARCH64 XTOOL_SHA256_X86_64 RCODESIGN_SHA256_AARCH64 RCODESIGN_SHA256_X86_64
  STATIC_SDK_URL STATIC_SDK_SHA256 LIBDMG_HFSPLUS_COMMIT LIBDMG_HFSPLUS_SHA256)
args+=(--build-arg "XLESS_VERSION=$version" --build-arg "XLESS_IMAGE_ID=$id-${vsum:0:12}")
if [[ -n "$xless_bin" ]]; then
  xdir="$(cd "$(dirname "$xless_bin")" && pwd)"
  args+=(--build-arg XLESS_FROM=prebuilt --build-context "xlessbin=$xdir")
fi
for pin in "${pins[@]}"; do args+=(--build-arg "$pin=${!pin}"); done
args+=(.)
echo "==> docker-images: $tag" >&2
exec $docker_cmd "${args[@]}"
