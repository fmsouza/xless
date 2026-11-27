#!/usr/bin/env bash
# What the xless image holds, built (scripts/docker-images.sh image --arch <arch>): nothing of an Xcode in its files, its
# labels or its history; xless of the image's release; the store of Xcode packs at /xcodes. Run by `make test-image`.
#   XLESS_IMAGE_ARCH: arm64 or amd64 (default: this machine's). XLESS_IMAGE: the image to check (default: the one
#   scripts/docker-images.sh tags from this checkout, xless:<short commit>[-dirty]-<arch>, or xless:<version>-<arch> outside git).
# Skips, with a notice, when docker or the image is not there.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
fail() { echo "FAIL: $*"; exit 1; }
skip() { echo "SKIP: $*"; exit 0; }
case "$(uname -m)" in arm64|aarch64) host=arm64 ;; *) host=amd64 ;; esac
arch="${XLESS_IMAGE_ARCH:-$host}"
# shellcheck disable=SC1091
version="$(. "$root/versions.env"; echo "$XLESS_VERSION")"
[[ ! -s "$root/VERSION" ]] || version="$(tr -d '[:space:]' < "$root/VERSION")"
if [[ -n "${XLESS_IMAGE:-}" ]]; then
  image="$XLESS_IMAGE"
elif [[ "$(git -C "$root" rev-parse --show-toplevel 2>/dev/null || true)" == "$root" ]]; then
  id="$(git -C "$root" rev-parse --short=12 HEAD)"
  git -C "$root" diff --quiet HEAD 2>/dev/null || id+="-dirty"
  image="xless:$id-$arch"
else
  image="xless:$version-$arch"
fi
command -v docker >/dev/null 2>&1 && docker version >/dev/null 2>&1 || skip "no docker"
docker image inspect "$image" >/dev/null 2>&1 || skip "no image $image (scripts/docker-images.sh image --arch $arch)"
run() { docker run --rm --pull=never --platform "linux/$arch" "$image" "$@"; }
t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT

# No file of an Xcode anywhere in its file system: no SDK, no SDK bundle or export, no toolchain metadata, no Xcode toolchain.
run find / -xdev \( -name '*.sdk' -o -name 'darwin.artifactbundle' -o -name 'darwin.xtoolsdk' -o -name 'toolchain-meta.json' \
  -o -name '*.xctoolchain' \) -print > "$t/found" 2>/dev/null || fail "find did not run in $image"
[[ ! -s "$t/found" ]] || fail "$image holds files of an Xcode: $(head -5 "$t/found" | tr '\n' ' ')"
# No label of an Xcode or its SDK (only org.xless.image and dev.xless.version, .arch, .image).
docker image inspect --format '{{range $k, $v := .Config.Labels}}{{$k}}{{"\n"}}{{end}}' "$image" > "$t/labels"
grep -q '^dev.xless.version$' "$t/labels" && grep -q '^org.xless.image$' "$t/labels" || fail "$image is no xless image: labels $(tr '\n' ' ' < "$t/labels")"
grep -iE 'sdk|xcode' "$t/labels" && fail "$image has a label of an Xcode (above)"
# Nothing of an Xcode in how it was built: no Xcode's version or build among its build arguments, no SDK export.
docker history --no-trunc --format '{{.CreatedBy}}' "$image" > "$t/history"
grep -i 'xcode[0-9]\|XLESS_XCODE_BUILD\|xtoolsdk' "$t/history" && fail "$image was built with an Xcode (above)"
# xless of the image's release, and the store of packs that any user can write (a setup runs as the calling user).
[[ "$(run xless --version)" == "$version" ]] || fail "xless --version in $image: $(run xless --version), not $version"
[[ "$(docker image inspect --format '{{index .Config.Labels "dev.xless.version"}}' "$image")" == "$version" ]] || fail "$image's dev.xless.version is not $version"
[[ "$(run sh -c 'echo $XLESS_XCODES')" == /xcodes ]] || fail "XLESS_XCODES in $image: $(run sh -c 'echo $XLESS_XCODES')"
[[ "$(run stat -c %a /xcodes)" == 1777 ]] || fail "/xcodes in $image is not writable by every user (mode $(run stat -c %a /xcodes))"
echo "PASS image-contents ($image)"
