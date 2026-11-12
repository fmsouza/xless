#!/usr/bin/env bash
# scripts/xcode-tools.sh: an image chain is made only from an Xcode whose actool/ibtool/copypng formats are measured
# (an XcodeToolsProfile entry); anything else is refused with the measuring commands.
set -euo pipefail
repo="$(cd "$(dirname "$0")/../.." && pwd)"
S="$repo/scripts/xcode-tools.sh"
fail() { echo "FAIL: $*"; exit 1; }

test_known_builds_pass() {
  for b in 17C52 27A266a 27A9275; do "$S" "$b" >/dev/null 2>&1 || fail "build $b refused"; done
}
test_unknown_build_refused() {
  local rc=0 err
  err=$("$S" 99A9999 2>&1 >/dev/null) || rc=$?
  [[ $rc == 2 ]] || fail "unknown build exits $rc, want 2"
  for s in assetkit-golden.sh ib-golden.sh copypng-golden.sh 99A9999; do
    [[ "$err" == *"$s"* ]] || fail "refusal does not mention $s: $err"
  done
}
test_partial_match_refused() {   # a prefix or substring of a profiled build is not that build
  for b in 17C5 7C52 27A266 "" ; do
    if "$S" "$b" >/dev/null 2>&1; then fail "'$b' accepted"; fi
  done
}
test_build_images_calls_it() {
  grep -q 'xcode-tools.sh' "$repo/scripts/build-images.sh" || fail "build-images.sh does not call xcode-tools.sh"
  # before anything is built: ahead of the first image build
  local gate make
  gate=$(grep -n 'xcode-tools.sh' "$repo/scripts/build-images.sh" | head -1 | cut -d: -f1)
  make=$(grep -n '^images base' "$repo/scripts/build-images.sh" | head -1 | cut -d: -f1)
  [[ "$gate" -lt "$make" ]] || fail "the gate runs after make"
}
test_rn_reference_refuses_unprofiled() {
  grep -q 'xcode-tools.sh' "$repo/scripts/rn-reference.sh" || fail "rn-reference.sh does not call xcode-tools.sh"
}

test_known_builds_pass
test_unknown_build_refused
test_partial_match_refused
test_build_images_calls_it
test_rn_reference_refuses_unprofiled
echo PASS
