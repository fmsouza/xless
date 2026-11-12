#!/usr/bin/env bash
# Black-box reference build of a Tauri v2 app with the real Tauri CLI and Xcode. Mac only.
#
#   scripts/tauri-ios-reference.sh [--platform ios|macos] <tauri-app-root> <out-dir>
#   (or: make tauri-reference APP=… OUT=… [PLATFORM=macos])
#
# --platform ios (default): `tauri ios build` (archive, App Store export method).
# --platform macos:         `tauri build --target universal-apple-darwin --bundles app,dmg` (both darwin slices + lipo).
#
# Env: DEVELOPER_DIR    the Xcode to record with (<Xcode.app>/Contents/Developer; never `xcode-select -s`). Default: the
#                       clone at ~/.cache/xless/Xcode.app when it is versions.env's XCODE_BUILD, else xcode-select's. A
#                       build without an XcodeToolsProfile entry (scripts/xcode-tools.sh) is refused. Every step runs
#                       with it, through PATH shims (scripts/xcode-pin.sh) because the Tauri CLI drops DEVELOPER_DIR
#                       from what it runs; the run is refused when the app's DTXcodeBuild/DTSDKBuild (ios) or any log
#                       names another Xcode or the Command Line Tools. xless (for reference.json) is built with
#                       xcode-select's Xcode, so a reference Xcode whose Swift is older than Package.swift's works too.
#      TAURI_FEATURES   cargo features for `tauri … build --features` (space or comma separated)
#      TAURI_DIR        Tauri directory inside the app root (default src-tauri)
#      REF_WORK         reuse this scratch dir instead of a fresh mktemp one: the work copy is recreated from
#                       scratch each run, but <tauri dir>/target is carried over (incremental cargo rebuilds)
#      REF_PRE_BUILD    shell command run in the work copy right before the tauri build, for gitignored build
#                       outputs an app's checkout normally already has (e.g. resource dirs its build.rs stages)
#
# The source tree is never touched: its tracked files (working-tree contents) are copied into <tmp>/work and
# everything runs there. Logging wrappers are put first on PATH; each appends one JSON line per call to
# <out>/<tool>.jsonl and execs the real tool: cargo, xcrun and swift (both platforms), plus lipo, hdiutil, codesign,
# SetFile and bless (macos; the last three are called by tauri-bundler's DMG script). Only the env families the
# contract needs are recorded for cargo (TAURI_*, IPHONEOS_DEPLOYMENT_TARGET (ios) or MACOSX_DEPLOYMENT_TARGET (macos),
# SDKROOT, CC*, CFLAGS*, RUSTFLAGS, CARGO_*TARGET*); names containing KEY/PASSWORD/SECRET/TOKEN are redacted.
#
# Signing: none. ios: `tauri ios build … --no-sign` with APPLE_DEVELOPMENT_TEAM unset, so no team or profile is
# involved. If that fails while a libapp.a from an earlier run exists, the script falls back to xcodebuild on the
# generated project with CODE_SIGNING_ALLOWED=NO (see "Fallback" below); otherwise it exits with tauri's status.
# macos: `tauri build … --no-sign` with the APPLE_* signing/notarization variables unset; the codesign wrapper shows
# whether anything was signed anyway (it should log nothing).
#
# Outputs in <out>: build.log, the *.jsonl logs, reference.json (`xless tauri report` of the unsigned .app) and
# calls.json (scripts/tauri-reference-normalize.py; absolute paths rewritten to $WORK, $SDK, $TOOLCHAIN, $DEVELOPER,
# $REFTMP, $DARWIN_USER_{CACHE,TEMP}_DIR and $HOME, ios also $DERIVED). ios adds link.txt (the final clang link line of
# the app executable), linkfiles.txt (its -filelist) and compile.json (the app's clang compile lines). macos adds
# dmg.json (the DMG's file name, volume name, image format, top-level entries and the volume root's Finder flags, read
# from a read-only attach).
# Only reference.json, calls.json and dmg.json are meant to be committed, and only for samples/HelloTauri. The work
# copy is left in place.
# The normalisation prefixes and generated wrappers hold literal $NAMES on purpose.
# shellcheck disable=SC2016
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=/dev/null
. "$ROOT/versions.env"

