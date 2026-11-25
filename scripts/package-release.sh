#!/usr/bin/env bash
# Packages a built xless into the release tarball.
#   scripts/package-release.sh [--os linux|macos|windows] <version> <x86_64|arm64> <xless-binary> <out-dir>   (--os linux by default)
# Writes <out-dir>/xless-<version>-<os>-<arch>.tar.gz (top directory xless-<version>-<os>-<arch>/) and adds its line to
# <out-dir>/SHA256SUMS (sha256sum's format; the other lines are kept). Layout (checked by scripts/check-package.sh):
#   bin/xless (stripped)  LICENSE  share/xless/{VERSION,versions.env,docker/,scripts/,credential-helpers/,samples/HelloShip/,licenses/}
# For Windows (x86_64) a .zip instead, of bin/xless.exe with the DLLs of the Swift runtime that it needs (from XLESS_RUNTIME),
# LICENSE and share/xless/{VERSION,licenses/}: builds do not run there.
# docker/ and samples/HelloShip are the tracked files only. The macOS binary is freed of the run paths of the Xcode it was
# built with, signed ad hoc (with the hardened runtime, and without any identity) and checked by scripts/check-macos-binary.sh;
# XLESS_LINK_MAP is the linker's map of it (scripts/check-link-map.sh, which says what may be linked in), without which none is made.
# XLESS_STRIP overrides the strip command, XLESS_CODESIGN, XLESS_CHECK_BINARY and XLESS_CHECK_MAP (a macOS package's) codesign and those checks;
# XLESS_CHECKOUTS is passed on to third-party-licenses.sh.
set -euo pipefail
os=linux
if [[ "${1:-}" == --os ]]; then os="${2:-}"; shift 2 || true; fi
version="${1:-}" arch="${2:-}" bin="${3:-}" outdir="${4:-}"
usage() { echo "usage: package-release.sh [--os linux|macos|windows] <version> <x86_64|arm64> <xless-binary> <out-dir>" >&2; exit 2; }
[[ -n "$version" && -n "$arch" && -n "$bin" && -n "$outdir" ]] || usage
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$ ]] || { echo "package-release: bad version '$version'" >&2; exit 2; }
case "$os" in linux|macos|windows) ;; *) echo "package-release: unsupported system '$os' (linux, macos or windows)" >&2; exit 2 ;; esac
case "$os-$arch" in *-x86_64|linux-arm64|macos-arm64) ;; *) echo "package-release: unsupported arch '$arch' (x86_64 or arm64; x86_64 on Windows)" >&2; exit 2 ;; esac
[[ -f "$bin" ]] || { echo "package-release: no binary at $bin" >&2; exit 1; }
root="$(cd "$(dirname "$0")/.." && pwd)"
name="xless-$version-$os-$arch"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
stage="$work/$name"
share="$stage/share/xless"

# Adds the file's line to <out-dir>/SHA256SUMS.
add_sum() {
  local sum
  if command -v sha256sum >/dev/null 2>&1; then sum=$(cd "$outdir" && sha256sum "$1" | tr '*' ' ')   # '*': binary, of Git for Windows
  else sum=$(cd "$outdir" && shasum -a 256 "$1"); fi
  {
    if [[ -f "$outdir/SHA256SUMS" ]]; then grep -vF "  $1" "$outdir/SHA256SUMS" || true; fi
    echo "$sum"
  } | LC_ALL=C sort -k2 > "$work/sums"
  cat "$work/sums" > "$outdir/SHA256SUMS"
}

if [[ "$os" == windows ]]; then
  python=python3; command -v python3 >/dev/null 2>&1 || python=python
  tool() { "$python" -I "$root/scripts/windows-package.py" "$@"; }
  mkdir -p "$work/stage/$name/bin" "$work/stage/$name/share/xless" "$outdir"
  stage="$work/stage/$name"
  cp "$bin" "$stage/bin/xless.exe"
  if [[ "${XLESS_STUB:-}" != true ]]; then
    [[ -d "${XLESS_RUNTIME:-}" ]] || { echo "package-release: XLESS_RUNTIME is not the directory of the Swift runtime's DLLs" >&2; exit 1; }
    tool closure "$bin" "$XLESS_RUNTIME" > "$work/libraries"
    while IFS= read -r f; do cp "$XLESS_RUNTIME/$f" "$stage/bin/$f"; done < "$work/libraries"
  fi
  cp "$root/LICENSE" "$stage/LICENSE"
  echo "$version" > "$stage/share/xless/VERSION"
  "$root/scripts/third-party-licenses.sh" --os windows "$stage/share/xless/licenses"
  tool pack "$work/stage" "$work/$name.zip"
  "$root/scripts/check-package.sh" windows "$version" "$arch" "$work/$name.zip" >/dev/null
  cat "$work/$name.zip" > "$outdir/$name.zip"
  add_sum "$name.zip"
  echo "$outdir/$name.zip"
  exit 0
