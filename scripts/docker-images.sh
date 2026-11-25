#!/usr/bin/env bash
# The docker recipe of the xless image (docker/Dockerfile), for a Mac checkout and a Linux install alike: the Makefile,
# scripts/build-images.sh and `xless setup --docker` all build through it. (The kits on top of it are ordinary Dockerfiles:
# docker/tauri, docker/react-native.)
# Usage: scripts/docker-images.sh tools --arch <arm64|amd64>
#   Builds xless:local-<arch>-setup: Swift, xtool and rcodesign, no SDK. `xtool sdk build` runs in it.
#        scripts/docker-images.sh image --arch <arm64|amd64> --xcode <version> --xcode-build <build> --sdk-dir <dir> [--xless-bin <file>]
#   Builds xless:local-<arch>-xcode<version> from the exported Darwin SDK in --sdk-dir. --xcode is major.minor (26.6), with the
#   patch when it is not 0 (26.0.1); --xcode-build (17F113) gives the Swift toolchain (scripts/xcode-swift.sh).
#   --xless-bin <file named xless>: a linux xless of the same arch (its ELF machine is checked against --arch) goes into the
#   image instead of one compiled from source (XLESS_FROM=prebuilt).
#   Both run `docker buildx build --load`. Pins come from versions.env next to this script's directory (the repository, or the
#   installed share/xless), which is the build context. XLESS_IMAGE_ID names the image for `xless prepare`'s fingerprint: the
#   commit (with -dirty) in a git checkout, else v<version>, then the first 12 hex of the sha256 of versions.env, then the Xcode.
#   DOCKER: the docker command (default docker); DOCKER_CONTEXT applies as usual.
set -euo pipefail

die() { echo "docker-images: $*" >&2; exit 2; }
usage="usage: $0 tools --arch <arm64|amd64>   or   $0 image --arch <arm64|amd64> --xcode <version> --xcode-build <build> --sdk-dir <dir> [--xless-bin <file>]"
[[ $# -ge 1 ]] || die "$usage"
what="$1"; shift
case "$what" in
  tools|image) ;;
  base|sdk|tauri|rn) die "there is one image now, and its kits (xless setup --docker --with …): $usage" ;;
  *) die "unknown image '$what' ($usage)" ;;
esac
arch=""; sdk_dir=""; xless_bin=""; xcode=""; xcode_build=""
while [[ $# -gt 0 ]]; do
  [[ $# -ge 2 ]] || die "$1 needs a value"
  case "$1" in
    --arch) arch="$2" ;;
    --xcode) xcode="$2" ;;
    --xcode-build) xcode_build="$2" ;;
    --sdk-dir) sdk_dir="$2" ;;
    --xless-bin) xless_bin="$2" ;;
    *) die "unknown option $1 ($usage)" ;;
  esac
  shift 2
done
[[ "$arch" == arm64 || "$arch" == amd64 ]] || die "--arch arm64 or amd64 is required"
if [[ "$what" == image ]]; then
  [[ "$xcode" =~ ^[0-9]+\.[0-9]+(\.[1-9][0-9]*)?$ ]] || die "image needs --xcode <version>: major.minor, with the patch when it is not 0"
  [[ -n "$xcode_build" ]] || die "image needs --xcode-build <the Xcode build the SDK comes from>"
  [[ -n "$sdk_dir" ]] || die "image needs --sdk-dir <the exported SDK>"
else
  [[ -z "$xcode$xcode_build$sdk_dir$xless_bin" ]] || die "tools takes --arch only"
fi
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

tag="xless:local-$arch-setup"
[[ "$what" == tools ]] || tag="xless:local-$arch-xcode$xcode"
# No provenance: the same layers are the same image, with the same ID, however often it is built.
args=(buildx build --platform "linux/$arch" --load --provenance=false -t "$tag" -f docker/Dockerfile)
pins=(SWIFT_IMAGE XTOOL_VERSION RCODESIGN_VERSION XTOOL_SHA256_AARCH64 XTOOL_SHA256_X86_64 RCODESIGN_SHA256_AARCH64 RCODESIGN_SHA256_X86_64)
if [[ "$what" == tools ]]; then
  args+=(--target tools)
else
  pins+=(STATIC_SDK_URL STATIC_SDK_SHA256 LIBDMG_HFSPLUS_COMMIT LIBDMG_HFSPLUS_SHA256
    SWB_TAG SWB_SHA256 SWB_DRIVER_SHA256 SWB_LLBUILD_SHA256 SWB_TSC_SHA256 SWB_TOOLS_PROTOCOLS_SHA256
    SWB_ARGUMENT_PARSER_VERSION SWB_ARGUMENT_PARSER_SHA256 SWB_SYSTEM_VERSION SWB_SYSTEM_SHA256 SWB_SQLITE_VERSION SWB_SQLITE_SHA256)
  version="$XLESS_VERSION"
  [[ ! -s VERSION ]] || version="$(tr -d '[:space:]' < VERSION)"
  if [[ "$(git -C "$root" rev-parse --show-toplevel 2>/dev/null || true)" == "$root" ]]; then
    id="$(git -C "$root" rev-parse --short=12 HEAD)"
    git -C "$root" diff --quiet HEAD 2>/dev/null || id+="-dirty"
  else
    id="v$version"
  fi
  if command -v sha256sum >/dev/null 2>&1; then vsum="$(sha256sum versions.env | cut -d' ' -f1)"; else vsum="$(shasum -a 256 versions.env | cut -d' ' -f1)"; fi
  swift_out="$("$root/scripts/xcode-swift.sh" "$xcode_build")" || exit 2
  while IFS= read -r line; do [[ -z "$line" ]] || args+=(--build-arg "$line"); done <<<"$swift_out"
  args+=(--build-context "sdk=$sdk_dir" --build-arg "XLESS_XCODE=$xcode" --build-arg "XLESS_XCODE_BUILD=$xcode_build"
    --build-arg "XLESS_VERSION=$version" --build-arg "XLESS_IMAGE_ID=$id-${vsum:0:12}-xcode$xcode-$xcode_build")
  if [[ -n "$xless_bin" ]]; then
    xdir="$(cd "$(dirname "$xless_bin")" && pwd)"
    args+=(--build-arg XLESS_FROM=prebuilt --build-context "xlessbin=$xdir")
  fi
fi
for pin in "${pins[@]}"; do args+=(--build-arg "$pin=${!pin}"); done
args+=(.)
echo "==> docker-images: $tag" >&2
exec $docker_cmd "${args[@]}"
