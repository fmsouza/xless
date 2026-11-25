#!/usr/bin/env bash
# m3 Task 5 end-to-end check: write a workspace's PIF and build request with XlessXcode (`xless xcode pif`) on Linux,
# then build it with the stock `swbuild` in the gate-G2 environment (docs/research/react-native-ios-contract.md,
# "Swift Build on Linux — spike G2"). Not part of xless's pipeline (Task 8 wires the build stage); kept as executable
# documentation and for re-running the check.
#
#   docker --context colima-xless run --rm -v "$PWD":/repo:ro -v xless-m3-t5:/scratch -w /repo xless:local-arm64-xcode27.0 \
#     scripts/xcode-pif-linux.sh samples/HelloPIF/HelloPIF.xcodeproj HelloPIF /scratch/dd-hellopif
#   … then: xless tauri compare samples/HelloPIF/reference/reference.json /scratch/dd-hellopif/Products/Release-iphoneos/HelloPIF.app \
#             --allow-file samples/HelloPIF/reference/allowed-gaps.txt   (no gaps: the image's actool shim builds the catalog)
#   CocoaPods-style fixture: … Tests/XlessXcodeTests/Fixtures/PodsStyle/PodsStyle.xcworkspace App /scratch/dd-pods, then
#     xless tauri compare Tests/XlessXcodeTests/Fixtures/PodsStyle-reference.json /scratch/dd-pods/Products/Release-iphoneos/App.app
#     (the reference is `xless tauri report` of `xcodebuild -workspace … -scheme App -configuration Release -sdk iphoneos
#     CODE_SIGNING_ALLOWED=NO` with Xcode 27A266a)
#
# Args: <.xcworkspace|.xcodeproj> <scheme> <derived data> [configuration, default Release]
# Env:  XLESS          an xless with `xcode pif` (default: built from this checkout into /scratch/build)
#       PIF_OUT        where the PIF and request.json go (default: a temporary directory)
set -euo pipefail
ws=$1 scheme=$2 dd=$3 config=${4:-Release}
B=/opt/xless/config/swiftpm/swift-sdks/darwin.artifactbundle
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
out=${PIF_OUT:-$work/pif}

if [[ -z "${XLESS:-}" ]]; then
  swift build --product xless --scratch-path /scratch/build >&2
  XLESS=/scratch/build/debug/xless
fi


# The G2 overrides (why each is needed: the contract doc's settings table).
mapfile -t files < <("$XLESS" xcode pif "$ws" --scheme "$scheme" --configuration "$config" --out "$out" \
  --override "SWIFT_SDK_TOOLSETS=$B/toolset-swb.json" --override CODE_SIGNING_ALLOWED=NO \
  --override LM_SKIP_METADATA_EXTRACTION=YES --override GENERATE_INTERMEDIATE_TEXT_BASED_STUBS=NO \
  --override STRIP_BITCODE_FROM_COPIED_FILES=NO --override SWIFT_STDLIB_TOOL_STRIP_BITCODE=NO)

unset SDKROOT
# actool/ibtool are the image's shims (docker/shims, on PATH).
export XCODE_EXTRA_PLATFORM_FOLDERS="$B/Developer/Platforms" PATH="$B/toolset/bin:$PATH"
swbuild build "${files[0]}" --derivedDataPath "$dd" --buildRequestFile "${files[1]}"
