# shellcheck shell=bash
# The docker daemon and the xless image that the image tests look at (image-contents.test.sh, image-direct.test.sh), decided in this
# one place: sourced by both (after `root` is set to the checkout), and printed for `make test-image`, which hands the same values
# to both.
#   XLESS_IMAGE_ARCH: arm64 or amd64 (default: this machine's).
#   XLESS_IMAGE: the xless image (default: scripts/docker-images.sh's tag of this checkout, xless:<short commit>[-dirty]-<arch>,
#   or xless:<version>-<arch> outside git). Its kits are <image>-tauri and <image>-react-native.
#   DOCKER_CONTEXT: the docker context (default: docker's current one when DOCKER_HOST is set, else colima-xless if it exists, else
#   docker's current one; scripts/docker-context.sh).
# Sets: arch, context, shown (its name, also when it is docker's current one), d (the docker command, with --context), image.
#   bash Tests/shell/image-target.sh --print     prints XLESS_IMAGE=… and DOCKER_CONTEXT=… as shell words
case "$(uname -m)" in arm64|aarch64) host=arm64 ;; *) host=amd64 ;; esac
arch="${XLESS_IMAGE_ARCH:-$host}"
root="${root:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
# shellcheck source=SCRIPTDIR/../../scripts/docker-context.sh
. "$root/scripts/docker-context.sh"   # docker_context: the context, as xless chooses it (none: docker's current one)
context="$(docker_context image-target)" || exit 2
[[ -z "$context" ]] || unset DOCKER_HOST   # a chosen context is the docker (docker ranks DOCKER_HOST above DOCKER_CONTEXT)
d=(docker)
[[ -z "$context" ]] || d+=(--context "$context")
# shellcheck disable=SC2034 # (read by the tests that source this)
shown="${context:-$(docker context show 2>/dev/null || true)}"   # its name for the tests to print, docker's current one's too
image="${XLESS_IMAGE:-xless:$("$root/scripts/docker-images.sh" tag --arch "$arch")-$arch}"
if [[ "${1:-}" == --print ]]; then
  printf 'XLESS_IMAGE=%q\n' "$image"
  [[ -z "$context" ]] || printf 'DOCKER_CONTEXT=%q\n' "$context"
fi
