#!/usr/bin/env bash
# Builds samples/HelloRN on Linux (in the xless-rn image) with its committed overlay through prepare, build, assets and
# finalize, unsigned, and compares the app and its app extension with samples/HelloRN/reference/reference.json and
# reference-appex.json (recorded from xcodebuild on a Mac by `make rn-reference`): the build stage's app as it is, the
# finalized app with the one key the overlay adds (ITSAppUsesNonExemptEncryption, from usesNonExemptEncryption: false).
# No allowed gaps: any other difference fails. Exits non-zero on a difference or a failed stage.
# On a Mac host, the asset catalogs are compared too: the built and finalized apps' .car files are copied out of the
# volume and `xless tauri compare --assets-only` (host build) reads them and the reference's recorded catalogs with
# `xcrun assetutil --info`: per rendition Name, Idiom, Scale, Appearance, Opaque, Encoding, Colorspace, pixel size,
# bits per component, color components (not compression, sizes or digests). The one known AssetKit gap (no MultiSized
# Image rendition for the app icon, docs/research/parity-known-gaps.md) is in samples/HelloRN/reference/allowed-gaps.txt,
# which lists `car:` keys only. The pod's catalog has a transparent image and a colorset, so opacity and colors are
# covered. Elsewhere this step is skipped (no assetutil).
#   make test-rn-linux
#   scripts/test-rn-linux.sh [--keep]
# Two runs:
#   1. From a fresh prepare: the work copy is deleted first (--keep skips that), so the JS install, `expo prebuild`,
#      `bundle install`, `pod install` and a clean Swift Build all run. Needs network (npm, gems, CocoaPods specs and pods).
#   2. Again with `--network none`: prepare finds the native project up to date (no prebuild, no pod install) and the
#      build runs offline, incrementally. This is the regression of Task 7's offline workspace build, now through
#      `xless ship` instead of a hand-run script (scripts/spikes/rn-workspace-linux.sh, removed).
# Both compare. Also checked: every Mach-O image's LINKEDIT tables are aligned as dyld requires (`xless inspect`),
# main.jsbundle is Hermes bytecode, Assets.car holds the local pod's image (compiled by CocoaPods' Copy Pods Resources
# phase through `xcrun actool`), both bundles carry the overlay's bundle IDs and the build number, and the build wrote
# entitlements.json and packages.json (what the sign step reads).
# No signing, no App Store Connect: the build number is explicit (XLESS_BUILD_NUMBER), so no dated-build lookup happens.
# 3. A simulator build of the same work copy (`--destination simulator`, offline), next to the device build: it must be an
#    arm64 iphonesimulator app, signed ad hoc, each executable carrying its simulated entitlements, and it must leave the
#    device build's outputs alone (its app, entitlements.json, packages.json, sdk.json, build-number and derived data).
# 4. The device build again, offline, after the simulator build: it must still match the reference (the work copy's
#    node_modules, where some packages cache build outputs, is shared by both).
# On a Mac host, scripts/sim-launch.sh then installs and launches the simulator app on an iOS Simulator and checks that
# it is still running after 10 s (its screenshot, console and any crash report are kept in ~/.cache/xless/sim/HelloRN);
# elsewhere that step is skipped. --no-launch skips it on a Mac too.
# Variables: ARCH (arm64 or amd64; default the host's: the image's platform, so ARCH=amd64 on an arm64 Mac runs the amd64 chain
#   under emulation), XLESS_IMAGE (default xless-rn:local-<arch>), DOCKER_CONTEXT (default colima-xless if it exists),
#   XLESS_RN_TEST_VOLUME (default xless-rn-test-work): the docker volume holding the work copy and the pnpm store.
#   XLESS_RN_OVERLAY (default samples/HelloRN/xless.overlay.yml): the overlay, relative to the repository; its work copy is
#     named after the file. XLESS_RN_REFERENCE (default samples/HelloRN/reference): the Mac reference directory (an absolute
#     host path; mounted read-only). With the Xcode 26.2 pin: XLESS_IMAGE=xless-rn:local-arm64-xcode26.2
#     XLESS_RN_OVERLAY=samples/HelloRN/xless.overlay-26.2.yml XLESS_RN_REFERENCE=<`DEVELOPER_DIR=<26.2> make rn-reference`'s OUT>
#     XLESS_RN_TEST_VOLUME=xless-rn-test-work-26.2 (the reference's directory also needs the allowed-gaps.txt of the default one).
# The repository is mounted read-only. Caches are the docker volumes xless run uses: xless-corepack,
# xless-bundle, xless-cocoapods-home, xless-cocoapods-cache (created on first use).
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
ctx="${DOCKER_CONTEXT:-}"
if [[ -z "$ctx" ]] && docker context ls --format '{{.Name}}' 2>/dev/null | grep -qx 'colima-xless'; then ctx=colima-xless; fi
case "$(uname -m)" in arm64|aarch64) arch=arm64 ;; *) arch=amd64 ;; esac
vsuf=""; plat=()   # ARCH=amd64|arm64 runs the image of that architecture (under emulation when it is not the host's)
if [[ -n "${ARCH:-}" ]]; then
  [[ "$ARCH" == arm64 || "$ARCH" == amd64 ]] || { echo "test-rn-linux: ARCH must be arm64 or amd64" >&2; exit 2; }
  [[ "$ARCH" == "$arch" ]] || vsuf="-$ARCH"   # another architecture's native gems and work copy stay apart from the host's
  arch="$ARCH"; plat=(--platform "linux/$ARCH")
