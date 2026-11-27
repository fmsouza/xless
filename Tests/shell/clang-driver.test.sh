#!/usr/bin/env bash
# docker/toolchain/clang-driver (Ruling R10): the bridge flags reach Darwin compiles only; any other invocation runs the
# real driver with its own arguments. On a Mac host, docker/toolchain/target-os-check is also run against the Xcode's
# own clang and its recorded table.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT
fail() { echo "FAIL: $*"; exit 1; }
# A fake real driver printing its arguments, one per line; the driver installed as clang, clang++ and clang-cpp.
printf '#!/bin/sh\nfor a; do echo "$a"; done\n' > "$t/real"; chmod +x "$t/real"
flags='-fdefine-target-os-macros -DTARGET_OS_ARROW=(TARGET_OS_OSX?(__is_target_arch(arm64)?1:__is_target_arch(arm64e)):0) -DTARGET_OS_XR=TARGET_OS_VISION'
mkdir "$t/bin"
python3 -c 'import sys; t = open(sys.argv[1]).read(); open(sys.argv[2], "w").write(t.replace("@DRIVER@", sys.argv[3]).replace("@FLAGS@", sys.argv[4]))' \
  "$root/docker/toolchain/clang-driver" "$t/bin/clang" "$t/real" "$flags"
chmod +x "$t/bin/clang"; cp "$t/bin/clang" "$t/bin/clang++"; ln -s clang "$t/bin/clang-cpp"
added=$(tr ' ' '\n' <<<"$flags")
cd "$t"   # a file matching a flag as a glob pattern must not replace it
touch -- '-DTARGET_OS_ARROW=(TARGET_OS_OSXx(__is_target_arch(arm64)x1:__is_target_arch(arm64e)):0)'
run() { local tool="$1"; shift; env -i "$t/bin/$tool" "$@"; }
same() { local out; out=$(run clang "$@"); [[ "$out" == "$(printf '%s\n' "$@")" ]] || fail "changed: $* → $(tr '\n' ' ' <<<"$out")"; }
bridged() { local out; out=$(run clang "$@"); [[ "$out" == "$(printf '%s\n' "$@")"$'\n'"$added" ]] || fail "not bridged: $* → $(tr '\n' ' ' <<<"$out")"; }

# Linux and the host default: unchanged, whatever the compile looks like.
same -c a.c -o a.o
same -target aarch64-unknown-linux-gnu -c a.c
same --target=x86_64-unknown-linux-gnu -E -dM -x c /dev/null
same -target aarch64-unknown-linux-gnu -fmodules -fno-cxx-modules -c a.cpp
same -arch arm64 -c a.c        # no Apple triple: the driver targets Linux
same -target arm64-apple-ios17.0 -target aarch64-unknown-linux-gnu -c a.c   # the last target wins
# Darwin compiles: -c, -S, -E, -fsyntax-only, -M, -MM, a source file or stdin.
bridged -target arm64-apple-ios17.0 -c a.c -o a.o
bridged --target=arm64-apple-macos11.0 -S a.m
bridged -target arm64-apple-ios17.0-simulator -E -dM -x c /dev/null
bridged -target=x86_64-apple-macos11.0 -fsyntax-only a.mm
bridged -target arm64-apple-ios17.0 -MM a.c
bridged -target arm64-apple-ios17.0 -x c - -dynamiclib -o stub
bridged --target arm64-apple-macos11.0 a.cpp -o a
# A Darwin link: no compile, nothing added.
same -target arm64-apple-ios17.0 a.o -o app -fuse-ld=lld
# Response files: the target and the compile flag may be in them (quoted or not).
printf -- '-target "arm64-apple-ios17.0"\n-c a.c\n' > r1.resp; bridged @r1.resp
printf -- '--target=aarch64-unknown-linux-gnu -c a.c\n' > r2.resp; same @r2.resp
printf -- '-c a.c\n' > r3.resp; bridged -target arm64-apple-ios17.0 @r3.resp
# -fno-cxx-modules: passed on to the compiler for Darwin only.
out=$(run clang++ -target arm64-apple-ios17.0 -fmodules -fno-cxx-modules -c a.cpp)
[[ "$out" == "$(printf '%s\n' --driver-mode=g++ -target arm64-apple-ios17.0 -fmodules -fno-cxx-modules -c a.cpp)"$'\n'"$added"$'\n-Xclang\n-fno-cxx-modules' ]] || fail "clang++ Darwin: $out"
printf -- '-fno-cxx-modules -fmodules\n' > r4.resp
out=$(run clang++ -target arm64-apple-ios17.0 @r4.resp -c a.cpp); [[ "$out" == *$'\n-Xclang\n-fno-cxx-modules' ]] || fail "response file -fno-cxx-modules: $out"
out=$(run clang++ -target aarch64-unknown-linux-gnu @r4.resp -c a.cpp); [[ "$out" != *-Xclang* && "$out" != *-fdefine* ]] || fail "Linux -fno-cxx-modules: $out"
# Driver modes by name; -cc1 untouched.
[[ "$(run clang-cpp -target aarch64-unknown-linux-gnu a.c | head -1)" == --driver-mode=cpp ]] || fail "clang-cpp mode"
[[ "$(run clang -cc1 -triple arm64-apple-ios -E a.c)" == "$(printf '%s\n' -cc1 -triple arm64-apple-ios -E a.c)" ]] || fail "-cc1 changed"

