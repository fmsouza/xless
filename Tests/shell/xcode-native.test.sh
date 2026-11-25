#!/usr/bin/env bash
# On a Mac, the built xless with the Xcode that is installed: samples/HelloShip for a device, for the simulator and for macOS, with
# HOME elsewhere (SwiftPM goes by the user on a Mac, and uses the user's own caches all the same) and nothing downloaded; then its
# iOS app signed by xless's signer with a throw-away certificate that the signer itself makes, and packaged. No Apple account, no
# keychain, and nothing is sent anywhere.
#   Tests/shell/xcode-native.test.sh            (builds xless with `swift build`; XLESS_BIN=<path> uses that binary)
#   XLESS_TEST_XCODE=1: nothing may be skipped, and the signer is fetched (pinned in versions.env). Without it the test ends early
#   where there is no Xcode, and before the signing.
set -euo pipefail
has() { grep "$@" > /dev/null; }   # which reads to the end: with pipefail, what a `grep -q` stopped early would count
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

cp -R "$repo/samples/HelloShip" "$t/p"
rm -rf "$t/p/.xless" "$t/p/.build"
sed 's/^  # macos: /  macos: /' "$repo/samples/HelloShip/xless.yml" > "$t/p/xless.yml"   # a macOS app too
build="$t/p/.xless/build"

# A device: an arm64 iOS app of that Xcode's SDK, with its icon.
ok run "$t/p" --platform ios --build-number 7 --to finalize
app="$build/ios/final/HelloShip.app"
[[ "$(lipo -archs "$app/HelloShip")" == arm64 ]] || fail "the iOS app is of $(lipo -archs "$app/HelloShip")"
xcrun vtool -show-build "$app/HelloShip" | has 'platform IOS$' || fail "the iOS app is not one"
[[ "$(plist "$app/Info.plist" CFBundleIdentifier)" == com.example.helloship ]] || fail "the bundle ID"
[[ "$(plist "$app/Info.plist" CFBundleVersion)" == 7 ]] || fail "the build number"
[[ "$(plist "$app/Info.plist" DTPlatformName)" == iphoneos ]] || fail "the platform stamp"
[[ "$(plist "$app/Info.plist" DTSDKBuild)" == "$(xcrun --sdk iphoneos --show-sdk-build-version)" ]] || fail "the SDK stamp"
[[ -f "$app/Assets.car" ]] || fail "no Assets.car"
[[ -n "$(find "$build/ios" -name 'HelloShip.app.dSYM' -type d)" ]] || fail "no dSYM"
! xcrun otool -l "$app/HelloShip" | grep -A2 LC_RPATH | has "path $t\|Xcode" || fail "the iOS app names a path of this Mac"

# The simulator: signed ad hoc, as the simulator asks.
ok ship --project "$t/p" --platform ios --destination simulator
app="$build/ios-simulator/app/HelloShip.app"
xcrun vtool -show-build "$app/HelloShip" | has 'platform IOSSIMULATOR' || fail "the simulator app is not one"
codesign --verify --strict "$app" || fail "the simulator app's signature"

# macOS: universal.
ok ship --project "$t/p" --platform macos --to finalize
app="$build/macos/final/HelloShip.app"
for arch in arm64 x86_64; do [[ " $(lipo -archs "$app/Contents/MacOS/HelloShip") " == *" $arch "* ]] || fail "the macOS app is of $(lipo -archs "$app/Contents/MacOS/HelloShip")"; done
[[ -f "$app/Contents/Resources/AppIcon.icns" ]] || fail "no AppIcon.icns"

# A library that the app loads is in it, without a path of this Mac's Xcode, and its dSYM is kept.
mkdir -p "$t/l/Sources/Demo" "$t/l/Dyn/Sources/Dyn"
echo 'public func word() -> String { "hi" }' > "$t/l/Dyn/Sources/Dyn/d.swift"
printf '%s\n' '// swift-tools-version: 6.0' 'import PackageDescription' \
  'let package = Package(name: "Dyn", platforms: [.macOS(.v14)], products: [.library(name: "Dyn", type: .dynamic, targets: ["Dyn"])], targets: [.target(name: "Dyn")])' > "$t/l/Dyn/Package.swift"
printf '%s\n' '// swift-tools-version: 6.0' 'import PackageDescription' \
  'let package = Package(name: "Demo", platforms: [.macOS(.v14)], products: [.library(name: "Demo", targets: ["Demo"])], dependencies: [.package(path: "Dyn")], targets: [.target(name: "Demo", dependencies: ["Dyn"])])' > "$t/l/Package.swift"
printf '%s\n' 'import SwiftUI' 'import Dyn' '@main struct Demo: App { var body: some Scene { WindowGroup { Text(word()) } } }' > "$t/l/Sources/Demo/a.swift"
printf '%s\n' 'bundleID: com.example.demo' 'teamID: ABCDE12345' 'version: 1.0.0' 'build: 1' 'platforms:' '  macos: { minimumOS: "14.0", product: Demo, distribution: developer-id }' > "$t/l/xless.yml"
ok build --project "$t/l" --platform macos
dylib="$t/l/.xless/build/macos/app/Demo.app/Contents/Frameworks/libDyn.dylib"
[[ -f "$dylib" ]] || fail "no libDyn.dylib in the app"
! xcrun otool -l "$dylib" | grep -A2 LC_RPATH | has 'path .*\(Xcode\|cryptexd\)' || fail "libDyn.dylib names a path of this Mac's Xcode"
[[ -d "$t/l/.xless/build/macos/dSYMs/libDyn.dylib.dSYM" ]] || fail "no dSYM of libDyn.dylib: $(find "$t/l/.xless/build/macos/dSYMs" -maxdepth 1)"

