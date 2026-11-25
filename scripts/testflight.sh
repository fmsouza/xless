#!/bin/sh
# Kept for one release, for those who call it: `xless run` does what this did (docs/signing-and-testflight.md). It runs the
# same arguments, in the images unless an SDK is installed natively (XLESS_USE_DOCKER as before), with the xless on this
# machine: $XLESS_SELF, else the one on PATH, else the one this script came with.
set -eu
die() { echo "testflight: $*" >&2; exit 2; }
[ "${XLESS_RUN_AS_SCRIPT:-}" != 1 ] || die "the xless that ran this (${XLESS_SELF:-xless}) is older than scripts/testflight.sh; update it (from a checkout: swift build)"
is_program() { case "$1" in -*) return 1 ;; */*) [ -f "$1" ] && [ -x "$1" ] ;; *) command -v "$1" >/dev/null 2>&1 ;; esac; }
[ -z "${XLESS_SELF:-}" ] || is_program "$XLESS_SELF" || die "XLESS_SELF ($XLESS_SELF) is not a program on this machine; set it to an xless, or unset it"
here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
for x in "${XLESS_SELF:-xless}" "$here/../../../bin/xless" "$here/../.build/release/xless" "$here/../.build/debug/xless"; do
  if is_program "$x"; then
    echo "note: scripts/testflight.sh is going away; use: xless run (or xless run --docker)" >&2
    XLESS_RUN_AS_SCRIPT=1 XLESS_SELF="${XLESS_SELF:-$x}" exec "$x" run "$@"
  fi
done
die "no xless on this machine, which does what this script did: install it (README.md), build it (swift build), or set XLESS_SELF"
