#!/usr/bin/env bash
# versions.env's SWIFT_IMAGE pins the Swift image by digest, its tag is SWIFT_VERSION's, and every workflow container and
# Dockerfile uses it (the workflows can't read versions.env, so they repeat it and this test keeps them equal).
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
fail() { echo "FAIL: $*"; exit 1; }
image="$(sed -n 's/^SWIFT_IMAGE=//p' "$root/versions.env")"
version="$(sed -n 's/^SWIFT_VERSION=//p' "$root/versions.env")"
[[ "$image" =~ ^swift:([0-9.]+)-jammy@sha256:[0-9a-f]{64}$ ]] || fail "SWIFT_IMAGE is not swift:<x.y.z>-jammy@sha256:<64 hex>: '$image'"
[[ "${BASH_REMATCH[1]}" == "$version" ]] || fail "SWIFT_IMAGE's tag ${BASH_REMATCH[1]} is not SWIFT_VERSION $version"

# Every `container:` of a workflow or composite action is the pinned image.
n=0
while IFS= read -r line; do
  file="${line%%:*}"; ref="${line#*container:}"; ref="${ref%%#*}"; ref="$(echo "$ref" | tr -d '[:space:]')"
  [[ "$ref" == "$image" ]] || fail "$file: container '$ref' is not versions.env's SWIFT_IMAGE '$image'"
  n=$((n + 1))
done < <(grep -rn -E '^[[:space:]]*container:' "$root/.github" | sed "s|^$root/||")
[[ $n -ge 3 ]] || fail "expected the containers of pr.yml (2) and release.yml (1), found $n"

# No swift image is referenced by tag only, anywhere that builds something.
if grep -rn -E 'swift:[0-9$][^@[:space:]]*-jammy([^@]|$)' "$root/.github" "$root/docker" "$root/Makefile" "$root/scripts"/*.sh \
    | grep -v -E '^[^:]+:[0-9]+:[[:space:]]*#'; then
  fail "a swift image referenced by tag only (above): use versions.env's SWIFT_IMAGE"
fi
from_line="FROM \${SWIFT_IMAGE}"
grep -qF "$from_line" "$root/docker/Dockerfile" || fail "docker/Dockerfile does not build $from_line"
# docker/react-native is a Dockerfile on its own (its folder is all it is built from), so it repeats it.
grep -qxF "ARG BUILD_IMAGE=$image" "$root/docker/react-native/Dockerfile" || fail "docker/react-native/Dockerfile's BUILD_IMAGE is not versions.env's SWIFT_IMAGE '$image'"
echo "swift-image: ok ($image, $n containers)"
