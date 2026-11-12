#!/usr/bin/env bash
# scripts/xcode-pin.sh: the Xcode a bench run asked for reaches every Apple tool found through PATH, even when the
# caller (the Tauri CLI) clears DEVELOPER_DIR; and a log naming another Xcode or the Command Line Tools is caught.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT
fail() { echo "FAIL: $*"; exit 1; }
S="$root/scripts/xcode-pin.sh"

# A fake /usr/bin: the xcode-select shims are hard links of one binary (here: a script printing its DEVELOPER_DIR), plus
# xcrun and xcode-select; git and python3 are unrelated tools.
mkdir -p "$t/usr/bin" "$t/dev dir/Contents/Developer"
# shellcheck disable=SC2016   # the fake tool's own $0, $DEVELOPER_DIR and $*
printf '#!/bin/sh\necho "${0##*/} DEVELOPER_DIR=$DEVELOPER_DIR args=$*"\n' > "$t/usr/bin/clang"; chmod +x "$t/usr/bin/clang"
for n in cc ld swift lipo; do ln "$t/usr/bin/clang" "$t/usr/bin/$n"; done
cp "$t/usr/bin/clang" "$t/usr/bin/xcodebuild"; ln "$t/usr/bin/xcodebuild" "$t/usr/bin/actool"
cp "$t/usr/bin/clang" "$t/usr/bin/xcrun"; cp "$t/usr/bin/clang" "$t/usr/bin/xcode-select"
cp "$t/usr/bin/clang" "$t/usr/bin/git"; cp "$t/usr/bin/clang" "$t/usr/bin/python3"
export XCODE_PIN_USR_BIN="$t/usr/bin"
dev="$t/dev dir/Contents/Developer"

"$S" shims "$dev" "$t/shims"
got=$(cd "$t/shims" && printf '%s ' *)
[[ "$got" == "actool cc clang ld lipo swift xcode-select xcodebuild xcrun " ]] || fail "shims: $got"
for n in xcodebuild xcrun cc swift xcode-select; do
  out=$(env -i PATH="$t/shims:/usr/bin:/bin" "$n" -x 'a b')
  [[ "$out" == "$n DEVELOPER_DIR=$dev args=-x a b" ]] || fail "$n: $out"
done
# An existing DEVELOPER_DIR does not win over the pinned one.
out=$(env -i DEVELOPER_DIR=/elsewhere PATH="$t/shims:/bin" xcodebuild -version)
[[ "$out" == "xcodebuild DEVELOPER_DIR=$dev args=-version" ]] || fail "outer DEVELOPER_DIR leaked: $out"

# Refusals: no Developer dir; no xcodebuild shim (not a Mac with Xcode shims).
rc=0; "$S" shims "$t/nope" "$t/s2" 2>/dev/null || rc=$?; [[ $rc == 2 ]] || fail "missing Developer dir exits $rc"
rm "$t/usr/bin/xcodebuild"
rc=0; err=$("$S" shims "$dev" "$t/s3" 2>&1) || rc=$?
[[ $rc == 2 && "$err" == *xcodebuild* ]] || fail "missing xcodebuild: $rc $err"

# check: the pinned Xcode only passes; another Xcode or the CLT anywhere fails and is named.
X=/Applications/Xcode-26.2.app/Contents/Developer
printf '%s\n' "$X/usr/bin/clang -isysroot$X/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS26.2.sdk -c a.c" \
  "{\"env\": {\"PATH\": \"/usr/bin:$X/usr/bin\", \"SDKROOT\": \"$X/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS.sdk\"}}" \
  "--sysroot=$X/SDKs/x.sdk,-L$X/usr/lib" > "$t/good.log"
"$S" check "$X" "$t/good.log" || fail "the pinned Xcode's own paths were refused"
"$S" check "$X/" "$t/good.log" || fail "a trailing slash on the Developer dir matters"
printf '"PATH": "/usr/bin:/Applications/Xcode.app/Contents/Developer/usr/bin"\n' > "$t/other.log"
printf 'ld: /Library/Developer/CommandLineTools/SDKs/MacOSX.sdk/usr/lib\n' > "$t/clt.log"
rc=0; err=$("$S" check "$X" "$t/good.log" "$t/other.log" "$t/clt.log" "$t/missing.log" 2>&1) || rc=$?
[[ $rc == 1 ]] || fail "another Xcode passed ($rc)"
[[ "$err" == $'/Applications/Xcode.app/Contents/Developer\n/Library/Developer/CommandLineTools' ]] || fail "check named: $err"

# tauri-ios-reference.sh pins its Xcode this way, checks its logs, and never switches xcode-select.
R="$root/scripts/tauri-ios-reference.sh"
grep -q 'xcode-pin.sh" shims' "$R" || fail "tauri-ios-reference.sh does not write the shims"
grep -q 'xcode-pin.sh" check' "$R" || fail "tauri-ios-reference.sh does not check its logs"
grep -q 'env -u DEVELOPER_DIR swift build' "$R" || fail "tauri-ios-reference.sh builds xless with the reference Xcode"
if grep -E '^[^#]*xcode-select +(-s|--switch)' "$R" "$root/scripts/sim-launch.sh" >/dev/null; then fail "a bench script switches xcode-select"; fi
echo PASS
