#!/usr/bin/env bash
# On a Mac, the built xless with the Xcode that is installed: Samples/HelloShip for a device, for the simulator and for macOS, with a
# home directory of its own and nothing downloaded; then its iOS app signed by xless's signer with a throw-away certificate that the
# signer itself makes, and packaged. No Apple account, no keychain, and nothing is sent anywhere.
#   Tests/shell/xcode-native.test.sh            (builds xless with `swift build`; XLESS_BIN=<path> uses that binary)
#   XLESS_TEST_XCODE=1: nothing may be skipped, and the signer is fetched (pinned in versions.env). Without it the test ends early
#   where there is no Xcode, and before the signing.
set -euo pipefail
repo="$(cd "$(dirname "$0")/../.." && pwd)"
all="${XLESS_TEST_XCODE:-}"
if [[ "$(uname -s)" != Darwin ]]; then
  echo "SKIP: an Xcode is installed on a Mac only"
  exit 0
fi
t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT
t="$(cd "$t" && pwd -P)"
fail() { echo "FAIL: $*"; [[ ! -f "$t/err" ]] || tail -40 "$t/err"; exit 1; }
x="${XLESS_BIN:-}"
if [[ -z "$x" ]]; then
  (cd "$repo" && env -u DEVELOPER_DIR swift build --product xless -q)
  x="$(cd "$repo" && env -u DEVELOPER_DIR swift build --show-bin-path)/xless"
fi
mkdir "$t/home"
developer=()
[[ -z "${DEVELOPER_DIR:-}" ]] || developer=(DEVELOPER_DIR="$DEVELOPER_DIR")
# stdout → $t/out, stderr → $t/err, exit code → $code
run() {
  code=0
  env -i HOME="$t/home" TMPDIR="$t" PATH=/usr/bin:/bin:/usr/sbin:/sbin XLESS_SHARE="$repo" ${developer[@]+"${developer[@]}"} \
    "$x" "$@" >"$t/out" 2>"$t/err" </dev/null || code=$?
}
ok() { run "$@"; [[ "$code" == 0 ]] || fail "xless $* exited $code"; }
plist() { /usr/bin/plutil -extract "$2" raw -o - "$1"; }

run setup
if [[ "$code" != 0 && -z "$all" ]]; then
  echo "SKIP: xless uses no Xcode of this Mac: $(tail -1 "$t/err")"
  exit 0
fi
[[ "$code" == 0 ]] || fail "xless setup exited $code"
[[ -z "$(find "$t/home" -type f)" ]] || fail "xless setup wrote into the home directory: $(find "$t/home" -type f)"

cp -R "$repo/Samples/HelloShip" "$t/p"
rm -rf "$t/p/.xless" "$t/p/.build"
build="$t/p/.xless/build"

# A device: an arm64 iOS app of that Xcode's SDK, with its icon.
ok run "$t/p" --platform ios --build-number 7 --to finalize
app="$build/ios/final/HelloShip.app"
[[ "$(lipo -archs "$app/HelloShip")" == arm64 ]] || fail "the iOS app is of $(lipo -archs "$app/HelloShip")"
xcrun vtool -show-build "$app/HelloShip" | grep -q 'platform IOS$' || fail "the iOS app is not one"
[[ "$(plist "$app/Info.plist" CFBundleIdentifier)" == com.example.helloship ]] || fail "the bundle ID"
[[ "$(plist "$app/Info.plist" CFBundleVersion)" == 7 ]] || fail "the build number"
[[ "$(plist "$app/Info.plist" DTPlatformName)" == iphoneos ]] || fail "the platform stamp"
[[ "$(plist "$app/Info.plist" DTSDKBuild)" == "$(xcrun --sdk iphoneos --show-sdk-build-version)" ]] || fail "the SDK stamp"
[[ -f "$app/Assets.car" ]] || fail "no Assets.car"
[[ -n "$(find "$build/ios" -name 'HelloShip.app.dSYM' -type d)" ]] || fail "no dSYM"
! xcrun otool -l "$app/HelloShip" | grep -A2 LC_RPATH | grep -q "path $t\|Xcode" || fail "the iOS app names a path of this Mac"

# The simulator: signed ad hoc, as the simulator asks.
ok ship --project "$t/p" --platform ios --destination simulator
app="$build/ios-simulator/app/HelloShip.app"
xcrun vtool -show-build "$app/HelloShip" | grep -q 'platform IOSSIMULATOR' || fail "the simulator app is not one"
codesign --verify --strict "$app" || fail "the simulator app's signature"

# macOS: universal.
ok ship --project "$t/p" --platform macos --to finalize
app="$build/macos/final/HelloShip.app"
for arch in arm64 x86_64; do [[ " $(lipo -archs "$app/Contents/MacOS/HelloShip") " == *" $arch "* ]] || fail "the macOS app is of $(lipo -archs "$app/Contents/MacOS/HelloShip")"; done
[[ -f "$app/Contents/Resources/AppIcon.icns" ]] || fail "no AppIcon.icns"

# Nothing of xless's was fetched for any of it.
left="$(find "$t/home/.local" "$t/home/.config" "$t/home/.cache" -type f -not -path '*/xless/locks/*' 2>/dev/null || true)"
[[ -z "$left" ]] || fail "a build left something: $left"

# The signer is fetched by the first command that signs, checked against its pin, before a secret is read: here there is none.
if [[ -z "$all" ]]; then
  echo "SKIP the signing: it fetches the signer (XLESS_TEST_XCODE=1)"
  echo "OK: the installed Xcode builds for a device, the simulator and macOS"
  exit 0
fi
run sign --project "$t/p" --platform ios
[[ "$code" != 0 ]] || fail "signed without a key"
grep -q '^xless: fetching rcodesign ' "$t/err" || fail "the signer was not fetched"
signer="$(find "$t/home/.local/share/xless-native/tools" -name rcodesign -type f)"
[[ -x "$signer" ]] || fail "no signer"
"$signer" generate-self-signed-certificate --person-name "xless test" --pem-unified-file "$t/throwaway.pem" >"$t/out" 2>"$t/err" || fail "no certificate"
mkdir -p "$build/ios/signed"
app="$build/ios/signed/HelloShip.app"
cp -R "$build/ios/final/HelloShip.app" "$app"
"$signer" sign -C /dev/null --pem-file "$t/throwaway.pem" --timestamp-url none --entitlements-xml-file "$t/p/ios.entitlements" "$app" \
  >"$t/out" 2>"$t/err" || fail "not signed"
codesign -dvv "$app" 2>&1 | grep 'Authority=' | grep -q 'xless test' || fail "$(codesign -dvv "$app" 2>&1)"
codesign --verify --strict --verbose=2 "$app" 2>&1 | grep -q 'valid on disk' || fail "$(codesign --verify --strict --verbose=2 "$app" 2>&1)"
ok package --project "$t/p" --platform ios
ipa="$(find "$build/ios/out" -name '*.ipa')"
unzip -l "$ipa" | grep -q 'Payload/HelloShip.app/_CodeSignature/CodeResources' || fail "the ipa: $(unzip -l "$ipa")"
echo "OK: the installed Xcode builds for a device, the simulator and macOS; xless's signer signs, and it packages"
