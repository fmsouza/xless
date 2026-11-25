#!/usr/bin/env bash
# scripts/docker-images.sh: the one docker recipe of the xless image. A DOCKER stub records its argv; nothing is built. And
# what the Dockerfiles may hold: xless's job in docker/Dockerfile, the toolchains of other languages in the kits' alone.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
S="$root/scripts/docker-images.sh"
t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT
fail() { echo "FAIL: $*"; exit 1; }
cat > "$t/docker" <<'D'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$DOCKER_ARGV"
D
chmod +x "$t/docker"
export DOCKER="$t/docker" DOCKER_ARGV="$t/argv"
has() { [[ " $(cat "$DOCKER_ARGV") " == *" $1 "* ]] || fail "$2: '$1' missing from: $(cat "$DOCKER_ARGV")"; }
refused() { local rc=0; rm -f "$DOCKER_ARGV"; "$S" "${@:2}" >/dev/null 2>"$t/err" || rc=$?
  [[ $rc == 2 && ! -e "$DOCKER_ARGV" ]] || fail "$1: exited $rc, not 2, or docker ran"; }
image=(image --arch arm64 --xcode 26.6 --xcode-build 17F113 --sdk-dir d)

# tools: the platform, the tag, the Dockerfile's target and every pin it uses.
"$S" tools --arch amd64 2>/dev/null
has "--platform linux/amd64 --load --provenance=false -t xless:local-amd64-setup -f docker/Dockerfile --target tools" tools
for k in SWIFT_IMAGE XTOOL_VERSION RCODESIGN_VERSION XTOOL_SHA256_AARCH64 XTOOL_SHA256_X86_64 RCODESIGN_SHA256_AARCH64 RCODESIGN_SHA256_X86_64; do
  grep -q -- "--build-arg $k=." "$DOCKER_ARGV" || fail "tools: --build-arg $k missing"
done
[[ "$(cat "$DOCKER_ARGV")" == "buildx build "* && "$(cat "$DOCKER_ARGV")" == *" ." ]] || fail "the context is not the share root: $(cat "$DOCKER_ARGV")"
grep -q -- "--push\|--pull" "$DOCKER_ARGV" && fail "an image is pushed or pulled: $(cat "$DOCKER_ARGV")"

# image: its one tag, the SDK, the Swift of its Xcode, and every ARG of the Dockerfile that has no value of its own.
"$S" "${image[@]}" 2>/dev/null
has "--platform linux/arm64 --load --provenance=false -t xless:local-arm64-xcode26.6 -f docker/Dockerfile" image
has "--build-context sdk=d" image
has "--build-arg APP_SWIFT_VERSION=6.3.3" image
has "--build-arg XLESS_XCODE=26.6" image; has "--build-arg XLESS_XCODE_BUILD=17F113" image
[[ "$(grep -o -- ' -t ' "$DOCKER_ARGV" | wc -l | tr -d ' ')" == 1 ]] || fail "more than one tag: $(cat "$DOCKER_ARGV")"
grep -q -- "--push\|--target\|XLESS_FROM" "$DOCKER_ARGV" && fail "image: $(cat "$DOCKER_ARGV")"
while read -r k; do
  [[ "$k" == TARGETARCH ]] || grep -q -- "--build-arg $k=." "$DOCKER_ARGV" || fail "image: --build-arg $k missing"
done < <(sed -nE 's/^ARG ([A-Z0-9_]+)$/\1/p' "$root/docker/Dockerfile" | LC_ALL=C sort -u | grep -v '^APP_SWIFT_')
"$S" image --arch arm64 --xcode 26.0.1 --xcode-build 17A400 --sdk-dir d 2>/dev/null
has "-t xless:local-arm64-xcode26.0.1" "a patch release"
for bad in "" 26 latest 26.6.0 "26.6 x" -26.6 26.6-17F113; do refused "--xcode '$bad'" image --arch arm64 --xcode "$bad" --xcode-build 17F113 --sdk-dir d; done
refused "no --sdk-dir" image --arch arm64 --xcode 26.6 --xcode-build 17F113
refused "no --xcode-build" image --arch arm64 --xcode 26.6 --sdk-dir d
refused "no --xcode" image --arch arm64 --xcode-build 17F113 --sdk-dir d
refused "an unknown Xcode build" image --arch arm64 --xcode 26.6 --xcode-build NOPE --sdk-dir d
refused "an unknown architecture" tools --arch riscv64
for old in base sdk tauri rn; do refused "$old" $old --arch arm64 --suffix ''; grep -q "there is one image" "$t/err" || fail "$old: $(cat "$t/err")"; done

# a prebuilt xless: a fake ELF header (64 bytes, e_machine at offset 18: 183 aarch64, 62 x86-64).
# shellcheck disable=SC2059
fake_elf() { { printf '\177ELF\002\001\001'; head -c 11 /dev/zero; printf "$2"; head -c 44 /dev/zero; } > "$1"; }
mkdir "$t/bin" "$t/bin64"
fake_elf "$t/bin/xless" '\267\000'
fake_elf "$t/bin64/xless" '\076\000'
"$S" "${image[@]}" --xless-bin "$t/bin/xless" 2>/dev/null
has "--build-arg XLESS_FROM=prebuilt" prebuilt
has "--build-context xlessbin=$t/bin" prebuilt
: > "$t/bin/other"
refused "a binary not named xless" "${image[@]}" --xless-bin "$t/bin/other"
refused "--xless-bin for tools" tools --arch arm64 --xless-bin "$t/bin/xless"
# The binary's ELF machine must be --arch's: an x86-64 xless in an arm64 image (or the reverse) is refused.
"$S" image --arch amd64 --xcode 26.6 --xcode-build 17F113 --sdk-dir d --xless-bin "$t/bin64/xless" 2>/dev/null
has "-t xless:local-amd64-xcode26.6" "prebuilt amd64"
refused "an aarch64 xless for amd64" image --arch amd64 --xcode 26.6 --xcode-build 17F113 --sdk-dir d --xless-bin "$t/bin/xless"
grep -q "aarch64" "$t/err" && grep -q "amd64" "$t/err" || fail "the mismatch message: $(cat "$t/err")"
refused "an x86-64 xless for arm64" "${image[@]}" --xless-bin "$t/bin64/xless"
mkdir "$t/bintxt"; echo 'not elf' > "$t/bintxt/xless"
refused "a non-ELF xless" "${image[@]}" --xless-bin "$t/bintxt/xless"

