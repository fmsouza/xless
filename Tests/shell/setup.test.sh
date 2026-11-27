#!/usr/bin/env bash
# `xless setup`, run against the built xless with a `docker` stub first on PATH (it records every call; nothing is built,
# nothing is downloaded): with --docker, the Docker preflight names the cause before any step runs, an unsupported file is
# refused with the supported releases, an Xcode xless cannot prepare a pack of is refused before docker is asked anything,
# and --dry-run prints the plan (the image, then the pack prepared by the image's xless setup in a container) of a fake .xip
# registered through a temp versions.env copy. Without --docker (native, on Linux): the missing host commands and the disk are checked first, --dry-run prints
# the native plan, and docker is never called; on a Mac it checks the installed Xcode and refuses any other source.
#   Tests/shell/setup.test.sh            (builds xless with `swift build`; XLESS_BIN=<path> uses that binary)
set -euo pipefail
repo="$(cd "$(dirname "$0")/../.." && pwd)"
t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT
fail() { echo "FAIL: $*"; exit 1; }
x="${XLESS_BIN:-}"
if [[ -z "$x" ]]; then
  (cd "$repo" && env -u DEVELOPER_DIR swift build --product xless -q)
  x="$(cd "$repo" && env -u DEVELOPER_DIR swift build --show-bin-path)/xless"
fi

mkdir -p "$t/bin" "$t/home"
cat > "$t/bin/docker" <<'D'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$DOCKER_LOG"
if [[ "$1" == info ]]; then
  case "$DOCKER_STUB" in
    perm) echo "permission denied while trying to connect to the Docker daemon socket at unix:///var/run/docker.sock: Get \"http://%2Fvar%2Frun%2Fdocker.sock/v1.47/info\": dial unix /var/run/docker.sock: connect: permission denied" >&2; exit 1 ;;
    down) echo "Cannot connect to the Docker daemon at unix:///var/run/docker.sock. Is the docker daemon running?" >&2; exit 1 ;;
  esac
  [[ -z "${DOCKER_ROOT:-}" ]] || echo "$DOCKER_ROOT|[]"
fi
# the images of $FAKE_IMAGES; a `build` adds the image its arguments name, and so does the image's `buildx build`
if [[ "$1 $2" == "context show" ]]; then echo here; fi
# the contexts of $STUB_CONTEXTS; none listed (nothing is checked) when it is not set
if [[ "$1 $2" == "context ls" ]]; then printf '%s\n' ${STUB_CONTEXTS:-}; fi
# a pack volume $STUB_IN_USE, which a running container uses
if [[ "$1 $2" == "volume ls" && -n "${STUB_IN_USE:-}" ]]; then echo "$STUB_IN_USE"; fi
if [[ "$1 $2" == "ps --filter" && -n "${STUB_IN_USE:-}" && "$3" == "volume=$STUB_IN_USE" ]]; then printf 'builder\txless:9.9.9-arm64\t77.1\n'; fi
if [[ -n "${FAKE_IMAGES:-}" ]]; then
  if [[ "$1" == image && "$2" != rm ]]; then exec "$FAKE" "$@"; fi
  if [[ "$1 $2" == "buildx build" ]]; then "$FAKE" base arm64 27.0 27A266a >> "$FAKE_IMAGES"; fi
  if [[ "$1" == build && -z "${BUILD_LOST:-}" ]]; then
    for a in "$@"; do case "$a" in dev.xless.kit=*) kit="${a#dev.xless.kit=}" ;; esac; done
    "$FAKE" kit "$kit" "$XLESS_SHARE" arm64 27.0 27A266a >> "$FAKE_IMAGES"
    echo "builder=${BUILDX_BUILDER-unset} buildkit=${DOCKER_BUILDKIT-unset}" >> "$DOCKER_LOG"
  fi
fi
exit 0
D
chmod +x "$t/bin/docker"
# The native preflight's host commands that a CI runner may lack (the setups here never run them): stubs, when missing.
for c in curl tar gzip unzip zip git python3 cpio; do
  [ -x "/usr/bin/$c" ] || [ -x "/bin/$c" ] || { printf '#!/bin/sh\nexit 1\n' > "$t/bin/$c"; chmod +x "$t/bin/$c"; }
done
log="$t/docker.log"
run() {   # STUB ARGS…: runs xless setup with a clean environment; stdout → $t/out, stderr → $t/err, exit code → $code
  local stub="$1"; shift
  : > "$log"; code=0
  env -i HOME="$t/home" PATH="${path:-$t/bin:/usr/bin:/bin}" XLESS_SHARE="${share:-$repo}" DOCKER_STUB="$stub" DOCKER_LOG="$log" FAKE="$repo/Tests/shell/fake-images.sh" \
    ${extra[@]+"${extra[@]}"} "$x" setup "$@" >"$t/out" 2>"$t/err" || code=$?
}

# A fake Xcode.app of the default release (a synthetic version.plist, no Apple file).
app="$t/Xcode.app"
mkdir -p "$app/Contents"
cat > "$app/Contents/version.plist" <<'P'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleShortVersionString</key><string>27.0</string>
<key>ProductBuildVersion</key><string>27A266a</string>
</dict></plist>
P

# The user is not in the docker group: exit 11, the cause and the fix named, nothing run.
run perm --docker --xcode "$app" --arch arm64
[[ $code == 11 ]] || fail "permission denied exits $code, want 11: $(cat "$t/err")"
grep -q '^error: \[sdk\]' "$t/err" || fail "no [sdk] error: $(cat "$t/err")"
grep -qi 'permission denied' "$t/err" || fail "the cause is not named: $(cat "$t/err")"
grep -q 'docker group' "$t/err" || fail "the fix does not mention the docker group: $(cat "$t/err")"
grep -q '^run\|^buildx\|^tag' "$log" && fail "docker was used past the preflight: $(cat "$log")"

# The daemon is not running: exit 11, start Docker.
run down --docker --xcode "$app" --arch arm64
[[ $code == 11 ]] || fail "cannot connect exits $code, want 11: $(cat "$t/err")"
grep -q 'start Docker' "$t/err" || fail "the fix does not say to start Docker: $(cat "$t/err")"
grep -q 'docker group' "$t/err" && fail "cannot connect blamed the docker group: $(cat "$t/err")"

