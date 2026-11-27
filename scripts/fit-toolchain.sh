#!/bin/sh
# Ruling R10, relocatable: fits the open-source Swift toolchain of an Xcode pack to the pack's installed Darwin SDK, as
# docker/Dockerfile fits the image's, with the same helpers (docker/toolchain: clang-driver, target-os-check, the
# target-os fixtures, record-flags.py), and leaves no absolute path in the pack, so the pack can be mounted anywhere.
#   scripts/fit-toolchain.sh <pack root> own|separate <docker/toolchain>
# The pack: toolchain/ (usr/bin/swiftc …), config/swiftpm/swift-sdks/darwin.artifactbundle (the SDK, as `xtool sdk install`
# leaves it: relative links only), toolchain-meta.json (xcodeBuild); it gets include/ and, last, swift-toolchain.json
# ({"version", "root": "toolchain", "clangFlags"}; root is relative to the record's directory).
# own: the toolchain is the release the image runs as its own Swift (SWIFT_VERSION): the SDK keeps the Xcode's clang
#   resource directory. separate: another release (docker/Dockerfile's APP_SWIFT_VERSION case): the SDK's resource directory
#   becomes the toolchain's own, with the Xcode's Darwin runtimes beside its headers, and its ld64.lld runs the SDK's.
# Then, in both, the clang driver is wrapped when it lacks the Apple clang defaults the Xcode's fixture records, and the
# flags it adds go to the record and to the SDK's toolsets. Every link made has a relative target, and the wrappers find
# their targets from their own place. Safe to re-run (after the SDK was installed again, or the pack moved): the
# toolchain's original links are kept in usr/bin/.xless-original-links and put back first.
set -eu
[ $# -eq 3 ] || { echo "usage: $0 <pack root> own|separate <docker/toolchain>" >&2; exit 2; }
die() { echo "fit-toolchain: $*" >&2; exit 1; }
case "$2" in own|separate) ;; *) die "mode must be own or separate, not $2" ;; esac
mode=$2 helpers=$3
pack=$(cd -P "$1" 2>/dev/null && pwd -P) || die "no pack at $1"
root="$pack/toolchain" bundle="$pack/config/swiftpm/swift-sdks/darwin.artifactbundle" meta="$pack/toolchain-meta.json"
record="$pack/swift-toolchain.json"
bin="$root/usr/bin"
[ -x "$bin/swiftc" ] || die "no toolchain at $root ($bin/swiftc)"
[ -d "$bundle" ] || die "no SDK at $bundle"
[ -f "$meta" ] || die "no $meta"
chk() { sh "$helpers/target-os-check" "$@"; }
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

