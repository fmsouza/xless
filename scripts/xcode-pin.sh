#!/usr/bin/env bash
# Pins one Xcode for a whole Mac bench run without `xcode-select -s`, for tools that drop DEVELOPER_DIR from the
# environment of what they run (the Tauri CLI, through cargo-mobile2, runs xcodebuild and cargo with only PATH, HOME
# and a few others: an exported DEVELOPER_DIR never reaches them). PATH survives, so a directory of shims put first on
# PATH carries the Xcode to every Apple tool found through it.
#
#   scripts/xcode-pin.sh shims <Developer dir> <shim dir>
#       Writes one shim per xcode-select shim in /usr/bin (xcodebuild, xcrun, clang, cc, ld, swift, … and xcode-select
#       itself: the tools that look DEVELOPER_DIR up, found as the files hard-linked with /usr/bin/xcodebuild and
#       /usr/bin/clang, plus xcrun and xcode-select): `DEVELOPER_DIR=<Developer dir> exec /usr/bin/<tool> "$@"`.
#       Exit 2 when the Developer dir or one of xcodebuild, xcrun, clang and cc is missing.
#   scripts/xcode-pin.sh check <Developer dir> <file>…
#       Lists every other Xcode or Command Line Tools directory the files mention (build logs, call logs, link lines):
#       exit 0 when there is none, 1 (the directories on stderr) when the run used another toolchain somewhere.
#
# Env: XCODE_PIN_USR_BIN  the directory holding the shims (default /usr/bin; tests point it at a fake one).
set -euo pipefail
die() { echo "xcode-pin: $*" >&2; exit 2; }
USR_BIN="${XCODE_PIN_USR_BIN:-/usr/bin}"

case "${1:-}" in
  shims)
    [[ $# -eq 3 ]] || die "usage: $0 shims <Developer dir> <shim dir>"
    dev="$2"; dir="$3"
    [[ -d "$dev" ]] || die "no Developer directory $dev"
    for t in xcodebuild xcrun clang cc; do [[ -x "$USR_BIN/$t" ]] || die "no $USR_BIN/$t: not a macOS with Xcode shims"; done
    mkdir -p "$dir"
    q="$(printf '%q' "$dev")"
    { find "$USR_BIN" -maxdepth 1 -type f \( -samefile "$USR_BIN/xcodebuild" -o -samefile "$USR_BIN/clang" \)
      echo "$USR_BIN/xcrun"; [[ ! -x "$USR_BIN/xcode-select" ]] || echo "$USR_BIN/xcode-select"; } | sort -u \
    | while IFS= read -r tool; do
        name="${tool##*/}"
        printf '#!/bin/sh\nDEVELOPER_DIR=%s exec %s "$@"\n' "$q" "$(printf '%q' "$tool")" > "$dir/$name"
        chmod +x "$dir/$name"
      done
    ;;
  check)
    [[ $# -ge 3 ]] || die "usage: $0 check <Developer dir> <file>…"
    dev="${2%/}"; shift 2
    real="$(cd "$dev" 2>/dev/null && pwd -P || echo "$dev")"
    # A path ends at whitespace, a quote or a list separator (PATH-style values, -flag=… and JSON strings).
    others="$( { grep -ohE "/[^\"'[:space:]:;,=\\\\]*\\.app/Contents/Developer|/Library/Developer/CommandLineTools" "$@" 2>/dev/null || true; } \
      | sort -u | grep -vxF -e "$dev" -e "$real" || true)"
    [[ -z "$others" ]] && exit 0
    echo "$others" >&2
    exit 1
    ;;
  *) die "usage: $0 shims <Developer dir> <shim dir> | check <Developer dir> <file>…" ;;
esac