# Not enough room in the cache: exit 11 before any step, naming the path, free and needed GB, and the override variable.
extra=(XLESS_SETUP_CACHE_GB=999999)
run ok --docker --xcode "$app" --arch arm64
[[ $code == 11 ]] || fail "a full cache exits $code, want 11: $(cat "$t/err")"
grep -qE "GB free under $t/home for the cache .*needs about 999999 GB there" "$t/err" || fail "cache refusal: $(cat "$t/err")"
grep -q 'set XLESS_SETUP_CACHE_GB' "$t/err" || fail "the cache refusal does not name XLESS_SETUP_CACHE_GB: $(cat "$t/err")"
grep -q '^run\|^buildx build' "$log" && fail "docker was used past the disk check: $(cat "$log")"
# Two architectures double the figure.
extra=(XLESS_SETUP_CACHE_GB=999999)
run ok --docker --xcode "$app" --arch arm64 --arch amd64
grep -q 'needs about 1999998 GB (999999 GB per architecture × 2) there' "$t/err" || fail "two-arch cache refusal: $(cat "$t/err")"
# Docker's data root (checked on Linux only): its own figure and variable.
if [[ "$(uname)" == Linux ]]; then
  mkdir -p "$t/dockerroot"
  extra=(XLESS_SETUP_CACHE_GB=0 XLESS_SETUP_DOCKER_GB=999999 DOCKER_ROOT="$t/dockerroot")
  run ok --docker --xcode "$app" --arch arm64
  [[ $code == 11 ]] || fail "a full Docker data root exits $code, want 11: $(cat "$t/err")"
  grep -q "GB free under $t/dockerroot for Docker's data root" "$t/err" || fail "docker root refusal: $(cat "$t/err")"
  grep -q 'set XLESS_SETUP_DOCKER_GB' "$t/err" || fail "the docker refusal does not name XLESS_SETUP_DOCKER_GB: $(cat "$t/err")"
fi
extra=()

# Not an Xcode at all: exit 11 with the supported releases, before docker is asked anything.
echo hello > "$t/hostname"
run ok --docker --xcode "$t/hostname"
[[ $code == 11 ]] || fail "an unsupported file exits $code, want 11: $(cat "$t/err")"
grep -q 'is not a supported Xcode (supported: Xcode 26.0.1 (17A400), Xcode 26.1 (17B55), Xcode 26.1.1 (17B100), Xcode 26.2 (17C52), Xcode 26.3 (17C529), Xcode 26.4 (17E192), Xcode 26.4.1 (17E202), Xcode 26.5 (17F42), Xcode 26.6 (17F113), Xcode 27.0 (27A266a), Xcode 27.1 (27A9275), Xcode 27.2 (27B52))' "$t/err" || fail "supported list: $(cat "$t/err")"
[[ ! -s "$log" ]] || fail "docker was called for an unsupported Xcode: $(cat "$log")"

# --dry-run: a fake .xip (any name, a path with spaces) registered by its sha256 in a temp copy of versions.env.
share="$t/share"
mkdir -p "$share/scripts" "$t/my downloads"
cp -R "$repo/docker" "$share/docker"
# what the pack's recipe hashes read
cp "$repo/scripts/fit-toolchain.sh" "$repo/scripts/pack-swift-build.sh" "$share/scripts/"
xip="$t/my downloads/Xcode copy.xip"
head -c 100000 /dev/zero | tr '\0' 'x' > "$xip"
sum="$( (sha256sum "$xip" 2>/dev/null || shasum -a 256 "$xip") | cut -d' ' -f1)"
sed "s/^XCODE_XIP_SHA256_27A266a=.*/XCODE_XIP_SHA256_27A266a=\"$sum\"/" "$repo/versions.env" > "$share/versions.env"
grep -q "$sum" "$share/versions.env" || fail "could not register the fake .xip"
# The image is named after this xless: the copy of the share is no checkout, so its version; the repository's is its commit.
st="$("$repo/Tests/shell/fake-images.sh" tag "$share")"; rt="$("$repo/Tests/shell/fake-images.sh" tag)"
run ok --docker --xcode "$xip" --arch arm64 --dry-run
[[ $code == 0 ]] || fail "--dry-run exits $code: $(cat "$t/err")"
# The image takes no Xcode; the pack is prepared by the image's own xless setup, which exports the SDK into the host's cache.
grep -qx "\[1/4\] xless:$st-arm64 (.*)" "$t/out" || fail "the plan does not name the image: $(cat "$t/out")"
grep -q 'docker-images.sh image --arch arm64 --xless-bin ' "$t/out" || fail "the plan does not build the image: $(cat "$t/out")"
grep -qF -- "--xcode-build" "$t/out" && fail "the image is given an Xcode: $(cat "$t/out")"
grep -qF "docker volume create --label org.xless.pack=true xless-xcode-27.0-27A266a-arm64" "$t/out" || fail "no volume for the pack: $(cat "$t/out")"
grep -qF "chown" "$t/out" || fail "the volume is not made the user's: $(cat "$t/out")"
pk="$(grep -F 'xless setup --xcode' "$t/out" || true)"
[[ -n "$pk" ]] || fail "the plan does not prepare the pack in the image: $(cat "$t/out")"
for want in "docker run --rm --pull=never --platform linux/arm64 --user $(id -u):$(id -g) -e HOME=/tmp " "src=$xip,dst=/xcode/Xcode copy.xip,readonly" \
            "type=bind,src=$t/home/.cache/xless/sdk/xcode27.0-27A266a,dst=/cache/xless/sdk/xcode27.0-27A266a " "-e XDG_CACHE_HOME=/cache" \
            "--mount type=volume,src=xless-xcode-27.0-27A266a-arm64,dst=/xcodes --label xless.setup=27.0-27A266a-arm64 xless:$st-arm64 xless setup --xcode '/xcode/Xcode copy.xip'"; do
  grep -qF -- "$want" <<<"$pk" || fail "the pack's container lacks '$want': $pk"
