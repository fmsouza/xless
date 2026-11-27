#!/usr/bin/env bash
# What the xless image holds, built (scripts/docker-images.sh image --arch <arch>), and each of its kits' images that is here
# (xless setup --docker --with tauri,react-native): nothing of an Xcode in any layer (every layer's files, also those a later
# layer deletes), label (its name or its value) or build argument and ENV of its history; xless of the image's release; the
# store of Xcode packs at /xcodes. Run by `make test-image`.
#   XLESS_IMAGE_ARCH: arm64 or amd64 (default: this machine's). XLESS_IMAGE: the image to check (default: the one
#   scripts/docker-images.sh tags from this checkout, xless:<short commit>[-dirty]-<arch>, or xless:<version>-<arch> outside git);
#   its kits are <image>-tauri and <image>-react-native.
#   XLESS_IMAGE_REQUIRED=1 (make test-image): a missing docker or image fails the test. Without it the test skips, with a notice.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
fail() { echo "FAIL: $*"; exit 1; }
skip() {
  [[ -z "${XLESS_IMAGE_REQUIRED:-}" ]] || fail "$* (XLESS_IMAGE_REQUIRED is set)"
  echo "SKIP: $*"
  exit 0
}
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
t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT

# Every file of every layer of the image, by name (docker save: the layers as tar files, read as they stream by; a file that a
# later layer deletes is still in the layer that added it). Prints each that is an Xcode's, and on its last line how many
# layers it read.
layer_files() {
  docker save "$1" | python3 -I -c '
import fnmatch, os, sys, tarfile
names = ["*.sdk", "darwin.artifactbundle", "darwin.xtoolsdk", "toolchain-meta.json", "*.xctoolchain"]
layers = 0
outer = tarfile.open(fileobj=sys.stdin.buffer, mode="r|")
for member in outer:
    if not member.isfile():
        continue
    try:
        inner = tarfile.open(fileobj=outer.extractfile(member), mode="r|*")
        for entry in inner:
            name = os.path.basename(entry.name.rstrip("/"))
            name = name[4:] if name.startswith(".wh.") else name
            if any(fnmatch.fnmatchcase(name, n) for n in names):
                print(f"{member.name}: {entry.name}")
        layers += 1
    except (tarfile.TarError, EOFError, OSError):
        pass  # the manifest, the configuration: no layer
print(layers)
'
}

check() {
  local image="$1"
  run() { docker run --rm --pull=never --platform "linux/$arch" "$image" "$@"; }
  # No file of an Xcode anywhere in its file system: no SDK, no SDK bundle or export, no toolchain metadata, no Xcode toolchain.
  run find / -xdev \( -name '*.sdk' -o -name 'darwin.artifactbundle' -o -name 'darwin.xtoolsdk' -o -name 'toolchain-meta.json' \
    -o -name '*.xctoolchain' \) -print > "$t/found" 2>/dev/null || fail "find did not run in $image"
  [[ ! -s "$t/found" ]] || fail "$image holds files of an Xcode: $(head -5 "$t/found" | tr '\n' ' ')"
  # No label of an Xcode or its SDK, by its name or its value (only org.xless.image, dev.xless.version, .arch, .image, a kit's
  # dev.xless.kit*, and the base image's own).
  docker image inspect --format '{{range $k, $v := .Config.Labels}}{{$k}}{{"\n"}}{{end}}' "$image" > "$t/labels"
  docker image inspect --format '{{range $k, $v := .Config.Labels}}{{$v}}{{"\n"}}{{end}}' "$image" > "$t/values"
  grep -q '^dev.xless.version$' "$t/labels" && grep -q '^org.xless.image$' "$t/labels" || fail "$image is no xless image: labels $(tr '\n' ' ' < "$t/labels")"
  grep -iE 'sdk|xcode' "$t/labels" && fail "$image has a label of an Xcode (above)"
  grep -iE 'sdk|xcode' "$t/values" && fail "$image has a label whose value names an Xcode (above)"
  # Nothing of an Xcode in how it was built: no Xcode's version or build among its build arguments (also given by value alone,
  # as a RUN line shows them: XLESS_XCODE=…), no ENV of one (XLESS_XCODE, XLESS_XCODE_…; the store, XLESS_XCODES, is no
  # Xcode), no SDK export.
  docker history --no-trunc --format '{{.CreatedBy}}' "$image" > "$t/history"
  grep -iE 'xcode[0-9]|XLESS_XCODE(_[A-Z0-9_]*)?=|xtoolsdk' "$t/history" && fail "$image was built with an Xcode (above)"
  # Nor in any layer: one that a later layer deletes, too.
  layer_files "$image" > "$t/layers" || fail "the layers of $image could not be read (docker save)"
  local count want
  count="$(tail -1 "$t/layers")"
  want="$(docker image inspect --format '{{range .RootFS.Layers}}{{println .}}{{end}}' "$image" | sort -u | grep -c .)"
  [[ "$count" == "$want" ]] || fail "$count of the $want layers of $image were read"
  sed '$d' "$t/layers" > "$t/in-layers"
  [[ ! -s "$t/in-layers" ]] || fail "a layer of $image holds files of an Xcode: $(head -5 "$t/in-layers" | tr '\n' ' ')"
  # xless of the image's release, and the store of packs that any user can write (a setup runs as the calling user).
  [[ "$(run xless --version)" == "$version" ]] || fail "xless --version in $image: $(run xless --version), not $version"
  [[ "$(docker image inspect --format '{{index .Config.Labels "dev.xless.version"}}' "$image")" == "$version" ]] || fail "$image's dev.xless.version is not $version"
  [[ "$(run sh -c 'echo $XLESS_XCODES')" == /xcodes ]] || fail "XLESS_XCODES in $image: $(run sh -c 'echo $XLESS_XCODES')"
  [[ "$(run stat -c %a /xcodes)" == 1777 ]] || fail "/xcodes in $image is not writable by every user (mode $(run stat -c %a /xcodes))"
  echo "PASS image-contents ($image, $count layers)"
}

check "$image"
for kit in tauri react-native; do
  if docker image inspect "$image-$kit" >/dev/null 2>&1; then check "$image-$kit"; else echo "note: no image $image-$kit (its kit is not built here)"; fi
done
