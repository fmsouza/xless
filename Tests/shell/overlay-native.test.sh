#!/usr/bin/env bash
# On a Mac, the built xless builds an overlay's app natively, with the Xcode that is installed and stand-ins for rustup and cargo: the
# stand-in is the app's build code, which looks for everything that it should not have and writes down what it got. Nothing is
# downloaded, no Apple account, no keychain, and the home directory is the test's own; the user's is only asked whether it can be
# listed (it cannot).
#   Tests/shell/overlay-native.test.sh            (builds xless with `swift build`; XLESS_BIN=<path> uses that binary)
#   XLESS_TEST_XCODE=1: it may not be skipped. Without it the test ends early where there is no Xcode.
set -euo pipefail
repo="$(cd "$(dirname "$0")/../.." && pwd)"
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
mkdir -p "$t/home/.ssh" "$t/home/.config/xless" "$t/home/bin" "$t/tools/bin" "$t/app" "$t/ov" "$t/elsewhere"
developer=()
[[ -z "${DEVELOPER_DIR:-}" ]] || developer=(DEVELOPER_DIR="$DEVELOPER_DIR")
more=()
# stdout → $t/out, stderr → $t/err, exit code → $code
run() {
  code=0
  env -i HOME="$t/home" TMPDIR="$t" PATH="$t/tools/bin:/usr/bin:/bin:/usr/sbin:/sbin" XLESS_SHARE="$repo" AN_EXPORTED_TOKEN=s3cret ASC_KEY_P8=s3cret \
    ${developer[@]+"${developer[@]}"} ${more[@]+"${more[@]}"} "$x" "$@" >"$t/out" 2>"$t/err" </dev/null || code=$?
}

run setup
if [[ "$code" != 0 && -z "${XLESS_TEST_XCODE:-}" ]]; then
  echo "SKIP: xless uses no Xcode of this Mac: $(tail -1 "$t/err")"
  exit 0
fi
[[ "$code" == 0 ]] || fail "xless setup exited $code"

echo s3cret >"$t/home/.ssh/id_test"
echo s3cret >"$t/home/.config/xless/testflight.env.txt"
echo s3cret >"$t/elsewhere/file"
echo open >"$t/app/untracked"
# A socket of the user's, as an agent has one. (Its path is short, and it is gone when the test is.)
socket="$t/s"
/usr/bin/perl -MIO::Socket::UNIX -e 'IO::Socket::UNIX->new(Local => $ARGV[0], Listen => 1) or die; sleep 120' "$socket" &
server=$!
disown "$server"
trap 'kill "$server" 2>/dev/null || true; rm -rf "$t"' EXIT

cat >"$t/tools/bin/rustup" <<'S'
#!/bin/sh
echo aarch64-apple-darwin
S
# What cargo does here: tells where it puts things, and links an executable with the linker that xless named.
cat >"$t/tools/bin/cargo" <<S
#!/bin/bash
real="$t"
user="$(id -un)"
tester=$$
S
cat >>"$t/tools/bin/cargo" <<'S'
if [ "$1" = metadata ]; then
  printf '{"packages":[{"name":"demo","targets":[{"name":"demo","kind":["bin"]}]}],"target_directory":"%s/target"}\n' "$PWD"
  exit
fi
probe() { name="$1"; shift; if "$@" >/dev/null 2>&1; then echo "$name: yes"; else echo "$name: no"; fi; }
{
  probe home ls "$real/home"
  probe passwd-home ls "$(eval echo "~$user")"
  probe key cat "$real/home/.ssh/id_test"
  probe config cat "$real/home/.config/xless/testflight.env.txt"
  probe elsewhere cat "$real/elsewhere/file"
  probe seen test -e "$real/elsewhere/file"
  probe overlay-write touch "$real/ov/x"
  probe source-write touch "$real/app/x"
  probe source-read cat "$real/app/untracked"
  probe signed mkdir -p .xless/build/macos/signed
  probe replaced mv .xless/build .xless/other
  probe socket /usr/bin/perl -MIO::Socket::UNIX -e 'exit(IO::Socket::UNIX->new(Peer => $ARGV[0]) ? 0 : 1)' "$real/s"
  probe keychain /usr/bin/security list-keychains
  # an app of its own, which the system would start outside the sandbox
  mkdir -p Out.app/Contents/MacOS
  printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' '<plist version="1.0"><dict><key>CFBundleExecutable</key><string>out</string><key>CFBundleIdentifier</key><string>com.example.out</string><key>CFBundlePackageType</key><string>APPL</string><key>LSBackgroundOnly</key><true/></dict></plist>' >Out.app/Contents/Info.plist
  printf '#!/bin/sh\ntouch "%s/app/x"\n' "$real" >Out.app/Contents/MacOS/out
  chmod +x Out.app/Contents/MacOS/out
  probe open /usr/bin/open -g "$PWD/Out.app"
  probe again /usr/bin/sandbox-exec -p '(version 1)(allow default)' /usr/bin/true
  probe parent kill -0 "$tester"
  probe terminal sh -c 'echo x >/dev/tty'
  probe token sh -c 'env | grep s3cret'
  probe told sh -c 'env | grep -q XLESS_SESSION='
  probe own sh -c 'echo x >"$HOME/mine" && cat "$HOME/mine" && echo x >"$TMPDIR/mine"'
  echo "home is $HOME"
} >report 2>&1
echo 'int main(void) { return 0; }' >m.c
mkdir -p target/aarch64-apple-darwin/release
"$CC_aarch64_apple_darwin" $CFLAGS_aarch64_apple_darwin -c m.c -o m.o
"$CARGO_TARGET_AARCH64_APPLE_DARWIN_LINKER" m.o -o target/aarch64-apple-darwin/release/demo
# what it leaves running has no part in anything
(sleep 60 >&2 &)
S
chmod +x "$t/tools/bin/rustup" "$t/tools/bin/cargo"