fi
image="${XLESS_IMAGE:-xless-rn:local-$arch}"
volume="${XLESS_RN_TEST_VOLUME:-xless-rn-test-work$vsuf}"
overlay="${XLESS_RN_OVERLAY:-samples/HelloRN/xless.overlay.yml}"
refdir="${XLESS_RN_REFERENCE:-$root/samples/HelloRN/reference}"
[[ -f "$root/$overlay" ]] || { echo "test-rn-linux: no overlay $root/$overlay" >&2; exit 2; }
[[ -f "$refdir/reference.json" ]] || { echo "test-rn-linux: no reference.json in $refdir" >&2; exit 2; }
workname="$(basename "$overlay" .yml)"   # the work copy is named after the overlay file
keep=0; launch=1
while [[ $# -gt 0 ]]; do
  case "$1" in
    --keep) keep=1; shift ;;
    --no-launch) launch=0; shift ;;
    *) echo "usage: $0 [--keep] [--no-launch]" >&2; exit 2 ;;
  esac
done
docker=(docker)
[[ -z "$ctx" ]] || docker+=(--context "$ctx")
alpine="$(sed -n 's/^ALPINE_IMAGE=//p' "$root/versions.env")"   # pinned by digest
[[ -n "$alpine" ]] || { echo "versions.env has no ALPINE_IMAGE" >&2; exit 2; }

