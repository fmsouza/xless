#!/usr/bin/env bash
# Installs a release from its assets before they are published, as a user would, and checks the version it reports:
#   scripts/verify-release.sh <version> <dist>
# <dist> holds the assets scripts/release-assets.sh made (the tarballs, SHA256SUMS, install.sh). They are laid out the way
# a GitHub release serves them, <dir>/download/v<version>/ and <dir>/latest/download/, and <dist>/install.sh installs from
# there (XLESS_RELEASE_BASE=file://<dir>) twice, into fresh prefixes: once pinned to <version> (XLESS_VERSION) and once
# as the latest. Each time `xless --version` and share/xless/VERSION must be <version>. The tarball installed is this
# machine's architecture (XLESS_UNAME_M / XLESS_UNAME_S pass through to install.sh, for tests). On macOS the installed program is
# checked again (scripts/check-macos-binary.sh; XLESS_CHECK_BINARY overrides it). On Windows: scripts/verify-release.ps1.
set -euo pipefail
version="${1:-}" dist="${2:-}"
die() { echo "verify-release: $*" >&2; exit 1; }
[[ -n "$version" && -n "$dist" ]] || { echo "usage: verify-release.sh <version> <dist>" >&2; exit 2; }
for f in SHA256SUMS install.sh; do [[ -f "$dist/$f" ]] || die "$dist/$f is missing (run scripts/release-assets.sh first)"; done
dist="$(cd "$dist" && pwd)"
t="$(mktemp -d)"
trap 'rm -rf "$t"' EXIT
root="$(cd "$(dirname "$0")/.." && pwd)"
arch="${XLESS_UNAME_M:-$(uname -m)}"
mkdir -p "$t/rel/download/v$version" "$t/rel/latest/download"
cp "$dist"/xless-*.tar.gz "$dist/SHA256SUMS" "$dist/install.sh" "$t/rel/download/v$version/"
cp "$dist"/xless-*.tar.gz "$dist/SHA256SUMS" "$dist/install.sh" "$t/rel/latest/download/"

check() {  # label prefix
  local got
  got="$("$2/bin/xless" --version)" || die "$1: $2/bin/xless --version failed"
  [[ "$got" == "$version" ]] || die "$1: xless --version printed '$got', expected '$version'"
  got="$(cat "$2/share/xless/VERSION")" || die "$1: no share/xless/VERSION"
  [[ "$got" == "$version" ]] || die "$1: share/xless/VERSION is '$got', expected '$version'"
  if [[ "${XLESS_UNAME_S:-$(uname -s)}" == Darwin ]]; then
    "${XLESS_CHECK_BINARY:-$root/scripts/check-macos-binary.sh}" "$2/bin/xless" "$arch" || die "$1: the installed program is not what is released"
  fi
  echo "verify-release: $1: xless $version installed and reports $version"
}
XLESS_RELEASE_BASE="file://$t/rel" XLESS_VERSION="$version" XLESS_PREFIX="$t/pinned" sh "$dist/install.sh" \
  || die "install.sh failed for v$version"
check "v$version" "$t/pinned"
env -u XLESS_VERSION XLESS_RELEASE_BASE="file://$t/rel" XLESS_PREFIX="$t/latest" sh "$dist/install.sh" \
  || die "install.sh failed for the latest release"
check latest "$t/latest"
