#!/usr/bin/env bash
# `xless clean`, run against the built xless with a `docker` stub first on PATH (it lists fake images and volumes and
# records every call): no option lists and removes nothing, --dry-run removes nothing, --all removes exactly xless's
# tags, volumes and cache, --old asks first (yes, no, --yes, no terminal) and removes no tag that is another image by then,
# --cache alone needs no Docker, and a Docker that doesn't answer is an error for --images.
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

mkdir -p "$t/bin" "$t/home" "$t/images"
cat > "$t/bin/docker" <<'D'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$DOCKER_LOG"
[[ "${DOCKER_DOWN:-0}" != 1 ]] || { echo "Cannot connect to the Docker daemon" >&2; exit 1; }
case "$1 $2" in
  "image ls")
    case "$*" in
      *label=dev.xless.sdk) printf '%s\n' xless:local-arm64-xcode27.0 xless:local-arm64-xcode27.0-tauri ;;
      *) printf '%s\n' xless-base:local-arm64 xless:local-arm64 xless:local-arm64-xcode27.0 xless:local-arm64-xcode27.0-tauri xless-rn:'<none>' xless:mine \
           registry.example.com/xless-rn:local-arm64 postgres:16 ;;
    esac ;;
  # (an image's ID is in a file where the test wants it to change, and its labels)
  "image inspect")
    ref="${*: -1}"; file="$IMAGES/${ref//[^A-Za-z0-9.-]/_}"
    [[ ! -e "$file.once" ]] || { cat "$file.once"; rm "$file.once"; exit 0; }
    [[ ! -e "$file" ]] || { cat "$file"; exit 0; }
    labels='{}'; case "$ref" in xless:local-arm64-xcode27.0*) labels='{"dev.xless.sdk":"27A266a"}' ;; esac
    printf '{"Id":"sha256:%s","Architecture":"arm64","Config":{"Labels":%s},"RootFS":{"Layers":[]}}\n' "$ref" "$labels" ;;
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
  env -i HOME="$t/home" PATH="$t/bin:/usr/bin:/bin" DOCKER_LOG="$log" IMAGES="$t/images" ${extra[@]+"${extra[@]}"} \
    "$x" clean "$@" >"$t/out" 2>"$t/err" || code=$?
}
on() {   # ANSWER ARGS…: the same on a terminal, where ANSWER is typed; without a terminal where it is "none"
  : > "$log"; code=0
  env -i HOME="$t/home" PATH="$t/bin:/usr/bin:/bin" DOCKER_LOG="$log" IMAGES="$t/images" python3 -I - "$x" "$@" >"$t/out" 2>"$t/err" <<'P' || code=$?
import os, pty, select, subprocess, sys
xless, answer, arguments = sys.argv[1], sys.argv[2], sys.argv[3:]
if answer == "none":
    sys.exit(subprocess.run([xless, "clean", *arguments], stdin=subprocess.DEVNULL, start_new_session=True).returncode)
pid, fd = pty.fork()
if pid == 0: os.execv("/bin/sh", ["sh", "-c", '"$@"; exit $?', "sh", xless, "clean", *arguments])
seen, typed = b"", False
while select.select([fd], [], [], 60)[0]:
    try: chunk = os.read(fd, 4096)
    except OSError: break
    if not chunk: break
    seen += chunk
    if not typed and seen.endswith(b"[y/N] "):
        typed = True
        os.write(fd, answer.encode() + b"\n")
sys.stdout.write(seen.decode().replace("\r\n", "\n"))
sys.stdout.flush()
sys.exit(os.waitstatus_to_exitcode(os.waitpid(pid, 0)[1]))
P
}
removed() { grep -E '^(image rm|image prune|volume rm)' "$log" || true; }

# No option: lists, removes nothing.
mkcache; extra=()
run
[[ $code == 0 ]] || fail "list exits $code: $(cat "$t/err")"
grep -q '^found 4 image tags:' "$t/out" || fail "image count: $(cat "$t/out")"
grep -qx '  xless:local-arm64-xcode27.0' "$t/out" || fail "tag not listed: $(cat "$t/out")"
grep -q 'postgres\|registry\|xless:mine' "$t/out" && fail "another project's image listed"
grep -q '^found 2 volumes:' "$t/out" || fail "volume count: $(cat "$t/out")"
grep -q 'pgdata' "$t/out" && fail "another project's volume listed"
grep -q "^found the cache $cache" "$t/out" || fail "cache not listed: $(cat "$t/out")"
grep -q '^nothing removed' "$t/out" || fail "no hint: $(cat "$t/out")"
[[ -z "$(removed)" && -d "$cache" ]] || fail "listing removed something: $(removed)"

# --dry-run: says what --all would remove, removes nothing.
run --all --dry-run
[[ $code == 0 ]] || fail "dry run exits $code"
grep -q '^would remove 4 image tags' "$t/out" || fail "dry run images: $(cat "$t/out")"
grep -q '^would remove the cache' "$t/out" || fail "dry run cache: $(cat "$t/out")"
[[ -z "$(removed)" && -d "$cache" ]] || fail "dry run removed something: $(removed)"

