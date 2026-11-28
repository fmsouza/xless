#!/bin/sh
# Swift Build for an Xcode pack, compiled by `xless setup` as the pack's swift-build part (this file is part of that
# part's recipe hash). `swbuild` is its CLI; it launches `SWBBuildServiceBundle` from its own directory, and both read the
# resource bundles (`SwiftBuild_*`, the xcspecs) next to the executable. Dependencies are sibling source checkouts
# (SWIFTCI_USE_LOCAL_DEPS=1), so nothing is resolved from a branch at build time.
#   scripts/pack-swift-build.sh <pack root> arm64|amd64 own|separate
# The pins come from the environment: versions.env's SWB_* (the caller sources it, or passes them with env). The pack's
# toolchain (<pack>/toolchain, the open-source release of the Xcode's Swift) compiles it: the same Swift Build release
# whatever the Xcode, running on that toolchain's Swift runtime. Its build service loads the toolchain's dependency scanner
# (lib_InternalSwiftScan) in process for explicitly built modules, and that library's Swift code needs the runtime it was
# built against: Swift 6.2.3's scanner in a Swift 6.4 process crashes (swift_release in evaluatePoundIfCondition).
# The mode is the fit's (own: the toolchain is the image's own Swift, SWIFT_VERSION; separate: another release).
# Writes <pack>/swift-build (swbuild, SWBBuildServiceBundle, the bundles, LICENSE.txt, SOURCE) last, whole, by a rename.
# Relocatable: the executables find the Swift runtime from their own place ($ORIGIN/../toolchain/usr/lib/swift/linux),
# not by the toolchain's absolute path, which a Swift link on Linux records by default; nothing written names the pack.
# Compiled on the machine of the arch it is for (Swift Build under emulation is not compiled here). Needs curl, tar,
# sha256sum, strip, and what the toolchain's `swift build` of it needs (libsqlite3-dev and libncurses-dev on Ubuntu, as
# docker/Dockerfile's tools stage installs).
set -eu
[ $# -eq 3 ] || { echo "usage: $0 <pack root> arm64|amd64 own|separate" >&2; exit 2; }
die() { echo "pack-swift-build: $*" >&2; exit 1; }
case "$3" in own|separate) ;; *) die "mode must be own or separate, not $3" ;; esac
mode=$3
case "$2" in arm64) want=aarch64 ;; amd64) want=x86_64 ;; *) die "arch must be arm64 or amd64, not $2" ;; esac
have=$(uname -m); [ "$have" != arm64 ] || have=aarch64
[ "$have" = "$want" ] || die "Swift Build for $2 is compiled on a $2 machine, and this one is $(uname -m)"
given=$(cd "$1" 2>/dev/null && pwd) || die "no pack at $1"
pack=$(cd -P "$1" && pwd -P)
bin="$pack/toolchain/usr/bin"
[ -x "$bin/swift" ] || die "no toolchain at $pack/toolchain ($bin/swift)"
for v in SWB_TAG SWB_SHA256 SWB_DRIVER_SHA256 SWB_LLBUILD_SHA256 SWB_TSC_SHA256 SWB_TOOLS_PROTOCOLS_SHA256 \
         SWB_ARGUMENT_PARSER_VERSION SWB_ARGUMENT_PARSER_SHA256 SWB_SYSTEM_VERSION SWB_SYSTEM_SHA256 SWB_SQLITE_VERSION SWB_SQLITE_SHA256; do
  eval "value=\${$v:-}"
  # shellcheck disable=SC2154 # set by the eval
  [ -n "$value" ] || die "$v is not set: run it with versions.env's SWB_* pins in the environment (set -a; . versions.env)"
done

out="$pack/swift-build.partial"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp" "$out"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
rm -rf "$out"
src="$tmp/src"