printf '%s\n' '[package]' 'name = "demo"' 'version = "1.2.3"' 'edition = "2021"' >"$t/app/Cargo.toml"
printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' '<plist version="1.0"><dict><key>CFBundleName</key><string>Demo</string></dict></plist>' >"$t/app/Info.plist"
printf '%s\n' 'type: cargo' 'source: ../app' 'bundleID: com.example.demo' 'teamID: ABCDE12345' 'version: cargo' 'build: "7"' 'usesNonExemptEncryption: false' \
  'macos: { package: demo, product: Demo, minimumOS: "13.0", infoPlist: Info.plist, architectures: [arm64] }' >"$t/ov/demo.yml"
git -C "$t/app" init -q
git -C "$t/app" add Cargo.toml Info.plist
git -C "$t/app" -c user.name=x -c user.email=x@example.com -c commit.gpgsign=false commit -qm one

work="$t/home/.cache/xless/work/demo"
begin=$SECONDS
run run --config "$t/ov/demo.yml" --platform macos --to finalize
[[ "$code" == 0 ]] || fail "xless run exited $code"
(( SECONDS - begin < 50 )) || fail "what the build left running held it"
grep -q "the app's build code runs in a sandbox" "$t/err" || fail "nothing says that there is a sandbox"
app="$work/.xless/build/macos/final/Demo.app"
[[ "$(lipo -archs "$app/Contents/MacOS/Demo")" == arm64 ]] || fail "no app"
want='home: no
passwd-home: no
key: no
config: no
elsewhere: no
seen: no
overlay-write: no
source-write: no
source-read: yes
signed: no
replaced: no
socket: no
keychain: no
open: no
again: no
parent: no
terminal: no
token: no
told: no
own: yes
home is '"$t/home/.cache/xless/build-home"
[[ "$(cat "$work/report")" == "$want" ]] || fail "the build code got something else: $(diff <(echo "$want") "$work/report")"
[[ ! -e "$t/ov/x" && ! -e "$t/app/x" ]] || fail "it wrote where it may not"

# Without the sandbox nothing of it runs: not when it is said to be there and is not, and not when the tool is gone (the rules
# cannot be put on in another sandbox: the same).
rm "$work/report"
more=(XLESS_BUILD_SANDBOX=1)
run ship --config "$t/ov/demo.yml" --platform macos --to build
[[ "$code" == 19 ]] || fail "xless went on without the sandbox ($code)"
grep -q 'not in force' "$t/err" || fail "xless went on without the sandbox ($code)"
more=()
sandboxed="$x"
x=/usr/bin/sandbox-exec
run -p '(version 1)(allow default)' "$sandboxed" ship --config "$t/ov/demo.yml" --platform macos --to build
x="$sandboxed"
[[ "$code" != 0 && ! -e "$work/report" ]] || fail "the build code ran where it cannot have its sandbox ($code)"

# React Native: xcodebuild, with a Swift package that has a plugin (from a repository that XLESS_BUILD_READ opens), and a build phase.
mkdir -p "$t/rn/ios/A.xcodeproj" "$t/rn/ios/A.xcworkspace" "$t/rn/ios/A.xcodeproj/xcshareddata/xcschemes" "$t/dep/Sources/Dep" "$t/dep/Sources/gen" "$t/dep/Plugins/Gen"
commit() { git -C "$1" init -q; git -C "$1" add .; git -C "$1" -c user.name=x -c user.email=x@example.com -c commit.gpgsign=false commit -qm one; }
cat >"$t/dep/Package.swift" <<'S'
// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "dep", platforms: [.iOS(.v17), .macOS(.v13)], products: [.library(name: "Dep", targets: ["Dep"])],
                      targets: [.executableTarget(name: "gen"), .plugin(name: "Gen", capability: .buildTool(), dependencies: ["gen"]), .target(name: "Dep", plugins: ["Gen"])])
