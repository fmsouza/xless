#!/usr/bin/env bash
# scripts/docker-images.sh: the one docker recipe of the xless image. A DOCKER stub records its argv; nothing is built. And
# what the Dockerfiles may hold: xless's job in docker/Dockerfile, the toolchains of other languages in the kits' alone, and
# nothing of an Xcode in any of them (the Xcode is an Xcode pack, which `xless setup` prepares).
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
image=(image --arch arm64)
# safe.directory lets git read a checkout owned by another user (CI's container).
in_git=(env GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=safe.directory GIT_CONFIG_VALUE_0="$root")
want="$( (sha256sum "$root/versions.env" 2>/dev/null || shasum -a 256 "$root/versions.env") | cut -c1-12)"

# image, in this checkout: the commit's tag, the platform, and every ARG of the Dockerfile that has no value of its own.
# Nothing of an Xcode: no SDK build context, no Xcode's version or build, no Swift of an Xcode, no Swift Build.
"${in_git[@]}" "$S" "${image[@]}" 2>/dev/null
grep -Eq -- "^buildx build --platform linux/arm64 --load --provenance=false -t xless:[0-9a-f]{12}(-dirty)?-arm64 -f docker/Dockerfile " "$DOCKER_ARGV" \
  || fail "image: $(cat "$DOCKER_ARGV")"
[[ "$(cat "$DOCKER_ARGV")" == *" ." ]] || fail "the context is not the share root: $(cat "$DOCKER_ARGV")"
[[ "$(grep -o -- ' -t ' "$DOCKER_ARGV" | wc -l | tr -d ' ')" == 1 ]] || fail "more than one tag: $(cat "$DOCKER_ARGV")"
grep -q -- "--push\|--pull\|--target\|XLESS_FROM" "$DOCKER_ARGV" && fail "image: $(cat "$DOCKER_ARGV")"
grep -qi -- "--build-context sdk=\|XLESS_XCODE\|APP_SWIFT_\|SWB_\|xcode" "$DOCKER_ARGV" && fail "image: something of an Xcode in: $(cat "$DOCKER_ARGV")"
while read -r k; do
  [[ "$k" == TARGETARCH ]] || grep -q -- "--build-arg $k=." "$DOCKER_ARGV" || fail "image: --build-arg $k missing"
done < <(sed -nE 's/^ARG ([A-Z0-9_]+)$/\1/p' "$root/docker/Dockerfile" | LC_ALL=C sort -u)
grep -Eq -- "--build-arg XLESS_IMAGE_ID=[0-9a-f]{12}(-dirty)?-$want( |$)" "$DOCKER_ARGV" || fail "image id in git: $(cat "$DOCKER_ARGV")"
"${in_git[@]}" "$S" image --arch amd64 2>/dev/null
grep -Eq -- "--platform linux/amd64 .* -t xless:[0-9a-f]{12}(-dirty)?-amd64 " "$DOCKER_ARGV" || fail "amd64: $(cat "$DOCKER_ARGV")"
# The tag, from the script's own `tag` mode (which tests/shell/fake-images.sh and the Swift test ImageName.tag(ofShare:) rely on).
[[ "$("${in_git[@]}" "$S" tag --arch arm64 2>/dev/null)" =~ ^[0-9a-f]{12}(-dirty)?$ ]] || fail "tag mode: $("${in_git[@]}" "$S" tag --arch arm64 2>&1)"
# ... a checkout reached through a symbolic link is still the checkout (its physical place is git's top): the commit's tag, not the release's
ln -s "$root" "$t/link"
linked_tag="$(GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=safe.directory GIT_CONFIG_VALUE_0="$root" "$t/link/scripts/docker-images.sh" tag --arch arm64 2>/dev/null)"
[[ "$linked_tag" == "$("${in_git[@]}" "$S" tag --arch arm64 2>/dev/null)" && "$linked_tag" =~ ^[0-9a-f]{12}(-dirty)?$ ]] || fail "through a link: '$linked_tag'"
GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=safe.directory GIT_CONFIG_VALUE_0="$root" "$t/link/scripts/docker-images.sh" image --arch arm64 2>/dev/null
grep -Eq -- " -t xless:[0-9a-f]{12}(-dirty)?-arm64 " "$DOCKER_ARGV" || fail "image through a link: $(cat "$DOCKER_ARGV")"
# a release: a share with a VERSION file and no git; and a checkout with no commit yet is no checkout
mkdir -p "$t/rel/scripts" "$t/nocommit/scripts"
for d in rel nocommit; do cp "$S" "$t/$d/scripts/"; cp "$root/versions.env" "$t/$d/"; done
echo 1.2.3 > "$t/rel/VERSION"
[[ "$("$t/rel/scripts/docker-images.sh" tag --arch arm64)" == 1.2.3 ]] || fail "release tag"
"$t/rel/scripts/docker-images.sh" image --arch amd64 2>/dev/null
grep -Eq -- " -t xless:1.2.3-amd64 " "$DOCKER_ARGV" || fail "release image: $(cat "$DOCKER_ARGV")"
git init -q "$t/nocommit"
[[ "$("$t/nocommit/scripts/docker-images.sh" tag --arch arm64)" == "$(sed -n 's/^XLESS_VERSION=//p' "$root/versions.env")" ]] || fail "a checkout with no commit: $("$t/nocommit/scripts/docker-images.sh" tag --arch arm64 2>&1)"
refused "an unknown architecture" image --arch riscv64
refused "no architecture" image
refused "an unknown option" image --arch arm64 --suffix x
# The Xcode went into the Xcode pack, which xless setup prepares: what built an image of one Xcode is refused, in one line
# that says so.
for old in "tools --arch arm64" "image --arch arm64 --xcode 26.6" "image --arch arm64 --xcode-build 17F113" "image --arch arm64 --sdk-dir d" \
           "image --arch arm64 --xcode 26.6 --xcode-build 17F113 --sdk-dir d"; do
  # shellcheck disable=SC2086
  refused "$old" $old
  [[ "$(wc -l < "$t/err" | tr -d ' ')" == 1 ]] && grep -q 'xless setup' "$t/err" || fail "$old: $(cat "$t/err")"