# canon <directory>: its physical path (the link-free spelling relpath needs).
canon() { (cd -P "$1" && pwd -P); }
# relpath <directory> <path>: <path> as seen from <directory>; both absolute and without links.
relpath() {
  from=${1%/}; to=$2; up=
  while :; do case "$to/" in "$from"/*) break ;; esac; from=${from%/*}; up="../$up"; done
  rest=${to#"$from"}; rest=${rest#/}; r="$up$rest"; r=${r%/}
  printf '%s\n' "${r:-.}"
}

saved="$bin/.xless-original-links"
if [ -f "$saved" ]; then
  while read -r name target; do rm -f "${bin:?}/$name"; ln -s "$target" "$bin/$name"; done < "$saved"
else
  for n in clang clang++ ld64.lld; do [ -L "$bin/$n" ] && echo "$n $(readlink "$bin/$n")"; done > "$saved.partial"
  mv "$saved.partial" "$saved"
fi

sv="$("$bin/swiftc" --version 2>/dev/null | sed -nE 's/.*Swift version ([0-9.]+) \(swift-.*/\1/p' | head -1)"
[ -n "$sv" ] || die "$bin/swiftc does not run (missing libraries? see docs/native-install.md)"
xb="$(tr -d '\n ' < "$meta" | sed -nE 's/.*"xcodeBuild":"([^"]*)".*/\1/p')"
fixture="$helpers/target-os/$xb.txt"; derived="$helpers/target-os/derived.txt"
[ -f "$fixture" ] || die "no $fixture for Xcode build '$xb'"

if [ "$mode" = separate ]; then
  x="$bundle/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib"
  own="$(canon "$("$bin/clang" -print-resource-dir)")"
  xcode="$(canon "$x/swift/clang")"
  # A dead link (an earlier Xcode's runtimes) is replaced.
  for d in "$xcode"/lib/*; do
    t="$own/lib/$(basename "$d")"
    if [ ! -e "$t" ]; then rm -f "$t"; ln -s "$(relpath "$own/lib" "$(canon "$(dirname "$d")")/$(basename "$d")")" "$t"; fi
  done
  for s in swift swift_static; do
    if [ -L "$x/$s/clang" ]; then rm "$x/$s/clang"; fi
    [ ! -e "$x/$s/clang" ] || die "$x/$s/clang is not a link"
    ln -s "$(relpath "$(canon "$x/$s")" "$own")" "$x/$s/clang"
    [ "$(canon "$x/$s/clang")" = "$own" ] || die "$x/$s/clang does not reach $own"
  done
  test -f "$x/swift/clang/lib/darwin/libclang_rt.ios.a" && test -f "$x/swift/clang/include/arm_neon.h"
  rm "$bin/ld64.lld"
  # A trampoline that finds the SDK's linker from its own place (usr/bin of the toolchain, in the pack), with shell builtins
  # only: Swift Build runs the linker with a PATH of the toolchain's and the platform's directories (no dirname). Its own
  # place is where it was run from ($0: a path, or a bare name of the current directory or of PATH, as `sh ld64.lld`
  # gives); a link to it elsewhere is not followed (nothing links to it: the toolchain's ld64.lld was the link it replaces).
  # shellcheck disable=SC2016 # the trampoline's own variables, expanded when it runs
  printf '%s\n' '#!/bin/sh' \
    'case "$0" in */*) self=$0 ;; *) if [ -f "$0" ]; then self=./$0; else self=$(command -v -- "$0") || exit 127; fi ;; esac' \
    'dir=${self%/*}; [ -n "$dir" ] || dir=/' \
    'here=$(CDPATH= cd -P -- "$dir" && pwd -P) || exit 127' \
    "exec \"\$here/$(relpath "$(canon "$bin")" "$(canon "$bundle")")/toolset/bin/ld64.lld\" \"\$@\"" > "$bin/ld64.lld"
  chmod 755 "$bin/ld64.lld"
fi

real="$(readlink "$bin/clang")"; [ -x "$bin/$real" ] || die "$bin/clang is not a link to the driver"
set -f
flags=; wrap=
"$bin/clang" -target arm64-apple-ios17.0 -dM -E -x c /dev/null | grep -q TARGET_OS_IOS || { flags=-fdefine-target-os-macros; wrap=1; }
# shellcheck disable=SC2086 # flags are words (no globbing: set -f)
missing="$(chk missing "$fixture" "$bin/clang" $flags)"
# shellcheck disable=SC2086
if [ -n "$missing" ]; then flags="$flags $(chk derive "$derived" $missing | tr '\n' ' ')"; wrap=1; fi
# shellcheck disable=SC2086,SC2116 # squeeze the words' spacing
flags="$(echo $flags)"
"$bin/clang++" -### -target arm64-apple-ios17.0 -x c++ -fmodules -fno-cxx-modules -c /dev/null -o /dev/null 2>&1 | grep -qF '"-fno-cxx-modules"' || wrap=1
if [ -n "$wrap" ]; then
  for d in clang clang++; do
    rm "$bin/$d"
    # @DRIVER@ is the driver's name: the driver finds it beside itself.
    python3 -c 'import sys; t = open(sys.argv[1]).read(); open(sys.argv[2], "w").write(t.replace("@DRIVER@", sys.argv[3]).replace("@FLAGS@", sys.argv[4]))' \
      "$helpers/clang-driver" "$bin/$d" "$real" "$flags"
    chmod 755 "$bin/$d"
  done
  printf '%s\n' '-target arm64-apple-ios17.0 -c -x c++ -fmodules -fno-cxx-modules' > "$tmp/r.resp"
  env -i "$bin/clang++" -### @"$tmp/r.resp" /dev/null 2>&1 | grep -qF '"-fno-cxx-modules"'
  printf '%s\n' '-target aarch64-unknown-linux-gnu -c -x c++ -fmodules -fno-cxx-modules' > "$tmp/r.resp"
  [ "$(env -i "$bin/clang++" -### @"$tmp/r.resp" /dev/null 2>&1 | grep -cF '"-fno-cxx-modules"')" = "$(env -i "$bin/$real" --driver-mode=g++ -### @"$tmp/r.resp" /dev/null 2>&1 | grep -cF '"-fno-cxx-modules"')" ]
  chk same "$fixture" "$bin/clang" "$bin/$real"
fi
chk check "$fixture" "$bin/clang"
# shellcheck disable=SC2086
chk darwin "$fixture" "$bin/$real" $flags

# Headers Apple's clang finds in its toolchain's usr/include and the open-source one does not: Swift's C++ interop header
# <swift/bridging> as a module (SwiftBridging); xless adds <pack>/include to every compile with -idirafter.
inc="$root/usr/include/swift"
[ -f "$inc/bridging" ] && [ -f "$inc/bridging.modulemap" ] || die "no swift/bridging in $inc"
mkdir -p "$pack/include/swift"
cp "$inc/bridging" "$inc/bridging.modulemap" "$pack/include/swift/"
echo 'extern module SwiftBridging "swift/bridging.modulemap"' > "$pack/include/module.modulemap"
# macOS resolves #include case-insensitively: the iOS SDK ships usr/include/Endian.h, and code includes <endian.h>. Each
# header in the SDKs' usr/include whose name has capitals gets an all-lowercase symbolic link when no file has that
# name already (only the spelling changes; it is the same file, so modules and include guards see one header).
set +f
for inc in "$bundle"/Developer/Platforms/*/Developer/SDKs/*.sdk/usr/include; do
  [ -d "$inc" ] || continue
  if [ -L "$(dirname "$inc")" ] || [ -L "$(dirname "$(dirname "$inc")")" ]; then continue; fi
  find "$inc" -name '*.h' -type f | while read -r f; do
    b=$(basename "$f"); l=$(printf %s "$b" | tr '[:upper:]' '[:lower:]')
    [ "$b" = "$l" ] || [ -e "$(dirname "$f")/$l" ] || ln -s "$b" "$(dirname "$f")/$l"
  done
done
set -f

if [ -n "$flags" ]; then
  # shellcheck disable=SC2086
  python3 "$helpers/record-flags.py" --record "$record.partial" --root toolchain "$sv" "$bundle" $flags
else
  python3 -c 'import json, sys; json.dump({"version": sys.argv[1], "root": "toolchain"}, open(sys.argv[2], "w"))' "$sv" "$record.partial"
fi
mv "$record.partial" "$record"
echo "fit-toolchain: Swift $sv in the pack, fitted to Xcode $xb's SDK ($mode)"
