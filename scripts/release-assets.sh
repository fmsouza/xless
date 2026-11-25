#!/usr/bin/env bash
# The release's assets, beside the four tarballs the build legs made:
#   scripts/release-assets.sh <version> <dist>
# <dist> must hold exactly xless-<version>-<linux|macos>-<x86_64|arm64>.tar.gz, each with what a package holds and nothing
# else (scripts/check-package.sh). Writes
# <dist>/SHA256SUMS (sha256sum's format, sorted by name) and copies scripts/install.sh to <dist>/install.sh. The release
# workflow's verify and publish jobs both run it, so what is installed before publishing is what is published.
set -euo pipefail
version="${1:-}" dist="${2:-}"
die() { echo "release-assets: $*" >&2; exit 1; }
[[ -n "$version" && -n "$dist" ]] || { echo "usage: release-assets.sh <version> <dist>" >&2; exit 2; }
[[ -d "$dist" ]] || die "no directory $dist"
root="$(cd "$(dirname "$0")/.." && pwd)"
want=()
for os in linux macos; do for arch in arm64 x86_64; do want+=("xless-$version-$os-$arch.tar.gz"); done; done
got=()
while IFS= read -r f; do got+=("$f"); done < <(cd "$dist" && find . -maxdepth 1 -name '*.tar.gz' | sed 's#^\./##' | LC_ALL=C sort)
[[ "${got[*]-}" == "${want[*]}" ]] || die "$dist holds [${got[*]-}], expected [${want[*]}]"
for os in linux macos; do for arch in arm64 x86_64; do
  "$root/scripts/check-package.sh" "$os" "$version" "$arch" "$dist/xless-$version-$os-$arch.tar.gz" >/dev/null || die "the $os $arch package is not as it must be"
done; done
if command -v sha256sum >/dev/null 2>&1; then (cd "$dist" && sha256sum "${want[@]}") > "$dist/SHA256SUMS"
else (cd "$dist" && shasum -a 256 "${want[@]}") > "$dist/SHA256SUMS"; fi
cp "$root/scripts/install.sh" "$dist/install.sh"
cat "$dist/SHA256SUMS"
