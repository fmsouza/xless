#!/usr/bin/env bash
# shellcheck disable=SC2016 # the fakes' own $ expansions, written as they are
# scripts/pack-check.sh <pack> with fake shims: each check runs against the pack (XLESS_XCODE names it, the shims come
# first on PATH and prepare/ first for the stub dylib's clang), a pack that passes them all is accepted, and each failing
# check stops it with its own message.
set -euo pipefail
repo="$(cd "$(dirname "$0")/../.." && pwd)"
t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT
fail() { echo "FAIL: $*"; exit 1; }
# The iOS SDK has Endian.h and endian.h side by side: a case-insensitive file system (macOS's default) cannot hold a pack.
touch "$t/A"; if [[ -e "$t/a" ]]; then echo "SKIP: needs a case-sensitive file system"; exit 0; fi; rm "$t/A"

shims="$t/shims"
mkdir -p "$shims/prepare"
# Every fake records that it ran, and the pack it ran against.
fake() { printf '#!/bin/sh\necho "%s $XLESS_XCODE $*" >> "$FAKE_LOG"\n%s\n' "$1" "$2" > "$shims/$1"; chmod +x "$shims/$1"; }
version='printf "<plist><dict><key>bundle-version</key><string>24127</string></dict></plist>\n"'
fake xcrun 'case "$1" in --sdk) echo "$XLESS_XCODE/config/swiftpm/swift-sdks/darwin.artifactbundle/iPhoneOS.sdk" ;; --find) echo "${XCRUN_FIND:-$(dirname "$0")/$2}" ;; actool) shift; exec actool "$@" ;; *) exit 1 ;; esac'
fake actool "if [ -n \"\${ACTOOL_BROKEN:-}\" ]; then echo nothing; else $version; fi"
fake ibtool "$version"
fake xcodebuild 'printf "Xcode 26.2\nBuild version 17C52\n"'
# The header of a 64-bit arm64 Mach-O dynamic library (MH_MAGIC_64, CPU_TYPE_ARM64, MH_DYLIB, no load commands), or text.
fake prepare/clang 'cat > /dev/null; while [ $# -gt 0 ]; do if [ "$1" = -o ]; then
  if [ -n "${STUB_TEXT:-}" ]; then echo stub > "$2"; else printf "\317\372\355\376\014\000\000\001\000\000\000\000\006\000\000\000%024d" 0 | tr 0 "\000" > "$2"; fi; fi; shift; done'

pack="$t/xcodes/26.2-17C52-arm64.partial"
b="$pack/config/swiftpm/swift-sdks/darwin.artifactbundle"
inc="$b/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS26.2.sdk/usr/include"
mkpack() {
  rm -rf "$t/xcodes"; mkdir -p "$inc" "$pack/swift-build"
  touch "$inc/Endian.h"; ln -s Endian.h "$inc/endian.h"
  echo '{}' > "$b/toolset-swb.json"
  printf '#!/bin/sh\necho "swbuild $*" >> "$FAKE_LOG"\n[ "$1" = --help ]\n' > "$pack/swift-build/swbuild"; chmod +x "$pack/swift-build/swbuild"
}
check() { : > "$t/log"; env XLESS_SHIM_DIR="$shims" FAKE_LOG="$t/log" "$@" sh "$repo/scripts/pack-check.sh" "$pack" > "$t/out" 2>&1; }

mkpack
check || fail "a good pack: $(cat "$t/out")"
real="$(cd -P "$pack" && pwd -P)"
for line in "xcrun $real --sdk iphoneos --show-sdk-path" "actool $real --version --output-format xml1" "ibtool $real --version --output-format xml1" \
            "xcodebuild $real -version" "swbuild --help"; do
  grep -qxF "$line" "$t/log" || fail "not run: $line ($(cat "$t/log"))"
done
[[ "$(grep -c "^actool $real --version" "$t/log")" == 2 ]] || fail "xcrun actool did not reach actool"
grep -q "^prepare/clang $real -x c - -dynamiclib -o .* -install_name @rpath/S.framework/S$" "$t/log" || fail "the stub dylib: $(grep clang "$t/log")"

check ACTOOL_BROKEN=1 && fail "an actool that answers no version was accepted"
grep -q actool "$t/out" || fail "actool message: $(cat "$t/out")"

check XCRUN_FIND=/usr/bin/actool && fail "an xcrun that finds another actool was accepted"
grep -q 'xcrun --find actool' "$t/out" || fail "xcrun --find message: $(cat "$t/out")"

check STUB_TEXT=1 && fail "a stub dylib that is no Mach-O was accepted"
grep -q 'no 64-bit Mach-O' "$t/out" || fail "Mach-O message: $(cat "$t/out")"

check XLESS_SHIM_DIR= && fail "no shims was accepted"
grep -q 'XLESS_SHIM_DIR names no directory of shims (unset)' "$t/out" || fail "no shims message: $(cat "$t/out")"
check XLESS_SHIM_DIR="$t/none" && fail "a shims directory that is not there was accepted"
grep -q "XLESS_SHIM_DIR names no directory of shims ($t/none)" "$t/out" || fail "missing shims message: $(cat "$t/out")"

mkpack; rm "$inc/endian.h"; touch "$inc/endian.h"
check && fail "an endian.h that is no link was accepted"
grep -q endian.h "$t/out" || fail "endian.h message: $(cat "$t/out")"

mkpack; rm "$b/toolset-swb.json"
check && fail "a pack without toolset-swb.json was accepted"
grep -q toolset-swb.json "$t/out" || fail "toolset message: $(cat "$t/out")"

mkpack; rm "$pack/swift-build/swbuild"
check && fail "a pack without swbuild was accepted"
grep -q swbuild "$t/out" || fail "swbuild message: $(cat "$t/out")"

mkpack
: > "$t/log"
env -u XLESS_SHIM_DIR FAKE_LOG="$t/log" sh "$repo/scripts/pack-check.sh" "$pack" > "$t/out" 2>&1 && fail "no shims was accepted"
grep -q XLESS_SHIM_DIR "$t/out" || fail "shims message: $(cat "$t/out")"
echo "PASS pack-check"