done
grep -q 'xtool sdk build\|xless sdk meta' "$t/out" && fail "the host exports the SDK: $(cat "$t/out")"
grep -q 'disk: the check asks for about .* GB free under .* (XLESS_SETUP_CACHE_GB)' "$t/out" || fail "--dry-run does not print the disk check: $(cat "$t/out")"
grep -q 'xless-base\|xless-tauri\|xless-rn\|docker build ' "$t/out" && fail "the plan builds more than one image: $(cat "$t/out")"
grep -q '^run\|^volume create\|^buildx' "$log" && fail "--dry-run ran docker: $(cat "$log")"
[[ ! -e "$t/home/.cache/xless/sdk" ]] || fail "--dry-run made the export's directory"
grep -q 'next: xless run' "$t/out" && fail "--dry-run promised the next step"
# The docker is chosen as `xless run` chooses it: a DOCKER_CONTEXT that docker does not have stops the setup (exit 2) before
# docker is asked anything else, naming where it was set and the contexts there are; one it has is given to every docker command.
extra=(DOCKER_CONTEXT=gone STUB_CONTEXTS="colima default")
run ok --docker --xcode "$xip" --arch arm64 --dry-run
[[ $code == 2 ]] || fail "a missing context: exit $code: $(cat "$t/err")"
grep -qxF "error: [config] DOCKER_CONTEXT is gone (set in the environment), but docker has no context of that name; its contexts: colima, default — set DOCKER_CONTEXT to one of them in the environment, or remove it there: xless then uses colima-xless when that context exists and DOCKER_HOST is not set, else docker's current one" "$t/err" \
  || fail "a missing context's message: $(cat "$t/err")"
[[ "$(cat "$log")" == "context ls --format {{.Name}}" ]] || fail "docker asked more than its contexts: $(cat "$log")"
printf 'DOCKER_CONTEXT=gone\n' > "$t/run.env"
extra=(XLESS_TESTFLIGHT_ENV="$t/run.env" DOCKER_CONTEXT=colima STUB_CONTEXTS="colima default")
run ok --docker --xcode "$xip" --arch arm64 --dry-run
[[ $code == 2 ]] && grep -qF "DOCKER_CONTEXT is gone (set in $t/run.env)" "$t/err" || fail "the run's file of settings is not read: $code $(cat "$t/err")"
extra=(STUB_CONTEXTS="default colima-xless")
run ok --docker --xcode "$xip" --arch arm64 --dry-run
[[ $code == 0 ]] || fail "colima-xless: exit $code: $(cat "$t/err")"
grep -q '^--context colima-xless ' "$log" || fail "no docker command with the context: $(cat "$log")"
grep -v '^context ls' "$log" | grep -qv '^--context colima-xless ' && fail "a docker command without the context: $(cat "$log")"
extra=()
# The xless that goes into the image is always a copy in the setup work dir (<arch>-bin/xless): its source directory
# (~/.local/bin, say) is never what docker-images.sh gets as the build context.
mkdir -p "$t/ext"; echo stub > "$t/ext/xless"; echo "do not send me to docker" > "$t/ext/other-file"
extra=(XLESS_BIN_ARM64="$t/ext/xless")
run ok --docker --xcode "$xip" --arch arm64 --dry-run
[[ $code == 0 ]] || fail "--dry-run with XLESS_BIN_ARM64 exits $code: $(cat "$t/err")"
binline="$(grep 'docker-images.sh' "$t/out" | grep -E '(^|[ =])[^ ]*xless-setup-[^ /]*/arm64-bin/xless' || true)"
[[ -n "$binline" ]] || fail "the build context is not the work dir's arm64-bin/xless: $(cat "$t/out")"
grep -F "$t/ext" "$t/out" && fail "the plan names the binary's own directory $t/ext: $(cat "$t/out")"
extra=()
# --with: the kits too, by the kinds of app they are for, each once; another name, or a native setup, is refused.
run ok --docker --xcode "$xip" --arch arm64 --with cargo,react-native,tauri --dry-run
[[ $code == 0 ]] || fail "--with exits $code: $(cat "$t/err")"
grep -q "^\[5/6\] xless:$st-arm64-tauri: " "$t/out" && grep -q "^\[6/6\] xless:$st-arm64-react-native: " "$t/out" || fail "--with plans: $(cat "$t/out")"
for bad in rust '' ','; do
  run ok --docker --xcode "$xip" --with "$bad" --dry-run
  [[ $code == 11 ]] && grep -q 'tauri, cargo, react-native, expo' "$t/err" || fail "--with '$bad': $code $(cat "$t/err")"
done
run ok --xcode "$xip" --with tauri --dry-run
[[ $code == 11 ]] && grep -q 'add --docker' "$t/err" || fail "--with without --docker: $code $(cat "$t/err")"
# The same .xip under the default (unregistered) table is refused: identification is by content.
share="$repo" run ok --docker --xcode "$xip" --dry-run
[[ $code == 11 ]] || fail "an unregistered .xip exits $code, want 11"

