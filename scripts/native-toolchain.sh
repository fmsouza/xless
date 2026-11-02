#!/bin/sh
# Ruling R10, natively: fits an open-source Swift toolchain that `xless setup` unpacked (not the user's own Swift) to the
# installed Darwin SDK, as docker/Dockerfile.sdk fits the image's, with the same helpers (docker/toolchain: clang-driver,
# target-os-check, the target-os fixtures, record-flags.py), then writes the toolchain record (XlessCore SwiftToolchain).
#   scripts/native-toolchain.sh <toolchain root> own|separate <darwin.artifactbundle> <toolchain-meta.json> <docker/toolchain> <record>
# own: the toolchain is the release the image chain runs as its own Swift (SWIFT_VERSION): the SDK keeps the Xcode's clang
#   resource directory. separate: another release (Dockerfile.sdk's APP_SWIFT_VERSION case): the SDK's resource directory
#   becomes the toolchain's own, with the Xcode's Darwin runtimes beside its headers, and its ld64.lld runs the SDK's.
# Then, in both, the clang driver is wrapped when it lacks the Apple clang defaults the Xcode's fixture records, and the
# flags it adds go to the record and to the SDK's toolsets. Safe to re-run (after the SDK was installed again): the
# toolchain's original links are kept in usr/bin/.xless-original-links and put back first. The record is written last.
set -eu
[ $# -eq 6 ] || { echo "usage: $0 <toolchain root> own|separate <darwin.artifactbundle> <toolchain-meta.json> <docker/toolchain> <record>" >&2; exit 2; }
root=$1 mode=$2 bundle=$3 meta=$4 helpers=$5 record=$6
die() { echo "native-toolchain: $*" >&2; exit 1; }
case "$mode" in own|separate) ;; *) die "mode must be own or separate, not $mode" ;; esac
bin="$root/usr/bin"
[ -x "$bin/swiftc" ] || die "no toolchain at $root ($bin/swiftc)"
[ -d "$bundle" ] || die "no SDK at $bundle"
chk() { sh "$helpers/target-os-check" "$@"; }
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

saved="$bin/.xless-original-links"
if [ -f "$saved" ]; then
  while read -r name target; do rm -f "$bin/$name"; ln -s "$target" "$bin/$name"; done < "$saved"
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
  own="$("$bin/clang" -print-resource-dir)"
  xcode="$(readlink -f "$x/swift/clang")"
  # A dead link (an earlier Xcode's runtimes) is replaced.
  for d in "$xcode"/lib/*; do t="$own/lib/$(basename "$d")"; if [ ! -e "$t" ]; then rm -f "$t"; ln -s "$d" "$t"; fi; done
  for s in swift swift_static; do
    if [ -L "$x/$s/clang" ]; then rm "$x/$s/clang"; fi
    [ ! -e "$x/$s/clang" ] || die "$x/$s/clang is not a link"
    ln -s "$own" "$x/$s/clang"
    [ "$(readlink -f "$x/$s/clang")" = "$(readlink -f "$own")" ]
  done
  test -f "$x/swift/clang/lib/darwin/libclang_rt.ios.a" && test -f "$x/swift/clang/include/arm_neon.h"
  rm "$bin/ld64.lld"; printf '#!/bin/sh\nexec "%s" "$@"\n' "$bundle/toolset/bin/ld64.lld" > "$bin/ld64.lld"
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
    python3 -c 'import sys; t = open(sys.argv[1]).read(); open(sys.argv[2], "w").write(t.replace("@DRIVER@", sys.argv[3]).replace("@FLAGS@", sys.argv[4]))' \
      "$helpers/clang-driver" "$bin/$d" "$bin/$real" "$flags"
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

if [ -n "$flags" ]; then
  # shellcheck disable=SC2086
  XLESS_SWIFT_TOOLCHAIN_RECORD="$record.partial" python3 "$helpers/record-flags.py" "$sv" "$root" "$bundle" $flags
else
  python3 -c 'import json, sys; json.dump({"version": sys.argv[1], "root": sys.argv[2]}, open(sys.argv[3], "w"))' "$sv" "$root" "$record.partial"
fi
mv "$record.partial" "$record"
echo "native-toolchain: Swift $sv at $root, fitted to Xcode $xb's SDK ($mode); record $record"
