#!/usr/bin/env bash
# scripts/fit-toolchain.sh <pack> own|separate <docker/toolchain> against this machine's clang (the CI container's:
# Swift 6.4's clang 21), on a fake pack: a fake toolchain, a fake SDK bundle, toolchain-meta.json. The driver is wrapped
# with the flags Xcode 27.0's fixture needs, the record and both toolsets get them, the pack holds no absolute path (no
# absolute link, no file naming where it was prepared), the record's root is relative, and the pack, moved, still works:
# the driver reaches its clang, ld64.lld the bundle's, the include directory is there, and a second fit succeeds.
# The wrappers run with no command of the system (env -i PATH=/nonexistent): Swift Build runs the linker and the compiler
# with a PATH of the toolchain's and the platform's directories only (no /usr/bin), before and after the move.
set -euo pipefail
repo="$(cd "$(dirname "$0")/../.." && pwd)"

# docker/toolchain/record-flags.py alone (python3 only, any OS): a flag a toolset already passes, wherever it is among its
# options, is not passed twice; the record file is named (there is no default place).
r=$(mktemp -d)
mkdir -p "$r/bundle"
echo '{"swiftCompiler":{"extraCLIOptions":["-Xfrontend","-x","-Xcc","-DB=0","-Xcc","-DA=1"]}}' > "$r/bundle/toolset.json"
echo '{"schemaVersion":"1.0"}' > "$r/bundle/toolset-swb.json"
python3 "$repo/docker/toolchain/record-flags.py" --record "$r/record.json" --root toolchain 6.4.0 "$r/bundle" -DA=1 -DB=0 >/dev/null \
  || { echo "FAIL: record-flags.py"; exit 1; }
python3 - "$r" <<'P' || { echo "FAIL: record-flags.py's toolsets or record: $(cat "$r"/bundle/toolset*.json "$r/record.json")"; exit 1; }
import json, sys
r = sys.argv[1]
assert json.load(open(f"{r}/record.json")) == {"version": "6.4.0", "root": "toolchain", "clangFlags": ["-DA=1", "-DB=0"]}
assert json.load(open(f"{r}/bundle/toolset.json"))["swiftCompiler"]["extraCLIOptions"] == ["-Xcc", "-DA=1", "-Xcc", "-DB=0", "-Xfrontend", "-x"]
assert json.load(open(f"{r}/bundle/toolset-swb.json"))["swiftCompiler"]["extraCLIOptions"] == ["-Xcc", "-DA=1", "-Xcc", "-DB=0"]
P
(cd "$r" && env -u XLESS_SWIFT_TOOLCHAIN_RECORD python3 "$repo/docker/toolchain/record-flags.py" --root toolchain 6.4.0 "$r/bundle" -DA=1 >/dev/null 2>&1) \
  && { echo "FAIL: record-flags.py wrote a record nobody named"; exit 1; }
rm -rf "$r"

