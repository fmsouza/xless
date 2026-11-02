#!/bin/sh
# Installs xless from a GitHub release (POSIX sh, for `curl -fsSL …/releases/latest/download/install.sh | sh`).
#   install.sh [--prefix <dir>]
# XLESS_PREFIX     install prefix (default $HOME/.local): bin/xless and share/xless/
# XLESS_VERSION    release to install, x.y.z or vx.y.z (default: the latest)
# XLESS_RELEASE_BASE   where releases live (default https://github.com/fmsouza/xless/releases)
# XLESS_UNAME_M, XLESS_UNAME_S   override `uname -m` / `uname -s` (tests only)
# The tarball is checked against the release's SHA256SUMS before anything is replaced.
set -eu
main() {

  base="${XLESS_RELEASE_BASE:-https://github.com/fmsouza/xless/releases}"
  home="${HOME:-}"
  prefix="${XLESS_PREFIX:-}"
  version="${XLESS_VERSION:-}"

  die() { echo "install.sh: $*" >&2; exit 1; }

  while [ $# -gt 0 ]; do
    case "$1" in
      --prefix) [ $# -ge 2 ] || die "--prefix needs a directory"; prefix="$2"; shift 2 ;;
      --prefix=*) prefix="${1#--prefix=}"; shift ;;
      -h|--help) sed -n '2,9p' "$0" 2>/dev/null || true; exit 0 ;;
      *) die "unknown argument: $1" ;;
    esac
  done
  if [ -z "$prefix" ]; then
    [ -n "$home" ] || die "HOME is unset: set XLESS_PREFIX or pass --prefix"
    prefix="$home/.local"
  fi
  case "$prefix" in /*) ;; *) prefix="$(pwd)/$prefix" ;; esac
  while [ "$prefix" != / ] && [ "${prefix%/}" != "$prefix" ]; do prefix="${prefix%/}"; done

  os="${XLESS_UNAME_S:-$(uname -s)}"
  [ "$os" = Linux ] || die "unsupported OS $os: xless installs on Linux (x86_64 or arm64); on a Mac use a Linux VM or container"
  case "${XLESS_UNAME_M:-$(uname -m)}" in
    x86_64|amd64) arch=x86_64 ;;
    aarch64|arm64) arch=arm64 ;;
    *) die "unsupported architecture ${XLESS_UNAME_M:-$(uname -m)}: xless releases are for x86_64 and arm64" ;;
  esac

  fetch() {  # url dest
    case "$1" in
      https://*)  # https only (no downgrading redirect), TLS 1.2 or newer
        if command -v curl >/dev/null 2>&1; then curl -fsSL --proto '=https' --tlsv1.2 -o "$2" "$1"
        elif command -v wget >/dev/null 2>&1; then
          # GNU wget has the flags; a BusyBox wget has not (and already speaks https only to an https URL).
          if wget --help 2>&1 | grep -q -e --https-only; then wget -qO "$2" --https-only --secure-protocol=TLSv1_2 "$1"; else wget -qO "$2" "$1"; fi
        else die "needs curl or wget"; fi ;;
      *)
        if command -v curl >/dev/null 2>&1; then curl -fsSL -o "$2" "$1"
        elif command -v wget >/dev/null 2>&1; then wget -qO "$2" "$1"
        else die "needs curl or wget"; fi ;;
    esac
  }
  sha256_of() {
    if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'
    else die "needs sha256sum or shasum to verify the download"; fi
  }

  tmp=""
  stage=""
  newbin=""
  swapping=0
  hadold=0
  cleanup() {
    trap '' HUP INT TERM  # a second signal must not interrupt a rollback
    # Failed or interrupted between the share swap and the binary rename (the new binary is still beside bin/xless): undo the swap.
    if [ "$swapping" = 1 ] && [ -n "$newbin" ] && [ -e "$newbin" ]; then
      if [ -e "$stage/previous" ]; then rm -rf "$prefix/share/xless"; mv "$stage/previous" "$prefix/share/xless"
      elif [ "$hadold" = 0 ]; then rm -rf "$prefix/share/xless"; fi
    fi
    [ -z "$newbin" ] || rm -f "$newbin"
    [ -z "$tmp" ] || rm -rf "$tmp"
    [ -z "$stage" ] || rm -rf "$stage"
  }
  trap cleanup EXIT
  trap 'exit 1' HUP INT TERM
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/xless-install.XXXXXX")"

  version="${version#v}"
  if [ -n "$version" ] && [ "$version" != latest ]; then
    dl="$base/download/v$version"
  else
    version=""
    dl="$base/latest/download"
  fi

  fetch "$dl/SHA256SUMS" "$tmp/SHA256SUMS" || die "could not download $dl/SHA256SUMS"
  if [ -z "$version" ]; then
    name="$(awk -v a="-linux-$arch.tar.gz" '{ n = $2; sub(/^\*/, "", n) } n ~ /^xless-.*-linux-/ && substr(n, length(n) - length(a) + 1) == a { print n; exit }' "$tmp/SHA256SUMS")"
    [ -n "$name" ] || die "the latest release lists no $arch tarball"
    version="${name#xless-}"; version="${version%-linux-"$arch".tar.gz}"
    # Pin to that release from here on: a release published meanwhile must not mix its files with this one's checksums.
    dl="$base/download/v$version"
    fetch "$dl/SHA256SUMS" "$tmp/SHA256SUMS" || die "could not download $dl/SHA256SUMS"
  else
    name="xless-$version-linux-$arch.tar.gz"
  fi
  want="$(awk -v n="$name" '$2 == n || $2 == "*" n { print $1; exit }' "$tmp/SHA256SUMS")"
  [ -n "$want" ] || die "SHA256SUMS does not list $name"

  echo "downloading $name"
  fetch "$dl/$name" "$tmp/$name" || die "could not download $dl/$name"
  got="$(sha256_of "$tmp/$name")"
  [ "$got" = "$want" ] || die "sha256 mismatch for $name (got $got, want $want); nothing was installed"

  mkdir -p "$prefix/bin" "$prefix/share"
  stage="$(mktemp -d "$prefix/share/.xless-install.XXXXXX")"
  top="xless-$version-linux-$arch"
  tar -xzf "$tmp/$name" -C "$stage" || die "could not unpack $name"
  if [ ! -f "$stage/$top/bin/xless" ] || [ ! -d "$stage/$top/share/xless" ]; then die "$name does not have the expected layout"; fi

  # 1. Copy the new binary beside the old one (nothing is replaced yet). 2. Swap share/xless. 3. Rename the binary into place.
  # Any failure or signal after step 2 puts the previous share/xless back (see cleanup); `previous` is deleted only on success.
  newbin="$prefix/bin/.xless.new.$$"
  if ! { cp "$stage/$top/bin/xless" "$newbin" && chmod 755 "$newbin"; }; then die "could not write $prefix/bin (is it writable, and is the disk full?)"; fi
  if [ -e "$prefix/share/xless" ]; then hadold=1; fi
  swapping=1
  if [ "$hadold" = 1 ]; then mv "$prefix/share/xless" "$stage/previous" || die "could not move the old share/xless aside"; fi
  mv "$stage/$top/share/xless" "$prefix/share/xless" || die "could not install $prefix/share/xless"
  mv -f "$newbin" "$prefix/bin/xless" || die "could not install $prefix/bin/xless"
  swapping=0

  echo "xless $version installed to $prefix/bin/xless"

  case ":${PATH:-}:" in
    *":$prefix/bin:"*) ;;
    *)
      case "${SHELL:-}" in */zsh) profile="$home/.zshrc" ;; */bash) profile="$home/.bashrc" ;; *) profile="$home/.profile" ;; esac
      if [ "$prefix" = "$home/.local" ]; then
        # Many systems (Ubuntu's ~/.profile among them) put ~/.local/bin on PATH at login once it exists.
        echo "$prefix/bin is not on PATH in this shell. Open a new terminal (many systems add ~/.local/bin to PATH at login"
        echo "once it exists), or run:"
        echo "  export PATH=\"$prefix/bin:\$PATH\""
        echo "If xless is still not found in a new terminal, add that line to $profile."
      else
        echo "$prefix/bin is not on PATH in this shell. Run:"
        echo "  export PATH=\"$prefix/bin:\$PATH\""
        echo "and add that line to $profile."
      fi
      ;;
  esac

  # Docker is optional: `xless setup` installs natively; only `--docker` (the images) needs it.
  echo "next: xless setup --xcode ~/Downloads/Xcode_27.xip"
}

# Everything is defined above and nothing runs until here, so a truncated `curl | sh` download runs nothing.
main "$@"
