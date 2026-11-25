#!/usr/bin/env bash
# Builds the xless image chain from one Xcode's SDK (Ruling R8): xless-base → xless (the Darwin SDK) → xless-tauri →
# xless-rn. The chain compiles app code with the Swift toolchain that Xcode ships (Ruling R10): scripts/xcode-swift.sh
# measures the Xcode's Swift and maps its build through versions.env's XCODE_SWIFT_<build> (an Xcode without an entry is
# refused); docker/Dockerfile.sdk installs that open-source release under /opt/xless/toolchains/ unless it is the
# image's own Swift (SWIFT_VERSION). A project pins its Xcode with `xcode: "<version>"` (xless.yml or an overlay); xless run selects
# the images made from that Xcode, and prepare (exit 19) and the build stage refuse an image whose SDK comes from another one.
# Usage: scripts/build-images.sh <Xcode.app | Xcode_*.xip> [arch ...]        (or: make images XCODE=<…> [ARCHS="arm64"])
#   Mac only: the SDK is exported from the Xcode bundle (`xless sdk export`, which runs `xtool sdk build` in xless-base).
#   arch: arm64 and/or amd64 (default: both).
#   A .xip is expanded once with `xip --expand` into ~/.cache/xless/xcode/<xip name>/ and reused from there (delete
#   that directory to reclaim its space). The docker VM must see the Xcode bundle: Colima shares $HOME, so keep an
#   Xcode.app under $HOME (e.g. `cp -cR /Applications/Xcode-26.2.app ~/.cache/xless/`), or share /Applications with it.
#   Tags (V = the Xcode's CFBundleShortVersionString as major.minor[.patch when not 0], e.g. 26.2; B = its
#   ProductBuildVersion, e.g. 17C52):
#     xless-base:local-<arch>-xcodeV-B  xless:local-<arch>-xcodeV-B  xless-tauri:…-xcodeV-B  xless-rn:…-xcodeV-B
#   which no other Xcode build ever moves, and the same names with -xcodeV, which a pin (xcode: "V") selects;
#   and, when the Xcode is versions.env's XCODE_VERSION/XCODE_BUILD (the default SDK), the plain local-<arch> tags too;
#   the plain tags are never moved to another Xcode.
#   Two builds of one version (a beta and the release): -xcodeV names one of them. When it names another build, the
#   script stops before building; XLESS_XCODE_RETAG=1 moves -xcodeV to this build (the other keeps its -xcodeV-B tags).
#   The exported SDK goes to dist/sdk-xcodeV/ (git-ignored): Apple SDK material lives only there and in the images.
#   A later run reuses it when it holds an export of the same Xcode build for every arch (XLESS_SDK_REEXPORT=1 exports again).
#   Docker: DOCKER_CONTEXT, default colima-xless when that context exists.
set -euo pipefail