if [[ "$(uname)" != Linux ]] || ! real=$(command -v clang); then echo "SKIP: needs Linux with an open-source clang"; exit 0; fi
real="$(readlink -f "$real")"
t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT
fail() { echo "FAIL: $*"; exit 1; }
pack="$t/prepared/pack"
toolchain() {   # the fake toolchain: swiftc names 6.4.0, clang-21 runs this machine's clang with a resource directory of the toolchain's own
  local bin="$pack/toolchain/usr/bin" rd="$pack/toolchain/usr/lib/clang/21"
  mkdir -p "$bin" "$rd/lib" "$rd/include" "$pack/toolchain/usr/include/swift"
  touch "$rd/include/arm_neon.h" "$pack/toolchain/usr/include/swift/bridging" "$pack/toolchain/usr/include/swift/bridging.modulemap"
  printf '#!/bin/sh\necho "Swift version 6.4.0 (swift-6.4.0-RELEASE)"\necho "Target: aarch64-unknown-linux-gnu"\n' > "$bin/swiftc"
  printf '#!/bin/sh\nhere="$(cd "${0%%/*}" && pwd -P)"\n[ "$1" = -print-resource-dir ] && { echo "$here/../lib/clang/21"; exit 0; }\nexec "%s" "$@"\n' "$real" > "$bin/clang-21"
  printf '#!/bin/sh\nexit 0\n' > "$bin/lld"
  chmod +x "$bin/swiftc" "$bin/clang-21" "$bin/lld"
  ln -s clang-21 "$bin/clang"; ln -s clang "$bin/clang++"; ln -s lld "$bin/ld64.lld"
}
sdk() {   # a freshly installed fake SDK bundle: no absolute path in it, links relative
  local b="$pack/config/swiftpm/swift-sdks/darwin.artifactbundle" x="$pack/config/swiftpm/swift-sdks/darwin.artifactbundle/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib"
  rm -rf "$b" "$pack/xcode-rd"
  mkdir -p "$b/toolset/bin" "$x/swift" "$x/swift_static" "$b/xcode-rd/lib/darwin" "$b/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS27.0.sdk/usr/include/sys"
  touch "$b/xcode-rd/lib/darwin/libclang_rt.ios.a"
  touch "$b/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS27.0.sdk/usr/include/Endian.h"
  ln -s ../../../../../../xcode-rd "$x/swift/clang"; ln -s ../../../../../../xcode-rd "$x/swift_static/clang"
  printf '#!/bin/sh\necho bundle-lld "$@"\n' > "$b/toolset/bin/ld64.lld"; chmod +x "$b/toolset/bin/ld64.lld"
  echo '{"schemaVersion":"1.0","linker":{"extraCLIOptions":["-use-ld=lld"]}}' > "$b/toolset.json"
  echo '{"schemaVersion":"1.0","swiftCompiler":{"extraCLIOptions":["-Xfrontend","-x"]}}' > "$b/toolset-swb.json"
  echo '{"xcodeVersion":"2700","xcodeBuild":"27A266a"}' > "$pack/toolchain-meta.json"
}
# bare <wrapper> <command…>: the wrapper run with an empty environment and a PATH where nothing is.
bare() { env -i PATH=/nonexistent "$@"; }
# reaches <toolchain bin> <where>: its ld64.lld reaches the bundle's with no command of the system, by its absolute path,
# by a bare name from its own directory (`sh ld64.lld`: $0 without a slash), and by a bare name found on PATH from another
# directory (`bash ld64.lld`: bash looks the script up on PATH, and $0 stays bare; PATH is the toolchain's directory alone, as
# Swift Build's holds the toolchain's directories).
reaches() {
  local out
  out=$(bare "$1/ld64.lld" a b 2>&1) || true
  [[ "$out" == "bundle-lld a b" ]] || fail "$2: ld64.lld with no command of the system: $out"
  out=$(cd "$1" && bare /bin/sh ld64.lld a b 2>&1) || true
  [[ "$out" == "bundle-lld a b" ]] || fail "$2: ld64.lld run as sh ld64.lld: $out"
  [[ ! -e "$t/ld64.lld" ]] || fail "$t holds an ld64.lld"
  out=$(cd "$t" && env -i PATH="$1" /bin/bash ld64.lld a b 2>&1) || true
  [[ "$out" == "bundle-lld a b" ]] || fail "$2: ld64.lld found on PATH by its bare name: $out"
}
fit() { sh "$repo/scripts/fit-toolchain.sh" "$pack" "$1" "$repo/docker/toolchain" >"$t/out" 2>&1 || fail "fit-toolchain.sh $1: $(cat "$t/out")"; }

