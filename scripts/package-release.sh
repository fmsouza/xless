#!/usr/bin/env bash
# Packages a built Linux xless into the release tarball.
#   scripts/package-release.sh <version> <x86_64|arm64> <xless-binary> <out-dir>
# Writes <out-dir>/xless-<version>-linux-<arch>.tar.gz (top directory xless-<version>-linux-<arch>/) and adds its line to
# <out-dir>/SHA256SUMS (sha256sum's format; the other arch's line is kept). Layout:
#   bin/xless (stripped)  LICENSE  share/xless/{VERSION,versions.env,docker/,scripts/,samples/HelloShip/,licenses/}
# docker/ and samples/HelloShip are the tracked files only. XLESS_STRIP overrides the strip command; XLESS_CHECKOUTS is
# passed on to third-party-licenses.sh.
set -euo pipefail
version="${1:-}" arch="${2:-}" bin="${3:-}" outdir="${4:-}"
usage() { echo "usage: package-release.sh <version> <x86_64|arm64> <xless-binary> <out-dir>" >&2; exit 2; }
[[ -n "$version" && -n "$arch" && -n "$bin" && -n "$outdir" ]] || usage
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$ ]] || { echo "package-release: bad version '$version'" >&2; exit 2; }
case "$arch" in x86_64|arm64) ;; *) echo "package-release: unsupported arch '$arch' (x86_64 or arm64)" >&2; exit 2 ;; esac
[[ -f "$bin" ]] || { echo "package-release: no binary at $bin" >&2; exit 1; }
root="$(cd "$(dirname "$0")/.." && pwd)"
name="xless-$version-linux-$arch"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
stage="$work/$name"
share="$stage/share/xless"
mkdir -p "$stage/bin" "$share/scripts"

install -m 755 "$bin" "$stage/bin/xless"
if [[ -n "${XLESS_STRIP:-}" ]]; then strip_cmd="$XLESS_STRIP"
elif command -v llvm-strip >/dev/null 2>&1; then strip_cmd=llvm-strip
else strip_cmd="strip"; fi
"$strip_cmd" "$stage/bin/xless"

cp "$root/LICENSE" "$stage/LICENSE"
echo "$version" > "$share/VERSION"
cp "$root/versions.env" "$share/versions.env"
for s in docker-images xcode-swift testflight native-toolchain; do install -m 755 "$root/scripts/$s.sh" "$share/scripts/$s.sh"; done

# Tracked files only (-c safe.directory: CI containers check out as another user).
git_files() { git -c "safe.directory=$root" -C "$root" ls-files "$1"; }
copy_tracked() {
  local f
  git_files "$1" | while IFS= read -r f; do
    mkdir -p "$share/$(dirname "$f")"
    cp -p "$root/$f" "$share/$f"
  done
}
copy_tracked docker
copy_tracked samples/HelloShip
[[ -f "$share/docker/Dockerfile.base" && -f "$share/samples/HelloShip/Package.swift" ]] || { echo "package-release: no tracked docker/ or samples/ files (not a git checkout?)" >&2; exit 1; }

"$root/scripts/third-party-licenses.sh" "$share/licenses"

mkdir -p "$outdir"
tarball="$outdir/$name.tar.gz"
tar_opts=()
if tar --version 2>/dev/null | grep -qi 'gnu tar'; then tar_opts=(--owner=0 --group=0 --numeric-owner --sort=name)
else tar_opts=(--uid 0 --gid 0 --numeric-owner); fi
COPYFILE_DISABLE=1 tar "${tar_opts[@]}" -czf "$tarball" -C "$work" "$name"

if command -v sha256sum >/dev/null 2>&1; then sum=$(cd "$outdir" && sha256sum "$name.tar.gz")
else sum=$(cd "$outdir" && shasum -a 256 "$name.tar.gz"); fi
sums="$outdir/SHA256SUMS"
{
  if [[ -f "$sums" ]]; then grep -vF "  $name.tar.gz" "$sums" || true; fi
  echo "$sum"
} | sort -k2 > "$work/sums"
cat "$work/sums" > "$sums"
echo "$tarball"
