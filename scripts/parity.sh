#!/usr/bin/env bash
# Compares an Xcode build of HelloShip with an xless (Linux) build of the same sources. Run on the Mac.
# Checks Info.plist keys, the main binary's LC_BUILD_VERSION, bundle file lists and (iOS) Assets.car renditions
# (`xless tauri compare --assets-only`: per rendition what assetutil --info reports that changes how it draws, such as
# Opaque, Colorspace and color components), validity (assetutil --validate-file) and thinnability;
# legitimate differences are listed with reasons in scripts/parity-allowlist.txt. Known AssetKit Assets.car gaps
# are described in docs/research/parity-known-gaps.md.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
W="$ROOT/.xless/parity"; S="$W/HelloShip"; rm -rf "$W"; mkdir -p "$W"
# A copy of the sample, as a macOS app too (the line is a comment in the sample).
cp -R "$ROOT/samples/HelloShip" "$S"; rm -rf "$S/.xless" "$S/.build"
sed 's/^  # macos: /  macos: /' "$ROOT/samples/HelloShip/xless.yml" > "$S/xless.yml"
ALLOW="$ROOT/scripts/parity-allowlist.txt"
(cd "$ROOT" && swift build -c release --product xless >/dev/null); X="$(cd "$ROOT" && swift build -c release --show-bin-path)/xless"
status=0
# The xless build runs in this checkout's image (make images builds it), with the Xcode's pack read-only (xless setup --docker
# prepares it): XLESS_XCODE_PIN (default versions.env's XCODE_VERSION) chooses it, from its volume or XLESS_XCODES; XLESS_IMAGE
# names another image; DOCKER_CONTEXT, default colima-xless when it exists.
case "$(uname -m)" in arm64|aarch64) arch=arm64 ;; *) arch=amd64 ;; esac
xcode="${XLESS_XCODE_PIN:-$(sed -n 's/^XCODE_VERSION=//p' "$ROOT/versions.env")}"
image="${XLESS_IMAGE:-xless:$("$ROOT/scripts/docker-images.sh" tag --arch "$arch")-$arch}"
# shellcheck source=SCRIPTDIR/docker-context.sh
. "$ROOT/scripts/docker-context.sh"   # docker_context: the context, as xless chooses it
ctx="$(docker_context parity)" || exit 2
args=(docker)
[[ -z "$ctx" ]] || args+=(--context "$ctx")
# shellcheck source=SCRIPTDIR/xcode-pack-args.sh
. "$ROOT/scripts/xcode-pack-args.sh"   # pack_args: the Xcode's pack, read-only, as xless run gives it
pack_args parity

for P in ios macos; do
  if [[ $P == ios ]]; then SCHEME=HelloShip-iOS; DEST='generic/platform=iOS'; else SCHEME=HelloShip-macOS; DEST='generic/platform=macOS'; fi
  (cd "$S" && xcodegen generate -q && xcodebuild -project HelloShipParity.xcodeproj -scheme "$SCHEME" -destination "$DEST" \
     -configuration Release CODE_SIGNING_ALLOWED=NO -derivedDataPath "$W/dd-$P" build -quiet)
  XAPP=$(find "$W/dd-$P/Build/Products" -maxdepth 2 -name HelloShip.app | head -1)
  "${args[@]}" run --rm --pull=never "${pack[@]}" -v "$S":/work -w /work "$image" bash -c "for s in build assets finalize; do xless \$s --platform $P || exit 1; done" >/dev/null
  LAPP="$S/.xless/build/$P/final/HelloShip.app"

  "$X" inspect "$XAPP" --platform "$P" > "$W/xcode-$P.json"
  "$X" inspect "$LAPP" --platform "$P" > "$W/xless-$P.json"
  python3 - "$W/xcode-$P.json" "$W/xless-$P.json" "$ALLOW" "$P" "$XAPP" "$LAPP" <<'PY' || status=1
import json, os, sys
a, b, allow_path, plat = json.load(open(sys.argv[1])), json.load(open(sys.argv[2])), sys.argv[3], sys.argv[4]
allow = {l.split('#')[0].strip() for l in open(allow_path) if l.split('#')[0].strip()}
bad = []
for k in sorted(set(a["infoPlist"]) | set(b["infoPlist"])):
    if f"{plat}:{k}" in allow or f"*:{k}" in allow: continue
    if a["infoPlist"].get(k) != b["infoPlist"].get(k): bad.append(f"Info.plist {k}: xcode={a['infoPlist'].get(k)!r} xless={b['infoPlist'].get(k)!r}")
main = lambda r: next((x for x in r["binaries"] if x["path"].endswith("HelloShip")), None)
if (main(a) or {}).get("buildVersions") != (main(b) or {}).get("buildVersions"):
    bad.append(f"main binary LC_BUILD_VERSION: xcode={main(a)} xless={main(b)}")
files = lambda app: {os.path.relpath(os.path.join(d, f), app) for d, _, fs in os.walk(app) for f in fs}
xf, lf = files(sys.argv[5]), files(sys.argv[6])
for f in sorted(xf ^ lf):
    if f"{plat}:file:{f}" in allow or f"*:file:{f}" in allow: continue
    bad.append(f"bundle file {f}: only in {'xcode' if f in xf else 'xless'}")
print(f"[{plat}] " + ("OK" if not bad else "DIFF\n  " + "\n  ".join(bad)))
sys.exit(1 if bad else 0)
PY

  if [[ $P == ios ]]; then
    # assetutil --info reads cars that App Store processing rejects (ITMS-90562); validate and thin like it does.
    xcrun assetutil --validate-file "$LAPP/Assets.car" >"$W/car-validate.txt" 2>&1 \
      || { echo "[ios] xless Assets.car fails assetutil --validate-file:"; cat "$W/car-validate.txt"; status=1; }
    xcrun assetutil -i phone -s 3 -p srgb -M 4 -g MTL5,1 -r 2026 -o "$W/car-thin.car" "$LAPP/Assets.car" >"$W/car-thin.txt" 2>&1
    [[ -f "$W/car-thin.car" ]] || { echo "[ios] xless Assets.car cannot be thinned:"; cat "$W/car-thin.txt"; status=1; }
    # Renditions: the Xcode app's report (with its asset catalogs) against the xless app's cars; the ios:car: entries
    # of the allow-list are `car:` compare keys.
    "$X" tauri report "$XAPP" --json "$W/xcode-report-ios.json"
    sed -n 's/^ios:\(car:[^#]*\).*/\1/p' "$ALLOW" | sed 's/[[:space:]]*$//' > "$W/car-allow.txt"
    if "$X" tauri compare --assets-only "$W/xcode-report-ios.json" "$LAPP" --allow-file "$W/car-allow.txt"; then
      echo "[ios] Assets.car renditions OK (known: $(grep -c . "$W/car-allow.txt") allow-listed)"
    else
      echo "[ios] Assets.car renditions DIFF"; status=1
    fi
  fi
done
exit $status
