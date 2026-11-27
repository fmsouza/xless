#!/usr/bin/env bash
# `xless clean`, run against the built xless with a `docker` stub first on PATH (it lists fake images and volumes and
# records every call): no option lists and removes nothing, --dry-run removes nothing, --all removes exactly xless's
# tags, volumes, Xcode packs and cache (--volumes only the work volumes, --packs only the packs, asked about), --old removes the legacy images, the images of another xless
# version and an older native install, asks first (yes, no, --yes, no terminal), removes no tag that is another image by then,
# and NEVER a pack, a pack volume, the store, an SDK export, a person's own tag or the swift-sdks directory; a pack that a
# running container uses is left; --cache alone needs no Docker, and a Docker that doesn't answer is an error for --images.
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

mkdir -p "$t/bin" "$t/home" "$t/images" "$t/share"
echo 9.9.9 > "$t/share/VERSION"   # the xless of these tests: its images are xless:9.9.9-<arch>[-<kit>]
share="$t/share"
rt="$(cd "$t" && pwd -P)"   # the directories a listing names are real paths (macOS /var is /private/var)
cat > "$t/bin/docker" <<'D'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$DOCKER_LOG"
[[ "${DOCKER_DOWN:-0}" != 1 ]] || { echo "Cannot connect to the Docker daemon" >&2; exit 1; }
case "$1 $2" in
  "image ls")
    case "$*" in
      *label=dev.xless.sdk) printf '%s\n' xless:local-arm64-xcode27.0 xless:local-arm64-xcode27.0-tauri ;;
      *) printf '%s\n' xless-base:local-arm64 xless:local-arm64 xless:local-arm64-xcode27.0-tauri xless:9.9.9-arm64 xless:9.9.9-arm64-tauri \
           xless:9.8.0-arm64 xless:9.8.0-arm64-react-native xless-rn:'<none>' xless:mine xless:1 ghcr.io/x/xless:9.8.0-arm64 me/xless:local-arm64 \
           registry.example.com/xless-rn:local-arm64 postgres:16 ;;
    esac ;;
  # (an image's ID is in a file where the test wants it to change, and its labels)
  "image inspect")
    ref="${*: -1}"; file="$IMAGES/${ref//[^A-Za-z0-9.-]/_}"
    [[ ! -e "$file.once" ]] || { cat "$file.once"; rm "$file.once"; exit 0; }
    [[ ! -e "$file" ]] || { cat "$file"; exit 0; }
    labels='{}'; case "$ref" in xless:local-arm64-xcode27.0*) labels='{"dev.xless.sdk":"27A266a"}' ;; esac
    printf '{"Id":"sha256:%s","Architecture":"arm64","Config":{"Labels":%s},"RootFS":{"Layers":[]}}\n' "$ref" "$labels" ;;
  "volume ls") printf '%s\n' xless-cargo xless-rn-work-ov-12345678 pgdata xless-xcode-26.2-17C52-arm64 xless-xcode-27.0-27A266a-arm64 xless-xcode-backup ;;
  # (the containers that use a pack volume: those named in PACK_IN_USE)
  # (docker cannot be asked: PS_FAIL; the first PSQ_FREE asks of `ps -q` find nothing running, the later ones a container with PSQ_MOUNT mounted)
  "ps -q") [[ "${PS_FAIL:-0}" != 1 ]] || exit 1
           n=$(( $(cat "$IMAGES/psq" 2>/dev/null || echo 0) + 1 )); echo $n > "$IMAGES/psq"
           [[ $n -le ${PSQ_FREE:-999} ]] || echo abc ;;
  "inspect --format") printf 'builder\txless:9.9.9-arm64\t\t[{"Source":"%s"}]\n' "${PSQ_MOUNT:-/nowhere}" ;;
  "ps --filter") [[ "${PS_FAIL:-0}" != 1 ]] || exit 1; vol="${3#volume=}"; [[ "${PACK_IN_USE:-}" != *"$vol"* ]] || printf 'builder\txless:9.9.9-arm64\t\n' ;;