# --with alone: the kits, on the image of this xless that is here. Nothing is exported, pulled or pushed, and an image that is
# there already is not built again. docker's own builder builds it: another could not see the local image.
img="$repo/Tests/shell/fake-images.sh"; images="$t/images"
{ "$img" base arm64 27.0 27A266a; "$img" base arm64 26.6 17F113; } > "$images"
extra=(FAKE_IMAGES="$images" BUILDX_BUILDER=other DOCKER_BUILDKIT=0)
share="$repo" run ok --docker --arch arm64 --with tauri,expo --dry-run
planned="$(sed -n 's/^    docker //p' "$t/out")"
[[ $code == 0 ]] || fail "--with alone, dry run, exits $code: $(cat "$t/err")"
[[ "$(sed -n 1p "$t/out")" == "==> the image xless:$rt-arm64, and the kits tauri, react-native on it" ]] || fail "--with alone is on: $(cat "$t/out")"
grep -q 'docker-images.sh\|xless setup' "$t/out" && fail "--with alone plans more than the kits: $(cat "$t/out")"
grep -q '^build\|^run' "$log" && fail "--dry-run built: $(cat "$log")"
share="$repo" run ok --docker --arch arm64 --with tauri,expo
[[ $code == 0 ]] || fail "--with alone exits $code: $(cat "$t/err")"
[[ "$(grep -c '^build ' "$log")" == 2 && "$(grep -c '^builder=unset buildkit=unset$' "$log")" == 2 ]] || fail "--with alone runs: $(cat "$log")"
[[ "$(grep '^build ' "$log")" == "$planned" ]] || fail "the dry run shows: $planned"
grep -q "^build --builder here --platform linux/arm64 --pull=false --provenance=false --build-arg XLESS_IMAGE=xless:$rt-arm64 --label dev.xless.kit=tauri --label dev.xless.kit.base=sha256:base27.0 --label dev.xless.kit.recipe=[0-9a-f]* -t xless:$rt-arm64-tauri $repo/docker/tauri$" "$log" || fail "the kit's build: $(cat "$log")"
grep -q -- '--push\|^pull\|^push\|^buildx build' "$log" && fail "--with alone runs: $(cat "$log")"
share="$repo" run ok --docker --arch arm64 --with tauri,expo
[[ $code == 0 ]] && ! grep -q '^build ' "$log" || fail "built again: $code $(cat "$log")"
grep -q 'it is there already' "$t/out" || fail "not said to be there: $(cat "$t/out")"
# A build that leaves no image of that kit (or one on something else) is a failure.
"$img" base arm64 27.0 27A266a > "$images"
extra=(FAKE_IMAGES="$images" BUILD_LOST=1)
share="$repo" run ok --docker --arch arm64 --with tauri
[[ $code == 11 ]] && grep -q "xless:$rt-arm64-tauri is not what was built" "$t/err" || fail "a lost build: $code $(cat "$t/err")"
# No image here: it is built first (it needs no Xcode; a checkout's compiles its own xless), then the kit on it.
: > "$images"
extra=(FAKE_IMAGES="$images")
share="$repo" run ok --docker --arch arm64 --with tauri
[[ $code == 0 ]] || fail "--with alone without an image: $code $(cat "$t/err")"
grep -q "^buildx build --platform linux/arm64 --load --provenance=false -t xless:$rt-arm64 " "$log" && ! grep -q -- '--xless-bin\|xlessbin' "$log" \
  && [[ "$(grep -c '^build ' "$log")" == 1 ]] || fail "--with alone without an image runs: $(cat "$log")"
extra=()

# Native (the default).
case "$(uname -m)" in arm64|aarch64) host=arm64 other=amd64 dl=aarch64 ;; *) host=amd64 other=arm64 dl=x86_64 ;; esac
run ok --xcode "$xip" --arch "$other" --dry-run
[[ $code == 11 ]] || fail "native --arch $other exits $code, want 11: $(cat "$t/err")"
grep -q 'needs --docker' "$t/err" || fail "native --arch refusal: $(cat "$t/err")"
if [[ "$(uname)" != Linux ]]; then
  # A Mac builds with its own Xcode: nothing is exported, downloaded or built.
  run ok --xcode "$xip" --dry-run
  [[ $code == 11 ]] || fail "native setup from a .xip on a Mac exits $code, want 11: $(cat "$t/err")"
  grep -q 'builds with the Xcode that is installed' "$t/err" && grep -q 'xless setup --docker' "$t/err" || fail "a .xip on a Mac: $(cat "$t/err")"
  mkdir -p "$t/Not.app/Contents/Developer"
  extra=(DEVELOPER_DIR="$t/Not.app/Contents/Developer")
  run ok
  [[ $code == 11 ]] && grep -q 'is not in an Xcode' "$t/err" || fail "a directory that is no Xcode: $code $(cat "$t/err")"
  # one that says it is an Xcode, and is not Apple's
  printf '%s' '<?xml version="1.0"?><plist version="1.0"><dict><key>CFBundleShortVersionString</key><string>99.0</string><key>ProductBuildVersion</key><string>99A1</string></dict></plist>' > "$t/Not.app/Contents/version.plist"
  mkdir -p "$t/Not.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin"
  cp /usr/bin/true "$t/Not.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift"
  run ok
  [[ $code == 11 ]] && grep -q 'is not used: it has no swift-build' "$t/err" || fail "a planted Xcode: $code $(cat "$t/err")"
  for tool in swift-build clang ld; do cp /usr/bin/true "$t/Not.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/$tool"; done
  run ok
  [[ $code == 11 ]] && grep -q 'Not.app is not signed by Apple' "$t/err" || fail "a planted Xcode: $code $(cat "$t/err")"
  extra=()
  if [[ "$(xcode-select -p 2>/dev/null)" == *.app/Contents/Developer ]]; then
    run ok
    [[ $code == 0 ]] && grep -q '^==> Xcode ' "$t/out" && grep -q '^==> ready: nothing to install' "$t/out" || fail "a Mac with Xcode: $code $(cat "$t/out" "$t/err")"
    [[ ! -e "$t/home/.local" && ! -e "$t/home/.cache" ]] || fail "xless setup on a Mac wrote $(ls -a "$t/home")"
    # Around the signature of the real one: its own program, Info.plist and list of files, links to its programs, and one that is
    # another. It is refused before anything of it is started.
    real="$(cd "$(xcode-select -p)/../.." && pwd -P)" forged="$t/Forged.app" run="$t/started"
    bin=Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin
    forge() {
      local tool
      chmod -RN "$forged" 2>/dev/null || true; rm -rf "$forged"
      mkdir -p "$forged/Contents/MacOS" "$forged/$bin" "$forged/Contents/Developer/usr/bin"
      cp "$real/Contents/MacOS/Xcode" "$forged/Contents/MacOS/"; cp -R "$real/Contents/_CodeSignature" "$forged/Contents/"
      cp "$real/Contents/Info.plist" "$real/Contents/version.plist" "$forged/Contents/"
      ln -s "$real/Contents/Developer/Platforms" "$forged/Contents/Developer/Platforms"
      for tool in swift swift-build swift-package clang ld install_name_tool; do ln -s "$real/$bin/$tool" "$forged/$bin/$tool"; done
      for tool in actool ibtool xcodebuild; do ln -s "$real/Contents/Developer/usr/bin/$tool" "$forged/Contents/Developer/usr/bin/$tool"; done
      chmod -R go-w "$forged"
    }
    extra=(DEVELOPER_DIR="$forged/Contents/Developer")
    for tool in $bin/swift $bin/swift-build $bin/swift-package $bin/clang $bin/ld $bin/install_name_tool Contents/Developer/usr/bin/actool Contents/Developer/usr/bin/ibtool Contents/Developer/usr/bin/xcodebuild; do
      forge; rm "$forged/$tool"; printf '#!/bin/sh\ntouch "%s"\n' "$run" > "$forged/$tool"; chmod 755 "$forged/$tool"
      run ok
      [[ $code == 11 ]] && grep -q "is not used: .*/${tool##*/} is no program" "$t/err" || fail "an Xcode with a script as ${tool##*/}: $code $(cat "$t/err")"
      forge; rm "$forged/$tool"; cp /bin/sh "$forged/$tool"; chmod 755 "$forged/$tool"
      run ok
      [[ $code == 11 ]] && grep -q "is not used: .*/${tool##*/} is not signed by Apple as " "$t/err" || fail "an Xcode with Apple's shell as ${tool##*/}: $code $(cat "$t/err")"
    done
    forge; chmod +a 'everyone allow add_file,delete_child' "$forged/$bin"
    run ok
    [[ $code == 11 ]] && grep -q 'can be written by other users (its access control list' "$t/err" || fail "an Xcode with an access control list: $code $(cat "$t/err")"
    forge; chmod 777 "$forged/Contents/Developer/usr/bin"
    run ok
    [[ $code == 11 ]] && grep -q 'Contents/Developer/usr/bin can be written by other users' "$t/err" || fail "an Xcode that others may write: $code $(cat "$t/err")"
    chmod -RN "$forged"
    [[ ! -e "$run" ]] || fail "a program of a refused Xcode was started"
    extra=()
  fi
  [[ ! -s "$log" ]] || fail "xless setup on a Mac called docker: $(cat "$log")"
