#!/usr/bin/env bash
# `xless clean`, run against the built xless with a `docker` stub first on PATH (it lists fake images and volumes and
# records every call): no option lists and removes nothing, --dry-run removes nothing, --all removes exactly xless's
# tags, volumes and cache, --cache alone needs no Docker, and a Docker that doesn't answer is an error for --images.
#   Tests/shell/clean.test.sh            (builds xless with `swift build`; XLESS_BIN=<path> uses that binary)
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
[[ "${DOCKER_DOWN:-0}" != 1 ]] || { echo "Cannot connect to the Docker daemon" >&2; exit 1; }
case "$1 $2" in
  "image ls") printf '%s\n' xless-base:local-arm64 xless:local-arm64 xless:local-arm64-xcode27.0 xless-rn:'<none>' postgres:16 ;;
  "volume ls") printf '%s\n' xless-cargo xless-rn-work-ov-12345678 pgdata ;;
esac
exit 0
D
chmod +x "$t/bin/docker"
log="$t/docker.log"
cache="$t/home/.cache/xless"
mkcache() { mkdir -p "$cache/sdk/xcode27.0-27A266a/arm64" "$cache/work"; echo x > "$cache/sdk/xcode27.0-27A266a/arm64/f"; }
run() {   # ARGS…: stdout → $t/out, stderr → $t/err, exit code → $code
  : > "$log"; code=0
  env -i HOME="$t/home" PATH="$t/bin:/usr/bin:/bin" DOCKER_LOG="$log" ${extra[@]+"${extra[@]}"} \
    "$x" clean "$@" >"$t/out" 2>"$t/err" || code=$?
}
removed() { grep -E '^(image rm|image prune|volume rm)' "$log" || true; }

# No option: lists, removes nothing.
mkcache; extra=()
run
[[ $code == 0 ]] || fail "list exits $code: $(cat "$t/err")"
grep -q '^found 3 image tags:' "$t/out" || fail "image count: $(cat "$t/out")"
grep -qx '  xless:local-arm64-xcode27.0' "$t/out" || fail "tag not listed: $(cat "$t/out")"
grep -q 'postgres' "$t/out" && fail "another project's image listed"
grep -q '^found 2 volumes:' "$t/out" || fail "volume count: $(cat "$t/out")"
grep -q 'pgdata' "$t/out" && fail "another project's volume listed"
grep -q "^found the cache $cache" "$t/out" || fail "cache not listed: $(cat "$t/out")"
grep -q '^nothing removed' "$t/out" || fail "no hint: $(cat "$t/out")"
[[ -z "$(removed)" && -d "$cache" ]] || fail "listing removed something: $(removed)"

# --dry-run: says what --all would remove, removes nothing.
run --all --dry-run
[[ $code == 0 ]] || fail "dry run exits $code"
grep -q '^would remove 3 image tags' "$t/out" || fail "dry run images: $(cat "$t/out")"
grep -q '^would remove the cache' "$t/out" || fail "dry run cache: $(cat "$t/out")"
[[ -z "$(removed)" && -d "$cache" ]] || fail "dry run removed something: $(removed)"

# --all: exactly xless's tags, the label prune, xless's volumes and the cache.
run --all
[[ $code == 0 ]] || fail "--all exits $code: $(cat "$t/err")"
grep -qx 'volume rm xless-cargo xless-rn-work-ov-12345678' "$log" || fail "volumes: $(removed)"
grep -qx 'image rm xless-base:local-arm64 xless:local-arm64 xless:local-arm64-xcode27.0' "$log" || fail "images: $(removed)"
grep -qx 'image prune --force --filter label=org.xless.image' "$log" || fail "no label prune: $(removed)"
grep -q 'builder prune\|system prune' "$log" && fail "pruned Docker-wide caches"
[[ ! -e "$cache" ]] || fail "cache left behind"
grep -q 'docker builder prune' "$t/out" || fail "no build cache hint: $(cat "$t/out")"

# --old: only the label prune (what an upgrade leaves), no tag, volume or cache removed.
mkcache
run --old
[[ $code == 0 ]] || fail "--old exits $code: $(cat "$t/err")"
[[ "$(removed)" == 'image prune --force --filter label=org.xless.image' ]] || fail "--old removed: $(removed)"
[[ -d "$cache" ]] || fail "--old removed the cache"

# --cache alone needs no Docker; --images with a Docker that doesn't answer fails (exit 11) and removes nothing.
mkcache; extra=(DOCKER_DOWN=1)
run --cache
[[ $code == 0 && ! -e "$cache" ]] || fail "--cache without docker: $code $(cat "$t/err")"
grep -q '^image\|^volume' "$log" && fail "--cache used docker: $(cat "$log")"
mkcache
run --images
[[ $code == 11 ]] || fail "--images with docker down exits $code"
grep -q 'docker does not answer' "$t/err" || fail "cause not named: $(cat "$t/err")"
[[ -d "$cache" ]] || fail "--images removed the cache"
run
[[ $code == 0 ]] && grep -q 'docker does not answer' "$t/out" || fail "listing with docker down: $code $(cat "$t/out")"

# --native: the native home and the SDK and metadata it installed, without Docker; listed by default, kept by --cache.
extra=(DOCKER_DOWN=1)
mknative() { mkdir -p "$t/home/.local/share/xless-native/bin" "$t/home/.swiftpm/swift-sdks/darwin.artifactbundle" "$t/home/.config/xless"
             echo '{}' > "$t/home/.config/xless/toolchain-meta.json"; mkdir -p "$t/home/.config/swiftpm-other"; }
# An SDK that `xless sdk install` put there, with no native setup (no toolchain record): only the native home goes.
mknative; mkcache
run --native
for p in .swiftpm/swift-sdks/darwin.artifactbundle .config/xless/toolchain-meta.json; do
  [[ -e "$t/home/$p" ]] || fail "--native without a native record removed $p"
done
[[ ! -e "$t/home/.local/share/xless-native" ]] || fail "--native left the native home"
mknative; echo '{"version":"6.4.0","root":"/x"}' > "$t/home/.local/share/xless-native/swift-toolchain.json"
run
grep -q "^found the native install's $t/home/.local/share/xless-native" "$t/out" || fail "native not listed: $(cat "$t/out")"
[[ -d "$t/home/.local/share/xless-native" ]] || fail "listing removed the native install"
run --cache
[[ -d "$t/home/.local/share/xless-native" ]] || fail "--cache removed the native install"
run --native --dry-run
grep -q "^would remove the native install's $t/home/.swiftpm/swift-sdks/darwin.artifactbundle" "$t/out" || fail "native dry run: $(cat "$t/out")"
[[ -d "$t/home/.local/share/xless-native" ]] || fail "dry run removed the native install"
run --native
[[ $code == 0 ]] || fail "--native exits $code: $(cat "$t/err")"
for p in .local/share/xless-native .swiftpm/swift-sdks/darwin.artifactbundle .config/xless/toolchain-meta.json; do
  [[ ! -e "$t/home/$p" ]] || fail "--native left $p"
done
[[ -d "$t/home/.config/swiftpm-other" ]] || fail "--native removed something else"
grep -q '^image\|^volume' "$log" && fail "--native used docker: $(cat "$log")"
run
grep -q '^no native install' "$t/out" || fail "no native install not said: $(cat "$t/out")"
echo "clean.test.sh: ok"