esac
exit 0
D
chmod +x "$t/bin/docker"
log="$t/docker.log"
cache="$t/home/.cache/xless"
mkcache() { mkdir -p "$cache/sdk/xcode27.0-27A266a/arm64" "$cache/work"; echo x > "$cache/sdk/xcode27.0-27A266a/arm64/f"; }
run() {   # ARGS…: stdout → $t/out, stderr → $t/err, exit code → $code
  : > "$log"; code=0
  env -i HOME="$t/home" PATH="$t/bin:/usr/bin:/bin" DOCKER_LOG="$log" IMAGES="$t/images" XLESS_SHARE="$share" ${extra[@]+"${extra[@]}"} \
    "$x" clean "$@" >"$t/out" 2>"$t/err" || code=$?
}
on() {   # ANSWER ARGS…: the same on a terminal, where ANSWER is typed; without a terminal where it is "none"
  : > "$log"; code=0
  env -i HOME="$t/home" PATH="$t/bin:/usr/bin:/bin" DOCKER_LOG="$log" IMAGES="$t/images" XLESS_SHARE="$share" ${extra[@]+"${extra[@]}"} python3 -I - "$x" "$@" >"$t/out" 2>"$t/err" <<'P' || code=$?
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
grep -q '^found 7 image tags:' "$t/out" || fail "image count: $(cat "$t/out")"
for r in xless:9.9.9-arm64 xless:9.9.9-arm64-tauri xless:9.8.0-arm64-react-native xless:local-arm64 xless-base:local-arm64 xless:local-arm64-xcode27.0-tauri; do
  grep -qx "  $r" "$t/out" || fail "$r not listed: $(cat "$t/out")"
done
# A person's own tag, one with a registry or a namespace, another project's image: never listed.
for own in xless:mine xless:1 ghcr.io me/xless registry postgres '<none>'; do grep -qF -- "$own" "$t/out" && fail "$own listed: $(cat "$t/out")"; done
grep -q '^found 2 volumes:' "$t/out" || fail "volume count: $(cat "$t/out")"
grep -q '^found 2 Xcode pack volumes:' "$t/out" || fail "pack count: $(cat "$t/out")"
grep -qx '  xless-xcode-26.2-17C52-arm64  Xcode 26.2 (17C52, arm64)' "$t/out" || fail "pack not listed with its Xcode: $(cat "$t/out")"
grep -q 'preparing a pack again takes minutes and needs its SDK export' "$t/out" || fail "no word on preparing again: $(cat "$t/out")"
grep -q 'pgdata\|xless-xcode-backup' "$t/out" && fail "another project's volume listed"
grep -q "^found the cache $cache" "$t/out" || fail "cache not listed: $(cat "$t/out")"
grep -q 'it holds 1 SDK export (xcode27.0-27A266a): packs are prepared from them, and without the .xip they are your only copy; only --cache and --all remove them' "$t/out" \
  || fail "cache's SDK exports not said: $(cat "$t/out")"
grep -q '^nothing removed' "$t/out" || fail "no hint: $(cat "$t/out")"
[[ -z "$(removed)" && -d "$cache" ]] || fail "listing removed something: $(removed)"

# --dry-run: says what --all would remove, removes nothing.
run --all --dry-run
[[ $code == 0 ]] || fail "dry run exits $code"
grep -q '^would remove 7 image tags' "$t/out" || fail "dry run images: $(cat "$t/out")"
grep -q '^would remove 2 Xcode pack volumes' "$t/out" || fail "dry run packs: $(cat "$t/out")"
grep -q '^would remove the cache' "$t/out" || fail "dry run cache: $(cat "$t/out")"
[[ -z "$(removed)" && -d "$cache" ]] || fail "dry run removed something: $(removed)"

# --all: exactly xless's tags, the label prune, xless's volumes, the packs and the cache. The packs are asked about.
on none --all
[[ $code == 11 && -z "$(removed)" && -d "$cache" ]] || fail "--all without a terminal: $code $(removed)"
on n --all
[[ $code == 0 && -z "$(removed)" && -d "$cache" ]] || fail "--all, answered no: $code $(removed)"
grep -q 'Remove 2 Xcode pack volumes?' "$t/out" || fail "--all does not ask about the packs: $(cat "$t/out")"
run --all --yes
[[ $code == 0 ]] || fail "--all exits $code: $(cat "$t/err")"
grep -qx 'volume rm xless-cargo xless-rn-work-ov-12345678' "$log" || fail "volumes: $(removed)"
grep -qx 'volume rm xless-xcode-26.2-17C52-arm64 xless-xcode-27.0-27A266a-arm64' "$log" || fail "pack volumes: $(removed)"
[[ "$(grep -c '^volume rm' "$log")" == 2 ]] || fail "removed another volume: $(removed)"
grep -qx 'image rm xless-base:local-arm64 xless:local-arm64 xless:local-arm64-xcode27.0-tauri xless:9.9.9-arm64 xless:9.9.9-arm64-tauri xless:9.8.0-arm64 xless:9.8.0-arm64-react-native' "$log" || fail "images: $(removed)"
grep -qx 'image prune --force --filter label=org.xless.image=true' "$log" || fail "no label prune: $(removed)"
grep -q 'builder prune\|system prune' "$log" && fail "pruned Docker-wide caches"
[[ ! -e "$cache" ]] || fail "cache left behind"
grep -q 'docker builder prune' "$t/out" || fail "no build cache hint: $(cat "$t/out")"

# --volumes: the work volumes only, as it always did: every pack volume stays, nothing is asked, the images and the cache stay.
mkcache
run --volumes
[[ $code == 0 && "$(removed)" == "volume rm xless-cargo xless-rn-work-ov-12345678" && -d "$cache" ]] || fail "--volumes: $code $(removed) $(cat "$t/err")"
grep -q 'xless-xcode\|Xcode pack' "$t/out" && fail "--volumes speaks of the packs: $(cat "$t/out")"
extra=(PACK_IN_USE=xless-xcode-27.0-27A266a-arm64)
run --volumes
[[ $code == 0 && "$(removed)" == "volume rm xless-cargo xless-rn-work-ov-12345678" ]] || fail "--volumes with a pack in use: $code $(removed)"
extra=()
# --packs: the pack volumes and nothing else (no work volume, no image, no prune, not the cache); asked about, with the Xcode of each.
on n --packs
[[ $code == 0 && -z "$(removed)" ]] || fail "--packs, answered no: $code $(removed)"
grep -qx '  xless-xcode-26.2-17C52-arm64  Xcode 26.2 (17C52, arm64)' "$t/out" && grep -q 'preparing a pack again takes minutes and needs its SDK export' "$t/out" \
  && grep -q 'Remove 2 Xcode pack volumes?' "$t/out" || fail "--packs asks: $(cat "$t/out")"
on none --packs
[[ $code == 11 && -z "$(removed)" ]] || fail "--packs without a terminal: $code $(removed)"
on y --packs
[[ $code == 0 && "$(removed)" == "volume rm xless-xcode-26.2-17C52-arm64 xless-xcode-27.0-27A266a-arm64" && -d "$cache" ]] || fail "--packs, answered yes: $code $(removed)"
# A pack that a running container uses is left, with --packs and with --all; the exit code says so.
extra=(PACK_IN_USE=xless-xcode-27.0-27A266a-arm64)
run --packs --yes
[[ $code == 11 && "$(removed)" == "volume rm xless-xcode-26.2-17C52-arm64" ]] || fail "--packs with a pack in use: $code $(removed)"
grep -q 'leaving the pack xless-xcode-27.0-27A266a-arm64: in use by builder (xless:9.9.9-arm64)' "$t/out" || fail "the container is not named: $(cat "$t/out")"
grep -q 'docker stop builder' "$t/err" || fail "no way out: $(cat "$t/err")"
run --all --yes
[[ $code == 11 ]] && grep -qx 'volume rm xless-xcode-26.2-17C52-arm64' "$log" && ! removed | grep -q 'xless-xcode-27.0' || fail "--all with a pack in use: $code $(removed)"
grep -qx 'volume rm xless-cargo xless-rn-work-ov-12345678' "$log" || fail "--all with a pack in use did not go on: $(removed)"
run --packs --dry-run
[[ $code == 0 && -z "$(removed)" ]] && grep -q 'would leave the pack xless-xcode-27.0-27A266a-arm64' "$t/out" || fail "dry run, pack in use: $code $(cat "$t/out")"
extra=()
mkcache

# --old: what older layouts leave: the legacy images and those of another xless version (xless:9.9.9-… and its kits stay), the label
# prune; no pack volume, no other volume, no cache.
mkcache
run --old --dry-run
[[ $code == 0 && -z "$(removed)" ]] || fail "--old --dry-run: $code $(removed)"
[[ "$(sed -n 1,6p "$t/out")" == "would remove 5 image tags:
  xless-base:local-arm64
  xless:local-arm64
  xless:local-arm64-xcode27.0-tauri
  xless:9.8.0-arm64
  xless:9.8.0-arm64-react-native" ]] || fail "--old --dry-run says: $(cat "$t/out")"
[[ "$(sed -n 7p "$t/out")" == "and the untagged older builds (docker image prune --filter label=org.xless.image=true)" ]] || fail "--old --dry-run says: $(cat "$t/out")"
grep -q '9\.9\.9\|xless-xcode' "$t/out" && fail "--old names this xless's image or a pack: $(cat "$t/out")"
both='image rm xless-base:local-arm64
image rm xless:local-arm64
image rm xless:local-arm64-xcode27.0-tauri
image rm xless:9.8.0-arm64
image rm xless:9.8.0-arm64-react-native
image prune --force --filter label=org.xless.image=true'
# It asks, and nothing but yes is yes.
for no in n "" nope; do
  on "$no" --old --cache
  [[ $code == 0 && -z "$(removed)" && -d "$cache" ]] || fail "--old, answered '$no': $code $(removed)"
  [[ "$(cat "$t/out")" == "would remove 5 image tags:
  xless-base:local-arm64
  xless:local-arm64
  xless:local-arm64-xcode27.0-tauri
  xless:9.8.0-arm64
  xless:9.8.0-arm64-react-native
and the untagged older builds (docker image prune --filter label=org.xless.image=true)
"*"Remove these 5 image tags, and the untagged older builds? [y/N] "*"cancelled; nothing was removed" ]] || fail "--old asks: $(cat "$t/out")"
done
on y --old
[[ $code == 0 && "$(removed)" == "$both" && -d "$cache" ]] || fail "--old, answered yes: $code $(removed) $(cat "$t/out")"
# --yes answers; without a terminal, or with --no-input, it is needed.
on none --old --yes
[[ $code == 0 && "$(removed)" == "$both" && -d "$cache" ]] || fail "--old --yes: $code $(removed) $(cat "$t/err")"
[[ "$(sed -n 1p "$t/out")" == "removing 5 image tags:" ]] || fail "--old --yes says: $(cat "$t/out")"
on none --old --cache
[[ $code == 11 && -z "$(removed)" && -d "$cache" ]] || fail "--old without a terminal: $code $(removed)"
grep -q 'needs a confirmation and there is no terminal — re-run with --yes' "$t/err" || fail "--old without a terminal says: $(cat "$t/err")"
on y --old --no-input
[[ $code == 23 && -z "$(removed)" ]] || fail "--old --no-input: $code $(removed)"
# What a tag is by the time it would go: `xless setup` in another terminal, while the question waits.
f="$t/images/xless_local-arm64"
echo '{"Id":"sha256:xless:local-arm64","Architecture":"arm64","Config":{"Labels":{}},"RootFS":{"Layers":[]}}' > "$f.once"
echo '{"Id":"sha256:new","Architecture":"arm64","Config":{"Labels":{}},"RootFS":{"Layers":[]}}' > "$f"
on y --old
[[ $code == 0 && "$(removed)" == "$(grep -vx 'image rm xless:local-arm64' <<<"$both")" ]] || fail "--old removed another image: $code $(removed)"
grep -qx 'kept xless:local-arm64: it is another image now' "$t/out" || fail "--old does not say it: $(cat "$t/out")"
rm -f "$f" "$f.once"
# This xless's image tag unknown (a share with no release): only the legacy images, never those of another version.
extra=(XLESS_SHARE="$t/noshare")
run --old --yes
[[ $code == 0 && "$(removed)" == 'image rm xless-base:local-arm64
image rm xless:local-arm64
image rm xless:local-arm64-xcode27.0-tauri
image prune --force --filter label=org.xless.image=true' ]] || fail "--old without a known tag: $code $(removed) $(cat "$t/err")"
extra=()
# Only untagged builds, and this xless's: nothing to ask about.
cp "$t/bin/docker" "$t/docker.keep"
sed -i.bak 's/xless-base:local-arm64 xless:local-arm64 xless:local-arm64-xcode27.0-tauri xless:9.9.9-arm64 xless:9.9.9-arm64-tauri/xless:9.9.9-arm64 xless:9.9.9-arm64-tauri/; s/xless:9.8.0-arm64 xless:9.8.0-arm64-react-native//' "$t/bin/docker"; rm "$t/bin/docker.bak"
on none --old
[[ $code == 0 && "$(removed)" == 'image prune --force --filter label=org.xless.image=true' ]] || fail "--old without an old tag: $code $(removed)"
cp "$t/docker.keep" "$t/bin/docker"

# --old and the native side: it removes an older install's SDK bundle, metadata, record and toolchains; never the swift-sdks directory
# around the bundle, a person's own SDK there, the store of packs, or the native home. Without the record the bundle is not xless's.
nh="$t/home/.local/share/xless-native"; sdks="$t/home/.swiftpm/swift-sdks"
pack_json='{"format":1,"xcode":"26.2","build":"17C52","arch":"arm64","swift":"6.2.3","mode":"own","parts":{}}'
mkolder() { mkdir -p "$nh/bin" "$nh/toolchains/swift-6.1.0" "$nh/xcodes/26.2-17C52-arm64" "$sdks/darwin.artifactbundle" "$sdks/mine.artifactbundle" "$t/home/.config/xless"
            echo "$pack_json" > "$nh/xcodes/26.2-17C52-arm64/pack.json"; echo '{}' > "$t/home/.config/xless/toolchain-meta.json"
            echo '{"version":"6.1.0","root":"/x"}' > "$nh/swift-toolchain.json"; mkcache; }
mkolder
run --old --dry-run
for p in .swiftpm/swift-sdks/darwin.artifactbundle .config/xless/toolchain-meta.json .local/share/xless-native/toolchains .local/share/xless-native/swift-toolchain.json; do
  grep -q "^would remove the older native install's $t/home/$p" "$t/out" || fail "--old --dry-run does not list $p: $(cat "$t/out")"
  [[ -e "$t/home/$p" ]] || fail "--old --dry-run removed $p"
done
on y --old
[[ $code == 0 ]] || fail "--old with an older install exits $code: $(cat "$t/err")"
grep -q 'Remove these 5 image tags, the untagged older builds, and what an older xless installed natively? \[y/N\] ' "$t/out" || fail "--old does not ask about the older install: $(cat "$t/out")"
for p in .swiftpm/swift-sdks/darwin.artifactbundle .config/xless/toolchain-meta.json .local/share/xless-native/toolchains .local/share/xless-native/swift-toolchain.json; do
  [[ ! -e "$t/home/$p" ]] || fail "--old left $p"
done
for p in .swiftpm/swift-sdks .swiftpm/swift-sdks/mine.artifactbundle .local/share/xless-native .local/share/xless-native/bin .local/share/xless-native/xcodes/26.2-17C52-arm64/pack.json .config/xless .cache/xless/sdk/xcode27.0-27A266a/arm64/f; do
  [[ -e "$t/home/$p" ]] || fail "--old removed $p"
done
grep -q '^volume' "$log" && fail "--old touched a volume: $(cat "$log")"
# Without the record, the SDK bundle (and the metadata) are not known to be xless's.
mkolder; rm "$nh/swift-toolchain.json"
on y --old
for p in .swiftpm/swift-sdks/darwin.artifactbundle .config/xless/toolchain-meta.json .local/share/xless-native/toolchains; do
  [[ -e "$t/home/$p" ]] || fail "--old removed $p without a record"
done
grep -q '^no older native install' "$t/out" || fail "no older install not said: $(cat "$t/out")"
# --old with the XDG_CONFIG_HOME of the SDK: the bundle where xtool keeps it, and no more.
rm -rf "$t/home/.swiftpm" "$nh" "$t/home/.config/xless"; mkdir -p "$t/xdg/swiftpm/swift-sdks/darwin.artifactbundle" "$t/xdg/swiftpm/swift-sdks/other" "$t/xdg/xless" "$nh"
echo '{}' > "$t/xdg/xless/toolchain-meta.json"; echo '{}' > "$nh/swift-toolchain.json"
extra=(XDG_CONFIG_HOME="$t/xdg")
run --old --yes
[[ ! -e "$t/xdg/swiftpm/swift-sdks/darwin.artifactbundle" && -d "$t/xdg/swiftpm/swift-sdks/other" && ! -e "$t/xdg/xless/toolchain-meta.json" ]] || fail "--old with XDG_CONFIG_HOME"
extra=(); rm -rf "$t/xdg" "$nh"

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

# What an override or a link leads to is not an older install's: XLESS_TOOLCHAIN_META names a file in use (an export's, a pack's), and a build's
# XDG_CONFIG_HOME is <cache>/xless/xtool-config/<pack>, whose swift-sdks links into the pack. Nothing of those goes, under --old or --native.
store="$t/store2"; rm -rf "$store"; mkdir -p "$store/26.2-17C52-arm64/config/swiftpm/swift-sdks/darwin.artifactbundle"
echo "$pack_json" > "$store/26.2-17C52-arm64/pack.json"; echo '{}' > "$store/26.2-17C52-arm64/toolchain-meta.json"
echo sdk > "$store/26.2-17C52-arm64/config/swiftpm/swift-sdks/darwin.artifactbundle/f"
survives() {   # DESCRIPTION: what must be there
  [[ -f "$cache/sdk/xcode27.0-27A266a/toolchain-meta.json" && -f "$store/26.2-17C52-arm64/toolchain-meta.json" && -f "$store/26.2-17C52-arm64/pack.json" \
     && -f "$store/26.2-17C52-arm64/config/swiftpm/swift-sdks/darwin.artifactbundle/f" ]] || fail "$1: an export or a pack lost a file"
}
for flag in --old --native; do
  # (a) XLESS_TOOLCHAIN_META names an export's metadata in the cache; (b) a pack's
  for target in "$cache/sdk/xcode27.0-27A266a/toolchain-meta.json" "$store/26.2-17C52-arm64/toolchain-meta.json"; do
    mkolder; echo '{}' > "$cache/sdk/xcode27.0-27A266a/toolchain-meta.json"
    extra=(XLESS_XCODES="$store" XLESS_TOOLCHAIN_META="$target")
    run "$flag" --yes
    [[ $code == 0 ]] || fail "$flag with XLESS_TOOLCHAIN_META=$target exits $code: $(cat "$t/err")"
    survives "$flag, XLESS_TOOLCHAIN_META=$target"
    [[ ! -e "$t/home/.config/xless/toolchain-meta.json" ]] || fail "$flag left the older install's own metadata"
  done
  # (c) XDG_CONFIG_HOME of a build: swift-sdks is a link into the pack
  mkolder; echo '{}' > "$cache/sdk/xcode27.0-27A266a/toolchain-meta.json"
  xdg="$cache/xless/xtool-config/26.2-17C52-arm64"; mkdir -p "$xdg/swiftpm"; ln -s "$store/26.2-17C52-arm64/config/swiftpm/swift-sdks" "$xdg/swiftpm/swift-sdks"
  extra=(XLESS_XCODES="$store" XDG_CONFIG_HOME="$xdg")
  run "$flag" --yes
  [[ $code == 0 ]] || fail "$flag with a build's XDG_CONFIG_HOME exits $code: $(cat "$t/err")"
  survives "$flag, XDG_CONFIG_HOME of a build"
  grep -q 'it is, or leads to' "$t/out" || [[ "$flag" == --native ]] || fail "$flag does not say it leaves the SDK of the pack: $(cat "$t/out")"
  extra=(); rm -rf "$nh" "$t/home/.swiftpm" "$t/home/.config/xless" "$cache/xless"
done
mkcache

# --native: the native home (its store of packs too) and the SDK and metadata an older install put elsewhere, without Docker; listed by
# default, kept by --cache. The packs are asked about.
extra=(DOCKER_DOWN=1)
mknative() { mkdir -p "$nh/bin" "$nh/xcodes/26.2-17C52-arm64" "$t/home/.swiftpm/swift-sdks/darwin.artifactbundle" "$t/home/.config/xless"
             echo "$pack_json" > "$nh/xcodes/26.2-17C52-arm64/pack.json"
             echo '{}' > "$t/home/.config/xless/toolchain-meta.json"; mkdir -p "$t/home/.config/swiftpm-other"; }
# An SDK that was put there with no older install (no toolchain record): only the native home goes.
mknative; mkcache
run --native --yes
for p in .swiftpm/swift-sdks/darwin.artifactbundle .config/xless/toolchain-meta.json; do
  [[ -e "$t/home/$p" ]] || fail "--native without a native record removed $p"
done
[[ ! -e "$nh" ]] || fail "--native left the native home"
mknative; echo '{"version":"6.4.0","root":"/x"}' > "$nh/swift-toolchain.json"
run
grep -q "^found the native install's $nh" "$t/out" || fail "native not listed: $(cat "$t/out")"
grep -q "^found the Xcode pack $rt/home/.local/share/xless-native/xcodes/26.2-17C52-arm64: Xcode 26.2 (17C52, arm64)" "$t/out" || fail "the pack of the store not listed: $(cat "$t/out")"
[[ -d "$nh" ]] || fail "listing removed the native install"
run --cache
[[ -d "$nh" ]] || fail "--cache removed the native install"
run --native --dry-run
grep -q "^would remove the native install's $t/home/.swiftpm/swift-sdks/darwin.artifactbundle" "$t/out" || fail "native dry run: $(cat "$t/out")"
[[ -d "$nh" ]] || fail "dry run removed the native install"
on none --native
[[ $code == 11 && -d "$nh/xcodes" ]] || fail "--native without a terminal removed the store: $code"
run --native --yes
[[ $code == 0 ]] || fail "--native exits $code: $(cat "$t/err")"
for p in .local/share/xless-native .swiftpm/swift-sdks/darwin.artifactbundle .config/xless/toolchain-meta.json; do
  [[ ! -e "$t/home/$p" ]] || fail "--native left $p"
done
[[ -d "$t/home/.config/swiftpm-other" ]] || fail "--native removed something else"
grep -q '^image\|^volume' "$log" && fail "--native used docker: $(cat "$log")"
run
grep -q '^no native install' "$t/out" || fail "no native install not said: $(cat "$t/out")"
# A store of its own (XLESS_XCODES): its packs go, with Docker to say none is in use; the directory and what else is in it stay.
store="$t/store"; mkdir -p "$store/26.2-17C52-arm64" "$store/notes"; echo "$pack_json" > "$store/26.2-17C52-arm64/pack.json"; echo keep > "$store/notes/f"
mkdir -p "$nh/bin"
extra=(XLESS_XCODES="$store")
run --native --yes
[[ $code == 0 && -d "$store/26.2-17C52-arm64" && ! -e "$nh" ]] || fail "--native took the packs of a store of its own: $code $(cat "$t/err")"
run --packs --yes
[[ $code == 0 && ! -e "$store/26.2-17C52-arm64" && -f "$store/notes/f" ]] || fail "--packs with XLESS_XCODES: $code $(cat "$t/err")"
# ... and --old leaves it whole.
mkdir -p "$store/26.2-17C52-arm64"; echo "$pack_json" > "$store/26.2-17C52-arm64/pack.json"; extra=(XLESS_XCODES="$store")
run --old --yes
[[ -f "$store/26.2-17C52-arm64/pack.json" ]] || fail "--old removed a pack of the store"
# The packs of the native home and of XLESS_XCODES, in two places: --native lists and asks about those of the home, --packs those of the other
# store; each only its own; a directory that is no pack of its name (a copy under another name) is neither listed nor removed.
nh="$t/home/.local/share/xless-native"; store="$t/store3"; rm -rf "$nh" "$store"
mkpack() { mkdir -p "$1"; echo "$pack_json" > "$1/pack.json"; }   # DIR: a pack of Xcode 26.2 in it
mkboth() { rm -rf "$nh" "$store"; mkdir -p "$nh/bin"; mkpack "$nh/xcodes/26.2-17C52-arm64"; mkpack "$store/26.2-17C52-arm64"; mkpack "$store/my-backup"; mkpack "$nh/xcodes/copy-of-it"; }
mkboth; extra=(XLESS_XCODES="$store" DOCKER_DOWN=0)
run --native --dry-run
grep -qx "would remove the Xcode pack $rt/home/.local/share/xless-native/xcodes/26.2-17C52-arm64: Xcode 26.2 (17C52, arm64)" "$t/out" || fail "the home's pack is not listed: $(cat "$t/out")"
grep -q "$store" "$t/out" && fail "--native lists the store of its own: $(cat "$t/out")"
grep -q 'my-backup\|copy-of-it' "$t/out" && fail "a copy under another name is listed: $(cat "$t/out")"
grep -q 'preparing a pack again takes minutes' "$t/out" || fail "--native does not say what preparing again needs: $(cat "$t/out")"
on n --native
grep -q 'Remove 1 Xcode pack of the native install?' "$t/out" && [[ -d "$nh/xcodes/26.2-17C52-arm64" ]] || fail "--native does not ask about the home's packs: $(cat "$t/out")"
on none --native
[[ $code == 11 && -d "$nh/xcodes" ]] || fail "--native without a terminal removed the home's packs: $code"
run --all --dry-run
grep -qx "would remove the Xcode pack $rt/home/.local/share/xless-native/xcodes/26.2-17C52-arm64: Xcode 26.2 (17C52, arm64)" "$t/out" && grep -qx "would remove the Xcode pack $rt/store3/26.2-17C52-arm64: Xcode 26.2 (17C52, arm64)" "$t/out" \
  || fail "--all does not list the packs of both places: $(cat "$t/out")"
run --packs --yes
[[ $code == 0 && ! -e "$store/26.2-17C52-arm64" && -d "$store/my-backup" && -d "$nh/xcodes/26.2-17C52-arm64" ]] || fail "--packs: $code $(cat "$t/err")"
mkboth
run --native --yes
[[ $code == 0 && ! -e "$nh" && -d "$store/26.2-17C52-arm64" && -d "$store/my-backup" ]] || fail "--native took more than the home: $code $(cat "$t/err")"
# A pack in use. docker cannot be asked: the pack is left and the message says so, not that a container uses it.
mkboth
extra=(XLESS_XCODES="$store" PS_FAIL=1)
run --packs --yes
[[ $code == 11 && -d "$store/26.2-17C52-arm64" ]] || fail "--packs with docker unable to answer: $code"
grep -q 'docker could not be asked whether a container uses it' "$t/err" && grep -q 'check that it runs (docker ps), then run xless clean again' "$t/err" \
  && ! grep -q 'docker stop' "$t/err" || fail "the message for docker unable to answer: $(cat "$t/err")"
extra=(PS_FAIL=1)
run --packs --yes
[[ $code == 11 && -z "$(removed)" ]] && grep -q 'docker could not be asked whether a container uses it' "$t/err" || fail "pack volumes with docker unable to answer: $code $(removed)"
# Looked at again right before it goes: no container the first time, one the second.
mkboth; rm -f "$t/images/psq"
extra=(XLESS_XCODES="$store" PSQ_FREE=1 PSQ_MOUNT="$store/26.2-17C52-arm64")
run --packs --yes
[[ $code == 11 && -d "$store/26.2-17C52-arm64" && -d "$store/my-backup" ]] || fail "a pack that a container began to use was removed: $code"
grep -q "the pack $rt/store3/26.2-17C52-arm64 was left: a running container uses it (builder (xless:9.9.9-arm64))" "$t/err" || fail "the pack in use is not named: $(cat "$t/err")"
# The native home with a pack in use in it: kept whole, and the listing says so (not that its packs are being removed).
mkboth; mkdir -p "$nh/xcodes/27.0-27A266a-arm64"; echo '{"format":1,"xcode":"27.0","build":"27A266a","arch":"arm64","swift":"6.4","mode":"own","parts":{}}' > "$nh/xcodes/27.0-27A266a-arm64/pack.json"; rm -f "$t/images/psq"
extra=(XLESS_XCODES="$nh/xcodes" PSQ_FREE=0 PSQ_MOUNT="$nh/xcodes/26.2-17C52-arm64")
run --native --yes
[[ $code == 11 && -d "$nh/xcodes/26.2-17C52-arm64" && -d "$nh/xcodes/27.0-27A266a-arm64" && -d "$nh/bin" ]] || fail "--native removed a home with a pack in use: $code"
grep -q "^leaving the native install's $nh: a pack in it is in use" "$t/out" && grep -q "^leaving the pack $rt/home/.local/share/xless-native/xcodes/26.2-17C52-arm64: in use by builder" "$t/out" \
  && grep -q "^leaving the Xcode pack $rt/home/.local/share/xless-native/xcodes/27.0-27A266a-arm64: the native install is kept whole" "$t/out" || fail "the listing of a blocked home: $(cat "$t/out")"
grep -q '^removing the' "$t/out" && fail "the listing says removing: $(cat "$t/out")"
extra=(); rm -f "$t/images/psq"
# --native removes a root that is what xless made, and refuses another: a relative one, /, the home directory, a directory with none of its marks.
mkdir -p "$t/other" "$t/rel"; echo x > "$t/other/file"
for home_ in "relative" "/" "$t/home" "$t/other"; do
  extra=(XLESS_NATIVE_HOME="$home_")
  code=0; (cd "$t/rel" && : > "$log" && env -i HOME="$t/home" PATH="$t/bin:/usr/bin:/bin" DOCKER_LOG="$log" IMAGES="$t/images" XLESS_SHARE="$share" XLESS_NATIVE_HOME="$home_" "$x" clean --native --yes >"$t/out" 2>"$t/err") || code=$?
  [[ $code == 11 ]] || fail "--native with XLESS_NATIVE_HOME=$home_ exits $code"
  grep -q 'set XLESS_NATIVE_HOME to the native home' "$t/err" || fail "no fix for XLESS_NATIVE_HOME=$home_: $(cat "$t/err")"
  case "$home_" in relative) want='is a relative path' ;; /) want='the native home is /' ;; "$t/home") want='is your home directory' ;; *) want='holds none of what xless puts in one' ;; esac
  grep -q -- "$want" "$t/err" || fail "XLESS_NATIVE_HOME=$home_ says: $(cat "$t/err")"
  run
  grep -q '^not listing the native home' "$t/out" || [[ "$home_" == relative ]] || fail "the listing for XLESS_NATIVE_HOME=$home_: $(cat "$t/out")"
done
[[ -f "$t/other/file" && -d "$t/home/.cache" ]] || fail "a refused root was touched"
extra=()
mkdir -p "$t/ok/bin"; extra=(XLESS_NATIVE_HOME="$t/ok"); run --native --yes
[[ $code == 0 && ! -e "$t/ok" ]] || fail "--native of a native home: $code $(cat "$t/err")"
extra=()

# `xless sdk install` (which --image used to serve) says what to run, in every form, so an old script gets the message, not "unknown command".
for form in "" "--image xless:local-arm64-xcode27.0" "--xtoolsdk $t/x/arm64/darwin.xtoolsdk --meta $t/x/toolchain-meta.json"; do
  code=0; env -i HOME="$t/home" PATH="$t/bin:/usr/bin:/bin" DOCKER_LOG="$log" "$x" sdk install $form >"$t/out" 2>"$t/err" || code=$?
  [[ $code == 11 ]] && grep -q 'xless sdk install no longer installs an SDK.*xless setup --sdk' "$t/err" || fail "sdk install $form: $code $(cat "$t/err")"
done
[[ -z "$(grep '^cp\|^create' "$log")" ]] || fail "sdk install --image used docker"
echo "clean.test.sh: ok"