else
  # The pack's recipe hashes the fit's script.
  mkdir -p "$share/scripts" && cp "$repo/scripts/fit-toolchain.sh" "$share/scripts/"
  extra=(XLESS_NATIVE_HOME="$t/native")
  run ok --xcode "$xip" --dry-run
  [[ $code == 0 ]] || fail "native --dry-run exits $code: $(cat "$t/err")"
  pk="$t/native/xcodes/27.0-27A266a-$host"
  for want in "natively for $host: the pack 27.0-27A266a-$host in $t/native/xcodes; tools in $t/native" "xtool-$dl.AppImage" "apple-codesign-" \
              "$t/native/bin/xtool sdk build" "-o $pk.partial/toolchain.partial.download" "darwin.xtoolsdk $t/native/bin/xtool" \
              "scripts/fit-toolchain.sh $pk.partial own" "put the pack in place: $pk" "under $t/native/xcodes (XLESS_SETUP_NATIVE_GB)"; do
    grep -qF -- "$want" "$t/out" || fail "the native plan lacks '$want': $(cat "$t/out")"
  done
  # Nothing of the native install of before the packs, and no Swift Build on a host without the shims.
  grep -q 'toolchains/swift-\|xless sdk install\|native-toolchain\|pack-swift-build\|pack-check' "$t/out" && fail "the native plan: $(cat "$t/out")"
  [[ ! -s "$log" ]] || fail "a native setup called docker: $(cat "$log")"
  [[ ! -e "$t/native" ]] || fail "--dry-run wrote $t/native"
  # A host without python3 (and the rest): refused before anything runs, every missing command and the apt line named.
  mkdir -p "$t/few"; for c in curl tar; do printf '#!/bin/sh\n' > "$t/few/$c"; chmod +x "$t/few/$c"; done
  path="$t/few" run ok --xcode "$xip"
  [[ $code == 11 ]] || fail "missing commands exit $code, want 11: $(cat "$t/err")"
  grep -q 'python3' "$t/err" && grep -q 'unzip' "$t/err" && grep -q 'sudo apt-get install -y' "$t/err" || fail "missing commands refusal: $(cat "$t/err")"
  sed -n 's/.*needs \(.*\), which.*/\1/p' "$t/err" | grep -q curl && fail "curl named as missing: $(cat "$t/err")"
  [[ ! -e "$t/native" ]] || fail "a refused setup wrote $t/native"
  # Not enough room for the native install: exit 11, naming the variable, nothing installed.
  extra=(XLESS_NATIVE_HOME="$t/native" XLESS_SETUP_CACHE_GB=0 XLESS_SETUP_NATIVE_GB=999999)
  # (only where this host has every command, or the commands refusal would come first)
  if [[ -z "$(for c in curl tar gzip unzip zip git python3; do command -v "$c" >/dev/null || echo "$c"; done)" ]]; then
    run ok --xcode "$xip"
    [[ $code == 11 ]] || fail "a full native home exits $code, want 11: $(cat "$t/err")"
    grep -q "GB free under $t/native/xcodes for the Xcode pack" "$t/err" && grep -q 'set XLESS_SETUP_NATIVE_GB' "$t/err" || fail "native disk refusal: $(cat "$t/err")"
    [[ ! -e "$t/native/tools" ]] || fail "a refused setup installed tools"
    [[ -z "$(find "$t/native/xcodes" -mindepth 1 ! -name '*.lock')" ]] || fail "a refused setup wrote into the store: $(ls -A "$t/native/xcodes")"
  fi
  extra=()
fi

# Reusing an SDK export instead of the Xcode (issue #51): --sdk <dir>, or with neither --xcode nor --sdk the cache's one export.
share="$repo"
export_meta() {   # DIR BUILD ARCH…: a fake export (no Apple file): <arch>/darwin.xtoolsdk and toolchain-meta.json naming BUILD
  local dir="$1" build="$2"; shift 2
  for a in "$@"; do mkdir -p "$dir/$a/darwin.xtoolsdk/Developer"; done
  printf '{"xcodeVersion":"2700","xcodeBuild":"%s","buildMachineOSBuild":"26A434","compiler":"com.apple.compilers.llvm.clang.1_0","platforms":{}}\n' \
    "$build" > "$dir/toolchain-meta.json"
}
run ok --docker --xcode "$app" --sdk "$t/nowhere" --dry-run
[[ $code == 11 ]] && grep -q -- '--xcode and --sdk both' "$t/err" || fail "--xcode with --sdk: $code $(cat "$t/err")"
run ok --docker --reexport --dry-run
[[ $code == 11 ]] && grep -q -- '--reexport exports the SDK again, which needs the Xcode' "$t/err" || fail "--reexport without --xcode: $code $(cat "$t/err")"
# Nothing to reuse: the image alone (it needs no Xcode), and the command that adds a pack.
run ok --docker --arch arm64 --dry-run
[[ $code == 0 ]] || fail "no --xcode and no export exits $code: $(cat "$t/err")"
grep -q "^\[1/1\] xless:$rt-arm64 " "$t/out" && grep -q "no Xcode pack is prepared (no --xcode, and no SDK export in $t/home/.cache/xless/sdk): xless setup --docker --xcode" "$t/out" \
  || fail "the image alone: $(cat "$t/out")"
