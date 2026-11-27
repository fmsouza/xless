#!/usr/bin/env bash
# Builds samples/HelloTauri on Linux (in the tauri kit's image) through build, assets and finalize, then compares the
# finalize output with samples/HelloTauri/reference/reference.json, ignoring the known gaps in
# samples/HelloTauri/reference/allowed-gaps.txt. Exits non-zero on any other difference or on any failed stage.
# No signing, no App Store Connect: the build number is explicit, so no dated-build lookup happens.
#   make test-tauri-linux
#   scripts/test-tauri-linux.sh --platform macos
# --platform macos (default ios) builds the universal macOS app instead, through finalize, and compares it with
# samples/HelloTauri/reference/macos/reference.json (allowed-gaps.txt next to it). Then it builds an UNSIGNED DMG from that
# app (the hidden `xless shim dmg-build`: no signing, no notarization, no secrets) and checks the image's name and its
# root listing against reference/macos/dmg.json (known gap: create-dmg's .VolumeIcon.icns and Finder layout).
# iOS on a Mac host: the asset catalogs are compared too. The container copies the finalized app's .car files to
# /cache/work/.assets-check (xless-work volume); the host copies them out and `xless tauri compare --assets-only`
# (host build) reads them and the reference's recorded catalogs with `xcrun assetutil --info` (Opaque, colour space,
# pixel size, … per rendition; docs/research/parity-known-gaps.md, "Asset catalog comparison"). Elsewhere it is skipped.
# Variables: ARCH (arm64 or amd64; default the host's: ARCH=amd64 on an arm64 Mac runs the amd64 chain under emulation),
#   XLESS_XCODE_PIN (default versions.env's XCODE_VERSION): the Xcode whose pack the container gets, read-only, as xless run gives it
#   (its volume xless-xcode-<XLESS_XCODE_PIN>-<build>-<arch>, or its directory in XLESS_XCODES), e.g. XLESS_XCODE_PIN=26.2;
#   XLESS_IMAGE (default xless:<this checkout's tag>-<arch>-tauri, which xless setup --docker --with tauri builds),
#   DOCKER_CONTEXT (default colima-xless if it exists).
# The repository is mounted read-only; the work copy lives in the xless-work volume, Rust toolchains in xless-rustup and
# xless-cargo (the first run downloads them and builds the Rust code, which takes a few minutes; later runs are faster).
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
ctx="${DOCKER_CONTEXT:-}"
if [[ -z "$ctx" ]] && docker context ls --format '{{.Name}}' 2>/dev/null | grep -qx 'colima-xless'; then ctx=colima-xless; fi
case "$(uname -m)" in arm64|aarch64) arch=arm64 ;; *) arch=amd64 ;; esac
vsuf=""; plat=()   # ARCH=amd64|arm64 runs the image of that architecture (under emulation when it is not the host's)
if [[ -n "${ARCH:-}" ]]; then
  [[ "$ARCH" == arm64 || "$ARCH" == amd64 ]] || { echo "test-tauri-linux: ARCH must be arm64 or amd64" >&2; exit 2; }
  [[ "$ARCH" == "$arch" ]] || vsuf="-$ARCH"   # another architecture's work copy and Rust toolchains stay apart from the host's
  arch="$ARCH"; plat=(--platform "linux/$ARCH")
