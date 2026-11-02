#!/usr/bin/env bash
# Builds xless from this checkout and installs it into <prefix>/bin (default /usr/local), on Debian/Ubuntu (arm64 or
# x86_64), for contributors. Users install the release (README) instead. Either way, `xless setup --xcode <Xcode.xip>`
# then installs the rest natively (xtool, rcodesign, the Xcode's Swift, the SDK): run it with XLESS_SHARE=<this checkout>,
# since a source build finds its data files (versions.env, the scripts) only through XLESS_SHARE.
# Swift SWIFT_VERSION (to compile xless) comes through swiftly when it is not on PATH; swiftly itself is fetched unpinned
# and unverified from download.swift.org (swiftly then installs the pinned SWIFT_VERSION).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/versions.env"
PREFIX="${PREFIX:-/usr/local}"
if [[ "${1:-}" == "--prefix" ]]; then PREFIX="${2:?--prefix needs a path}"; fi
case "$(uname -m)" in
  aarch64|arm64) A=aarch64 ;;
  x86_64) A=x86_64 ;;
  *) echo "unsupported arch $(uname -m)" >&2; exit 1 ;;
esac
SUDO=""; [[ $EUID -ne 0 ]] && SUDO="sudo"
export DEBIAN_FRONTEND=noninteractive
SUDO_ENV="env DEBIAN_FRONTEND=noninteractive"

$SUDO $SUDO_ENV apt-get update -qq
$SUDO $SUDO_ENV apt-get install -y -qq curl ca-certificates tar gzip zip unzip git python3 build-essential libcurl4-openssl-dev libxml2-dev >/dev/null

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
SWIFTLY_ENV="${SWIFTLY_HOME_DIR:-$HOME/.local/share/swiftly}/env.sh"
# shellcheck disable=SC1090
[[ -f "$SWIFTLY_ENV" ]] && . "$SWIFTLY_ENV"

have_swift() { local v; v=$(swift --version 2>/dev/null) || return 1; local want="${SWIFT_VERSION%.0}"  # swift prints 6.4 for 6.4.0
  [[ "$v" == *"Swift version ${SWIFT_VERSION} "* || "$v" == *"Swift version ${want} "* ]]; }
if ! have_swift; then
  if ! command -v swiftly >/dev/null 2>&1; then
    curl -fsSL -o "$TMP/swiftly.tar.gz" "https://download.swift.org/swiftly/linux/swiftly-${A}.tar.gz"
    tar -xzf "$TMP/swiftly.tar.gz" -C "$TMP"
    "$TMP/swiftly" init --assume-yes --quiet-shell-followup --skip-install
    # shellcheck disable=SC1090
    . "$SWIFTLY_ENV"
    echo "note: swiftly added itself to your shell profile; open a new shell (or source $SWIFTLY_ENV) to use swift."
  fi
  # swiftly exits non-zero when the toolchain needs extra apt packages; it writes them to a post-install script.
  (cd "$TMP" && swiftly install --use --assume-yes --post-install-file "$TMP/post-install.sh" "${SWIFT_VERSION}") || [[ -s "$TMP/post-install.sh" ]]
  if [[ -s "$TMP/post-install.sh" ]]; then $SUDO $SUDO_ENV bash "$TMP/post-install.sh"; fi
  have_swift
fi

# GitHub rate-limits git over HTTP/2 from some git versions (401); scope the workaround to this build only.
export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=http.version GIT_CONFIG_VALUE_0=HTTP/1.1
(cd "$ROOT" && swift build -c release --product xless)
$SUDO mkdir -p "$PREFIX/bin"
$SUDO install -m755 "$(cd "$ROOT" && swift build -c release --show-bin-path)/xless" "$PREFIX/bin/xless"

xless --version
echo "Installed. Next: XLESS_SHARE=$ROOT xless setup --xcode ~/Downloads/Xcode_27.xip"