grep -q '^run\|^buildx\|^volume' "$log" && fail "--dry-run ran docker: $(cat "$log")"
# Natively there is nothing to do without one: refused, naming --xcode (on a Mac, the installed Xcode is checked instead).
if [[ "$(uname)" == Linux ]]; then
  run ok --arch arm64 --dry-run
  [[ $code == 11 ]] && grep -q "no --xcode, and no SDK export under $t/home/.cache/xless/sdk to reuse" "$t/err" || fail "native, no export: $code $(cat "$t/err")"
fi
# The cache's one export: the images are planned from it, nothing is exported and the cache needs no room.
cached="$t/home/.cache/xless/sdk/xcode27.0-27A266a"
export_meta "$cached" 27A266a arm64
run ok --docker --arch arm64 --dry-run
[[ $code == 0 ]] || fail "--docker from the cache's export exits $code: $(cat "$t/err")"
grep -qF "from its SDK export $cached (no Xcode needed)" "$t/out" || fail "the plan does not name the export: $(cat "$t/out")"
grep -q 'xtool sdk build' "$t/out" && fail "the plan exports from an export: $(cat "$t/out")"
grep -qF -- "--mount type=bind,src=$cached,dst=/cache/xless/sdk/xcode27.0-27A266a,readonly -e XDG_CACHE_HOME=/cache" "$t/out" \
  && grep -qF -- "xless setup --sdk /cache/xless/sdk/xcode27.0-27A266a" "$t/out" || fail "the pack is not prepared from the export: $(cat "$t/out")"
grep -qF -- "dst=/xcode/" "$t/out" && fail "an export mounts an Xcode: $(cat "$t/out")"
grep -q 'about 0 GB free under .* (XLESS_SETUP_CACHE_GB)' "$t/out" || fail "the cache check still asks for room: $(cat "$t/out")"
grep -q 'xless sdk meta' "$t/out" && fail "the plan rewrites the export's toolchain-meta.json: $(cat "$t/out")"
grep -q '^run' "$log" && fail "--dry-run ran docker: $(cat "$log")"
# For real, while a running build uses the pack's volume: refused before the volume is written, naming the container.
"$repo/Tests/shell/fake-images.sh" base arm64 27.0 27A266a > "$t/images"
extra=(FAKE_IMAGES="$t/images" STUB_IN_USE=xless-xcode-27.0-27A266a-arm64)
share="$repo" run ok --docker --arch arm64
[[ $code != 0 ]] && grep -q "builder (xless:9.9.9-arm64)" "$t/err" || fail "a pack in use is replaced: $code $(cat "$t/out" "$t/err")"
# (the volume is read, read-only, to tell whether its pack is current; nothing mounts it at /xcodes, where it is written)
grep -q '^ps --filter volume=xless-xcode-27.0-27A266a-arm64 ' "$log" && ! grep -q '^volume create\|dst=/xcodes' "$log" \
  || fail "the volume was written while in use, or the setup did not ask: $(cat "$log")"
extra=()
# An architecture the export lacks: refused, naming it and --xcode.
run ok --docker --arch arm64 --arch amd64 --dry-run
[[ $code == 11 ]] && grep -q "holds arm64 and amd64 (xcode27.0-27A266a holds arm64)" "$t/err" || fail "missing-arch refusal: $code $(cat "$t/err")"
run ok --docker --arch arm64 --arch amd64 --sdk "$cached" --dry-run
[[ $code == 11 ]] && grep -qF "the SDK export $cached holds no amd64 SDK (it holds arm64)" "$t/err" || fail "--sdk missing-arch refusal: $code $(cat "$t/err")"
# --sdk: an export anywhere (a relative path), identified by its toolchain-meta.json.
export_meta "$t/exports/x26" 17C52 arm64
pushd "$t" >/dev/null
run ok --docker --arch arm64 --sdk exports/x26 --dry-run
popd >/dev/null
[[ $code == 0 ]] || fail "--sdk exits $code: $(cat "$t/err")"
grep -qF "Xcode 26.2 (17C52) from its SDK export $t/exports/x26" "$t/out" || fail "--sdk plan: $(cat "$t/out")"
grep -qF -- "src=$t/exports/x26,dst=/cache/xless/sdk/xcode26.2-17C52,readonly" "$t/out" && grep -qF "xless-xcode-26.2-17C52-arm64" "$t/out" \
  || fail "--sdk is not what the pack is prepared from: $(cat "$t/out")"