b="$pack/config/swiftpm/swift-sdks/darwin.artifactbundle"
check() {   # $1: the pack's current place
  local p="$1" bin="$1/toolchain/usr/bin"
  [[ -L "$bin/clang" ]] && fail "clang is not wrapped"
  grep -q '^real=' "$bin/clang" || fail "clang is not the driver"
  grep -qx 'clang clang-21' "$bin/.xless-original-links" || fail "original links: $(cat "$bin/.xless-original-links")"
  python3 - "$p/swift-toolchain.json" "$p/config/swiftpm/swift-sdks/darwin.artifactbundle" <<'P' || fail "record or toolsets: $(cat "$t/out")"
import json, sys
rec = json.load(open(sys.argv[1]))
assert rec["version"] == "6.4.0" and rec["root"] == "toolchain", rec
flags = rec["clangFlags"]
assert flags and any(f.startswith("-DTARGET_OS_") for f in flags), flags
for name in ("toolset.json", "toolset-swb.json"):
    opts = json.load(open(f"{sys.argv[2]}/{name}"))["swiftCompiler"]["extraCLIOptions"]
    assert opts[:2 * len(flags)] == [w for f in flags for w in ("-Xcc", f)], (name, opts)
    assert opts.count("-Xcc") == len(flags), (name, opts)
P
  [[ -z "$(find "$p" -type l -lname '/*')" ]] || fail "absolute links: $(find "$p" -type l -lname '/*')"
  [[ -z "$(grep -rIl "$pack" "$p/toolchain/usr/bin" "$p/swift-toolchain.json" "$p"/config/swiftpm/swift-sdks/darwin.artifactbundle/toolset*.json || true)" ]] \
    || fail "files name the place the pack was prepared in"
  [[ -z "$(grep -rIlF "$pack" "$p" || true)" ]] || fail "somewhere in the pack: $(grep -rIlF "$pack" "$p")"
  [[ -e "$p/include/swift/bridging" && -e "$p/include/swift/bridging.modulemap" ]] || fail "no include/swift"
  [[ "$(cat "$p/include/module.modulemap")" == 'extern module SwiftBridging "swift/bridging.modulemap"' ]] || fail "module.modulemap"
  [[ -L "$p"/config/swiftpm/swift-sdks/darwin.artifactbundle/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS27.0.sdk/usr/include/endian.h ]] || fail "no lowercase header link"
}

toolchain; sdk; fit own; check "$pack"
grep -q 'TARGET_OS_' "$pack/toolchain/usr/bin/clang" || fail "the driver carries no flags"
[[ -L "$pack/toolchain/usr/bin/ld64.lld" ]] || fail "own mode replaced ld64.lld"
[[ "$(readlink "$b/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/clang")" == ../../../../../../xcode-rd ]] || fail "own mode moved the resource directory"
first=$(cat "$pack/swift-toolchain.json")
# The SDK installed again: the same result, the links put back first.
sdk; fit own; check "$pack"
[[ "$(cat "$pack/swift-toolchain.json")" == "$first" ]] || fail "re-run record differs"

# separate: the toolchain's own resource directory, the Xcode's runtimes linked into it, ld64.lld runs the SDK's.
sdk; fit separate; check "$pack"
x="$b/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib"
for s in swift swift_static; do [[ "$(readlink "$x/$s/clang")" == ../../../../../../../../../../toolchain/usr/lib/clang/21 ]] || fail "$s/clang → $(readlink "$x/$s/clang")"; done
[[ -f "$pack/toolchain/usr/lib/clang/21/lib/darwin/libclang_rt.ios.a" ]] || fail "the Xcode's runtimes are not in the toolchain's resource directory"
[[ -f "$x/swift/clang/lib/darwin/libclang_rt.ios.a" && -f "$x/swift/clang/include/arm_neon.h" ]] || fail "the SDK's resource directory is not usable"
grep -qx 'ld64.lld lld' "$pack/toolchain/usr/bin/.xless-original-links" || fail "ld64.lld's link not kept"
[[ "$("$pack/toolchain/usr/bin/ld64.lld" a b)" == "bundle-lld a b" ]] || fail "ld64.lld does not reach the bundle's"
reaches "$pack/toolchain/usr/bin" prepared

