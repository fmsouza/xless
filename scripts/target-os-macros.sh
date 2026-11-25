#!/usr/bin/env bash
# Ruling R10: the TARGET_OS_* macros an Xcode's own clang predefines for each triple xless compiles for, measured
# black-box (the compiler's output for an empty input: `clang -target <triple> -dM -E -x c /dev/null`; no Apple file is
# read or copied). Prints docker/toolchain/target-os/<Xcode build>.txt, which docker/Dockerfile checks the image's
# clang against (docker/toolchain/target-os-check):
#   scripts/target-os-macros.sh <Xcode.app> > docker/toolchain/target-os/<Xcode build>.txt
# One "<triple> <macro> <value>" line per macro; "<triple> -" for a triple with none (Linux: Apple clang predefines no
# TARGET_OS_ macro for it, and neither may the image's clang driver).
set -euo pipefail
die() { echo "target-os-macros: $*" >&2; exit 2; }
[[ $# -eq 1 ]] || die "usage: $0 <Xcode.app>"
xcode="$1"
clang="$xcode/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang"
[[ -x "$clang" ]] || die "$clang is missing: pass a full Xcode.app"
plist="$xcode/Contents/version.plist"
build="$(/usr/libexec/PlistBuddy -c 'Print :ProductBuildVersion' "$plist" 2>/dev/null)" || die "no ProductBuildVersion in $plist"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist")"
echo "# Xcode $version ($build), $("$clang" --version | head -1): clang -target <triple> -dM -E -x c /dev/null, its TARGET_OS_ macros."
echo "# Measured black-box by scripts/target-os-macros.sh (compiler output for an empty input); checked by docker/toolchain/target-os-check."
for t in arm64-apple-ios arm64-apple-ios-simulator arm64-apple-macos x86_64-apple-macos aarch64-unknown-linux-gnu x86_64-unknown-linux-gnu; do
  out="$("$clang" -target "$t" -dM -E -x c /dev/null | sed -n 's/^#define \(TARGET_OS_[A-Z0-9_]*\) \(.*\)$/\1 \2/p' | sort)"
  if [[ -z "$out" ]]; then echo "$t -"; else sed "s/^/$t /" <<<"$out"; fi
done