S
cat >"$t/dep/Sources/gen/main.swift" <<'S'
import Foundation
let key = (try? String(contentsOfFile: "/etc/hosts", encoding: .utf8)) == nil ? "closed" : "open"
try "public let generated = \"\(key) \(CommandLine.arguments[2])\"\n".write(toFile: CommandLine.arguments[1], atomically: true, encoding: .utf8)
S
cat >"$t/dep/Plugins/Gen/p.swift" <<'S'
import Foundation
import PackagePlugin
@main struct Gen: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: Target) async throws -> [Command] {
        let out = context.pluginWorkDirectory.appending("g.swift")
        let seen = FileManager.default.contents(atPath: "@T@/elsewhere/file") == nil ? "unseen" : "seen"
        return [.buildCommand(displayName: "gen", executable: try context.tool(named: "gen").path, arguments: [out.string, seen], outputFiles: [out])]
    }
}
S
sed -i '' "s|@T@|$t|" "$t/dep/Plugins/Gen/p.swift"
echo 'public let dep = generated' >"$t/dep/Sources/Dep/d.swift"
commit "$t/dep"
printf '%s\n' 'import Dep' 'import SwiftUI' '@main struct A: App { var body: some Scene { WindowGroup { Text(dep) } } }' >"$t/rn/ios/a.swift"
cat >"$t/rn/ios/A.xcodeproj/project.pbxproj" <<S
// !\$*UTF8*\$!
{ archiveVersion = 1; classes = { }; objectVersion = 60; rootObject = 01; objects = {
  01 = { isa = PBXProject; buildConfigurationList = 02; mainGroup = 03; targets = (04); packageReferences = (05); projectDirPath = ""; projectRoot = ""; };
  02 = { isa = XCConfigurationList; buildConfigurations = (06); };
  06 = { isa = XCBuildConfiguration; name = Release; buildSettings = { SDKROOT = iphoneos; IPHONEOS_DEPLOYMENT_TARGET = 17.0; SWIFT_VERSION = 5.0; TARGETED_DEVICE_FAMILY = 1; }; };
  03 = { isa = PBXGroup; children = (07, 08); sourceTree = "<group>"; };
  07 = { isa = PBXFileReference; path = a.swift; lastKnownFileType = sourcecode.swift; sourceTree = "<group>"; };
  08 = { isa = PBXFileReference; path = A.app; explicitFileType = wrapper.application; sourceTree = BUILT_PRODUCTS_DIR; };
  04 = { isa = PBXNativeTarget; name = A; productName = A; productType = "com.apple.product-type.application"; productReference = 08; buildConfigurationList = 09;
         buildPhases = (10, 11, 12); buildRules = (); dependencies = (); packageProductDependencies = (13); };
  09 = { isa = XCConfigurationList; buildConfigurations = (14); };
  14 = { isa = XCBuildConfiguration; name = Release; buildSettings = { PRODUCT_NAME = A; PRODUCT_BUNDLE_IDENTIFIER = com.example.other; GENERATE_INFOPLIST_FILE = YES;
         CURRENT_PROJECT_VERSION = 1; MARKETING_VERSION = 1.0; INFOPLIST_KEY_UILaunchScreen_Generation = YES; }; };
  10 = { isa = PBXSourcesBuildPhase; files = (15); };
  15 = { isa = PBXBuildFile; fileRef = 07; };
  11 = { isa = PBXFrameworksBuildPhase; files = (16); };
  16 = { isa = PBXBuildFile; productRef = 13; };
  12 = { isa = PBXShellScriptBuildPhase; files = (); alwaysOutOfDate = 1; shellPath = /bin/sh;
         shellScript = "{ cat '$t/home/.ssh/id_test' || echo no key; touch '$t/rn/x' || echo no source; env | grep s3cret || echo no token; xcrun --find actool | grep -o '[.]xless/.*'; } 2>/dev/null >\"\$SRCROOT/report\"\n"; };
  05 = { isa = XCRemoteSwiftPackageReference; repositoryURL = "file://$t/dep"; requirement = { kind = revision; revision = $(git -C "$t/dep" rev-parse HEAD); }; };
  13 = { isa = XCSwiftPackageProductDependency; package = 05; productName = Dep; };
}; }
S
echo '<Workspace version="1.0"><FileRef location="group:A.xcodeproj"/></Workspace>' >"$t/rn/ios/A.xcworkspace/contents.xcworkspacedata"
cat >"$t/rn/ios/A.xcodeproj/xcshareddata/xcschemes/A.xcscheme" <<'S'
<Scheme version="1.7"><BuildAction><BuildActionEntries><BuildActionEntry buildForRunning="YES" buildForArchiving="YES">
<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="04" BuildableName="A.app" BlueprintName="A" ReferencedContainer="container:A.xcodeproj"/>
</BuildActionEntry></BuildActionEntries></BuildAction></Scheme>
S
printf '%s\n' GEM '  specs:' '    cocoapods (1.15.2)' '' 'BUNDLED WITH' '   2.7.2' >"$t/rn/Gemfile.lock"
echo '{"name":"a","version":"1.0.0"}' >"$t/rn/package.json"
echo '{"lockfileVersion":3}' >"$t/rn/package-lock.json"
echo 'target "A"' >"$t/rn/ios/Podfile"
commit "$t/rn"
cat >"$t/tools/bin/npm" <<'S'
#!/bin/sh
[ "$1" != --version ] || { echo 10; exit; }
mkdir -p node_modules/react-native node_modules/expo
echo '{"version":"0.86.1"}' >node_modules/react-native/package.json
echo '{"version":"57.0.1"}' >node_modules/expo/package.json
S
cp "$t/tools/bin/npm" "$t/tools/bin/node"
cat >"$t/tools/bin/bundle" <<'S'
#!/bin/sh
[ "$1" != -v ] || { echo "Bundler version 2.7.2"; exit; }
[ "$1" != exec ] || { mkdir -p Pods; echo a >Podfile.lock; echo a >Pods/Manifest.lock; }
S
chmod +x "$t/tools/bin/npm" "$t/tools/bin/node" "$t/tools/bin/bundle"
printf '%s\n' 'type: react-native' 'source: ../rn' 'teamID: ABCDE12345' 'version: "3.2.1"' 'build: "7"' 'bundleIDs: { A: com.example.rn }' 'usesNonExemptEncryption: false' 'scheme: A' \
  'configuration: Release' 'privacyManifest: p.xcprivacy' >"$t/ov/rn.yml"