run() {   # RUN-NAME [docker run options...]: one build and compare, in a fresh container
  local name="$1"; shift
  echo "==> HelloRN: $name" >&2
  "${docker[@]}" run --rm -i ${plat[@]+"${plat[@]}"} "$@" -v "$root":/repo:ro -v "$volume":/cache/work -v "$refdir":/ref:ro \
    -v xless-corepack:/cache/corepack -v "xless-bundle$vsuf":/cache/bundle \
    -v xless-cocoapods-home:/root/.cocoapods -v xless-cocoapods-cache:/root/Library/Caches/CocoaPods \
    -e XLESS_BUILD_NUMBER=1.0.0.2026101601 -e FRESH="$fresh" -e OVERLAY="$overlay" -e WORKNAME="$workname" "$image" bash -s <<'IN'
set -euo pipefail
o=/repo/$OVERLAY
s=/repo/samples/HelloRN
r=/ref
w=/cache/work/$WORKNAME            # the work copy is named after the overlay file
if [[ "$FRESH" == 1 ]]; then echo "==> removing the work copy $w (the pnpm store next to it stays)"; rm -rf "$w"; fi
start=$(date +%s)
# prepare, build, assets, finalize; ship prints each stage's output directory, finalize's last
final=$(xless ship --config "$o" --source "$s" --platform ios --to finalize | tail -1)
echo "==> built $final in $(( $(date +%s) - start )) s"
t=$(mktemp -d)
python3 -c "import json,sys; json.dump(json.load(open(sys.argv[1]))['HelloExtension.appex'], open(sys.argv[2], 'w'))" "$r/reference-appex.json" "$t/appex.json"
# The build's app is what xcodebuild produced on the Mac. finalize then stamps what the overlay asks for on top
# (usesNonExemptEncryption: false), so the finalized app is compared with the reference plus that key.
built="$w/.xless/build/ios/app/$(basename "$final")"
python3 -c "import json,sys; r=json.load(open(sys.argv[1])); r['infoPlist']['ITSAppUsesNonExemptEncryption']='false'; json.dump(r, open(sys.argv[2], 'w'))" "$r/reference.json" "$t/final.json"
for pair in "$r/reference.json $built" "$t/final.json $final"; do
  set -- $pair
  echo "==> comparing $2 with the reference"
  xless tauri compare "$1" "$2"
  echo "==> comparing its HelloExtension.appex with the reference"
  xless tauri compare "$t/appex.json" "$2/PlugIns/HelloExtension.appex"
done
# The local pod plugins/HelloAssets ships an asset catalog as a pod resource: CocoaPods' [CP] Copy Pods Resources phase
# compiles it into the app's Assets.car through `xcrun actool` (as on the Mac, where the reference app has it too). The
# reference compares file lists only, so check the car itself: the pod's image and the app's own icon are both in it.
for app in "$built" "$final"; do
  for name in HelloPodBadge AppIcon; do
    LC_ALL=C grep -aq "$name" "$app/Assets.car" || { echo "$app/Assets.car has no $name"; exit 1; }
  done
done
# Every Mach-O image (the app, its frameworks, the extension) has its LINKEDIT tables aligned as dyld requires (the strip
# shim re-aligns llvm-strip's output; finalize also refuses a misaligned image): `xless inspect` lists what dyld would refuse.
for app in "$built" "$final"; do
  xless inspect "$app" --platform ios | python3 -c '
import json, sys
bins = json.load(sys.stdin)["binaries"]
bad = [(b["path"], b["linkeditProblems"]) for b in bins if b["linkeditProblems"]]
assert not bad, bad
assert any(b["path"].startswith("PlugIns/") for b in bins), [b["path"] for b in bins]
print("==> %s: %d Mach-O images, LINKEDIT aligned" % (sys.argv[1], len(bins)))' "$app"
done
magic=$(head -c 8 "$final/main.jsbundle" | od -A n -t x1 | tr -d ' \n')
[[ "$magic" == c61fbc03c103191f ]] || { echo "main.jsbundle is not Hermes bytecode (starts $magic)"; exit 1; }
check() {   # PLIST KEY WANT
  local got; got=$(/usr/libexec/PlistBuddy -c "Print :$2" "$1")
  [[ "$got" == "$3" ]] || { echo "$1: $2 is '$got', want '$3'"; exit 1; }
}
check "$final/Info.plist" CFBundleIdentifier com.example.hellorn
check "$final/Info.plist" CFBundleVersion 1.0.0.2026101601
check "$final/PlugIns/HelloExtension.appex/Info.plist" CFBundleIdentifier com.example.hellorn.HelloExtension
check "$final/PlugIns/HelloExtension.appex/Info.plist" CFBundleVersion 1.0.0.2026101601
# what the sign step (xless run, step 3) reads next to the app
python3 - "$w/.xless/build/ios" <<'PY'
import json, sys
d = sys.argv[1]
e = json.load(open(d + "/entitlements.json"))
assert sorted(e) == ["", "PlugIns/HelloExtension.appex"], sorted(e)
assert e[""]["bundleID"] == "com.example.hellorn" and e["PlugIns/HelloExtension.appex"]["bundleID"] == "com.example.hellorn.HelloExtension", e
assert json.load(open(d + "/packages.json")) == {"packages": []}
assert open(d + "/build-number").read().strip() == "1.0.0.2026101601"
PY
echo "==> HelloRN matches the Mac reference (app and extension, no allowed gaps)"
IN
}

