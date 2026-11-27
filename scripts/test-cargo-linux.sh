#!/usr/bin/env bash
# Builds samples/HelloCargo on Linux (in the tauri kit's image) for iOS and for universal macOS through prepare, build,
# assets and finalize, then checks the finalized apps. There is no Mac reference for a plain Cargo app; the checks are
# the bundle's contract:
#   iOS:   the executable is a thin arm64 Mach-O with LC_BUILD_VERSION platform 2 (iOS) and minos 17.0; Info.plist has
#          CFBundleIdentifier com.example.hellocargo, CFBundleVersion 1.0.0.2026010101 and no @PLACEHOLDER@ left;
#          Assets.car exists (the compiled catalog).
#   macOS: the executable is a fat Mach-O of [x86_64, arm64] (in that order), both slices platform 1 (macOS); Info.plist has
#          CFBundleIdentifier com.example.hellocargo.mac, CFBundleVersion 1.0.0.202601010000, CFBundleIconFile AppIcon,
#          the GIT_SHA and SHORT_VERSION of macos/Info.plist.in filled in, and no @PLACEHOLDER@ left;
#          Contents/Resources/AppIcon.icns exists (ICNS.make from the asset catalog: `assets:` names the file AppIcon.icns;
#          an `icon:` would name it <product>.icns).
# No signing, no App Store Connect: the build numbers are explicit, so no dated-build lookup happens.
#   make test-cargo-linux
#   scripts/test-cargo-linux.sh --platform macos
# --platform ios|macos|all (default all).
# Variables: ARCH (arm64 or amd64; default the host's: ARCH=amd64 on an arm64 Mac runs the amd64 chain under emulation),
#   XCODE (default versions.env's XCODE_VERSION): the Xcode whose pack the container gets, read-only, as xless run gives it
#   (its volume xless-xcode-<XCODE>-<build>-<arch>, or its directory in XLESS_XCODES), e.g. XCODE=26.2;
#   XLESS_IMAGE (default xless:<this checkout's tag>-<arch>-tauri, which xless setup --docker --with tauri builds),
#   DOCKER_CONTEXT (default colima-xless if it exists).
# The repository is mounted read-only and must be a normal git checkout, not a git worktree (a worktree's .git file points
# outside the mount, so the container cannot read the tracked files or GIT_SHA); the sample's files are the tracked ones,
# and GIT_SHA is its HEAD; the work copy lives in the xless-work volume, Rust toolchains in xless-rustup and xless-cargo (the first run
# downloads them and builds the dependencies, which takes a few minutes; later runs are faster).
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
ctx="${DOCKER_CONTEXT:-}"
if [[ -z "$ctx" ]] && docker context ls --format '{{.Name}}' 2>/dev/null | grep -qx 'colima-xless'; then ctx=colima-xless; fi
case "$(uname -m)" in arm64|aarch64) arch=arm64 ;; *) arch=amd64 ;; esac
vsuf=""; plat=()   # ARCH=amd64|arm64 runs the image of that architecture (under emulation when it is not the host's)
if [[ -n "${ARCH:-}" ]]; then
  [[ "$ARCH" == arm64 || "$ARCH" == amd64 ]] || { echo "test-cargo-linux: ARCH must be arm64 or amd64" >&2; exit 2; }
  [[ "$ARCH" == "$arch" ]] || vsuf="-$ARCH"   # another architecture's work copy and Rust toolchains stay apart from the host's
  arch="$ARCH"; plat=(--platform "linux/$ARCH")