# --sdk given an architecture's directory: refused, naming the export.
run ok --docker --arch arm64 --sdk "$t/exports/x26/arm64" --dry-run
[[ $code == 11 ]] && grep -qF -- "--sdk $t/exports/x26" "$t/err" || fail "--sdk <arch dir>: $code $(cat "$t/err")"
# Two exports in the cache that fit: refused, listing them.
export_meta "$t/home/.cache/xless/sdk/xcode26.2-17C52" 17C52 arm64
run ok --docker --arch arm64 --dry-run
[[ $code == 11 ]] && grep -q 'holds 2 SDK exports for arm64 (xcode26.2-17C52, xcode27.0-27A266a)' "$t/err" || fail "two exports: $code $(cat "$t/err")"
rm -rf "$t/home/.cache/xless/sdk/xcode26.2-17C52"
# An Xcode that versions.env lists, which xless has not measured the asset tools of: refused before docker is asked anything (a
# pack of it would fail its check minutes in), here and natively, naming the Xcodes it can prepare.
us="$t/ushare"
mkdir -p "$us"; cp -R "$repo/docker" "$repo/scripts" "$us/"
cp "$us/docker/toolchain/target-os/27A266a.txt" "$us/docker/toolchain/target-os/27Z1.txt"
sed -e 's/^XCODE_RELEASES="\(.*\)"/XCODE_RELEASES="\1 27Z1"/' "$repo/versions.env" > "$us/versions.env"
printf 'XCODE_SHORT_27Z1=27.9\nXCODE_APPLE_SWIFT_27Z1=6.4\nXCODE_BUILD_MACHINE_OS_27Z1=26A434\nXCODE_SWIFT_27Z1=6.4.0\n' >> "$us/versions.env"
export_meta "$t/x99" 27Z1 arm64
for how in --docker ''; do
  [[ -n "$how" || "$(uname)" == Linux ]] || continue
  share="$us" run ok $how --arch arm64 --sdk "$t/x99"
  [[ $code == 11 ]] && grep -q "has not measured the asset catalog and storyboard tools of Xcode 27.9 (27Z1)" "$t/err" \
    && grep -q "use an Xcode this xless supports (Xcode 26.0.1 (17A400), .*Xcode 27.0 (27A266a)" "$t/err" || fail "an unmeasured Xcode ($how): $code $(cat "$t/err")"
  [[ ! -s "$log" ]] || fail "docker was asked about an unmeasured Xcode: $(cat "$log")"
done
if [[ "$(uname)" == Linux ]]; then
  # Native, from the cache's export of this machine's architecture: no export step, the SDK installed from the export.
  export_meta "$cached" 27A266a "$host"
  extra=(XLESS_NATIVE_HOME="$t/native")
  run ok --dry-run
  [[ $code == 0 ]] || fail "native from the cache's export exits $code: $(cat "$t/err")"
  grep -q 'sdk build' "$t/out" && fail "the native plan exports from an export: $(cat "$t/out")"
  grep -F "sdk install" "$t/out" | grep -qF "$cached/$host/darwin.xtoolsdk $t/native/bin/xtool" \
    && grep -qF "cp $cached/toolchain-meta.json $t/native/xcodes/27.0-27A266a-$host.partial/toolchain-meta.json" "$t/out" \
    || fail "the native plan does not install the export into the pack: $(cat "$t/out")"
  grep -q 'about 0 GB free under .* (XLESS_SETUP_CACHE_GB)' "$t/out" || fail "the native cache check still asks for room: $(cat "$t/out")"
  [[ ! -s "$log" ]] || fail "a native setup called docker: $(cat "$log")"
  extra=()
fi
if [[ "$(uname)" == Linux ]]; then
  # A native setup for real, against fakes (nothing is downloaded, no Apple file): curl serves a fake toolchain tarball
  # registered by its sha256 in a copy of the share, xtool and rcodesign are fakes already installed, the fit is a fake
  # that writes what fit-toolchain.sh leaves (or fails), and the export is a fake one.
  ps="$t/pshare" fake="$t/fake"
  mkdir -p "$ps" "$fake" "$t/tc/swift/usr/bin" "$t/native/bin"
  cp -R "$repo/docker" "$repo/scripts" "$ps/"
  cat > "$ps/scripts/fit-toolchain.sh" <<'F'
