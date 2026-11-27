#!/usr/bin/env bash
# `make images` builds the image of this checkout, which holds no Xcode: an XCODE given to it (on the command line or in the
# environment) stops it with the command that prepares that Xcode's pack, before anything is built.
set -euo pipefail
repo="$(cd "$(dirname "$0")/../.." && pwd)"
command -v make >/dev/null || { echo "SKIP: needs make"; exit 0; }
fail() { echo "FAIL: $*"; exit 1; }
want="make images: the image holds no Xcode, so XCODE is not used here; prepare the Xcode's pack with xless setup --docker --xcode /x/Xcode_26.2.xip"
code=0; out=$(make -s -C "$repo" images XCODE=/x/Xcode_26.2.xip 2>&1) || code=$?
[[ $code != 0 && "$out" == "$want"* ]] || fail "XCODE on the command line: $code $out"
code=0; out=$(XCODE=/x/Xcode_26.2.xip make -s -C "$repo" images 2>&1) || code=$?
[[ $code != 0 && "$out" == "$want"* ]] || fail "XCODE in the environment: $code $out"
# (without XCODE it builds: make -n shows the build, and runs nothing)
[[ "$(env -u XCODE make -s -n -C "$repo" images | tail -1)" == "scripts/build-images.sh "* ]] || fail "without XCODE it does not build"
echo "PASS make-images"