# What the image says it is. Outside a git checkout: v<version>-<12 hex of sha256 versions.env>-xcode<V>-<B>; the version is
# the share directory's VERSION file's (a release), else versions.env's.
mkdir -p "$t/share"; cp -R "$root/scripts" "$root/versions.env" "$t/share/"
want="$( (sha256sum "$root/versions.env" 2>/dev/null || shasum -a 256 "$root/versions.env") | cut -c1-12)"
"$t/share/scripts/docker-images.sh" "${image[@]}" 2>/dev/null
has "--build-arg XLESS_IMAGE_ID=v0.0.0-dev-$want-xcode26.6-17F113" "image id"; has "--build-arg XLESS_VERSION=0.0.0-dev" version
echo 1.2.3 > "$t/share/VERSION"
"$t/share/scripts/docker-images.sh" "${image[@]}" 2>/dev/null
has "--build-arg XLESS_IMAGE_ID=v1.2.3-$want-xcode26.6-17F113" "image id of a release"; has "--build-arg XLESS_VERSION=1.2.3" "a release's version"
# Inside the checkout: the commit. safe.directory lets git read a checkout owned by another user (CI's container).
GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=safe.directory GIT_CONFIG_VALUE_0="$root" "$S" "${image[@]}" 2>/dev/null
grep -Eq -- "--build-arg XLESS_IMAGE_ID=[0-9a-f]{12}(-dirty)?-$want-xcode26.6-17F113( |$)" "$DOCKER_ARGV" || fail "image id in git: $(cat "$DOCKER_ARGV")"

# The Dockerfiles. Every FROM is the pinned Swift image, a stage, or (the kits') the local xless image.
D="$root/docker/Dockerfile"
grep -v '^#' "$D" > "$t/image"
grep -niE 'nodejs|node\.tar|corepack|pnpm|rustup|ruby|bundler|hermes' "$t/image" && fail "docker/Dockerfile holds a toolchain of another language (above)"
for what in xtool rcodesign swbuild 'docker/shims/' hfsprogs 'llvm ' 'dmg' toolchain-meta.json; do grep -q -- "$what" "$t/image" || fail "docker/Dockerfile has no $what"; done
for l in dev.xless.sdk dev.xless.xcode dev.xless.version dev.xless.arch dev.xless.image org.xless.image; do grep -qE "^LABEL .*$l=" "$D" || fail "docker/Dockerfile: no label $l"; done
for f in "$D" "$root"/docker/*/Dockerfile; do
  stages=" $(sed -nE 's/^FROM .* AS ([a-z-]+)$/\1/p' "$f" | tr '\n' ' ') scratch xless-\${XLESS_FROM} "
  while read -r from; do
    # shellcheck disable=SC2016
    case "$from" in '${SWIFT_IMAGE}'|'${XLESS_IMAGE}'|'${BUILD_IMAGE}') ;; *) [[ "$stages" == *" $from "* ]] || fail "$f builds on $from" ;; esac
  done < <(sed -nE 's/^FROM (--platform=[^ ]+ )?([^ ]+).*/\2/p' "$f")
  grep -n '^ADD ' "$f" && fail "$f: ADD (above)"
  # every download is checked
  [[ "$(grep -c 'curl -fsSL' "$f")" -le "$(grep -c 'sha256sum -c -' "$f")" ]] || fail "$f: a download without a checksum"
done
for k in tauri react-native; do
  f="$root/docker/$k/Dockerfile"
  # shellcheck disable=SC2016
  [[ "$(sed -nE 's/^FROM ([^ ]+)$/\1/p' "$f")" == '${XLESS_IMAGE}' ]] || fail "$k is not built on the xless image"
  grep -qx 'ARG XLESS_IMAGE' "$f" || fail "$k: the xless image has a default, which could be another one"
  # nothing of the machine that builds it, and no label of xless's own image
  grep -nE '^COPY --from=[a-z]+ ' "$f" >/dev/null || [[ "$k" == tauri ]] || fail "$k copies nothing"
  grep -nE '^COPY [^-]|dev\.xless|--mount=type=(secret|ssh)' "$f" && fail "$k: (above)"
  # hermesc is React Native's
  if [[ "$k" == tauri ]]; then grep -qi hermes "$f" && fail "hermesc in docker/tauri"; else grep -q 'hermesc -version' "$f" || fail "no hermesc in docker/react-native"; fi
done
grep -h '^ARG NODE_' "$root/docker/tauri/Dockerfile" | cmp -s - <(grep -h '^ARG NODE_' "$root/docker/react-native/Dockerfile") || fail "the kits pin different Nodes"
# the build context: what the Dockerfile copies, and nothing else of the checkout
[[ "$(grep -v '^#' "$root/docker/Dockerfile.dockerignore" | head -1)" == '*' ]] || fail "docker/Dockerfile.dockerignore does not start by leaving everything out"
echo "docker-images.test.sh: ok"
