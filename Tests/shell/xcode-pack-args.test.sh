#!/usr/bin/env bash
# scripts/xcode-pack-args.sh's pack_args, sourced as the sample scripts source it (set -euo pipefail): the newest build of
# $xcode for $arch, from a directory store (XLESS_XCODES) or from the pack volumes, found by name (a volume made by hand has
# no label); and without one, the message that names what prepares it, and exit 2.
set -euo pipefail
repo="$(cd "$(dirname "$0")/../.." && pwd)"
t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT
fail() { echo "FAIL: $*"; exit 1; }

# run <xcode> <arch> [XLESS_XCODES]: pack_args in a shell of its own; prints the words of $pack, one per line.
run() {
  XLESS_XCODES="${3:-}" xcode="$1" arch="$2" FAKE="$t/docker.log" bash -c '
    set -euo pipefail
    . "$1/scripts/xcode-pack-args.sh"
    args=("$2/docker" --context fake)
    pack_args sample
    printf "%s\n" "${pack[@]}"' sh "$repo" "$t"
}

# The fake docker: lists volumes (it would leave the unlabelled one out of a listing filtered by the label).
cat > "$t/docker" <<'EOF'
#!/bin/sh
echo "$*" >> "$FAKE"
[ "${DOCKER_DOWN:-0}" != 1 ] || { echo "Cannot connect to the Docker daemon" >&2; exit 1; }
case "$*" in *"volume ls"*) ;; *) exit 1 ;; esac
case "$*" in *label=*) printf 'xless-xcode-26.2-17C52-arm64\n' ;;
  *) printf 'carryon_db\nxless-xcode-26.2-17C52-arm64\nxless-xcode-26.2-17C60-arm64\nxless-xcode-26.2-17C52-amd64\nxless-xcode-27.0-27A266a-arm64\n' ;; esac
EOF
chmod +x "$t/docker"

# Volumes: the newest build of 26.2 on arm64 (17C60, made by hand: no label), read-only at /xcodes.
out=$(run 26.2 arm64) || fail "volumes: $out"
[[ "$out" == $'--mount\ntype=volume,src=xless-xcode-26.2-17C60-arm64,dst=/xcodes,readonly\n-e\nXLESS_XCODE=/xcodes/26.2-17C60-arm64' ]] || fail "volumes: $out"
grep -q -- 'label=' "$t/docker.log" && fail "the volumes are listed by label: $(cat "$t/docker.log")"
# None of that Xcode: the message, and exit 2.
code=0; out=$(run 26.4 arm64 2>&1) || code=$?
[[ $code == 2 ]] || fail "no pack volume: exit $code: $out"
[[ "$out" == "sample: no pack volume of Xcode 26.4 for arm64; prepare it: xless setup --docker --xcode <Xcode 26.4 .xip>" ]] || fail "no pack volume: $out"
# A docker that fails to list the volumes is said to fail (its own message too), not taken for no pack volume.
code=0; out=$(DOCKER_DOWN=1 run 26.2 arm64 2>&1) || code=$?
[[ $code == 2 && "$out" == *"Cannot connect to the Docker daemon"* && "$out" == *"sample: docker could not list the volumes ($t/docker --context fake volume ls); check that it runs (docker ps)"* \
   && "$out" != *"no pack volume"* ]] || fail "docker down: exit $code: $out"

# A directory store: the newest pack of 26.2 for arm64 with a pack.json, its directory alone, read-only.
mkdir -p "$t/store/26.2-17C52-arm64" "$t/store/26.2-17C60-arm64" "$t/store/26.2-17C60-amd64"
for p in 26.2-17C52-arm64 26.2-17C60-arm64 26.2-17C60-amd64; do echo '{}' > "$t/store/$p/pack.json"; done
out=$(run 26.2 arm64 "$t/store") || fail "store: $out"
[[ "$out" == "--mount"$'\n'"type=bind,src=$t/store/26.2-17C60-arm64,dst=/xcodes/26.2-17C60-arm64,readonly"$'\n-e\nXLESS_XCODE=/xcodes/26.2-17C60-arm64' ]] || fail "store: $out"
# A store whose path has a comma or a quote: the field quoted, as docker reads --mount (CSV), and as xless writes it.
mkdir -p "$t/a,b\"c/26.2-17C52-arm64" && echo '{}' > "$t/a,b\"c/26.2-17C52-arm64/pack.json"
out=$(run 26.2 arm64 "$t/a,b\"c") || fail "a store with a comma: $out"
[[ "$(sed -n 2p <<<"$out")" == "type=bind,\"src=$t/a,b\"\"c/26.2-17C52-arm64\",dst=/xcodes/26.2-17C52-arm64,readonly" ]] || fail "a store with a comma: $out"
# None there (ls finds nothing, which fails under pipefail): the message, and exit 2, not a silent stop.
code=0; out=$(run 27.0 arm64 "$t/store" 2>&1) || code=$?
[[ $code == 2 ]] || fail "no pack in the store: exit $code: $out"
[[ "$out" == "sample: no pack of Xcode 27.0 for arm64 in $t/store; prepare it: xless setup --docker --xcode <Xcode 27.0 .xip>" ]] || fail "no pack in the store: $out"
echo "PASS xcode-pack-args"
