#!/usr/bin/env bash
# A macOS xless needs nothing but the system, and has the signature a release has:
#   scripts/check-macos-binary.sh <xless-binary> <x86_64|arm64>
# One architecture; libraries of /usr/lib and /System/Library only (the Swift runtime is the system's: none is bundled, and
# there is no run path where one could be put); for macOS 14.0 or later; an ad hoc signature with the hardened runtime and
# "restrict", and no entitlements. Uses otool, lipo and codesign (in Xcode and in its command line tools).
set -euo pipefail
bin="${1:-}" arch="${2:-}"
die() { echo "check-macos-binary: $*" >&2; exit 1; }
[[ -n "$bin" && -n "$arch" ]] || { echo "usage: check-macos-binary.sh <xless-binary> <x86_64|arm64>" >&2; exit 2; }
[[ -f "$bin" ]] || die "no $bin"

archs="$(lipo -archs "$bin")" || die "$bin is not a Mach-O file"
[[ "${archs%% }" == "$arch" ]] || die "$bin is for [$archs], not $arch"

libraries="$(otool -L "$bin" | sed 1d | sed 's/^[[:space:]]*//; s/ (compatibility version .*$//')"
[[ -n "$libraries" ]] || die "$bin has no libraries: otool told nothing"
odd="$(grep -vE '^(/usr/lib|/System/Library)/' <<< "$libraries" || true; grep -E '/\.\.?(/|$)' <<< "$libraries" || true)"
[[ -z "$odd" ]] || die "$bin needs what is not the system's: $odd"

commands="$(otool -l "$bin")"
rpaths="$(sed -n '/cmd LC_RPATH/,/path /s/^ *path \(.*\) (offset [0-9]*)$/\1/p' <<< "$commands")"
odd="$(grep -vx -e /usr/lib/swift -e '' <<< "$rpaths" || true)"
[[ -z "$odd" ]] || die "$bin has a run path of its own: $odd"
# The archives of Xcode's toolchain that the compiler adds for systems older than 14.0 (-runtime-compatibility-version none), as far
# as a program shows them: which objects it was linked of is for check-link-map.sh, where it is built.
hooks="$(grep -oE '__swift[0-9]*_hooks' <<< "$commands" || true)"
[[ -z "$hooks" ]] || die "$bin holds a compatibility library of Swift: $hooks"
grep -q 'cmd LC_DYLD_ENVIRONMENT' <<< "$commands" && die "$bin sets variables of the dynamic linker"

target="$(sed -n '/cmd LC_BUILD_VERSION/,/sdk /p' <<< "$commands")"
grep -qE '^ *platform (1|MACOS)$' <<< "$target" || die "$bin is not for macOS"
minos="$(sed -n 's/^ *minos //p' <<< "$target")"
[[ "$minos" == 14.0 ]] || die "$bin is for macOS $minos or later, not 14.0"

codesign --verify --strict "$bin" || die "the signature of $bin does not verify"
signature="$(codesign -dvv "$bin" 2>&1)"
grep -qx 'Signature=adhoc' <<< "$signature" || die "$bin is not signed ad hoc"
flags="$(sed -n 's/^CodeDirectory .* flags=0x[0-9a-f]*(\(.*\)) .*/\1/p' <<< "$signature")"
for flag in adhoc runtime restrict; do
  [[ ",$flags," == *",$flag,"* ]] || die "the signature of $bin has the flags ($flags), not $flag"
done
[[ -z "$(codesign -d --entitlements - --xml "$bin" 2>/dev/null)" ]] || die "$bin has entitlements"
echo "check-macos-binary: $bin: $arch, macOS 14.0 or later, system libraries only, signed ad hoc"