simulator() {   # the simulator build of run 3, offline, in the same work copy
  echo "==> HelloRN: simulator build (offline)" >&2
  "${docker[@]}" run --rm -i ${plat[@]+"${plat[@]}"} --network none -v "$root":/repo:ro -v "$volume":/cache/work \
    -v xless-corepack:/cache/corepack -v "xless-bundle$vsuf":/cache/bundle \
    -v xless-cocoapods-home:/root/.cocoapods -v xless-cocoapods-cache:/root/Library/Caches/CocoaPods \
    -e XLESS_BUILD_NUMBER=1.0.0.2026101601 -e OVERLAY="$overlay" -e WORKNAME="$workname" "$image" bash -s <<'IN'
set -euo pipefail
o=/repo/$OVERLAY
w=/cache/work/$WORKNAME
device_app="$w/.xless/build/ios/app/HelloRN.app"
before=$(stat -c %Y "$device_app/Info.plist")
# The device build's records and its derived data must not change either (run 4 then rebuilds the device app offline
# from this work copy and compares it again, which catches a change to shared caches such as node_modules).
records() { (cd "$w/.xless/build/ios" && sha256sum entitlements.json packages.json sdk.json build-number 2>/dev/null); }
records_before=$(records)
marker=$(mktemp); touch "$marker"; sleep 1
app=$(xless ship --config "$o" --source /repo/samples/HelloRN --platform ios --destination simulator | tail -1)
[[ "$app" == "$w/.xless/build/ios-simulator/app/HelloRN.app" ]] || { echo "simulator app at $app"; exit 1; }
[[ $(stat -c %Y "$device_app/Info.plist") == "$before" ]] || { echo "the simulator build touched the device build's app"; exit 1; }
[[ "$(records)" == "$records_before" ]] || { echo "the simulator build changed the device build's records:"; records; exit 1; }
changed=$(find "$w/.xless/build/ios" "$w/.xless/derived-data" -newer "$marker" | head -5)
[[ -z "$changed" ]] || { echo "the simulator build wrote into the device build's outputs or derived data: $changed"; exit 1; }
check() {   # PLIST KEY WANT
  local got; got=$(/usr/libexec/PlistBuddy -c "Print :$2" "$1")
  [[ "$got" == "$3" ]] || { echo "$1: $2 is '$got', want '$3'"; exit 1; }
}
check "$app/Info.plist" DTPlatformName iphonesimulator
check "$app/Info.plist" CFBundleSupportedPlatforms:0 iPhoneSimulator
check "$app/Info.plist" CFBundleIdentifier com.example.hellorn
check "$app/PlugIns/HelloExtension.appex/Info.plist" DTPlatformName iphonesimulator
magic=$(head -c 8 "$app/main.jsbundle" | od -A n -t x1 | tr -d ' \n')
[[ "$magic" == c61fbc03c103191f ]] || { echo "main.jsbundle is not Hermes bytecode (starts $magic)"; exit 1; }
# arm64 simulator images (LC_BUILD_VERSION iossimulator), each executable with its simulated entitlements linked in
for exe in "$app/HelloRN" "$app/PlugIns/HelloExtension.appex/HelloExtension"; do
  cmds=$(llvm-otool -l "$exe")   # captured: `grep -q` on a pipe would end otool early, which pipefail reports
  grep -A2 "cmd LC_BUILD_VERSION" <<<"$cmds" | grep -q "platform iossimulator" || { echo "$exe is not a simulator image"; exit 1; }
  for sect in __entitlements __ents_der; do
    grep -q "sectname $sect" <<<"$cmds" || { echo "$exe has no __TEXT,$sect"; exit 1; }
  done
  LC_ALL=C grep -aq "ABCDE12345.com.example.hellorn" "$exe" || { echo "$exe: no application-identifier in its entitlements"; exit 1; }
done
# signed ad hoc: the app, the extension and every framework (on a Mac, sim-launch.sh also runs codesign --verify --deep --strict)
for code in "$app" "$app/PlugIns/HelloExtension.appex" "$app"/Frameworks/*.framework; do
  [[ -f "$code/_CodeSignature/CodeResources" ]] || { echo "$code is not signed"; exit 1; }
done
echo "==> simulator app $app: arm64 iphonesimulator, signed ad hoc, simulated entitlements linked"
IN
}

assets() {   # Mac host only: the device build's asset catalogs, read by assetutil, against the reference's
  local r="$refdir" cars x stage inner
  cars="$(mktemp -d "${TMPDIR:-/tmp}/hellorn-cars.XXXXXX")"
  (cd "$root" && env -u DEVELOPER_DIR swift build --product xless -q)
  x="$(cd "$root" && env -u DEVELOPER_DIR swift build --show-bin-path)/xless"
  for stage in app final; do
    inner="/cache/work/$workname/.xless/build/ios/$stage/HelloRN.app"
    mkdir -p "$cars/$stage"
    "${docker[@]}" run --rm -v "$volume:/cache/work:ro" "$alpine" sh -c "cd '$inner' && tar -cf - \$(find . -name '*.car')" \
      | tar -C "$cars/$stage" -xf -
    echo "==> comparing the asset catalogs of $inner with the reference (assetutil)" >&2
    "$x" tauri compare --assets-only "$r/reference.json" "$cars/$stage" --allow-file "$r/allowed-gaps.txt"
  done
  rm -rf "$cars"
}

fresh=$(( 1 - keep ))
run "fresh prepare, build, finalize (network)"
fresh=0
run "again, offline (--network none)" --network none
echo "==> HelloRN: both runs match the Mac reference" >&2
if [[ "$(uname)" == Darwin ]]; then
  assets
  echo "==> HelloRN: asset catalogs match the Mac reference (known gaps: $refdir/allowed-gaps.txt)" >&2
else
  echo "==> HelloRN: asset catalog comparison skipped (needs xcrun assetutil, a Mac host)" >&2
fi
simulator
run "device build after the simulator build, offline (--network none)" --network none
echo "==> HelloRN: the device build still matches the Mac reference after the simulator build" >&2
if [[ $launch == 1 && "$(uname)" == Darwin ]]; then
  echo "==> HelloRN: launching the simulator build on an iOS Simulator" >&2
  "$root/scripts/sim-launch.sh" "volume:$volume:/cache/work/$workname/.xless/build/ios-simulator/app/HelloRN.app"
else
  echo "==> HelloRN: simulator launch skipped ($( [[ $launch == 0 ]] && echo "--no-launch" || echo "not a Mac host"))" >&2
fi