fi
xcode="${XCODE:-$(sed -n 's/^XCODE_VERSION=//p' "$root/versions.env")}"   # the Xcode whose pack builds (XCODE=26.2: that pin's)
image="${XLESS_IMAGE:-xless:$("$root/scripts/docker-images.sh" tag --arch "$arch")-$arch-tauri}"   # xless setup --docker --with tauri builds it
platform=all
while [[ $# -gt 0 ]]; do
  case "$1" in
    --platform) [[ $# -ge 2 ]] || { echo "--platform needs ios, macos or all" >&2; exit 2; }; platform="$2"; shift 2 ;;
    --platform=*) platform="${1#--platform=}"; shift ;;
    *) echo "usage: $0 [--platform ios|macos|all]" >&2; exit 2 ;;
  esac
done
[[ "$platform" == ios || "$platform" == macos || "$platform" == all ]] || { echo "--platform must be ios, macos or all" >&2; exit 2; }
args=(docker)
[[ -z "$ctx" ]] || args+=(--context "$ctx")
# The Xcode's pack, read-only, as xless run gives it to every container (xless setup --docker prepares it): the newest build of
# $xcode for $arch in its volume, or in the directory XLESS_XCODES names (that pack's directory alone).
pack_args() {
  local name dir
  if [[ -n "${XLESS_XCODES:-}" ]]; then
    dir="$(ls -d "$XLESS_XCODES/$xcode"-*-"$arch" 2>/dev/null | sort | tail -1)"
    [[ -n "$dir" && -f "$dir/pack.json" ]] || { echo "$1: no pack of Xcode $xcode for $arch in $XLESS_XCODES; prepare it: xless setup --docker --xcode <Xcode $xcode .xip>" >&2; exit 2; }
    name="$(basename "$dir")"; pack=(--mount "type=bind,src=$dir,dst=/xcodes/$name,readonly" -e "XLESS_XCODE=/xcodes/$name")
  else
    name="$("${args[@]}" volume ls --filter label=org.xless.pack --format '{{.Name}}' | grep -E "^xless-xcode-${xcode//./\\.}-[^-]+-$arch\$" | sort | tail -1 || true)"
    [[ -n "$name" ]] || { echo "$1: no pack volume of Xcode $xcode for $arch; prepare it: xless setup --docker --xcode <Xcode $xcode .xip>" >&2; exit 2; }
    pack=(--mount "type=volume,src=$name,dst=/xcodes,readonly" -e "XLESS_XCODE=/xcodes/${name#xless-xcode-}")
  fi
}
pack_args test-cargo-linux

"${args[@]}" run --rm -i --pull=never ${plat[@]+"${plat[@]}"} "${pack[@]}" -v "$root":/repo:ro -v "xless-work$vsuf":/cache/work -v "xless-rustup$vsuf":/cache/rustup -v "xless-cargo$vsuf":/cache/cargo \
  -e PLATFORM="$platform" "$image" bash -s <<'IN'
set -euo pipefail
o=/repo/samples/HelloCargo/xless.overlay.example.yml
s=/repo/samples/HelloCargo

# check <ios|macos> <dir finalize printed>: the assertions on the finalized app, in python (no Mach-O tool needed).
check() {
  python3 - "$1" "$2" <<'PY'
import pathlib, plistlib, re, struct, sys

platform, out = sys.argv[1], pathlib.Path(sys.argv[2])
apps = [out] if out.suffix == ".app" else sorted(out.glob("*.app"))
if len(apps) != 1 or apps[0].name != "HelloCargo.app":
    sys.exit(f"{platform}: expected HelloCargo.app in {out}, found {[a.name for a in apps]}")
app = apps[0]
base = app / "Contents" if platform == "macos" else app
exe = base / ("MacOS" if platform == "macos" else ".") / "HelloCargo"
failed = []

def fail(message):
    failed.append(message)
    print(f"FAIL {platform}: {message}")

def ok(message):
    print(f"ok   {platform}: {message}")

CPU = {0x01000007: "x86_64", 0x0100000C: "arm64"}
PLATFORM = {1: "macos", 2: "ios"}

def thin(data):
    """(cpu, [(platform, minos)]) of one 64-bit little-endian Mach-O image."""
    magic, cputype, _, _, ncmds, _, _, _ = struct.unpack_from("<IiIIIIII", data, 0)
    if magic != 0xFEEDFACF:
        raise ValueError(f"not a 64-bit Mach-O (magic {magic:#x})")
    offset, builds = 32, []
    for _ in range(ncmds):
        cmd, size = struct.unpack_from("<II", data, offset)
        if cmd == 0x32:  # LC_BUILD_VERSION
            plat, minos, _sdk, _ntools = struct.unpack_from("<IIII", data, offset + 8)
            builds.append((PLATFORM.get(plat, f"platform {plat}"), f"{minos >> 16}.{(minos >> 8) & 0xFF}"))
        offset += size
    return CPU.get(cputype & 0xFFFFFFFF, f"cputype {cputype:#x}"), builds

def slices(data):
    if struct.unpack_from(">I", data, 0)[0] == 0xCAFEBABE:  # fat: big-endian header, slices in file order
        count = struct.unpack_from(">I", data, 4)[0]
        for i in range(count):
            _, _, offset, size, _ = struct.unpack_from(">iiIII", data, 8 + 20 * i)
            yield thin(data[offset:offset + size])
    else:
        yield thin(data)

try:
    found = list(slices(exe.read_bytes()))
except (OSError, ValueError, struct.error) as e:
    sys.exit(f"{platform}: cannot read the executable {exe}: {e}")
want_cpus = ["x86_64", "arm64"] if platform == "macos" else ["arm64"]
cpus = [cpu for cpu, _ in found]
(ok if cpus == want_cpus else fail)(f"architectures {cpus} (want {want_cpus})")
for cpu, builds in found:
    if len(builds) != 1:
        fail(f"{cpu} slice has {len(builds)} LC_BUILD_VERSION commands")
        continue
    plat, minos = builds[0]
    (ok if plat == platform else fail)(f"{cpu} LC_BUILD_VERSION platform {plat}, minos {minos}")
    if platform == "ios" and minos != "17.0":
        fail(f"{cpu} minos is {minos}, want 17.0")

info_path = base / "Info.plist"
raw = info_path.read_bytes()
info = plistlib.loads(raw)
left = sorted(set(re.findall(rb"@[A-Z][A-Z0-9_]*@", raw)))
(fail if left else ok)(f"placeholders left in Info.plist: {[m.decode() for m in left]}" if left else "no @PLACEHOLDER@ left in Info.plist")
want_id = "com.example.hellocargo.mac" if platform == "macos" else "com.example.hellocargo"
want_build = "1.0.0.202601010000" if platform == "macos" else "1.0.0.2026010101"
(ok if info.get("CFBundleIdentifier") == want_id else fail)(f"CFBundleIdentifier {info.get('CFBundleIdentifier')!r} (want {want_id!r})")
(ok if info.get("CFBundleVersion") == want_build else fail)(f"CFBundleVersion {info.get('CFBundleVersion')!r} (want {want_build!r})")
(ok if info.get("CFBundleExecutable") == "HelloCargo" else fail)(f"CFBundleExecutable {info.get('CFBundleExecutable')!r}")

if platform == "ios":
    (ok if (app / "Assets.car").is_file() else fail)("Assets.car exists")
else:
    # macos/Info.plist.in: "HelloCargo @SHORT_VERSION@ (@GIT_SHA@)"
    got = info.get("CFBundleGetInfoString", "")
    (ok if re.fullmatch(r"HelloCargo 1\.0\.0 \([0-9a-f]{40}\)", got) else fail)(f"CFBundleGetInfoString {got!r}")
    icns = base / "Resources" / "AppIcon.icns"
    (ok if icns.is_file() and icns.read_bytes()[:4] == b"icns" else fail)("Contents/Resources/AppIcon.icns exists and is an icns")
    (ok if info.get("CFBundleIconFile") == "AppIcon" else fail)(f"CFBundleIconFile {info.get('CFBundleIconFile')!r}")

if failed:
    sys.exit(f"{platform}: {len(failed)} check(s) failed")
PY
}

# prepare, build, assets, finalize; ship prints each stage's output directory, finalize's last
if [[ "$PLATFORM" == ios || "$PLATFORM" == all ]]; then
  echo "==> HelloCargo iOS: ship to finalize"
  final=$(XLESS_BUILD_NUMBER=1.0.0.2026010101 xless ship --config "$o" --source "$s" --platform ios --to finalize </dev/null | tail -1)
  check ios "$final"
fi
if [[ "$PLATFORM" == macos || "$PLATFORM" == all ]]; then
  echo "==> HelloCargo macOS: ship to finalize"
  final=$(XLESS_BUILD_NUMBER=1.0.0.202601010000 xless ship --config "$o" --source "$s" --platform macos --to finalize </dev/null | tail -1)
  check macos "$final"
fi
echo "==> HelloCargo: the finalized apps pass the checks"
IN
