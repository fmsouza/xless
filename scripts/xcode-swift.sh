#!/usr/bin/env bash
# Ruling R10: the Swift toolchain an Xcode's pack compiles app code with (a check of versions.env's entry for an Xcode). Reads Apple's Swift for the Xcode build
# from versions.env's table (XCODE_APPLE_SWIFT_<build>, measured once on the maintainer's Mac; nothing is executed),
# looks the build up in the map (XCODE_SWIFT_<build>), checks the entry against the map's rule (same major.minor as
# Apple's Swift, patch not above it), and prints the toolchain's variables, one per line:
#   APP_SWIFT_VERSION=<x.y.z>            (empty when it is versions.env's SWIFT_VERSION: the image's own Swift, fit mode own)
#   APP_SWIFT_URL_AARCH64=… APP_SWIFT_SHA256_AARCH64=… APP_SWIFT_URL_X86_64=… APP_SWIFT_SHA256_X86_64=…
# Refuses (exit 2) an Xcode without an entry, an entry that breaks the rule, and a release without pinned downloads.
# Usage: scripts/xcode-swift.sh <Xcode build>       (docs/maintainers.md: adding an Xcode)
#   VERSIONS_ENV: the versions file (default: the repository's versions.env).
set -euo pipefail

die() { echo "xcode-swift: $*" >&2; exit 2; }
[[ $# -eq 1 ]] || die "usage: $0 <Xcode build>"
build="$1"
versions="${VERSIONS_ENV:-$(cd "$(dirname "$0")/.." && pwd)/versions.env}"
[[ "$build" =~ ^[0-9A-Za-z]+$ ]] || die "unexpected Xcode build '$build'"
set -a; . "$versions"; set +a

avar="XCODE_APPLE_SWIFT_$build"
apple="${!avar:-}"
[[ -n "$apple" ]] || die "Xcode build $build is not a supported release: versions.env has no $avar (add the XCODE_* table entries)"
line="Apple Swift $apple"

var="XCODE_SWIFT_$build"
mapped="${!var:-}"
[[ -n "$mapped" ]] || die "Xcode build $build ships $line, and versions.env has no $var: add $var=<the open-source release with the same major.minor and the highest patch not above ${apple}> (and its SWIFT_TOOLCHAIN_<x_y_z>_* downloads unless it is SWIFT_VERSION $SWIFT_VERSION)"
[[ "$mapped" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "$var=$mapped is not a release (x.y.z)"
IFS=. read -r am an ap _ <<<"$apple.0.0"
IFS=. read -r om on op <<<"$mapped"
[[ "$am" == "$om" && "$an" == "$on" && "$op" -le "$ap" ]] \
  || die "$var=$mapped breaks the map's rule for Xcode build $build's Swift $apple (same major.minor, patch not above Apple's)"
echo "==> Xcode build $build: $line → swift-$mapped-RELEASE" >&2

if [[ "$mapped" == "$SWIFT_VERSION" ]]; then
  echo "APP_SWIFT_VERSION="
  exit 0
fi
key="SWIFT_TOOLCHAIN_${mapped//./_}"
echo "APP_SWIFT_VERSION=$mapped"
for a in AARCH64 X86_64; do
  for f in URL SHA256; do
    v="${key}_${f}_$a"
    [[ -n "${!v:-}" ]] || die "versions.env has no $v for swift-$mapped-RELEASE"
    echo "APP_SWIFT_${f}_$a=${!v}"
  done
done