done
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
# The binary's ELF machine must be --arch's: an x86-64 xless in an arm64 image (or the reverse) is refused.
"$S" image --arch amd64 --xless-bin "$t/bin64/xless" 2>/dev/null
grep -Eq -- " -t xless:[^ ]+-amd64 " "$DOCKER_ARGV" || fail "prebuilt amd64: $(cat "$DOCKER_ARGV")"
refused "an aarch64 xless for amd64" image --arch amd64 --xless-bin "$t/bin/xless"
grep -q "aarch64" "$t/err" && grep -q "amd64" "$t/err" || fail "the mismatch message: $(cat "$t/err")"
refused "an x86-64 xless for arm64" "${image[@]}" --xless-bin "$t/bin64/xless"
mkdir "$t/bintxt"; echo 'not elf' > "$t/bintxt/xless"
refused "a non-ELF xless" "${image[@]}" --xless-bin "$t/bintxt/xless"

# What the image says it is, outside a git checkout (an installed share): the tag xless:<version>-<arch>, the id
# v<version>-<12 hex of sha256 versions.env>; the version is the share directory's VERSION file's (a release), else
# versions.env's.
mkdir -p "$t/share"; cp -R "$root/scripts" "$root/versions.env" "$t/share/"
"$t/share/scripts/docker-images.sh" "${image[@]}" 2>/dev/null
has "-t xless:0.0.0-dev-arm64" "tag"
has "--build-arg XLESS_IMAGE_ID=v0.0.0-dev-$want" "image id"; has "--build-arg XLESS_VERSION=0.0.0-dev" version
echo 1.2.3 > "$t/share/VERSION"
"$t/share/scripts/docker-images.sh" "${image[@]}" 2>/dev/null
has "-t xless:1.2.3-arm64" "a release's tag"
has "--build-arg XLESS_IMAGE_ID=v1.2.3-$want" "image id of a release"; has "--build-arg XLESS_VERSION=1.2.3" "a release's version"

# The Dockerfiles. Every FROM is the pinned Swift image, a stage, or (the kits') the local xless image.
D="$root/docker/Dockerfile"
grep -v '^#' "$D" > "$t/image"
grep -niE 'nodejs|node\.tar|corepack|pnpm|rustup|ruby|bundler|hermes' "$t/image" && fail "docker/Dockerfile holds a toolchain of another language (above)"
for what in xtool rcodesign 'docker/shims/' hfsprogs 'llvm ' 'dmg' libncurses-dev libsqlite3-dev \
            scripts/fit-toolchain.sh scripts/pack-swift-build.sh scripts/pack-check.sh docker/toolchain versions.env 'XLESS_XCODES=/xcodes'; do
  grep -q -- "$what" "$t/image" || fail "docker/Dockerfile has no $what"
done
# Nothing of an Xcode: no SDK, no Xcode's Swift toolchain or Swift Build, no label or argument naming one.
# (The store of packs, XLESS_XCODES=/xcodes, is the one word of it that may be there.)
sed -e 's/XLESS_XCODES//g' -e 's#/xcodes##g' "$t/image" \
  | grep -niE 'xcode|xtoolsdk|darwin\.artifactbundle|toolchain-meta|swift-toolchain\.json|APP_SWIFT|SWB_|swbuild|xtool sdk install|XDG_CONFIG_HOME|XLESS_TOOLCHAIN' \
  && fail "docker/Dockerfile holds something of an Xcode (above)"
for l in dev.xless.version dev.xless.arch dev.xless.image org.xless.image; do grep -qE "^LABEL .*$l=" "$D" || fail "docker/Dockerfile: no label $l"; done
grep -E '^LABEL ' "$D" | grep -iE 'sdk|xcode' && fail "docker/Dockerfile: a label of an Xcode (above)"
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
  # nothing that needs an Xcode's SDK at build time, and no word of one
  grep -niE "Apple's SDK|xcode[0-9]|-dynamiclib|-apple-ios|shims/prepare" "$f" && fail "$k: something of an Xcode (above)"
  # hermesc is React Native's
  if [[ "$k" == tauri ]]; then grep -qi hermes "$f" && fail "hermesc in docker/tauri"; else grep -q 'hermesc -version' "$f" || fail "no hermesc in docker/react-native"; fi
done
grep -h '^ARG NODE_' "$root/docker/tauri/Dockerfile" | cmp -s - <(grep -h '^ARG NODE_' "$root/docker/react-native/Dockerfile") || fail "the kits pin different Nodes"
# the build context: what the Dockerfile copies, and nothing else of the checkout
[[ "$(grep -v '^#' "$root/docker/Dockerfile.dockerignore" | head -1)" == '*' ]] || fail "docker/Dockerfile.dockerignore does not start by leaving everything out"
for f in versions.env scripts/fit-toolchain.sh scripts/pack-swift-build.sh scripts/pack-check.sh docker/toolchain docker/shims; do
  grep -qx "!$f" "$root/docker/Dockerfile.dockerignore" || fail "docker/Dockerfile.dockerignore leaves out $f, which the image copies"
done
echo "docker-images.test.sh: ok"