#!/bin/sh
[ -z "${FIT_FAIL:-}" ] || { echo "fit-toolchain: failing as asked" >&2; exit 1; }
mkdir -p "$1/include/swift"
printf '{"version":"6.4.0","root":"toolchain"}\n' > "$1/swift-toolchain.json"
F
  printf '#!/bin/sh\necho "Swift version 6.4.0 (swift-6.4.0-RELEASE)"\n' > "$t/tc/swift/usr/bin/swiftc"
  chmod +x "$ps/scripts/fit-toolchain.sh" "$t/tc/swift/usr/bin/swiftc"
  tar -czf "$t/tc.tar.gz" -C "$t/tc" swift
  tsum="$(sha256sum "$t/tc.tar.gz" | cut -d' ' -f1)"
  A="$(echo "$dl" | tr '[:lower:]' '[:upper:]')"
  sed -e "s/^SWIFT_TOOLCHAIN_6_4_0_SHA256_$A=.*/SWIFT_TOOLCHAIN_6_4_0_SHA256_$A=$tsum/" \
      -e "s/^SWIFT_TOOLCHAIN_6_2_3_SHA256_$A=.*/SWIFT_TOOLCHAIN_6_2_3_SHA256_$A=$tsum/" "$repo/versions.env" > "$ps/versions.env"
  grep -q "$tsum" "$ps/versions.env" || fail "could not register the fake toolchain"
  printf '#!/bin/sh\nwhile [ $# -gt 0 ]; do [ "$1" = -o ] && { out=$2; shift; }; shift; done\necho "$out" >> "$CURL_LOG"; cp "$FAKE_TARBALL" "$out"\n' > "$fake/curl"
  printf '#!/bin/sh\n[ "$1 $2" = "sdk install" ] || exit 2\nmkdir -p "$XDG_CONFIG_HOME/swiftpm/swift-sdks/darwin.artifactbundle"\n' > "$t/native/bin/xtool"
  printf '#!/bin/sh\n' > "$t/native/bin/rcodesign"
  chmod +x "$fake/curl" "$t/native/bin/xtool" "$t/native/bin/rcodesign"
  export_meta "$t/x27" 27A266a "$host"
  export_meta "$t/x26" 17C52 "$host"
  st="$t/store" n27="27.0-27A266a-$host" n26="26.2-17C52-$host"
  curls="$t/curl.log"
  native() {   # ARGS…: xless setup natively, against the fakes, into $st
    : > "$curls"
    extra=(XLESS_NATIVE_HOME="$t/native" XLESS_XCODES="$st" XLESS_SETUP_CACHE_GB=0 XLESS_SETUP_NATIVE_GB=0
           FAKE_TARBALL="$t/tc.tar.gz" CURL_LOG="$curls" ${more[@]+"${more[@]}"})
    share="$ps" path="$fake:$t/bin:/usr/bin:/bin" run ok "$@"
    extra=()
  }
  parts() { python3 -c 'import json, sys; print(" ".join(sorted(json.load(open(sys.argv[1]))["parts"])))' "$1/pack.json"; }
  stale() { python3 -c 'import json, sys; p = sys.argv[1] + "/pack.json"; m = json.load(open(p)); m["parts"]["sdk"] = "stale"; json.dump(m, open(p, "w"))' "$1"; }

  # A bare host (no shims): the pack holds the sdk part alone, and nothing is left beside it.
  more=()
  native --sdk "$t/x27"
  [[ $code == 0 ]] || fail "a native setup exits $code: $(cat "$t/out" "$t/err")"
  [[ "$(parts "$st/$n27")" == sdk ]] || fail "the pack's parts: $(cat "$st/$n27/pack.json")"
  for f in toolchain/usr/bin/swiftc config/swiftpm/swift-sdks/darwin.artifactbundle toolchain-meta.json swift-toolchain.json include; do
    [[ -e "$st/$n27/$f" ]] || fail "the pack lacks $f"
  done
  [[ "$(ls -A "$st")" == "$n27"$'\n'"$n27.lock" ]] || fail "the store holds: $(ls -A "$st")"
  [[ ! -e "$t/native/toolchains" ]] || fail "a toolchain was installed under the native home"
  grep -q "^==> done in .*: the pack $n27 of Xcode 27.0 (27A266a), in $st" "$t/out" || fail "done: $(cat "$t/out")"
  # Again: nothing to do, nothing downloaded.
  native --sdk "$t/x27"
  [[ $code == 0 ]] && grep -q "^==> nothing to do: the pack $n27 of Xcode 27.0 (27A266a) is current" "$t/out" && [[ ! -s "$curls" ]] \
    || fail "a second setup: $code $(cat "$t/out" "$t/err")"

  # A second setup of the same pack waits for the one that holds its lock, says so, then finds nothing to do.
  if command -v flock >/dev/null; then
    rm -f "$t/held"
    flock "$st/$n27.lock" sh -c "touch '$t/held'; sleep 3" &
    holder=$!
    for _ in $(seq 50); do [[ -e "$t/held" ]] && break; sleep 0.1; done
    native --sdk "$t/x27"
    wait "$holder"
    [[ $code == 0 ]] && grep -q "^==> waiting for another xless setup, which is preparing the pack $n27 (it holds $st/$n27.lock)" "$t/out" \
      && grep -q "^==> nothing to do" "$t/out" || fail "a setup behind another: $code $(cat "$t/out" "$t/err")"
  else
    echo "note: no flock(1): the waiting setup is not tested here (PackLockTests is)"
  fi

  # A failing fit leaves the earlier pack as it was, and nothing beside it.
  stale "$st/$n27"; cp "$st/$n27/pack.json" "$t/before.json"
  more=(FIT_FAIL=1)
  native --sdk "$t/x27"
  [[ $code != 0 ]] && grep -q 'fit-toolchain: failing as asked' "$t/out" "$t/err" || fail "a failing fit: $code $(cat "$t/out" "$t/err")"
  cmp -s "$t/before.json" "$st/$n27/pack.json" || fail "a failing fit changed the pack: $(cat "$st/$n27/pack.json")"
  [[ ! -e "$st/$n27.partial" && ! -e "$st/$n27.old" ]] || fail "a failing fit left: $(ls -A "$st")"

  # A setup stopped between the two renames of its commit left the pack aside: the next one puts it back first.
  mv "$st/$n27" "$st/$n27.old"
  native --sdk "$t/x27"
  grep -q "^==> the pack $n27 is back in place: a setup had stopped while it replaced it" "$t/out" || fail "not put back: $(cat "$t/out" "$t/err")"
  cmp -s "$t/before.json" "$st/$n27/pack.json" && [[ ! -e "$st/$n27.old" && ! -e "$st/$n27.partial" ]] || fail "put back: $(ls -A "$st")"

  # A leftover staging directory of an earlier run is removed first, never reused.
  mkdir -p "$st/$n27.partial/toolchain"; echo junk > "$st/$n27.partial/junk"; cp "$t/before.json" "$st/$n27.partial/pack.json"
  more=()
  native --sdk "$t/x27"
  [[ $code == 0 && ! -e "$st/$n27/junk" && ! -e "$st/$n27.partial" ]] || fail "a leftover .partial: $code $(cat "$t/out" "$t/err") $(ls -A "$st/$n27")"
  [[ "$(parts "$st/$n27")" == sdk ]] && ! grep -q stale "$st/$n27/pack.json" || fail "the pack after a leftover: $(cat "$st/$n27/pack.json")"

  # Several Xcodes: a second Xcode's setup adds its pack and touches no other.
  cp "$st/$n27/pack.json" "$t/27.json"; ino="$(stat -c %i "$st/$n27/toolchain-meta.json")"
  native --sdk "$t/x26"
  [[ $code == 0 && -f "$st/$n26/pack.json" ]] || fail "a second Xcode: $code $(cat "$t/out" "$t/err")"
  grep -q "scripts/fit-toolchain.sh $st/$n26.partial separate" "$t/out" || grep -q "separate" "$st/$n26/pack.json" || fail "26.2 is not separate: $(cat "$st/$n26/pack.json")"
  cmp -s "$t/27.json" "$st/$n27/pack.json" && [[ "$(stat -c %i "$st/$n27/toolchain-meta.json")" == "$ino" ]] || fail "the 27.0 pack was touched"

  # An Xcode installed natively by an xless of before the packs (its SDK and toolchain record, no pack): reported, not
  # used, and the pack prepared from the export; then the command that removes it.
  mkdir -p "$t/home/.swiftpm/swift-sdks/darwin.artifactbundle"; echo '{}' > "$t/native/swift-toolchain.json"
  st="$t/store2"
  native --sdk "$t/x27"
  [[ $code == 0 ]] || fail "over an older install: $code $(cat "$t/out" "$t/err")"
  grep -q "^note: the Xcode that an older xless installed natively (the SDK in $t/home/.swiftpm/swift-sdks, the Swift toolchain under $t/native/toolchains) is not used any more" "$t/out" \
    && grep -q "xless clean --old removes it" "$t/out" && [[ -f "$st/$n27/pack.json" ]] || fail "an older install: $(cat "$t/out")"
  native --sdk "$t/x27"
  grep -q 'older xless' "$t/out" && fail "an older install is reported beside a pack: $(cat "$t/out")"
  st="$t/store"; more=()
fi
echo "setup.test.sh: ok"