echo '<plist version="1.0"><dict><key>NSPrivacyTracking</key><false/></dict></plist>' >"$t/ov/p.xcprivacy"
work="$t/home/.cache/xless/work/rn"
for destination in device simulator; do
  more=(XLESS_BUILD_READ="$t/dep")
  if [[ "$destination" == device ]]; then run ship --config "$t/ov/rn.yml" --platform ios --to finalize; else run ship --config "$t/ov/rn.yml" --platform ios --destination simulator --from build; fi
  [[ "$code" == 0 ]] || fail "the React Native app for the $destination exited $code"
  grep -q "of your files it reads .*, $t/dep and the tools on PATH" "$t/err" || fail "xless does not say what it opens"
  [[ "$(cat "$work/ios/report")" == "no key
no source
no token
.xless/bin/actool" ]] || fail "a build phase got something else: $(cat "$work/ios/report")"
  app=$(tail -1 "$t/out")
  [[ "$app" == */A.app && "$(plutil -extract CFBundleIdentifier raw "$app/Info.plist") $(plutil -extract CFBundleVersion raw "$app/Info.plist")" == "com.example.rn 7" ]] || fail "$app is not the app"
  strings -a "$app/A" | grep -q '^open unseen$' || fail "the package's plugin got something else"
done
more=()

# The build's failure is xless's, once.
printf '%s\n' '#!/bin/sh' 'echo it broke >&2' 'exit 3' >"$t/tools/bin/cargo"
run build --config "$t/ov/demo.yml" --platform macos
[[ "$code" == 12 && "$(grep -c '^error:' "$t/err")" == 1 ]] || fail "a build that fails exits $code"
[[ -z "$(cat "$t/out")" ]] || fail "xless build printed $(cat "$t/out")"

# A home directory is not opened, and a secret that is in what is opened is refused.
cp "$t/ov/demo.yml" "$t/home/demo.yml"
run ship --config "$t/home/demo.yml" --source "$t/app" --platform macos --to build
[[ "$code" == 10 ]] || fail "an overlay in the home directory: $code"
grep -q 'would open a home directory' "$t/err" || fail "an overlay in the home directory: $code"
echo s3cret >"$t/ov/key.pem"
more=(XLESS_DEVID_KEY_FILE="$t/ov/key.pem")
run run --config "$t/ov/demo.yml" --platform macos --to finalize
[[ "$code" == 2 ]] || fail "a key beside the overlay: $code"
grep -q "readable to the app's build code" "$t/err" || fail "a key beside the overlay: $code"

echo "ok: overlay-native"
