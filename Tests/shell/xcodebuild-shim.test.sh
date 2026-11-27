#!/usr/bin/env bash
# docker/shims/xcodebuild, run as Expo's ExpoModulesJSI build phase runs xcodebuild: under `env -i` with PATH and HOME
# kept. It restores the image's settings, and what chooses the pack (XLESS_XCODES, XLESS_XCODE, XLESS_XCODE_PIN) from the
# nearest process above it that was not run that way, so that with a whole store mounted the nested build uses the pinned
# pack, not the newest; nothing that the build did not have.
set -euo pipefail
repo="$(cd "$(dirname "$0")/../.." && pwd)"
if [[ ! -r /proc/self/environ ]]; then echo "SKIP: needs Linux's /proc"; exit 0; fi
t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT
fail() { echo "FAIL: $*"; exit 1; }

# The fake xless: prints what the shim gave it.
mkdir -p "$t/bin"
cat > "$t/bin/xless" <<'EOF'
#!/bin/sh
echo "args=$*"
for v in XLESS_SHIM_DIR XLESS_XCODES XLESS_XCODE XLESS_XCODE_PIN SWIFT_DETERMINISTIC_HASHING OTHER; do
  eval "printf '%s=%s\n' $v \"\${$v-<unset>}\""
done
EOF
chmod +x "$t/bin/xless"

# phase <variables…>: the build phase's shell, with the image's settings and <variables…>, runs the shim under env -i
# (`; :` keeps that shell alive, as the phase's is, rather than letting it exec env).
phase() {
  # shellcheck disable=SC2016 # the phase's shell expands them
  env -i PATH="$t/bin:/usr/bin:/bin" HOME="$t" XLESS_SHIM_DIR=/opt/xless/shims XLESS_XCODES=/xcodes OTHER=x "$@" \
    sh -c 'env -i PATH="$PATH" HOME="$HOME" sh "$1" -version; :' sh "$repo/docker/shims/xcodebuild"
}

# The pin and the pack named: carried through, and nothing else.
out=$(phase XLESS_XCODE=/xcodes/26.2-17C52-arm64 XLESS_XCODE_PIN=26.2)
expected="args=shim xcodebuild -version
XLESS_SHIM_DIR=/opt/xless/shims
XLESS_XCODES=/xcodes
XLESS_XCODE=/xcodes/26.2-17C52-arm64
XLESS_XCODE_PIN=26.2
SWIFT_DETERMINISTIC_HASHING=1
OTHER=<unset>"
[[ "$out" == "$expected" ]] || fail "pin and pack: $out"

# Another store, and no pin: that store, and neither variable invented.
out=$(phase XLESS_XCODES=/stores/mine)
[[ "$out" == *$'XLESS_XCODES=/stores/mine\nXLESS_XCODE=<unset>\nXLESS_XCODE_PIN=<unset>'* ]] || fail "another store: $out"

# Not under env -i (the image's settings are there): the shim changes nothing of them.
out=$(env XLESS_SHIM_DIR=/opt/xless/shims XLESS_XCODES=/xcodes XLESS_XCODE_PIN=27.0 PATH="$t/bin:/usr/bin:/bin" sh "$repo/docker/shims/xcodebuild")
[[ "$out" == *$'XLESS_XCODE=<unset>\nXLESS_XCODE_PIN=27.0'* ]] || fail "without env -i: $out"

# No process above it has them (a shim run by hand under env -i): the image's defaults only.
out=$(env -i PATH="$t/bin:/usr/bin:/bin" HOME="$t" sh "$repo/docker/shims/xcodebuild")
[[ "$out" == *$'XLESS_SHIM_DIR=/opt/xless/shims\nXLESS_XCODES=/xcodes\nXLESS_XCODE=<unset>\nXLESS_XCODE_PIN=<unset>'* ]] || fail "by hand: $out"
echo "PASS xcodebuild-shim"