fi
xcode="${XLESS_XCODE_PIN:-$(sed -n 's/^XCODE_VERSION=//p' "$root/versions.env")}"   # the Xcode whose pack builds (XLESS_XCODE_PIN=26.2: that pin's; not XCODE, the Xcode.app the Makefile exports for make images)
[[ "$xcode" =~ ^[0-9]+(\.[0-9]+)*$ ]] || { echo "test-tauri-linux: XLESS_XCODE_PIN must be an Xcode version such as 26.2, not $xcode" >&2; exit 2; }
image="${XLESS_IMAGE:-xless:$("$root/scripts/docker-images.sh" tag --arch "$arch")-$arch-tauri}"   # xless setup --docker --with tauri builds it
platform=ios
while [[ $# -gt 0 ]]; do
  case "$1" in
    --platform) [[ $# -ge 2 ]] || { echo "--platform needs ios or macos" >&2; exit 2; }; platform="$2"; shift 2 ;;
    --platform=*) platform="${1#--platform=}"; shift ;;
    *) echo "usage: $0 [--platform ios|macos]" >&2; exit 2 ;;
  esac
done
[[ "$platform" == ios || "$platform" == macos ]] || { echo "--platform must be ios or macos" >&2; exit 2; }
args=(docker)
[[ -z "$ctx" ]] || args+=(--context "$ctx")
# shellcheck source=SCRIPTDIR/xcode-pack-args.sh
. "$root/scripts/xcode-pack-args.sh"   # pack_args: the Xcode's pack, read-only, as xless run gives it
pack_args test-tauri-linux

# The in-container script reads the same XLESS_BUILD_NUMBER from the environment, never contacting App Store Connect. The overlay
# is `build: dated`, so the override is a dated build of the sample's version (1.0.0).
"${args[@]}" run --rm -i --pull=never ${plat[@]+"${plat[@]}"} "${pack[@]}" -v "$root":/repo:ro -v "xless-work$vsuf":/cache/work -v "xless-rustup$vsuf":/cache/rustup -v "xless-cargo$vsuf":/cache/cargo \
  -e XLESS_BUILD_NUMBER="$([[ $platform == macos ]] && echo 1.0.0.202601010000 || echo 1.0.0.2026010101)" -e PLATFORM="$platform" \
  "$image" bash -s <<'IN'
set -euo pipefail
o=/repo/samples/HelloTauri/xless.overlay.example.yml
s=/repo/samples/HelloTauri
r=/repo/samples/HelloTauri/reference
if [[ "$PLATFORM" == macos ]]; then
  r=$r/macos
  final=$(xless ship --config "$o" --source "$s" --platform macos --to finalize | tail -1)
  echo "==> comparing $final with the macOS reference"
  xless tauri compare "$r/reference.json" "$final" --allow-file "$r/allowed-gaps.txt"
  echo "==> building an unsigned DMG (no signing, no notarization)"
  out=$(mktemp -d)
  dmg=$(xless shim dmg-build "$final" "$out/dmg" --volume-name HelloTauri --app-version 1.0.0 | tail -1)
  want=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['fileName'])" "$r/dmg.json")
  [[ "$(basename "$dmg")" == "$want" ]] || { echo "DMG is named $(basename "$dmg"), the reference $want"; exit 1; }
  dmg extract "$dmg" "$out/img.hfs" >/dev/null
  # `hfsplus ls`: "<mode> <uid> <gid> <size> <date> <time> <name>" per entry, then a total line
  root=$(hfsplus "$out/img.hfs" ls /)
  listing=$(awk '/^[0-7][0-7][0-7][0-7][0-7][0-7] /{ $1=$2=$3=$4=$5=$6=""; sub(/^ +/, ""); print }' <<<"$root" | sort)
  grep -q '^120[0-7]* .* Applications$' <<<"$root" || { echo "/Applications is not a symlink:"; echo "$root"; exit 1; }
  # the reference root minus create-dmg's volume icon (a known gap)
  expected=$(python3 -c "import json,sys; print('\n'.join(sorted(e['name'] for e in json.load(open(sys.argv[1]))['entries'] if e['name'] != '.VolumeIcon.icns')))" "$r/dmg.json")
  if [[ "$listing" != "$expected" ]]; then
    echo "DMG root listing differs from the reference (minus .VolumeIcon.icns):"; diff <(echo "$expected") <(echo "$listing") || true; exit 1
  fi
  echo "==> HelloTauri macOS matches the Mac reference (known gaps: $r/allowed-gaps.txt, docs/research/parity-known-gaps.md)"
  exit 0
fi
# prepare, build, assets, finalize; ship prints each stage's output directory, finalize's last
final=$(xless ship --config "$o" --source "$s" --platform ios --to finalize | tail -1)
echo "==> comparing $final with the reference"
xless tauri compare "$r/reference.json" "$final" --allow-file "$r/allowed-gaps.txt"
echo "==> HelloTauri matches the Mac reference (known gaps: $r/allowed-gaps.txt)"
rm -rf /cache/work/.assets-check && mkdir -p /cache/work/.assets-check
(cd "$final" && find . -name '*.car' -exec cp --parents {} /cache/work/.assets-check/ \;)
IN
if [[ "$platform" == ios ]]; then
  if [[ "$(uname)" == Darwin ]]; then
    r="$root/samples/HelloTauri/reference"
    cars="$(mktemp -d "${TMPDIR:-/tmp}/hellotauri-cars.XXXXXX")"
    alpine="$(sed -n 's/^ALPINE_IMAGE=//p' "$root/versions.env")"   # pinned by digest
    [[ -n "$alpine" ]] || { echo "versions.env has no ALPINE_IMAGE" >&2; exit 2; }
    "${args[@]}" run --rm -v "xless-work$vsuf":/cache/work:ro "$alpine" tar -C /cache/work/.assets-check -cf - . | tar -C "$cars" -xf -
    (cd "$root" && env -u DEVELOPER_DIR swift build --product xless -q)
    x="$(cd "$root" && env -u DEVELOPER_DIR swift build --show-bin-path)/xless"
    echo "==> comparing the finalized app's asset catalogs with the reference (assetutil)"
    "$x" tauri compare --assets-only "$r/reference.json" "$cars" --allow-file "$r/allowed-gaps.txt"
    rm -rf "$cars"
    echo "==> HelloTauri asset catalogs match the Mac reference (known gaps: $r/allowed-gaps.txt)"
  else
    echo "==> HelloTauri: asset catalog comparison skipped (needs xcrun assetutil, a Mac host)"
  fi
fi