# Moved: nothing points at where it was prepared.
other="$t/mounted/elsewhere/pack"
mkdir -p "$(dirname "$other")"; mv "$pack" "$other"
[[ ! -e "$t/prepared/pack" ]] || fail "not moved"
cd "$t"; echo 'int x;' > x.c
out=$("$other/toolchain/usr/bin/clang" -### -target arm64-apple-ios17.0 -c x.c 2>&1) || fail "the moved driver: $out"
grep -q 'TARGET_OS_' <<<"$out" || fail "the moved driver does not add the flags: $out"
[[ "$("$other/toolchain/usr/bin/ld64.lld" a b)" == "bundle-lld a b" ]] || fail "the moved ld64.lld does not reach the bundle's"
reaches "$other/toolchain/usr/bin" moved
# The driver needs no command of the system either (readlink only through a link, from /usr/bin, which it puts on PATH).
out=$(bare "$other/toolchain/usr/bin/clang" -### -target arm64-apple-ios17.0 -c x.c 2>&1) || fail "the moved driver with no command of the system: $out"
grep -q 'TARGET_OS_' <<<"$out" || fail "the moved driver with no command of the system does not add the flags: $out"
mkdir -p "$t/links"; ln -s "$other/toolchain/usr/bin/clang++" "$t/links/clang++"
out=$(bare "$t/links/clang++" -### -target arm64-apple-ios17.0 -c -x c++ -fmodules -fno-cxx-modules x.c 2>&1) || fail "the driver through a link: $out"
grep -qF '"-fno-cxx-modules"' <<<"$out" || fail "the driver through a link does not pass -fno-cxx-modules: $out"
[[ -e "$other/include/swift/bridging" ]] || fail "the moved include directory"
[[ -f "$other/config/swiftpm/swift-sdks/darwin.artifactbundle/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/clang/lib/darwin/libclang_rt.ios.a" ]] || fail "the moved SDK's resource directory"
[[ -z "$(find "$other" -type l ! -exec test -e {} \; -print)" ]] || fail "dead links after the move: $(find "$other" -type l ! -exec test -e {} \; -print)"
# And fitted again, in its new place: same record, no flag added twice.
pack="$other"; b="$pack/config/swiftpm/swift-sdks/darwin.artifactbundle"
fit separate; check "$other"
[[ "$(cat "$other/swift-toolchain.json")" == "$first" ]] || fail "re-fit record differs"

# Refusals: an unknown mode, and an Xcode without a fixture; the record is left as it was.
before=$(cat "$pack/swift-toolchain.json")
# separate, with an SDK whose resource directory lacks the iOS runtime: refused, and named; nothing recorded.
pack="$t/no-runtime/pack"; b="$pack/config/swiftpm/swift-sdks/darwin.artifactbundle"
toolchain; sdk; rm "$b/xcode-rd/lib/darwin/libclang_rt.ios.a"
sh "$repo/scripts/fit-toolchain.sh" "$pack" separate "$repo/docker/toolchain" >"$t/out" 2>&1 && fail "a resource directory without libclang_rt.ios.a was fitted: $(cat "$t/out")"
grep -q 'libclang_rt.ios.a' "$t/out" || fail "missing runtime refusal: $(cat "$t/out")"
[[ ! -e "$pack/swift-toolchain.json" ]] || fail "a refused fit recorded the toolchain"
# a toolchain without Swift's bridging module (either file of it): refused, and named; nothing recorded.
for gone in bridging bridging.modulemap; do
  pack="$t/no-$gone/pack"
  toolchain; sdk; rm "$pack/toolchain/usr/include/swift/$gone"
  sh "$repo/scripts/fit-toolchain.sh" "$pack" separate "$repo/docker/toolchain" >"$t/out" 2>&1 && fail "a toolchain without $gone was fitted: $(cat "$t/out")"
  grep -q 'no swift/bridging in' "$t/out" || fail "missing $gone refusal: $(cat "$t/out")"
  [[ ! -e "$pack/swift-toolchain.json" ]] || fail "a refused fit recorded the toolchain"
done
pack="$other"; b="$pack/config/swiftpm/swift-sdks/darwin.artifactbundle"
sh "$repo/scripts/fit-toolchain.sh" "$pack" both "$repo/docker/toolchain" 2>/dev/null && fail "mode both accepted"
echo '{"xcodeBuild":"99Z999"}' > "$pack/toolchain-meta.json"
sh "$repo/scripts/fit-toolchain.sh" "$pack" own "$repo/docker/toolchain" 2>"$t/err" && fail "unknown Xcode accepted"
grep -q '99Z999' "$t/err" || fail "unknown Xcode refusal: $(cat "$t/err")"
[[ "$(cat "$pack/swift-toolchain.json")" == "$before" ]] || fail "a refused run changed the record"
echo PASS
