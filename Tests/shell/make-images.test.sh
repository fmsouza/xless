#!/usr/bin/env bash
# `make images` builds the image of this checkout, which holds no Xcode: an XCODE given to it (on the command line or in the
# environment) stops it with the command that prepares that Xcode's pack, before anything is built.
set -euo pipefail
repo="$(cd "$(dirname "$0")/../.." && pwd)"
fail() { echo "FAIL: $*"; exit 1; }

# scripts/build-images.sh hands docker-images.sh the context xless would choose (scripts/docker-context.sh): a chosen one as
# DOCKER_CONTEXT, without the DOCKER_HOST that docker would rank above it; with DOCKER_HOST and no DOCKER_CONTEXT, DOCKER_HOST.
t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
mkdir -p "$t/repo/scripts" "$t/bin" "$t/home"
cp "$repo/scripts/build-images.sh" "$repo/scripts/docker-context.sh" "$t/repo/scripts/"
# shellcheck disable=SC2016 # (a script, written as it is)
printf '#!/bin/sh\necho "context=${DOCKER_CONTEXT:--} host=${DOCKER_HOST:--}" >> "%s"\n' "$t/images.log" > "$t/repo/scripts/docker-images.sh"
printf '#!/bin/sh\nprintf "default\\ncolima-xless\\nmine\\n"\n' > "$t/bin/docker"
chmod +x "$t/repo/scripts/docker-images.sh" "$t/bin/docker"
build() { : > "$t/images.log"; env -i PATH="$t/bin:/usr/bin:/bin" HOME="$t/home" "$@" bash "$t/repo/scripts/build-images.sh" arm64 2>/dev/null; cat "$t/images.log"; }
[[ "$(build DOCKER_CONTEXT=mine DOCKER_HOST=tcp://build:2376)" == "context=mine host=-" ]] || fail "a chosen context keeps DOCKER_HOST: $(cat "$t/images.log")"
[[ "$(build DOCKER_HOST=tcp://build:2376)" == "context=- host=tcp://build:2376" ]] || fail "DOCKER_HOST alone is not kept: $(cat "$t/images.log")"
[[ "$(build)" == "context=colima-xless host=-" ]] || fail "colima-xless is not chosen: $(cat "$t/images.log")"

command -v make >/dev/null || { echo "SKIP (make): needs make"; echo "PASS make-images"; exit 0; }
want="make images: the image holds no Xcode, so XCODE is not used here; prepare the Xcode's pack with xless setup --docker --xcode /x/Xcode_26.2.xip"
code=0; out=$(make -s -C "$repo" images XCODE=/x/Xcode_26.2.xip 2>&1) || code=$?
[[ $code != 0 && "$out" == "$want"* ]] || fail "XCODE on the command line: $code $out"
code=0; out=$(XCODE=/x/Xcode_26.2.xip make -s -C "$repo" images 2>&1) || code=$?
[[ $code != 0 && "$out" == "$want"* ]] || fail "XCODE in the environment: $code $out"
# (without XCODE it builds: make -n shows the build, and runs nothing)
[[ "$(env -u XCODE make -s -n -C "$repo" images | tail -1)" == "scripts/build-images.sh "* ]] || fail "without XCODE it does not build"
echo "PASS make-images"
