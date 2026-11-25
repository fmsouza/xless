#!/usr/bin/env bash
# SPIKE (m3 Task 3, gate G2): build samples/HelloPIF for iphoneos with the stock `swbuild` (swift-build) on Linux, from
# the PIF that `xcodebuild -dumpPIF` wrote on a Mac. Kept as executable documentation of the Swift Build invocation
# that the m3 build stage automates; it is not part of xless and is not run by CI. Findings:
# docs/research/react-native-ios-contract.md, "Swift Build on Linux — spike G2".
#
#   mac$  cd samples/HelloPIF && xcodegen generate && xcodebuild -project HelloPIF.xcodeproj -dumpPIF /tmp/HelloPIF.pif
#   linux (the xless image, repo at /repo):
#         scripts/spikes/hellopif-swbuild-linux.sh /tmp/HelloPIF.pif <mac samples/HelloPIF dir> <derived data> \
#           [--implicit]
#
# The PIF's absolute paths (workspace, project, projectDirectory) are rewritten from the Mac directory to this
# checkout's samples/HelloPIF. --implicit empties the app target's explicit dependencies and builds through a
# --buildRequestFile with implicit dependencies on (the `build` command's own request has them off).
# Env: ACTOOL_STANDIN_LOG  file that receives every actool argv (default /dev/null).
# Check: xless tauri compare samples/HelloPIF/reference/reference.json <dd>/Products/Release-iphoneos/HelloPIF.app \
#          --allow-file <file listing the five stand-in gaps named in samples/HelloPIF/reference/allowed-gaps.txt>
# (the image's real actool shim, m3 Task 6a, closes them: scripts/xcode-pif-linux.sh)
set -euo pipefail
pif=$1 mac_dir=${2%/} dd=$3 implicit=${4:-}
project="$(cd "$(dirname "$0")/../../samples/HelloPIF" && pwd)"
B=/opt/xless/config/swiftpm/swift-sdks/darwin.artifactbundle
work="$(mktemp -d)"
mkdir -p "$work/bin"

cat > "$work/bin/actool" <<'ACTOOL'
#!/bin/bash
# Gate G2 spike stand-in for Apple's actool (absent on Linux): logs argv to $ACTOOL_STANDIN_LOG, answers Swift Build's
# two probes (--version, --print-asset-tag-combinations) and writes every declared output empty. No Assets.car and no
# icons are produced. The Swift asset-symbols file gets the imports the real one has: they decide which Swift overlays
# the app autolinks (without SwiftUI the executable misses libswiftCoreAudio).
printf '%q ' "$0" "$@" >> "${ACTOOL_STANDIN_LOG:-/dev/null}"; echo >> "${ACTOOL_STANDIN_LOG:-/dev/null}"
plist_head='<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">'
case " $* " in
  *" --version "*)
    echo "$plist_head<dict><key>com.apple.actool.version</key><dict><key>bundle-version</key><string>25098</string>"\
"<key>short-bundle-version</key><string>27.0</string></dict></dict></plist>"; exit 0 ;;
  *" --print-asset-tag-combinations "*)
    echo "$plist_head<dict><key>com.apple.actool.asset-tag-combinations</key><array/></dict></plist>"; exit 0 ;;
esac
while [ $# -gt 0 ]; do
  case "$1" in
    --compile) mkdir -p "$2"; shift ;;
    --output-partial-info-plist) echo "$plist_head<dict/></plist>" > "$2"; shift ;;
    --export-dependency-info) printf '\0actool-standin\0' > "$2"; shift ;;
    --generate-swift-asset-symbols)
      printf '%s\n' 'import Foundation' '#if canImport(UIKit)' 'import UIKit' '#endif' \
        '#if canImport(SwiftUI)' 'import SwiftUI' '#endif' \
        '#if canImport(DeveloperToolsSupport)' 'import DeveloperToolsSupport' '#endif' > "$2"; shift ;;
    --generate-objc-asset-symbols) : > "$2"; shift ;;
    --generate-asset-symbol-index) echo "$plist_head<dict/></plist>" > "$2"; shift ;;
  esac
  shift
done
echo "/* com.apple.actool.compilation-results */"
exit 0
ACTOOL
chmod +x "$work/bin/actool"

python3 - "$pif" "$mac_dir" "$project" "$work" "$B" "$implicit" <<'PY'
import json, sys
pif_path, mac_dir, project, work, bundle, implicit = sys.argv[1:]
pif = json.loads(open(pif_path).read().replace(mac_dir, project))
# Overrides on top of the project's settings; why each is needed: the contract doc's settings table.
params = {"configurationName": "Release", "overrides": {"commandLine": {"table": {
    "SWIFT_SDK_TOOLSETS": f"{bundle}/toolset-swb.json",
    "CODE_SIGNING_ALLOWED": "NO",
    "LM_SKIP_METADATA_EXTRACTION": "YES",
    "GENERATE_INTERMEDIATE_TEXT_BASED_STUBS": "NO",
    "STRIP_BITCODE_FROM_COPIED_FILES": "NO",
    "SWIFT_STDLIB_TOOL_STRIP_BITCODE": "NO",
}}}}
app = next(o["contents"] for o in pif if o["type"] == "target" and o["contents"]["name"] == "HelloPIF")
if implicit:
    app["dependencies"] = []
json.dump(pif, open(f"{work}/HelloPIF.pif", "w"))
json.dump(params, open(f"{work}/params.json", "w"))
json.dump({"parameters": {**params, "action": "build"}, "configuredTargets": [{"guid": app["guid"]}],
           "useParallelTargets": True, "useImplicitDependencies": True, "dependencyScope": "workspace",
           "useDryRun": False, "continueBuildingAfterErrors": False, "hideShellScriptEnvironment": True,
           "showNonLoggedProgress": True,
           "buildCommand": {"command": "build", "style": "buildOnly", "skipDependencies": False},
           "enableIndexBuildArena": False, "useLegacyBuildLocations": False}, open(f"{work}/request.json", "w"))
PY

# SDKROOT unset and the bundle's platforms on XCODE_EXTRA_PLATFORM_FOLDERS: then swbuild has iphoneos.
unset SDKROOT
export XCODE_EXTRA_PLATFORM_FOLDERS="$B/Developer/Platforms" PATH="$work/bin:$B/toolset/bin:$PATH"
if [ -n "$implicit" ]; then
  exec swbuild build "$work/HelloPIF.pif" --derivedDataPath "$dd" --buildRequestFile "$work/request.json"
else
  exec swbuild build "$work/HelloPIF.pif" --target HelloPIF --configuration Release --derivedDataPath "$dd" \
    --buildParametersFile "$work/params.json"
fi
