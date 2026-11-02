#!/usr/bin/env bash
# scripts/native-toolchain.sh against this machine's clang (the CI container's: Swift 6.4's clang 21), behind a fake
# toolchain root and a fake SDK bundle: the driver is wrapped with the flags Xcode 27.0's fixture needs, the record and
# both toolsets get them, a re-run (after the SDK is installed again) gives the same result, and the separate mode
# points the SDK's clang resource directory at the toolchain's own, with the Xcode's runtimes and the ld64.lld trampoline.
# Nothing outside a temp directory is changed.
set -euo pipefail
repo="$(cd "$(dirname "$0")/../.." && pwd)"
if [[ "$(uname)" != Linux ]] || ! real=$(command -v clang); then echo "SKIP: needs Linux with an open-source clang"; exit 0; fi
real="$(readlink -f "$real")"
t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT
fail() { echo "FAIL: $*"; exit 1; }

# The fake toolchain: swiftc names 6.4.0, clang-21 runs this machine's clang (its resource directory is a temp one).
root="$t/toolchains/swift-6.4.0"; bin="$root/usr/bin"; rd="$t/own-rd"
mkdir -p "$bin" "$rd/lib" "$rd/include"
touch "$rd/include/arm_neon.h"
printf '#!/bin/sh\necho "Swift version 6.4.0 (swift-6.4.0-RELEASE)"\necho "Target: aarch64-unknown-linux-gnu"\n' > "$bin/swiftc"
printf '#!/bin/sh\n[ "$1" = -print-resource-dir ] && { echo "%s"; exit 0; }\nexec "%s" "$@"\n' "$rd" "$real" > "$bin/clang-21"
printf '#!/bin/sh\nexit 0\n' > "$bin/lld"
chmod +x "$bin/swiftc" "$bin/clang-21" "$bin/lld"
ln -s clang-21 "$bin/clang"; ln -s clang "$bin/clang++"; ln -s lld "$bin/ld64.lld"

sdk() {   # a freshly installed fake SDK bundle (as xtool sdk install leaves it)
  rm -rf "$t/bundle" "$t/xcode-rd"
  local b="$t/bundle" x="$t/bundle/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib"
  mkdir -p "$b/toolset/bin" "$x/swift" "$x/swift_static" "$t/xcode-rd/lib/darwin"
  touch "$t/xcode-rd/lib/darwin/libclang_rt.ios.a"
  ln -s "$t/xcode-rd" "$x/swift/clang"; ln -s "$t/xcode-rd" "$x/swift_static/clang"
  printf '#!/bin/sh\nexit 0\n' > "$b/toolset/bin/ld64.lld"; chmod +x "$b/toolset/bin/ld64.lld"
  echo '{"schemaVersion":"1.0","linker":{"extraCLIOptions":["-use-ld=lld"]}}' > "$b/toolset.json"
  echo '{"schemaVersion":"1.0","swiftCompiler":{"extraCLIOptions":["-Xfrontend","-x"]}}' > "$b/toolset-swb.json"
}
echo '{"xcodeVersion":"2700","xcodeBuild":"27A266a"}' > "$t/meta.json"
run() { sh "$repo/scripts/native-toolchain.sh" "$root" "$1" "$t/bundle" "$t/meta.json" "$repo/docker/toolchain" "$t/record.json" >"$t/out" 2>&1 \
  || fail "native-toolchain.sh $1: $(cat "$t/out")"; }

check() {
  [[ -L "$bin/clang" ]] && fail "clang is not wrapped"
  grep -q '^real=' "$bin/clang" || fail "clang is not the driver"
  grep -qx 'clang clang-21' "$bin/.xless-original-links" || fail "original links: $(cat "$bin/.xless-original-links")"
  python3 - "$t/record.json" "$t/bundle" "$root" <<'P' || fail "record or toolsets: $(cat "$t/out")"
import json, sys
rec = json.load(open(sys.argv[1]))
assert rec["version"] == "6.4.0" and rec["root"] == sys.argv[3], rec
flags = rec["clangFlags"]
assert flags and any(f.startswith("-DTARGET_OS_") for f in flags), flags
for name in ("toolset.json", "toolset-swb.json"):
    opts = json.load(open(f"{sys.argv[2]}/{name}"))["swiftCompiler"]["extraCLIOptions"]
    assert opts[:2 * len(flags)] == [w for f in flags for w in ("-Xcc", f)], (name, opts)
    assert opts.count("-Xcc") == len(flags), (name, opts)
P
}

sdk; run own; check
grep -q 'TARGET_OS_' "$bin/clang" || fail "the driver carries no flags"
first=$(cat "$t/record.json")
# The SDK installed again (setup re-run): the same result, the links put back first.
sdk; run own; check
[[ "$(cat "$t/record.json")" == "$first" ]] || fail "re-run record differs: $(cat "$t/record.json")"
[[ -L "$bin/ld64.lld" ]] || fail "own mode replaced ld64.lld"
[[ "$(readlink "$t/bundle/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/clang")" == "$t/xcode-rd" ]] || fail "own mode moved the resource directory"

# separate: the toolchain's own resource directory, the Xcode's runtimes linked into it, ld64.lld runs the SDK's.
sdk; run separate; check
x="$t/bundle/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib"
for s in swift swift_static; do [[ "$(readlink "$x/$s/clang")" == "$rd" ]] || fail "$s/clang → $(readlink "$x/$s/clang")"; done
[[ -f "$rd/lib/darwin/libclang_rt.ios.a" ]] || fail "the Xcode's runtimes are not in the toolchain's resource directory"
grep -qF "$t/bundle/toolset/bin/ld64.lld" "$bin/ld64.lld" || fail "ld64.lld is not the trampoline"
grep -qx 'ld64.lld lld' "$bin/.xless-original-links" || fail "ld64.lld's link not kept"

# Refusals: an unknown mode, and an Xcode without a fixture; the record is left as it was.
before=$(cat "$t/record.json")
sh "$repo/scripts/native-toolchain.sh" "$root" both "$t/bundle" "$t/meta.json" "$repo/docker/toolchain" "$t/record.json" 2>/dev/null && fail "mode both accepted"
echo '{"xcodeBuild":"99Z999"}' > "$t/meta2.json"
sdk
sh "$repo/scripts/native-toolchain.sh" "$root" own "$t/bundle" "$t/meta2.json" "$repo/docker/toolchain" "$t/record.json" 2>"$t/err" && fail "unknown Xcode accepted"
grep -q '99Z999' "$t/err" || fail "unknown Xcode refusal: $(cat "$t/err")"
[[ "$(cat "$t/record.json")" == "$before" ]] || fail "a refused run changed the record"
echo PASS
