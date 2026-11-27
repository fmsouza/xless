#!/bin/sh
# The checks of an Xcode pack that need its SDK: those docker/Dockerfile's last stage ran when the image held the SDK,
# each in the form it had there, run against the pack (XLESS_XCODE) with the shims of this machine (XLESS_SHIM_DIR,
# first on PATH, as in the image) and the pack's toolchain before the rest of PATH, as a build has them.
#   scripts/pack-check.sh <pack root>
# A pack checked here has both parts: the SDK (and its fitted toolchain) and Swift Build. Writes nothing in the pack.
set -eu
[ $# -eq 1 ] || { echo "usage: $0 <pack root>" >&2; exit 2; }
die() { echo "pack-check: $*" >&2; exit 1; }
pack=$(cd -P "$1" 2>/dev/null && pwd -P) || die "no pack at $1"
shims=${XLESS_SHIM_DIR:-}
[ -n "$shims" ] && [ -d "$shims" ] || die "XLESS_SHIM_DIR names no directory of shims (${shims:-unset}): the checks run Xcode's tools through them"
export XLESS_XCODE="$pack" PATH="$shims:$pack/toolchain/usr/bin:$PATH"
bundle="$pack/config/swiftpm/swift-sdks/darwin.artifactbundle"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

xcrun --sdk iphoneos --show-sdk-path >/dev/null || die "xcrun --sdk iphoneos --show-sdk-path finds no iOS SDK in the pack"
actool --version --output-format xml1 | grep -qE '<string>[0-9]+</string>' || die "actool answers no version (an Xcode without a profile?)"
xcrun actool --version --output-format xml1 | grep -qE '<string>[0-9]+</string>' || die "xcrun actool answers no version"
ibtool --version --output-format xml1 | grep -qE '<string>[0-9]+</string>' || die "ibtool answers no version (an Xcode without a profile?)"
xcodebuild -version | grep -qx 'Build version [0-9A-Za-z]*' || die "xcodebuild -version prints no build version"
echo 'int f(void){return 0;}' | PATH="$shims/prepare:$PATH" clang -x c - -dynamiclib -o "$tmp/stub" -install_name @rpath/S.framework/S \
  || die "the iOS stub dylib (Expo's ExpoModulesJSI) does not link"
test -s "$tmp/stub" || die "the iOS stub dylib is empty"
"$pack/swift-build/swbuild" --help >/dev/null || die "$pack/swift-build/swbuild --help fails"
test -f "$bundle/toolset-swb.json" || die "no $bundle/toolset-swb.json (Swift Build's toolset of the SDK)"
set -- "$bundle"/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS[0-9]*.sdk
{ [ "$#" -eq 1 ] && [ -d "$1" ] && test -L "$1/usr/include/endian.h"; } \
  || die "the iPhoneOS SDK's usr/include/endian.h is no link to Endian.h (in $*)"
echo "pack-check: the pack at $pack passes"