fi
mkdir -p "$stage/bin" "$share/scripts" "$share/credential-helpers"

install -m 755 "$bin" "$stage/bin/xless"
if [[ -n "${XLESS_STRIP:-}" ]]; then strip_cmd="$XLESS_STRIP"
elif [[ "$os" == linux ]] && command -v llvm-strip >/dev/null 2>&1; then strip_cmd=llvm-strip
else strip_cmd="strip"; fi
"$strip_cmd" "$stage/bin/xless"
if [[ "$os" == macos ]]; then
  if [[ -z "${XLESS_CHECK_MAP:-}" && -z "${XLESS_LINK_MAP:-}" ]]; then echo "package-release: XLESS_LINK_MAP is not set: swift build … -Xlinker -map -Xlinker <file>" >&2; exit 1; fi
  "${XLESS_CHECK_MAP:-$root/scripts/check-link-map.sh}" "${XLESS_LINK_MAP:-}" "$bin" "$arch"
  # The Swift runtime is the system's: a run path of the build machine's Xcode (or of the program's own directory) is a place
  # where a library could be put in its stead.
  if command -v otool >/dev/null 2>&1; then
    while IFS= read -r rpath; do install_name_tool -delete_rpath "$rpath" "$stage/bin/xless" || { echo "package-release: cannot take the run path $rpath out" >&2; exit 1; }
    done < <(otool -l "$stage/bin/xless" 2>/dev/null | sed -n '/cmd LC_RPATH/,/path /s/^ *path \(.*\) (offset [0-9]*)$/\1/p' | grep -vx /usr/lib/swift || true)
  fi
  # Ad hoc: no identity, so nobody but the checksums and the attestation vouches for it (docs/maintainers.md#releases). The
  # hardened runtime refuses debuggers and DYLD_ variables; "restrict" hides the environment from the user's other programs.
  "${XLESS_CODESIGN:-codesign}" --force --sign - --identifier xless --options runtime,restrict "$stage/bin/xless"
  "${XLESS_CHECK_BINARY:-$root/scripts/check-macos-binary.sh}" "$stage/bin/xless" "$arch"
fi

cp "$root/LICENSE" "$stage/LICENSE"
echo "$version" > "$share/VERSION"
cp "$root/versions.env" "$share/versions.env"
for s in docker-images xcode-swift testflight native-toolchain; do install -m 755 "$root/scripts/$s.sh" "$share/scripts/$s.sh"; done
# The reference credential helpers (`secrets: { backend: helper }`, docs/secrets.md): users put them on PATH.
for h in pass secret-tool; do install -m 755 "$root/scripts/credential-helpers/xless-credential-$h" "$share/credential-helpers/xless-credential-$h"; done

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
[[ -f "$share/docker/Dockerfile" && -f "$share/samples/HelloShip/Package.swift" ]] || { echo "package-release: no tracked docker/ or samples/ files (not a git checkout?)" >&2; exit 1; }

"$root/scripts/third-party-licenses.sh" --os "$os" "$share/licenses"
chmod -R u=rwX,go=rX "$stage"   # whatever the umask here, and the modes of what was copied

mkdir -p "$outdir"
tarball="$outdir/$name.tar.gz"
if tar --version 2>/dev/null | grep -qi 'gnu tar'; then tar_opts=(--owner=0 --group=0 --numeric-owner --sort=name "$name")
else
  (cd "$work" && find "$name" | tr / '\001' | LC_ALL=C sort | tr '\001' /) > "$work/names"   # GNU tar's order
  tar_opts=(--uid 0 --gid 0 --numeric-owner --no-mac-metadata --no-xattrs --no-acls --no-fflags -n -T "$work/names")
fi
# To its own name once it is checked: nothing else takes it up.
COPYFILE_DISABLE=1 tar -czf "$work/$name.tar.gz" -C "$work" "${tar_opts[@]}"
"$root/scripts/check-package.sh" "$os" "$version" "$arch" "$work/$name.tar.gz" >/dev/null
cat "$work/$name.tar.gz" > "$tarball"

add_sum "$name.tar.gz"
echo "$tarball"
