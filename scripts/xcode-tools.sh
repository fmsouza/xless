#!/usr/bin/env bash
# The asset and storyboard tools gate: an image is made only from an Xcode build whose actool, ibtool and copypng
# output formats xless has measured (an entry in Sources/XlessCore/XcodeToolsProfile.swift). The image's
# actool/ibtool shims refuse a build without an entry (exit 70) and never write another Xcode's formats, so an image made
# from an unprofiled Xcode could not compile an asset catalog or a storyboard: refuse it here, before anything is built.
# Usage: scripts/xcode-tools.sh <Xcode build>        (scripts/rn-reference.sh runs it)
#   0  the build has a profile
#   2  it has none: the commands that measure it are printed
#   XCODE_TOOLS_PROFILE: the Swift file to read (default: the repository's XcodeToolsProfile.swift).
set -euo pipefail

die() { echo "xcode-tools: $*" >&2; exit 2; }
[[ $# -eq 1 ]] || die "usage: $0 <Xcode build>"
build="$1"
[[ "$build" =~ ^[0-9A-Za-z]+$ ]] || die "unexpected Xcode build '$build'"
file="${XCODE_TOOLS_PROFILE:-$(cd "$(dirname "$0")/.." && pwd)/Sources/XlessCore/XcodeToolsProfile.swift}"
[[ -f "$file" ]] || die "$file is missing"

# One `xcodeBuild: "<B>"` literal per entry (a test keeps it so); the doc comments mention `xcodeBuild:` without a quote.
if grep -Fq "xcodeBuild: \"$build\"" "$file"; then exit 0; fi

known="$(sed -nE 's/.*xcodeBuild: "([^"]+)".*/\1/p' "$file" | sort -u | tr '\n' ' ')"
cat >&2 <<MSG
xcode-tools: Xcode build $build has no asset/storyboard tools profile (measured: ${known:-none}).
An image made from it could not compile asset catalogs or storyboards, so no image is built.
Measure that Xcode's actool, ibtool and copypng black-box (DEVELOPER_DIR selects the Xcode), then add an
XcodeToolsProfile entry (Sources/XlessCore/XcodeToolsProfile.swift) with the measured values:
  DEVELOPER_DIR=<Xcode.app>/Contents/Developer scripts/assetkit-golden.sh
  DEVELOPER_DIR=<Xcode.app>/Contents/Developer scripts/ib-golden.sh
  DEVELOPER_DIR=<Xcode.app>/Contents/Developer scripts/copypng-golden.sh
MSG
exit 2