# --all: exactly xless's tags, the label prune, xless's volumes and the cache.
run --all
[[ $code == 0 ]] || fail "--all exits $code: $(cat "$t/err")"
grep -qx 'volume rm xless-cargo xless-rn-work-ov-12345678' "$log" || fail "volumes: $(removed)"
grep -qx 'image rm xless-base:local-arm64 xless:local-arm64 xless:local-arm64-xcode27.0 xless:local-arm64-xcode27.0-tauri' "$log" || fail "images: $(removed)"
grep -qx 'image prune --force --filter label=org.xless.image=true' "$log" || fail "no label prune: $(removed)"
grep -q 'builder prune\|system prune' "$log" && fail "pruned Docker-wide caches"
[[ ! -e "$cache" ]] || fail "cache left behind"
grep -q 'docker builder prune' "$t/out" || fail "no build cache hint: $(cat "$t/out")"

# --old: what an upgrade leaves (the images of xless 0.10 and older, shown, and the label prune): no image of this xless, no
# volume, no cache.
mkcache
run --old --dry-run
[[ $code == 0 && -z "$(removed)" ]] || fail "--old --dry-run: $code $(removed)"
[[ "$(sed -n 1,3p "$t/out")" == "would remove 2 image tags:
  xless-base:local-arm64
  xless:local-arm64" ]] || fail "--old --dry-run says: $(cat "$t/out")"
[[ "$(sed -n 4p "$t/out")" == "and the untagged older builds (docker image prune --filter label=org.xless.image=true)" ]] || fail "--old --dry-run says: $(cat "$t/out")"
both='image rm xless-base:local-arm64
image rm xless:local-arm64
image prune --force --filter label=org.xless.image=true'
# It asks, and nothing but yes is yes.
for no in n "" nope; do
  on "$no" --old --cache
  [[ $code == 0 && -z "$(removed)" && -d "$cache" ]] || fail "--old, answered '$no': $code $(removed)"
  [[ "$(cat "$t/out")" == "would remove 2 image tags:
  xless-base:local-arm64
  xless:local-arm64
and the untagged older builds (docker image prune --filter label=org.xless.image=true)
"*"Remove these 2 image tags, and the untagged older builds? [y/N] "*"cancelled; nothing was removed" ]] || fail "--old asks: $(cat "$t/out")"
done
on y --old
[[ $code == 0 && "$(removed)" == "$both" && -d "$cache" ]] || fail "--old, answered yes: $code $(removed) $(cat "$t/out")"
# --yes answers; without a terminal, or with --no-input, it is needed.
on none --old --yes
[[ $code == 0 && "$(removed)" == "$both" && -d "$cache" ]] || fail "--old --yes: $code $(removed) $(cat "$t/err")"
[[ "$(sed -n 1p "$t/out")" == "removing 2 image tags:" ]] || fail "--old --yes says: $(cat "$t/out")"
on none --old --cache
[[ $code == 11 && -z "$(removed)" && -d "$cache" ]] || fail "--old without a terminal: $code $(removed)"
grep -q 'removing the images of an older xless needs a confirmation and there is no terminal — re-run with --yes' "$t/err" || fail "--old without a terminal says: $(cat "$t/err")"
on y --old --no-input
[[ $code == 23 && -z "$(removed)" ]] || fail "--old --no-input: $code $(removed)"
# What a tag is by the time it would go: `xless setup` in another terminal, while the question waits.
f="$t/images/xless_local-arm64"
echo '{"Id":"sha256:xless:local-arm64","Architecture":"arm64","Config":{"Labels":{}},"RootFS":{"Layers":[]}}' > "$f.once"
echo '{"Id":"sha256:new","Architecture":"arm64","Config":{"Labels":{}},"RootFS":{"Layers":[]}}' > "$f"
on y --old
[[ $code == 0 && "$(removed)" == "$(grep -v 'rm xless:local' <<<"$both")" ]] || fail "--old removed another image: $code $(removed)"
grep -qx 'kept xless:local-arm64: it is another image now' "$t/out" || fail "--old does not say it: $(cat "$t/out")"
echo '{"Id":"sha256:xless:local-arm64","Architecture":"arm64","Config":{"Labels":{"dev.xless.sdk":"27A266a"}},"RootFS":{"Layers":[]}}' > "$f"
on none --old --yes
[[ $code == 0 && "$(removed)" == "$(grep -v 'rm xless:local' <<<"$both")" ]] || fail "--old removed an image of this xless: $code $(removed)"
rm -f "$f" "$f.once"
# Only untagged builds: nothing to ask about.
sed -i.bak 's/xless-base:local-arm64 xless:local-arm64 xless:local-arm64-xcode27.0/xless:local-arm64-xcode27.0/' "$t/bin/docker"; rm "$t/bin/docker.bak"
on none --old
[[ $code == 0 && "$(removed)" == 'image prune --force --filter label=org.xless.image=true' ]] || fail "--old without an old tag: $code $(removed)"

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