PLATFORM=ios
if [[ "${1:-}" == --platform ]]; then PLATFORM="${2:-}"; shift 2 || true; fi
if [[ ( "$PLATFORM" != ios && "$PLATFORM" != macos ) || $# -ne 2 ]]; then
  echo "usage: $0 [--platform ios|macos] <tauri-app-root> <out-dir>" >&2; exit 2
fi
[[ "$(uname)" == Darwin ]] || { echo "tauri-ios-reference: needs macOS (uname is $(uname))" >&2; exit 1; }
# The Xcode: DEVELOPER_DIR if set, else the APFS clone at ~/.cache/xless/Xcode.app when it is versions.env's pinned
# build, else xcode-select's (as scripts/rn-reference.sh). Any Xcode with an XcodeToolsProfile entry is a valid reference
# for that Xcode's SDK.
CLONE="$HOME/.cache/xless/Xcode.app/Contents/Developer"
if [[ -z "${DEVELOPER_DIR:-}" && -d "$CLONE" ]] \
   && DEVELOPER_DIR="$CLONE" xcodebuild -version 2>/dev/null | grep -qx "Build version $XCODE_BUILD"; then
  DEVELOPER_DIR="$CLONE"
fi
DEV="${DEVELOPER_DIR:-$(xcode-select -p)}"; DEV="${DEV%/}"
XCODE_FOUND="$(DEVELOPER_DIR="$DEV" xcodebuild -version 2>/dev/null | sed -n 's/^Build version //p')"
[[ -n "$XCODE_FOUND" ]] || { echo "tauri-ios-reference: no Xcode at $DEV (set DEVELOPER_DIR=<Xcode.app>/Contents/Developer)" >&2; exit 1; }
"$ROOT/scripts/xcode-tools.sh" "$XCODE_FOUND" || exit 1
if [[ "$XCODE_FOUND" != "$XCODE_BUILD" ]]; then
  echo "==> note: Xcode build $XCODE_FOUND, not versions.env's default $XCODE_BUILD: a reference for that Xcode's SDK only" >&2
fi
echo "==> Xcode $XCODE_FOUND at $DEV"

APP="$(cd "$1" && pwd)"
mkdir -p "$2"; OUT="$(cd "$2" && pwd)"
TAURI_DIR="${TAURI_DIR:-src-tauri}"
git -C "$APP" rev-parse --git-dir >/dev/null 2>&1 || { echo "tauri-ios-reference: $APP is not in a git repository" >&2; exit 1; }

# rustup's cargo first, so the app's rust-toolchain.toml is honoured (Homebrew's cargo would shadow it).
export PATH="$HOME/.cargo/bin:$PATH"
REAL_CARGO="$(command -v cargo)"
unset APPLE_DEVELOPMENT_TEAM
if [[ "$PLATFORM" == macos ]]; then
  # tauri-bundler's signing and notarization inputs: none of them may reach an unsigned reference build.
  unset APPLE_SIGNING_IDENTITY APPLE_CERTIFICATE APPLE_CERTIFICATE_PASSWORD APPLE_ID APPLE_PASSWORD APPLE_TEAM_ID \
        APPLE_API_KEY APPLE_API_ISSUER APPLE_API_KEY_PATH APPLE_PROVIDER_SHORT_NAME TAURI_SIGNING_PRIVATE_KEY \
        TAURI_SIGNING_PRIVATE_KEY_PASSWORD
fi
# CI=true also makes tauri-bundler's DMG script skip its Finder AppleScript (window layout), as on a build server.
export LANG="${LANG:-en_US.UTF-8}" CI=true

if [[ -n "${REF_WORK:-}" ]]; then TMP="$REF_WORK"; mkdir -p "$TMP"; else TMP="$(mktemp -d "${TMPDIR:-/tmp}/tauri-ref.XXXXXX")"; fi
TMP_LOGICAL="$(cd "$TMP" && pwd -L)"; TMP="$(cd "$TMP" && pwd -P)"   # /var/folders/… vs /private/var/folders/…
WORK="$TMP/work"; BIN="$TMP/bin"; XBIN="$TMP/xcode-bin"
# A reused REF_WORK starts from a fresh work tree (rsync --files-from does not delete stale files); only the cargo
# target dir survives, for incremental builds.
KEEP="$TMP/target.keep"
if [[ -d "$WORK/$TAURI_DIR/target" ]]; then rm -rf "$KEEP"; mv "$WORK/$TAURI_DIR/target" "$KEEP"; fi
rm -rf "$WORK" "$BIN" "$XBIN"
mkdir -p "$WORK" "$BIN"
echo "==> work copy: $WORK"
# Tracked files that exist in the working tree (a tracked file deleted but not yet staged would make rsync fail).
git -C "$APP" ls-files -z | while IFS= read -r -d '' f; do
  if [[ -e "$APP/$f" || -L "$APP/$f" ]]; then printf '%s\0' "$f"; fi
done | rsync -a --from0 --files-from=- "$APP"/ "$WORK"/
if [[ -d "$KEEP" ]]; then mkdir -p "$WORK/$TAURI_DIR"; mv "$KEEP" "$WORK/$TAURI_DIR/target"; fi
# Clear old outputs only after the sync: <out> may sit inside the app tree (samples/HelloTauri/reference).
rm -f "$OUT"/{cargo,xcrun,swift,lipo,hdiutil,codesign,SetFile,bless}.jsonl \
      "$OUT"/{build.log,link.txt,linkfiles.txt,compile.json,calls.json,prefixes.json,dmg.json}

# --- logging wrappers -------------------------------------------------------------------------------------------
if [[ "$PLATFORM" == ios ]]; then DEPLOYMENT=IPHONEOS_DEPLOYMENT_TARGET; else DEPLOYMENT=MACOSX_DEPLOYMENT_TARGET; fi
# /usr/bin/python3 is an xcrun shim, and xcrun exports SDKROOT (the macOS SDK) to the tool it runs when it is unset.
# So whether cargo itself got an SDKROOT is decided in bash, before python starts (argv[2]: 1 if set).
cat > "$BIN/cargo" <<EOF
#!/bin/bash
/usr/bin/python3 -c 'import json, os, re, sys
keep = re.compile(r"^(TAURI_.*|$DEPLOYMENT|SDKROOT|CC.*|CFLAGS.*|RUSTFLAGS|CARGO_.*TARGET.*)\$")
secret = re.compile(r"KEY|PASSWORD|SECRET|TOKEN")
env = {k: ("<redacted>" if secret.search(k) else v) for k, v in os.environ.items() if keep.match(k)}
if sys.argv[2] != "1": env.pop("SDKROOT", None)
with open(sys.argv[1], "a") as f: f.write(json.dumps({"cwd": os.getcwd(), "argv": sys.argv[3:], "env": env}, sort_keys=True) + "\n")' "$OUT/cargo.jsonl" "\${SDKROOT+1}" "\$@"
exec "$REAL_CARGO" "\$@"
EOF
# argv_wrapper <name> <real command…>: logs cwd and argv, then execs the real tool.
argv_wrapper() {
  local name="$1"; shift
  cat > "$BIN/$name" <<EOF
#!/bin/bash
/usr/bin/python3 -c 'import json, os, sys
with open(sys.argv[1], "a") as f: f.write(json.dumps({"cwd": os.getcwd(), "argv": sys.argv[2:]}) + "\n")' "$OUT/$name.jsonl" "\$@"
exec $* "\$@"
EOF
}
# The Xcode reaches every tool through PATH: the Tauri CLI runs xcodebuild and cargo with a cleared environment that
# keeps PATH but not DEVELOPER_DIR, so an exported DEVELOPER_DIR alone would leave them on xcode-select's Xcode.
# scripts/xcode-pin.sh writes a DEVELOPER_DIR-pinning shim for each Xcode shim in /usr/bin into $XBIN.
"$ROOT/scripts/xcode-pin.sh" shims "$DEV" "$XBIN" || exit 1
pinned="$(env -u DEVELOPER_DIR PATH="$XBIN:/usr/bin:/bin" xcodebuild -version 2>/dev/null | sed -n 's/^Build version //p')"
[[ "$pinned" == "$XCODE_FOUND" ]] \
  || { echo "tauri-ios-reference: the PATH shims in $XBIN run Xcode build '${pinned:-none}', not $XCODE_FOUND: no reference for $DEV" >&2; exit 1; }
argv_wrapper xcrun "$XBIN/xcrun"
argv_wrapper swift "$XBIN/xcrun" swift
WRAPPED=(cargo xcrun swift)
if [[ "$PLATFORM" == macos ]]; then
  argv_wrapper lipo "$XBIN/lipo"
  argv_wrapper hdiutil /usr/bin/hdiutil
  argv_wrapper codesign /usr/bin/codesign
  argv_wrapper SetFile "$XBIN/SetFile"
  argv_wrapper bless /usr/sbin/bless
  WRAPPED+=(lipo hdiutil codesign SetFile bless)
fi
for w in "${WRAPPED[@]}"; do chmod +x "$BIN/$w"; done
ORIG_PATH="$PATH"
export DEVELOPER_DIR="$DEV" PATH="$BIN:$XBIN:$PATH"

# --- dependencies (inside the work copy only) ------------------------------------------------------------------
cd "$WORK"
if [[ -f pnpm-lock.yaml ]]; then pnpm install --frozen-lockfile
elif [[ -f package-lock.json ]]; then npm ci
elif [[ -f yarn.lock ]]; then yarn install --frozen-lockfile
fi
FEATURES=()
if [[ -n "${TAURI_FEATURES:-}" ]]; then read -ra feats <<< "${TAURI_FEATURES//,/ }"; FEATURES=(--features ${feats[@]+"${feats[@]}"}); fi
unset TAURI_FEATURES   # ours, not Tauri's: keep it out of the recorded TAURI_* env

TOOLCHAIN="$DEV/Toolchains/XcodeDefault.xctoolchain"
# Normalisation prefixes for calls.json (more are added per platform below).
PREFIXES=('$WORK' "$WORK" '$WORK' "$TMP_LOGICAL/work" '$REFTMP' "$TMP" '$REFTMP' "$TMP_LOGICAL"
          '$TOOLCHAIN' "$TOOLCHAIN" '$DEVELOPER' "$DEV" '$HOME' "$HOME"
          '$DARWIN_USER_CACHE_DIR' "$(getconf DARWIN_USER_CACHE_DIR | sed 's:/$::')"
          '$DARWIN_USER_TEMP_DIR' "$(getconf DARWIN_USER_TEMP_DIR | sed 's:/$::')")

# report_app <app>: `xless tauri report` of the built bundle → <out>/reference.json (wrappers off: app build only).
# xless itself is built by xcode-select's Xcode: the reference's Xcode may ship a Swift older than Package.swift's tools
# version (6.3 before Xcode 26.4), and which Xcode builds the reporting tool does not change the report.
report_app() {
  export PATH="$ORIG_PATH"
  (cd "$ROOT" && env -u DEVELOPER_DIR swift build --product xless -q) \
    || { echo "tauri-ios-reference: building xless with xcode-select's Xcode ($(env -u DEVELOPER_DIR xcode-select -p)) failed" >&2; exit 1; }
  "$(cd "$ROOT" && env -u DEVELOPER_DIR swift build --show-bin-path)/xless" tauri report "$1" --json "$OUT/reference.json"
}
# check_xcode <file>…: refuse the run when a log names another Xcode or the Command Line Tools (a tool that bypassed
# the PATH shims, e.g. by an absolute /usr/bin path with DEVELOPER_DIR cleared).
check_xcode() {
  local others
  if ! others="$("$ROOT/scripts/xcode-pin.sh" check "$DEV" "$@" 2>&1)"; then
    echo "tauri-ios-reference: the build used a toolchain other than $DEV, so it is no reference for Xcode $XCODE_FOUND:" >&2
    while IFS= read -r line; do echo "  $line" >&2; done <<< "$others"
    exit 1
  fi
}
# normalize <platform>: merges the logs into <out>/calls.json.
normalize() {
  /usr/bin/python3 -c 'import json, sys; print(json.dumps(list(zip(sys.argv[1::2], sys.argv[2::2]))))' "${PREFIXES[@]}" \
    > "$OUT/prefixes.json"
  /usr/bin/python3 "$ROOT/scripts/tauri-reference-normalize.py" "$OUT" "$1"
  rm -f "$OUT/prefixes.json"
}

if [[ "$PLATFORM" == macos ]]; then
  # --- macOS: universal .app and .dmg ---------------------------------------------------------------------------
  [[ -z "${REF_PRE_BUILD:-}" ]] || { echo "==> REF_PRE_BUILD: $REF_PRE_BUILD"; bash -c "$REF_PRE_BUILD"; }
  set +e
  pnpm tauri build --target universal-apple-darwin --bundles app,dmg --no-sign -v ${FEATURES[@]+"${FEATURES[@]}"} 2>&1 \
    | tee "$OUT/build.log"
  status=${PIPESTATUS[0]}
  set -e
  [[ $status -eq 0 ]] || { echo "tauri-ios-reference: tauri build exited $status (see $OUT/build.log)" >&2; exit "$status"; }
  BUNDLE_DIR="$(find "$WORK" -type d -path '*/universal-apple-darwin/release/bundle' -not -path '*/node_modules/*' | head -1)"
  APP_BUNDLE="$(find "$BUNDLE_DIR/macos" -maxdepth 1 -type d -name '*.app' | head -1)"
  DMG="$(find "$BUNDLE_DIR/dmg" -maxdepth 1 -type f -name '*.dmg' | head -1)"
  [[ -n "$APP_BUNDLE" && -n "$DMG" ]] || { echo "tauri-ios-reference: no .app or .dmg under $BUNDLE_DIR" >&2; exit 1; }
  echo "==> app: $APP_BUNDLE"
  echo "==> dmg: $DMG"
  check_xcode "$OUT"/*.jsonl "$OUT/build.log"
  report_app "$APP_BUNDLE"

  # DMG: read-only attach at a private mount point (no Finder window), list the top level, detach.
  MNT="$TMP/dmg-mount"; mkdir -p "$MNT"
  hdiutil attach -nobrowse -readonly -noautoopen -mountpoint "$MNT" "$DMG" >/dev/null
  trap 'hdiutil detach "$MNT" -quiet >/dev/null 2>&1 || hdiutil detach "$MNT" -force -quiet >/dev/null 2>&1 || true' EXIT
  diskutil info -plist "$MNT" > "$TMP/dmg-volume.plist"
  GetFileInfo -a "$MNT" > "$TMP/dmg-root-attrs.txt"   # Finder flags of the volume root (C = custom icon)
  hdiutil imageinfo -plist "$DMG" > "$TMP/dmg-image.plist"
  /usr/bin/python3 - "$DMG" "$MNT" "$TMP/dmg-volume.plist" "$TMP/dmg-image.plist" "$TMP/dmg-root-attrs.txt" "$OUT/dmg.json" <<'PY'
import json, os, plistlib, sys
dmg, mnt, vol_plist, img_plist, root_attrs, out = sys.argv[1:]
vol = plistlib.load(open(vol_plist, "rb"))
img = plistlib.load(open(img_plist, "rb"))
entries = []
for name in sorted(os.listdir(mnt)):
    p = os.path.join(mnt, name)
    if os.path.islink(p):
        entries.append({"name": name, "type": "symlink", "target": os.readlink(p)})
    elif os.path.isdir(p):
        entries.append({"name": name, "type": "dir"})
    else:
        entries.append({"name": name, "type": "file"})
json.dump({
    "fileName": os.path.basename(dmg),
    "volumeName": vol.get("VolumeName"),
    "filesystem": vol.get("FilesystemName"),
    "format": img.get("Format"),
    "partitionScheme": img.get("partitions", {}).get("partition-scheme"),
    "rootFinderAttributes": open(root_attrs).read().strip(),
    "entries": entries,
}, open(out, "w"), indent=2, sort_keys=True)
open(out, "a").write("\n")
PY
  hdiutil detach "$MNT" -quiet; trap - EXIT
  echo "==> codesign -dv of the .app: $(codesign -dv "$APP_BUNDLE" 2>&1 | tr '\n' ' ')"

  SDK="$("$XBIN/xcrun" --sdk macosx --show-sdk-path)"
  PREFIXES+=('$SDK' "$SDK")
  normalize macos
  echo "==> wrote $OUT/reference.json, $OUT/calls.json and $OUT/dmg.json"
  exit 0
fi

# --- iOS --------------------------------------------------------------------------------------------------------
APPLE_DIR="$WORK/$TAURI_DIR/gen/apple"
# CocoaPods only when the Podfile actually declares pods (Tauri's template Podfile declares none).
if [[ -f "$APPLE_DIR/Podfile" ]] && grep -Eq "^[[:space:]]*pod[[:space:]]+['\"]" "$APPLE_DIR/Podfile"; then
  (cd "$APPLE_DIR" && pod install)
fi

rm -rf "$APPLE_DIR/build"
[[ -z "${REF_PRE_BUILD:-}" ]] || { echo "==> REF_PRE_BUILD: $REF_PRE_BUILD"; bash -c "$REF_PRE_BUILD"; }
set +e
pnpm tauri ios build --export-method app-store-connect --build-number 1 --no-sign --ci -v ${FEATURES[@]+"${FEATURES[@]}"} 2>&1 | tee "$OUT/build.log"
status=${PIPESTATUS[0]}
set -e
# Prefer the archived (installed, stripped) product; else the iphoneos build product.
find_app() {
  { find "$APPLE_DIR/build" -type d -name '*.app' -path '*.xcarchive/Products/Applications/*' 2>/dev/null
    find "$APPLE_DIR/build" "$TMP/dd" -type d -name '*.app' -path '*-iphoneos/*' 2>/dev/null; } | head -1
}
APP_BUNDLE="$(find_app || true)"
if [[ $status -ne 0 || -z "$APP_BUNDLE" ]]; then
  # Fallback: build the generated project directly, unsigned. With tauri-cli 2.12 the project's "Build Rust Code"
  # phase (`tauri ios xcode-script`) needs a running `tauri ios build` (it reads
  # gen/apple/.tauri/cli-options-server.json), so this can only link a libapp.a an earlier run left in Externals.
  # Without one, report tauri's own failure instead.
  if [[ ! -f "$APPLE_DIR/Externals/arm64/release/libapp.a" ]]; then
    echo "tauri-ios-reference: tauri ios build exited $status without an .app (see $OUT/build.log)" >&2
    exit $(( status == 0 ? 1 : status ))
  fi
  echo "==> tauri ios build exited $status; falling back to xcodebuild CODE_SIGNING_ALLOWED=NO" | tee -a "$OUT/build.log"
  projs=("$APPLE_DIR"/*.xcodeproj); PROJ="${projs[0]}"
  SCHEME="$(basename "$PROJ" .xcodeproj)_iOS"
  xcodebuild -project "$PROJ" -scheme "$SCHEME" -configuration release -sdk iphoneos -destination 'generic/platform=iOS' \
    -derivedDataPath "$TMP/dd" CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY= build 2>&1 | tee -a "$OUT/build.log"
  [[ ${PIPESTATUS[0]} -eq 0 ]] || { echo "tauri-ios-reference: xcodebuild fallback failed (see $OUT/build.log)" >&2; exit 1; }
  APP_BUNDLE="$(find_app || true)"
fi
[[ -n "$APP_BUNDLE" ]] || { echo "tauri-ios-reference: no .app produced (see $OUT/build.log)" >&2; exit 1; }
echo "==> app: $APP_BUNDLE"

# --- link line, bundle report, calls.json -----------------------------------------------------------------------
EXE="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP_BUNDLE/Info.plist")"
# `tauri ios build` does not echo xcodebuild's output, so the compile/link transcripts come from the activity logs of
# the DerivedData folders whose WorkspacePath is inside this work copy (plus the fallback's own -derivedDataPath).
DERIVED=()
[[ -d "$TMP/dd" ]] && DERIVED+=("$TMP/dd")
for d in "$HOME/Library/Developer/Xcode/DerivedData"/*; do
  ws="$(/usr/libexec/PlistBuddy -c 'Print :WorkspacePath' "$d/info.plist" 2>/dev/null || true)"
  [[ "$ws" == "$WORK/"* || "$ws" == "$TMP_LOGICAL/work/"* ]] && DERIVED+=("$d")
done
LOGS=("$OUT/build.log")
for d in ${DERIVED[@]+"${DERIVED[@]}"}; do
  while IFS= read -r f; do LOGS+=("$f"); done < <(ls -tr "$d"/Logs/Build/*.xcactivitylog 2>/dev/null)
done
/usr/bin/python3 "$ROOT/scripts/tauri-reference-xcodelog.py" "$EXE" "$OUT" "${LOGS[@]}"
# Xcode stamps its own build and the SDK's into the app: both must be the requested Xcode's.
stamped="$(/usr/libexec/PlistBuddy -c 'Print :DTXcodeBuild' "$APP_BUNDLE/Info.plist" 2>/dev/null || true)"
sdk_build="$(/usr/libexec/PlistBuddy -c 'Print :DTSDKBuild' "$APP_BUNDLE/Info.plist" 2>/dev/null || true)"
want_sdk="$("$XBIN/xcrun" --sdk iphoneos --show-sdk-build-version)"
[[ "$stamped" == "$XCODE_FOUND" && "$sdk_build" == "$want_sdk" ]] || {
  echo "tauri-ios-reference: the app was built by Xcode build '$stamped' with SDK '$sdk_build', not $XCODE_FOUND with $want_sdk" >&2
  exit 1; }
check_xcode "$OUT"/*.jsonl "$OUT/build.log" "$OUT/link.txt" "$OUT/compile.json"

report_app "$APP_BUNDLE"

SDK="$("$XBIN/xcrun" --sdk iphoneos --show-sdk-path)"
PREFIXES+=('$SDK' "$SDK")
for d in ${DERIVED[@]+"${DERIVED[@]}"}; do PREFIXES+=('$DERIVED' "$d"); done
normalize ios
# DerivedData of a throwaway work copy is useless afterwards; keep it when the work dir is reused (REF_WORK).
[[ -n "${REF_WORK:-}" ]] || for d in ${DERIVED[@]+"${DERIVED[@]}"}; do rm -rf "$d"; done
echo "==> wrote $OUT/reference.json and $OUT/calls.json"
