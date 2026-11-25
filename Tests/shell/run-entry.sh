# shellcheck shell=bash
# Sourced by testflight*.test.sh: S is `xless run` as scripts/testflight.sh starts it, with the steps run by $XLESS_SELF
# (else the xless on PATH, a fake one in these tests). XLESS_BIN=<path>: that binary, else one built with `swift build`.
# Needs $t, a directory of the test's own.
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
XLESS_RUN="${XLESS_BIN:-}"
if [[ -z "$XLESS_RUN" ]]; then
  (cd "$repo" && env -u DEVELOPER_DIR swift build --product xless -q)
  XLESS_RUN="$(cd "$repo" && env -u DEVELOPER_DIR swift build --show-bin-path)/xless"
fi
XLESS_RUN="$(cd "$(dirname "$XLESS_RUN")" && pwd -P)/$(basename "$XLESS_RUN")"
S="$t/xless-run"
cat > "$S" <<S
#!/bin/sh
XLESS_RUN_AS_SCRIPT=1 XLESS_SELF="\${XLESS_SELF:-xless}" XLESS_SHARE="$repo" exec "$XLESS_RUN" run "\$@"
S
chmod +x "$S"