die() { echo "build-images: $*" >&2; exit 2; }
[[ $# -ge 1 ]] || die "usage: $0 <Xcode.app | Xcode_*.xip> [arm64] [amd64]"
[[ "$(uname -s)" == Darwin ]] || die "run it on a Mac: the SDK is exported from an Xcode bundle (xless sdk export)"
repo="$(cd "$(dirname "$0")/.." && pwd)"
src="$1"; shift
archs=("$@"); [[ ${#archs[@]} -gt 0 ]] || archs=(arm64 amd64)
for a in "${archs[@]}"; do [[ "$a" == arm64 || "$a" == amd64 ]] || die "unknown architecture '$a' (use arm64 or amd64)"; done
case "$src" in "~/"*) src="$HOME/${src#\~/}" ;; esac
[[ -e "$src" ]] || die "$src does not exist"
src="$(cd "$(dirname "$src")" && pwd)/$(basename "$src")"

xcode="$src"
if [[ "$src" == *.xip ]]; then
  dest="$HOME/.cache/xless/xcode/$(basename "$src" .xip)"
  found() { find "$dest" -maxdepth 1 -name 'Xcode*.app' -type d 2>/dev/null | sort; }
  if [[ -z "$(found)" ]]; then
    # xip --expand writes into the current directory; it verifies Apple's signature on the archive as it expands.
    echo "==> expanding $(basename "$src") into $dest (xip --expand; this takes a while)" >&2
    mkdir -p "$dest"
    (cd "$dest" && xip --expand "$src")
  fi
  [[ "$(found | wc -l | tr -d ' ')" == 1 ]] || die "expected one Xcode*.app in $dest after xip --expand, found: $(found | tr '\n' ' ')"
  xcode="$(found)"
fi
[[ -d "$xcode" && -f "$xcode/Contents/version.plist" ]] || die "$xcode is not an Xcode.app (no Contents/version.plist)"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$xcode/Contents/version.plist")"
build="$(/usr/libexec/PlistBuddy -c 'Print :ProductBuildVersion' "$xcode/Contents/version.plist")"
[[ "$version" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]] || die "unexpected Xcode version '$version' in $xcode"
[[ "$build" =~ ^[0-9A-Za-z]+$ ]] || die "unexpected Xcode build '$build' in $xcode"
# As xless run looks a pin up: major.minor, plus the patch when it is not 0 (26.2.0 → 26.2).
canonical_xcode() { local IFS=.; local p=($1); local v="$((10#${p[0]})).$((10#${p[1]:-0}))"
  [[ -z "${p[2]:-}" ]] || [[ $((10#${p[2]})) -eq 0 ]] || v+=".$((10#${p[2]}))"; echo "$v"; }
version="$(canonical_xcode "$version")"
suffix="-xcode$version"
bsuffix="$suffix-$build"   # this Xcode build's own tags: never moved by another build of the same version
set -a; . "$repo/versions.env"; set +a
default=0; [[ "$version" == "$XCODE_VERSION" && "$build" == "$XCODE_BUILD" ]] && default=1
# Ruling R10: the app Swift toolchain for Dockerfile.sdk (scripts/docker-images.sh reads it again); refused before anything is built.
"$repo/scripts/xcode-swift.sh" "$build" >/dev/null || exit 2
# The asset and storyboard tools: an Xcode whose actool/ibtool/copypng formats are not measured (no XcodeToolsProfile entry)
# is refused, as the image's shims would refuse it.
"$repo/scripts/xcode-tools.sh" "$build" || exit 2
# The TARGET_OS_ macros of the Xcode's own clang, which docker/Dockerfile.sdk checks the image's clang against.
[[ -f "$repo/docker/toolchain/target-os/$build.txt" ]] \
  || die "docker/toolchain/target-os/$build.txt is missing: measure Xcode $version ($build)'s clang with scripts/target-os-macros.sh '$xcode' > docker/toolchain/target-os/$build.txt"

if [[ -z "${DOCKER_CONTEXT:-}" ]] && docker context ls --format '{{.Name}}' 2>/dev/null | grep -qx colima-xless; then
  export DOCKER_CONTEXT=colima-xless
fi
echo "==> Xcode $version ($build) at $xcode → images *:local-<arch>$bsuffix and *:local-<arch>$suffix for ${archs[*]}$([[ $default == 1 ]] && echo ", and the default local-<arch> tags")" >&2
echo "==> docker context: ${DOCKER_CONTEXT:-(current)}" >&2

# -xcodeV of another build of this version (a beta and the release): refused unless XLESS_XCODE_RETAG=1, before anything
# is built. Moving it first gives the other build's images their -xcodeV-B tags, so they stay usable (XLESS_IMAGE).
for a in "${archs[@]}"; do
  docker image inspect "xless:local-$a$suffix" >/dev/null 2>&1 || continue
  old="$(docker run --rm --platform "linux/$a" --entrypoint cat "xless:local-$a$suffix" /opt/xless/toolchain-meta.json 2>/dev/null \
    | tr -d '\n ' | sed -nE 's/.*"xcodeBuild":"([^"]*)".*/\1/p')" || true
  [[ -n "$old" && "$old" != "$build" ]] || continue
  [[ "${XLESS_XCODE_RETAG:-0}" == 1 ]] || die "the images *:local-$a$suffix are another build of Xcode $version ($old, this is $build); a pin xcode: \"$version\" selects them. To point them at this build: XLESS_XCODE_RETAG=1 make images XCODE=… (the $old images keep their *-xcode$version-$old tags)"
  for i in xless-base xless xless-tauri xless-rn; do
    if docker image inspect "$i:local-$a$suffix" >/dev/null 2>&1; then docker tag "$i:local-$a$suffix" "$i:local-$a$suffix-$old"; fi
  done
  echo "==> XLESS_XCODE_RETAG=1: *:local-$a$suffix moves from Xcode $version ($old) to $build; the $old images stay as *:local-$a$suffix-$old" >&2
done

export_sdk=1
sdk_dir="$repo/dist/sdk-xcode$version"
reuse=0
if [[ "${XLESS_SDK_REEXPORT:-0}" != 1 && -f "$sdk_dir/toolchain-meta.json" ]] && grep -Eq "\"xcodeBuild\" *: *\"$build\"" "$sdk_dir/toolchain-meta.json"; then
  reuse=1; for a in "${archs[@]}"; do [[ -d "$sdk_dir/$a/darwin.xtoolsdk" ]] || reuse=0; done
fi
if [[ $reuse == 1 ]]; then
  echo "==> reusing the SDK exported from Xcode $version ($build) in $sdk_dir (XLESS_SDK_REEXPORT=1 exports it again)" >&2
  export_sdk=0
  # Metadata exported before Ruling R10 lacks the Xcode's Swift version, which prepare and the build stage check: write it again
  # (the SDK itself is unchanged).
  if ! grep -q '"swiftVersion"' "$sdk_dir/toolchain-meta.json"; then
    echo "==> adding the Xcode's Swift version to $sdk_dir/toolchain-meta.json (xless sdk meta)" >&2
    (cd "$repo" && swift run xless sdk meta --xcode "$xcode" --out "$sdk_dir/toolchain-meta.json")
  fi
fi

start=$(date +%s)
images() { local i a; for a in "${archs[@]}"; do for i in "$@"; do
  local extra=(); [[ "$i" != sdk ]] || extra=(--sdk-dir "$sdk_dir" --xcode-build "$build")
  "$repo/scripts/docker-images.sh" "$i" --arch "$a" --suffix "$bsuffix" ${extra[@]+"${extra[@]}"} || exit 1
done; done; }
images base
# The Mac's own step: xless sdk export (xtool in the base image, Xcode mounted read-only). -o: the base images are built above.
[[ $export_sdk == 0 ]] || make -C "$repo" -o base-local sdk-export XCODE="$xcode" ARCHS="${archs[*]}" IMAGE_SUFFIX="$bsuffix" SDK_DIR="dist/sdk-xcode$version"
images sdk tauri rn

for a in "${archs[@]}"; do
  for i in xless-base xless xless-tauri xless-rn; do
    docker tag "$i:local-$a$bsuffix" "$i:local-$a$suffix"
    [[ $default == 0 ]] || docker tag "$i:local-$a$bsuffix" "$i:local-$a"
  done
done
# The SDK the images carry, as the build stage will read it.
for a in "${archs[@]}"; do
  meta="$(docker run --rm --platform "linux/$a" --entrypoint cat "xless-rn:local-$a$suffix" /opt/xless/toolchain-meta.json | tr -d '\n ')"
  swift="$(docker run --rm --platform "linux/$a" --entrypoint cat "xless-rn:local-$a$suffix" /opt/xless/swift-toolchain.json | tr -d '\n ')"
  echo "==> xless-rn:local-$a$suffix: Xcode build $(sed -E 's/.*"xcodeBuild":"([^"]*)".*/\1/' <<<"$meta"), SDK $(grep -o '"sdkName":"iphoneos[^"]*"' <<<"$meta" | cut -d'"' -f4), app Swift $(sed -E 's/.*"version":"([^"]*)".*/\1/' <<<"$swift") ($(sed -E 's/.*"root":"([^"]*)".*/\1/' <<<"$swift"))" >&2
done
echo "==> done in $(( ($(date +%s) - start) / 60 )) min; pin it with xcode: \"$version\"" >&2
