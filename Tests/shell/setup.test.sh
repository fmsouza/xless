#!/usr/bin/env bash
# `xless setup`, run against the built xless with a `docker` stub first on PATH (it records every call; nothing is built,
# nothing is downloaded): with --docker, the Docker preflight names the cause before any step runs, an unsupported file is
# refused with the supported releases, and --dry-run prints the plan of a fake .xip registered through a temp versions.env
# copy. Without --docker (native, Linux only): the missing host commands and the disk are checked first, --dry-run prints
# the native plan, and docker is never called; elsewhere, or with another --arch, it is refused naming --docker.
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
  env -i HOME="$t/home" PATH="${path:-$t/bin:/usr/bin:/bin}" XLESS_SHARE="${share:-$repo}" DOCKER_STUB="$stub" DOCKER_LOG="$log" \
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
grep -q 'is not a supported Xcode (supported: Xcode 26.2 (17C52), Xcode 27.0 (27A266a))' "$t/err" || fail "supported list: $(cat "$t/err")"
[[ ! -s "$log" ]] || fail "docker was called for an unsupported Xcode: $(cat "$log")"

# --dry-run: a fake .xip (any name, a path with spaces) registered by its sha256 in a temp copy of versions.env.
share="$t/share"
mkdir -p "$share" "$t/my downloads"
xip="$t/my downloads/Xcode copy.xip"
head -c 100000 /dev/zero | tr '\0' 'x' > "$xip"
sum="$( (sha256sum "$xip" 2>/dev/null || shasum -a 256 "$xip") | cut -d' ' -f1)"
sed "s/^XCODE_XIP_SHA256_27A266a=.*/XCODE_XIP_SHA256_27A266a=\"$sum\"/" "$repo/versions.env" > "$share/versions.env"
grep -q "$sum" "$share/versions.env" || fail "could not register the fake .xip"
run ok --docker --xcode "$xip" --arch arm64 --dry-run
[[ $code == 0 ]] || fail "--dry-run exits $code: $(cat "$t/err")"
grep -q 'xtool sdk build' "$t/out" || fail "the plan does not export the SDK: $(cat "$t/out")"
grep -q "Xcode copy.xip:/xcode/Xcode copy.xip:ro" "$t/out" || fail "the .xip is not mounted read-only: $(cat "$t/out")"
grep -q 'docker-images.sh rn' "$t/out" || fail "the plan does not build xless-rn: $(cat "$t/out")"
grep -q 'disk: the check asks for about .* GB free under .* (XLESS_SETUP_CACHE_GB)' "$t/out" || fail "--dry-run does not print the disk check: $(cat "$t/out")"
grep -q 'xless-rn:local-arm64-xcode27.0' "$t/out" || fail "the plan does not tag xless-rn: $(cat "$t/out")"
grep -q '^run' "$log" && fail "--dry-run ran docker: $(cat "$log")"
grep -q 'next: xless run' "$t/out" && fail "--dry-run promised the next step"
# The xless that goes into xless-base is always a copy in the setup work dir (<arch>-bin/xless): its source directory
# (~/.local/bin, say) is never what docker-images.sh gets as the build context.
mkdir -p "$t/ext"; echo stub > "$t/ext/xless"; echo "do not send me to docker" > "$t/ext/other-file"
extra=(XLESS_BIN_ARM64="$t/ext/xless")
run ok --docker --xcode "$xip" --arch arm64 --dry-run
[[ $code == 0 ]] || fail "--dry-run with XLESS_BIN_ARM64 exits $code: $(cat "$t/err")"
binline="$(grep 'docker-images.sh' "$t/out" | grep -E '(^|[ =])[^ ]*xless-setup-[^ /]*/arm64-bin/xless' || true)"
[[ -n "$binline" ]] || fail "the build context is not the work dir's arm64-bin/xless: $(cat "$t/out")"
grep -F "$t/ext" "$t/out" && fail "the plan names the binary's own directory $t/ext: $(cat "$t/out")"
extra=()
# The same .xip under the default (unregistered) table is refused: identification is by content.
share="$repo" run ok --docker --xcode "$xip" --dry-run
[[ $code == 11 ]] || fail "an unregistered .xip exits $code, want 11"

# Native (the default).
case "$(uname -m)" in arm64|aarch64) host=arm64 other=amd64 dl=aarch64 ;; *) host=amd64 other=arm64 dl=x86_64 ;; esac
run ok --xcode "$xip" --arch "$other" --dry-run
[[ $code == 11 ]] || fail "native --arch $other exits $code, want 11: $(cat "$t/err")"
grep -q 'needs --docker' "$t/err" || fail "native --arch refusal: $(cat "$t/err")"
if [[ "$(uname)" != Linux ]]; then
  run ok --xcode "$xip" --dry-run
  [[ $code == 11 ]] || fail "native setup off Linux exits $code, want 11: $(cat "$t/err")"
  grep -q 'runs on Linux only' "$t/err" && grep -q 'xless setup --docker' "$t/err" || fail "off-Linux refusal: $(cat "$t/err")"
else
  extra=(XLESS_NATIVE_HOME="$t/native")
  run ok --xcode "$xip" --dry-run
  [[ $code == 0 ]] || fail "native --dry-run exits $code: $(cat "$t/err")"
  for want in "natively for $host into $t/native" "xtool-$dl.AppImage" "apple-codesign-" "$t/native/toolchains/swift-6.4.0" \
              "$t/native/bin/xtool sdk build" "xless sdk install --xtoolsdk" "scripts/native-toolchain.sh $t/native/toolchains/swift-6.4.0 own" \
              "(XLESS_SETUP_NATIVE_GB)"; do
    grep -qF -- "$want" "$t/out" || fail "the native plan lacks '$want': $(cat "$t/out")"
  done
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
    grep -q 'for the native install' "$t/err" && grep -q 'set XLESS_SETUP_NATIVE_GB' "$t/err" || fail "native disk refusal: $(cat "$t/err")"
    [[ ! -e "$t/native/tools" ]] || fail "a refused setup installed tools"
  fi
  extra=()
fi
echo "setup.test.sh: ok"
