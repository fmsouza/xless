#!/usr/bin/env bash
# Builds the xless image of one Xcode from this checkout (Ruling R8), as `xless setup --docker --xcode` does with a released xless:
# the Darwin SDK export, then xless:local-<arch>-xcode<version> (docker/Dockerfile) with the xless compiled here. It compiles app
# code with the Swift toolchain that Xcode ships (Ruling R10): scripts/xcode-swift.sh measures the Xcode's Swift and maps its build
# through versions.env's XCODE_SWIFT_<build> (an Xcode without an entry is refused); docker/Dockerfile installs that open-source
# release under /opt/xless/toolchains/ unless it is the image's own Swift (SWIFT_VERSION). A project pins its Xcode with
# `xcode: "<version>"` (xless.yml or an overlay); xless run selects the image of that Xcode, and prepare (exit 19) and the build
# stage refuse an image whose SDK comes from another one. The kits on top of it: `xless setup --docker --with tauri,react-native`
# (make kits), or the first xless run that needs one.
# Usage: scripts/build-images.sh <Xcode.app | Xcode_*.xip> [arch ...]        (or: make images XCODE=<…> [ARCHS="arm64"])
#   Mac only: the SDK is exported from the Xcode bundle (`xless sdk export`, which runs `xtool sdk build` in xless:local-<arch>-setup,
#   removed again at the end).
#   arch: arm64 and/or amd64 (default: both).
#   A .xip is expanded once with `xip --expand` into ~/.cache/xless/xcode/<xip name>/ and reused from there (delete
#   that directory to reclaim its space). The docker VM must see the Xcode bundle: Colima shares $HOME, so keep an
#   Xcode.app under $HOME (e.g. `cp -cR /Applications/Xcode-26.2.app ~/.cache/xless/`), or share /Applications with it.
#   The tag's version is the Xcode's CFBundleShortVersionString as major.minor[.patch when not 0], e.g. 26.2.
#   Two builds of one version (a beta and the release): the tag is one of them. When it is another build, the script stops before
#   building; XLESS_XCODE_RETAG=1 moves it to this build (the other stays as xless:local-<arch>-xcode<version>-<its build>).
#   The exported SDK goes to dist/sdk-xcode<version>/ (git-ignored): Apple SDK material lives only there and in the images.
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
# Ruling R10: the app Swift toolchain for docker/Dockerfile (scripts/docker-images.sh reads it again); refused before anything is built.
"$repo/scripts/xcode-swift.sh" "$build" >/dev/null || exit 2
# The asset and storyboard tools: an Xcode whose actool/ibtool/copypng formats are not measured (no XcodeToolsProfile entry)
# is refused, as the image's shims would refuse it.
"$repo/scripts/xcode-tools.sh" "$build" || exit 2
# The TARGET_OS_ macros of the Xcode's own clang, which docker/Dockerfile checks the image's clang against.
[[ -f "$repo/docker/toolchain/target-os/$build.txt" ]] \
  || die "docker/toolchain/target-os/$build.txt is missing: measure Xcode $version ($build)'s clang with scripts/target-os-macros.sh '$xcode' > docker/toolchain/target-os/$build.txt"

if [[ -z "${DOCKER_CONTEXT:-}" ]] && docker context ls --format '{{.Name}}' 2>/dev/null | grep -qx colima-xless; then
  export DOCKER_CONTEXT=colima-xless
fi
echo "==> Xcode $version ($build) at $xcode → xless:local-<arch>-xcode$version for ${archs[*]}" >&2
echo "==> docker context: ${DOCKER_CONTEXT:-(current)}" >&2

# The tag of another build of this version (a beta and the release): refused unless XLESS_XCODE_RETAG=1, before anything is built.
for a in "${archs[@]}"; do
  image="xless:local-$a-xcode$version"
  old="$(docker image inspect --format '{{index .Config.Labels "dev.xless.sdk"}}' "$image" 2>/dev/null)" || continue
  [[ -n "$old" && "$old" != "$build" ]] || continue
  [[ "$old" =~ ^[0-9A-Za-z]+$ ]] || die "$image has an unexpected Xcode build '$old'"
  [[ "${XLESS_XCODE_RETAG:-0}" == 1 ]] || die "$image is another build of Xcode $version ($old, this is $build); a pin xcode: \"$version\" selects it. To point it at this build: XLESS_XCODE_RETAG=1 make images XCODE=… (the $old image stays as $image-$old)"
  docker tag "$image" "$image-$old"
  echo "==> XLESS_XCODE_RETAG=1: $image moves from Xcode $version ($old) to $build; the $old image stays as $image-$old" >&2
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
if [[ $export_sdk == 1 ]]; then
  # The Mac's own step: xless sdk export (xtool in the tools image, the Xcode mounted read-only).
  for a in "${archs[@]}"; do "$repo/scripts/docker-images.sh" tools --arch "$a"; done
  make -C "$repo" sdk-export XCODE="$xcode" ARCHS="${archs[*]}" SDK_DIR="dist/sdk-xcode$version"
  for a in "${archs[@]}"; do docker image rm "xless:local-$a-setup" >/dev/null || true; done
fi
for a in "${archs[@]}"; do
  "$repo/scripts/docker-images.sh" image --arch "$a" --xcode "$version" --xcode-build "$build" --sdk-dir "$sdk_dir"
done
# The SDK the images carry, as the build stage will read it.
for a in "${archs[@]}"; do
  image="xless:local-$a-xcode$version"
  meta="$(docker run --rm --pull=never --platform "linux/$a" --entrypoint cat "$image" /opt/xless/toolchain-meta.json | tr -d '\n ')"
  swift="$(docker run --rm --pull=never --platform "linux/$a" --entrypoint cat "$image" /opt/xless/swift-toolchain.json | tr -d '\n ')"
  echo "==> $image: Xcode build $(sed -E 's/.*"xcodeBuild":"([^"]*)".*/\1/' <<<"$meta"), SDK $(grep -o '"sdkName":"iphoneos[^"]*"' <<<"$meta" | cut -d'"' -f4), app Swift $(sed -E 's/.*"version":"([^"]*)".*/\1/' <<<"$swift") ($(sed -E 's/.*"root":"([^"]*)".*/\1/' <<<"$swift"))" >&2
done
echo "==> done in $(( ($(date +%s) - start) / 60 )) min; pin it with xcode: \"$version\"" >&2