# @DRIVER@ as a bare name: the driver beside this one, found from its own path (through links, from any directory),
# so a moved toolchain still runs.
mkdir -p "$t/rel/bin" "$t/elsewhere"
cp "$t/real" "$t/rel/bin/real-driver"
python3 -c 'import sys; t = open(sys.argv[1]).read(); open(sys.argv[2], "w").write(t.replace("@DRIVER@", "real-driver").replace("@FLAGS@", sys.argv[3]))' \
  "$root/docker/toolchain/clang-driver" "$t/rel/bin/clang" "$flags"
chmod +x "$t/rel/bin/clang"; ln -s clang "$t/rel/bin/clang++"
ln -s "$t/rel/bin/clang" "$t/elsewhere/cc"            # a link from another directory, with an absolute target
ln -s ../rel/bin/clang "$t/elsewhere/cc-rel"          # and with a relative one
ln -s ../rel/bin "$t/elsewhere/bindir"                # a link to the directory
bare() { local out; out=$(cd "$1" && env -i "$2" "${@:3}") || fail "bare driver $2 failed"
  [[ "$out" == "$(printf '%s\n' "${@:3}")"$'\n'"$added" ]] || fail "bare driver $2: $(tr '\n' ' ' <<<"$out")"; }
bare "$t" "$t/rel/bin/clang" -target arm64-apple-ios17.0 -c a.c
bare "$t/elsewhere" "$t/rel/bin/clang" -target arm64-apple-ios17.0 -c a.c
bare "$t/elsewhere" "$t/elsewhere/cc" -target arm64-apple-ios17.0 -c a.c
bare "$t/elsewhere" ./cc-rel -target arm64-apple-ios17.0 -c a.c
bare "$t/elsewhere" ./bindir/clang -target arm64-apple-ios17.0 -c a.c
bare "$t/rel/bin" ./clang -target arm64-apple-ios17.0 -c a.c
out=$(cd "$t/elsewhere" && env -i "$t/rel/bin/clang++" -target aarch64-unknown-linux-gnu -c a.cpp)
[[ "$out" == "$(printf '%s\n' --driver-mode=g++ -target aarch64-unknown-linux-gnu -c a.cpp)" ]] || fail "bare clang++: $out"
mv "$t/rel" "$t/moved"
[[ "$(env -i "$t/moved/bin/clang" -target aarch64-unknown-linux-gnu -c a.c | head -1)" == -target ]] || fail "moved driver"

# A Linux compile on an amd64 host (cargo build scripts, cc host builds) runs the real driver with exactly its own arguments.
test_x86_64_linux_unchanged() {
  local out; out=$(run clang -target x86_64-unknown-linux-gnu -c x.c)
  [[ "$out" == "$(printf '%s\n' -target x86_64-unknown-linux-gnu -c x.c)" ]] || fail "x86_64 Linux changed: $(tr '\n' ' ' <<<"$out")"
  [[ "$out" != *-fdefine-target-os-macros* && "$out" != *-D* ]] || fail "x86_64 Linux got a bridge flag"
}
# Every recorded table has the x86_64 Linux triple, with no macros.
test_fixture_has_x86_64_linux() {
  local f n=0
  for f in "$root"/docker/toolchain/target-os/*.txt; do
    [[ "$(basename "$f")" == derived.txt ]] && continue
    grep -qx 'x86_64-unknown-linux-gnu -' "$f" || fail "$f has no 'x86_64-unknown-linux-gnu -' row"
    n=$((n + 1))
  done
  [[ $n -gt 0 ]] || fail "no target-os tables"
}
# The default chain is bridged and checked strictly: no allow-list for undefined macros.
test_no_allow_undef() {
  if grep -q TARGET_OS_ALLOW_UNDEF "$root/docker/toolchain/target-os-check" "$root/docker/Dockerfile.sdk"; then
    fail "TARGET_OS_ALLOW_UNDEF is still in target-os-check or Dockerfile.sdk"
  fi
}
test_x86_64_linux_unchanged
test_fixture_has_x86_64_linux
test_no_allow_undef

# docker/toolchain/target-os-check against the Xcode's own clang (Mac only): its table passes, an extra or a missing
# macro fails, and a macro without a rule cannot be derived.
if [[ "$(uname)" == Darwin ]] && xcode="$(xcode-select -p 2>/dev/null)" && [[ -x "$xcode/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang" ]]; then
  cc="$xcode/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang"
  build=$(/usr/libexec/PlistBuddy -c 'Print :ProductBuildVersion' "$xcode/../version.plist")
  fixture="$root/docker/toolchain/target-os/$build.txt"
  chk="sh $root/docker/toolchain/target-os-check"
  if [[ -f "$fixture" ]]; then
    $chk check "$fixture" "$cc" || fail "Xcode $build's clang does not match its own table"
    [[ -z "$($chk missing "$fixture" "$cc")" ]] || fail "missing reported for Apple clang"
    $chk check "$fixture" "$cc" -DTARGET_OS_EXTRA=1 2>/dev/null && fail "an extra macro passed"
    $chk check "$fixture" "$cc" -DTARGET_OS_IOS=0 2>/dev/null && fail "a wrong value passed"
    $chk check "$fixture" "$cc" -fdefine-target-os-macros 2>/dev/null && fail "TARGET_OS_ macros on Linux passed"
    $chk darwin "$fixture" "$cc" -fdefine-target-os-macros || fail "darwin ignores Linux"
    [[ "$($chk derive "$root/docker/toolchain/target-os/derived.txt" TARGET_OS_IOSMAC)" == -DTARGET_OS_IOSMAC=TARGET_OS_MACCATALYST ]] || fail "derive"
    $chk derive "$root/docker/toolchain/target-os/derived.txt" TARGET_OS_IOS 2>/dev/null && fail "derived a macro without a rule"
  else
    echo "note: no recorded table for Xcode $build; target-os-check not run"
  fi
fi
echo PASS
