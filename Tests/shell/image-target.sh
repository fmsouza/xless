# shellcheck shell=bash
# The docker daemon and the xless image that the image tests look at (image-contents.test.sh, image-direct.test.sh), decided in this
# one place: sourced by both (after `root` is set to the checkout), and printed for `make test-image`, which hands the same values
# to both.
#   XLESS_IMAGE_ARCH: arm64 or amd64 (default: this machine's).
#   XLESS_IMAGE: the xless image (default: scripts/docker-images.sh's tag of this checkout, xless:<short commit>[-dirty]-<arch>,
#   or xless:<version>-<arch> outside git). Its kits are <image>-tauri and <image>-react-native.
#   DOCKER_CONTEXT: the docker context (default: colima-xless if it exists, else docker's current one).
# Sets: arch, context, d (the docker command, with --context), image.
#   bash Tests/shell/image-target.sh --print     prints XLESS_IMAGE=… and DOCKER_CONTEXT=… as shell words
case "$(uname -m)" in arm64|aarch64) host=arm64 ;; *) host=amd64 ;; esac
arch="${XLESS_IMAGE_ARCH:-$host}"
root="${root:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
context="${DOCKER_CONTEXT:-}"
if [[ -z "$context" ]] && command -v docker >/dev/null 2>&1; then
  if docker context ls --format '{{.Name}}' 2>/dev/null | grep -qx colima-xless; then context=colima-xless
  else context="$(docker context show 2>/dev/null || true)"; fi
fi
d=(docker)
[[ -z "$context" ]] || d+=(--context "$context")
image="${XLESS_IMAGE:-xless:$("$root/scripts/docker-images.sh" tag --arch "$arch")-$arch}"
if [[ "${1:-}" == --print ]]; then
  printf 'XLESS_IMAGE=%q\n' "$image"
  [[ -z "$context" ]] || printf 'DOCKER_CONTEXT=%q\n' "$context"
fi