# A package that the app no longer has leaves nothing in it.
mkdir -p "$t/q/Sources/Demo" "$t/q/Dep/Sources/Dep"
printf '%s\n' 'public func word() -> String { "hi" }' > "$t/q/Dep/Sources/Dep/d.swift"
echo '{}' > "$t/q/Dep/Sources/Dep/data.json"
cat > "$t/q/Dep/Package.swift" <<'P'
// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "Dep", platforms: [.macOS(.v14)], products: [.library(name: "Dep", targets: ["Dep"])], targets: [.target(name: "Dep", resources: [.process("data.json")])])
P
manifest() {   # DEPENDENCY TARGET-DEPENDENCY
  printf '%s\n' '// swift-tools-version: 6.0' 'import PackageDescription' \
    "let package = Package(name: \"Demo\", platforms: [.macOS(.v14)], products: [.library(name: \"Demo\", targets: [\"Demo\"])], dependencies: [$1], targets: [.target(name: \"Demo\", dependencies: [$2])])" > "$t/q/Package.swift"
}
app() { printf '%s\n' "import SwiftUI" "$1" "@main struct Demo: App { var body: some Scene { WindowGroup { Text($2) } } }" > "$t/q/Sources/Demo/a.swift"; }
printf '%s\n' 'bundleID: com.example.demo' 'teamID: ABCDE12345' 'version: 1.0.0' 'build: 1' 'platforms:' '  macos: { minimumOS: "14.0", product: Demo, distribution: developer-id }' > "$t/q/xless.yml"
manifest '.package(path: "Dep")' '"Dep"'; app 'import Dep' 'word()'
app="$t/q/.xless/build/macos/app/Demo.app"
ok build --project "$t/q" --platform macos
[[ -d "$app/Contents/Resources/Dep_Dep.bundle" ]] || fail "no resources of a package: $(find "$app")"
ok build --project "$t/q" --platform macos   # nothing to do for Swift Build
[[ -d "$app/Contents/Resources/Dep_Dep.bundle" ]] || fail "no resources of a package in a second build: $(find "$app")"
manifest '' ''; app '' '"hi"'
ok build --project "$t/q" --platform macos
[[ ! -e "$app/Contents/Resources/Dep_Dep.bundle" ]] || fail "the resources of a package that is gone are in the app"

# Package.resolved decides. (SwiftPM keeps a copy of the package in this user's caches: not on a machine of your own.)
if [[ -n "$all" ]]; then
  mkdir -p "$t/dep"; cp -R "$t/q/Dep/." "$t/dep/"
  g() { git -C "$t/dep" -c user.name=x -c user.email=x@example.com -c commit.gpgsign=false -c tag.gpgsign=false "$@" >/dev/null; }
  g init; g add -A; g commit -m one; g tag 1.0.0
  printf '%s\n' 'public func word() -> String { "second" }' > "$t/dep/Sources/Dep/d.swift"
  g commit -am two; g tag 1.1.0
  printf '{"pins":[{"identity":"dep","kind":"localSourceControl","location":"%s","state":{"revision":"%s","version":"1.0.0"}}],"version":3}\n' \
    "$t/dep" "$(git -C "$t/dep" rev-parse 1.0.0)" > "$t/q/Package.resolved"
  cp "$t/q/Package.resolved" "$t/kept"
  manifest ".package(url: \"$t/dep\", from: \"1.0.0\")" '.product(name: "Dep", package: "dep")'; app 'import Dep' 'word()'
  ok build --project "$t/q" --platform macos
  ! strings "$app/Contents/MacOS/Demo" | has -x second || fail "built with 1.1.0, not the 1.0.0 of Package.resolved"
  cmp "$t/kept" "$t/q/Package.resolved" || fail "the project's Package.resolved was changed"
  ! grep -q 'note: .*Package.resolved' "$t/err" || fail "a note of $(grep Package.resolved "$t/err")"
  rm "$t/q/Package.resolved"
  ok build --project "$t/q" --platform macos
  grep -q 'the project has no Package.resolved, .*: dep 1' "$t/err" || fail "no note of what was built"
  [[ ! -e "$t/q/Package.resolved" ]] || fail "a Package.resolved was written into the project"
fi

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
codesign -dvv "$app" 2>&1 | grep 'Authority=' | has 'xless test' || fail "$(codesign -dvv "$app" 2>&1)"
codesign --verify --strict --verbose=2 "$app" 2>&1 | has 'valid on disk' || fail "$(codesign --verify --strict --verbose=2 "$app" 2>&1)"
ok package --project "$t/p" --platform ios
ipa="$(find "$build/ios/out" -name '*.ipa')"
names="$(unzip -l "$ipa")"
grep -q 'Payload/HelloShip.app/_CodeSignature/CodeResources' <<<"$names" || fail "the ipa: $names"
echo "OK: the installed Xcode builds for a device, the simulator and macOS; xless's signer signs, and it packages"
