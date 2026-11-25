#!/usr/bin/env bash
# What was linked into a macOS xless: the objects this build made of this repository's and its packages' sources, and nothing
# else (an archive of the toolchain, which is Apple's and may not be published, is the case in mind).
#   scripts/check-link-map.sh <link-map> <xless-binary> <x86_64|arm64>
# The map is the linker's (-Xlinker -map -Xlinker <link-map>). <xless-binary> is the one it names, in its build directory
# (…/out/Products/Release/xless). All that may be in a map:
#   linker synthesized                           what the linker makes itself (stubs, __mh_execute_header)
#   …/SDKs/MacOSX<version>.sdk/….tbd             a library of the system's, by name: a .tbd is a list of names, and holds no code
#   <build>/out/Intermediates.noindex/….o        an object the build compiled
#   <build>/out/Products/Release/<target>.o      a target's objects in one: which those are is in its LinkFileList, each must be one
#                                                of the above, and it must define nothing that they do not (an archive that
#                                                was taken in there is not in the map)
# So no archive, no library file, no object of a package's own (a binary target, a checkout), none of the toolchain.
set -euo pipefail
map="${1:-}" bin="${2:-}" arch="${3:-}"
die() { echo "check-link-map: $*" >&2; exit 1; }
[[ -n "$map" && -n "$bin" && -n "$arch" ]] || { echo "usage: check-link-map.sh <link-map> <xless-binary> <x86_64|arm64>" >&2; exit 2; }
[[ -s "$map" ]] || die "no link map $map (swift build … -Xlinker -map -Xlinker $map)"
export LC_ALL=C
t="$(mktemp -d)"
trap 'rm -rf "$t"' EXIT

path="$(sed -n '1,10s/^# Path: //p' "$map")"
[[ -n "$path" && -f "$bin" && "$path" -ef "$bin" ]] || die "$map is the map of '$path', not of $bin"
got="$(sed -n '1,10s/^# Arch: //p' "$map")"
[[ "$got" == "$arch" ]] || die "$map is for $got, not $arch"
out="${path%/Products/Release/xless}"
[[ "$out" == */out ]] || die "$path is in no build directory that this check knows (…/out/Products/Release/xless)"

sed -n '/^# Object files:$/,/^# Sections:$/{/^#/d;s/^\[ *[0-9]*\] //p;}' "$map" > "$t/objects"
[[ -s "$t/objects" ]] || die "$map lists no objects"
made() {  # whether $1 is an object that the build compiled
  case "$1" in */../*|*/./*) return 1 ;; "$out"/Intermediates.noindex/*.o) return 0 ;; *) return 1 ;; esac
}
odd=0 compiled=0
while IFS= read -r object; do
  if made "$object"; then compiled=$((compiled + 1)); continue; fi
  case "$object" in
    'linker synthesized') continue ;;
    */../*|*/./*) ;;
    */SDKs/MacOSX*.sdk/*.tbd) continue ;;
    "$out"/Products/Release/*.o)
      name="${object##*/}"
      if [[ "$object" == "$out/Products/Release/$name" ]]; then echo "$name" >> "$t/targets"; continue; fi ;;
  esac
  echo "check-link-map: linked into xless, and not made by this build of this repository's or its packages' sources: $object" >&2
  odd=1
done < "$t/objects"
[[ $odd == 0 ]] || exit 1
[[ $compiled -gt 0 ]] || die "$map lists no objects of the build's"

[[ -e "$t/targets" ]] || : > "$t/targets"
while IFS= read -r name; do
  find "$out/Intermediates.noindex" -path "*/Release/*/Objects-normal/$arch/${name%.o}.LinkFileList" > "$t/lists"
  [[ "$(wc -l < "$t/lists")" -eq 1 ]] || die "no list of the objects of $name (or more than one)"
  IFS= read -r list < "$t/lists"
  [[ -s "$list" ]] || die "no list of the objects of $name: $list is empty"
  : > "$t/parts"
  while IFS= read -r object || [[ -n "$object" ]]; do
    made "$object" || die "in $name, and not made by this build: $object"
    nm -jU -arch "$arch" "$object" >> "$t/parts" 2>/dev/null || die "nm cannot read $object"
  done < "$list"
  nm -jU -arch "$arch" "$out/Products/Release/$name" > "$t/whole" 2>/dev/null || die "nm cannot read $name"
  odd="$(comm -23 <(sort -u "$t/whole") <(sort -u "$t/parts") | sed -n 1,5p)"
  [[ -z "$odd" ]] || die "$name defines what its own objects do not: $odd"
done < "$t/targets"
echo "check-link-map: $bin: $compiled objects and $(wc -l < "$t/targets" | tr -d ' ') targets of this build, and the system's libraries by name"