fetch() {
  curl -fsSL -o "$tmp/$1.tar.gz" "https://github.com/$2/archive/refs/tags/$3.tar.gz"
  echo "$4  $tmp/$1.tar.gz" | sha256sum -c - >/dev/null 2>&1 \
    || die "github.com/$2 at $3 does not have versions.env's sha256 ($4): nothing was compiled"
  mkdir -p "$src/$1"; tar -xzf "$tmp/$1.tar.gz" -C "$src/$1" --strip-components=1; rm "$tmp/$1.tar.gz"
}
fetch swift-build swiftlang/swift-build "$SWB_TAG" "$SWB_SHA256"
fetch swift-driver swiftlang/swift-driver "$SWB_TAG" "$SWB_DRIVER_SHA256"
fetch llbuild swiftlang/swift-llbuild "$SWB_TAG" "$SWB_LLBUILD_SHA256"
fetch swift-tools-support-core swiftlang/swift-tools-support-core "$SWB_TAG" "$SWB_TSC_SHA256"
fetch swift-tools-protocols swiftlang/swift-tools-protocols "$SWB_TAG" "$SWB_TOOLS_PROTOCOLS_SHA256"
fetch swift-argument-parser apple/swift-argument-parser "$SWB_ARGUMENT_PARSER_VERSION" "$SWB_ARGUMENT_PARSER_SHA256"
fetch swift-system apple/swift-system "$SWB_SYSTEM_VERSION" "$SWB_SYSTEM_SHA256"
fetch swift-toolchain-sqlite swiftlang/swift-toolchain-sqlite "$SWB_SQLITE_VERSION" "$SWB_SQLITE_SHA256"

cd "$src/swift-build"
export SWIFTCI_USE_LOCAL_DEPS=1 PATH="$bin:$PATH"
# The runtime from the executable's place, not the toolchain's absolute path (swiftc's default rpath on Linux).
# shellcheck disable=SC2016 # $ORIGIN is the dynamic loader's, not the shell's
set -- -Xswiftc -no-toolchain-stdlib-rpath -Xlinker -rpath -Xlinker '$ORIGIN/../toolchain/usr/lib/swift/linux'
swift --version
swift build -c release --product SWBBuildServiceBundle "$@"
swift build -c release --product swbuild "$@"

# With another toolchain than the image's own: `strip --strip-debug` (a full strip breaks Foundation's Bundle lookup in
# Swift 6.2.3's runtime), and resources in `<package>_<target>.resources` (Swift 6.4's SwiftPM writes `.bundle`).
strip_to() { if [ "$mode" = own ]; then strip -o "$1" "$2"; else strip --strip-debug -o "$1" "$2"; fi; }
B="$(swift build -c release --show-bin-path)"; mkdir -p "$out"
for x in swbuild SWBBuildServiceBundle; do strip_to "$out/$x" "$B/$x"; done
for r in "$B"/SwiftBuild_*.bundle "$B"/SwiftBuild_*.resources; do [ ! -e "$r" ] || cp -R "$r" "$out/"; done
ls -d "$out"/SwiftBuild_SWBCore.* >/dev/null || die "no SwiftBuild_SWBCore bundle in $B"
cp "$src/swift-build/LICENSE.txt" "$out/LICENSE.txt"
echo "https://github.com/swiftlang/swift-build/tree/${SWB_TAG}" > "$out/SOURCE"
# swbuild is the executable itself, never a symbolic link to it: Swift 6.2.3's Foundation crashes looking up bundles from a
# symlinked executable. Whoever runs it runs <pack>/swift-build/swbuild by its path.
for p in "$pack" "$given"; do
  # grep: 0 found, 1 found nothing, 2 could not search (that is no clean answer).
  status=0; found=$(grep -rlF "$p" "$out") || status=$?
  case $status in
    0) die "$(echo "$found" | tr '\n' ' ')names the place the pack is prepared in ($p), and a pack must be relocatable" ;;
    1) ;;
    *) die "grep could not search $out for the place the pack is prepared in ($p): it cannot be shown relocatable" ;;
  esac
done

rm -rf "$pack/swift-build"
mv "$out" "$pack/swift-build"
echo "pack-swift-build: Swift Build $SWB_TAG in the pack, on Swift $(swift --version 2>/dev/null | sed -nE 's/.*Swift version ([0-9.]+).*/\1/p' | head -1) ($mode)"
