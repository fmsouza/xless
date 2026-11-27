#!/usr/bin/env bash
# The xless image used directly: a container of it, started by hand or as a CI job's, is a Linux host that has everything
# installed (docs/images.md). With the tauri kit's image, as the calling user (HOME=/tmp), samples/HelloCargo copied to a
# writable /work:
#   - with an Xcode's pack volume read-only at /xcodes (the store the image names, XLESS_XCODES), `xless run --config … --to
#     finalize` builds it natively and the .app is there;
#   - the same volume mounted elsewhere (XLESS_XCODE and XLESS_XCODES naming it there) builds it too: the pack is relocatable;
#   - nothing writes to the pack: a touch into it fails, also as root;
#   - with no pack, the account commands work (`xless apps --help`), `xless build` of samples/HelloShip exits with the usage
#     code and names `xless setup`, and in the xless image, which has no Node or Rust, an overlay's run says what is missing.
# Run by `make test-image`.
#   XLESS_IMAGE_ARCH, XLESS_IMAGE, DOCKER_CONTEXT: the image and the docker context, as Tests/shell/image-target.sh decides them
#   (the same for image-contents.test.sh; make test-image passes them to both); the tauri kit is <image>-tauri. XLESS_XCODE_PIN
#   (default versions.env's XCODE_VERSION): the Xcode whose pack volume (xless-xcode-<pin>-<build>-<arch>) builds.
#   XLESS_IMAGE_REQUIRED=1 (make test-image): a missing docker, image, kit or pack fails the test. Without it the test skips.
# The first run downloads the sample's Rust toolchain and crates into a volume of its own, which it removes when it ends.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
fail() { echo "FAIL: $*"; [[ ! -f "${t:-/nonexistent}/err" ]] || tail -30 "$t/err"; exit 1; }
skip() {
  [[ -z "${XLESS_IMAGE_REQUIRED:-}" ]] || fail "$* (XLESS_IMAGE_REQUIRED is set)"
  echo "SKIP: $*"
  exit 0
}
command -v docker >/dev/null 2>&1 || skip "no docker"
# shellcheck source=SCRIPTDIR/image-target.sh
. "$root/Tests/shell/image-target.sh"
echo "image-direct: image $image, docker context ${shown:-default}"
xcode="${XLESS_XCODE_PIN:-$(sed -n 's/^XCODE_VERSION=//p' "$root/versions.env")}"
"${d[@]}" version >/dev/null 2>&1 || skip "no docker daemon (context ${shown:-default})"
kit="$image-tauri"
"${d[@]}" image inspect "$image" >/dev/null 2>&1 || skip "no image $image (scripts/docker-images.sh image --arch $arch)"
"${d[@]}" image inspect "$kit" >/dev/null 2>&1 || skip "no image $kit (xless setup --docker --with tauri)"
volume="$("${d[@]}" volume ls --format '{{.Name}}' | grep -E "^xless-xcode-${xcode//./\\.}-[A-Za-z0-9]+-$arch\$" | sort | tail -1 || true)"
[[ -n "$volume" ]] || skip "no pack volume of Xcode $xcode for $arch (xless setup --docker --xcode <Xcode $xcode .xip>)"
name="${volume#xless-xcode-}"

t=$(mktemp -d)
cache="xless-image-direct-$$"
cleanup() { "${d[@]}" volume rm -f "$cache" >/dev/null 2>&1 || true; rm -rf "$t"; }
trap cleanup EXIT
"${d[@]}" volume create --label org.xless.test=image-direct "$cache" >/dev/null
# The samples' tracked files, for a container's stdin.
for sample in HelloCargo HelloShip; do git -C "$root" archive -o "$t/$sample.tar" "HEAD:samples/$sample"; done
# As the calling user, with a home of its own; the work copies and the Rust toolchains in the test's volume at /cache (the
# image's XLESS_WORK_ROOT, RUSTUP_HOME and CARGO_HOME), the sample in /work. stdout+stderr → $t/err, exit code → $code.
# shellcheck disable=SC2054 # (the commas are --tmpfs options)
as_user=(run --rm -i --pull=never --platform "linux/$arch" --user "$(id -u):$(id -g)" -e HOME=/tmp --tmpfs /work:exec,mode=1777)
box() {
  code=0
  "${d[@]}" "${as_user[@]}" "$@" >"$t/err" 2>&1 || code=$?
}
store=(--mount "type=volume,src=$volume,dst=/xcodes,readonly")
elsewhere=(--mount "type=volume,src=$volume,dst=/elsewhere,readonly" -e "XLESS_XCODE=/elsewhere/$name" -e XLESS_XCODES=/elsewhere)
# The sample's tracked files, as a git checkout of their own (xless copies the tracked files of an overlay's source).
# Each step under set -e (a step of an && list that fails does not stop it): no app, or a part of it missing, exits 1.
build='set -eu
mkdir /work/HelloCargo
tar -x -C /work/HelloCargo
cd /work/HelloCargo
git init -q
git add -A
git -c user.name=t -c user.email=t@example.com -c commit.gpgsign=false commit -qm sample
XLESS_BUILD_NUMBER=1.0.0.2026010101 xless run --config /work/HelloCargo/xless.overlay.example.yml --to finalize </dev/null
app="$(find /cache/work -maxdepth 6 -path "*/ios/final/HelloCargo.app" | head -1)"
[ -n "$app" ] && [ -s "$app/HelloCargo" ] && [ -s "$app/Info.plist" ] || { echo "no HelloCargo.app with its executable and Info.plist"; exit 1; }
echo "app: $app"'

# 1. Built natively in the kit's image, from the pack the image's store holds.
box -v "$cache:/cache" "${store[@]}" "$kit" bash -c "$build" <"$t/HelloCargo.tar"
[[ "$code" == 0 ]] || fail "xless run --config … --to finalize in $kit with the pack $name read-only exited $code"
grep -q 'needs, and this machine lacks' "$t/err" && fail "xless said something is missing in $kit"
grep -q '^app: /' "$t/err" || fail "no HelloCargo.app"
grep -qF "from /xcodes/$name/toolchain" "$t/err" || fail "the build did not use the pack at /xcodes/$name"
echo "ok: built natively in $kit with the pack at /xcodes/$name read-only ($(grep '^app: ' "$t/err"))"

# 2. The same volume mounted elsewhere: XLESS_XCODE and XLESS_XCODES name it there, and nothing is at /xcodes.
"${d[@]}" "${as_user[@]}" -v "$cache:/cache" "$kit" sh -c 'rm -rf /cache/work/*' >/dev/null
box -v "$cache:/cache" "${elsewhere[@]}" "$kit" bash -c "set -eu; [ -z \"\$(ls -A /xcodes)\" ] || { echo '/xcodes is not empty'; exit 3; }; $build" <"$t/HelloCargo.tar"
[[ "$code" == 0 ]] || fail "the pack mounted at /elsewhere/$name: the build exited $code"
grep -q '^app: /' "$t/err" || fail "no HelloCargo.app with the pack at /elsewhere/$name"
grep -qF "from /elsewhere/$name/toolchain" "$t/err" || fail "the build did not use the pack at /elsewhere/$name"
echo "ok: built natively with the pack at /elsewhere/$name (relocated)"

# 3. Read-only: a touch into the pack fails, as the user and as root.
box "${store[@]}" "$image" touch "/xcodes/$name/x"
[[ "$code" != 0 ]] || fail "the user wrote into the pack"
code=0
"${d[@]}" run --rm --pull=never --platform "linux/$arch" "${store[@]}" "$image" touch "/xcodes/$name/x" >"$t/err" 2>&1 || code=$?
[[ "$code" != 0 ]] && grep -qi 'read-only' "$t/err" || fail "root wrote into the pack ($code): $(cat "$t/err")"
echo "ok: the pack is read-only ($(head -1 "$t/err"))"

# 4. No pack at all: the account commands work; a build says what to run.
box "$image" xless apps --help
[[ "$code" == 0 ]] || fail "xless apps --help with no pack exited $code"
box "$image" bash -c 'set -eu; mkdir /work/HelloShip; tar -x -C /work/HelloShip; cd /work/HelloShip; exec xless build --platform ios </dev/null' <"$t/HelloShip.tar"
[[ "$code" == 2 ]] && grep -q 'xless setup' "$t/err" || fail "xless build with no pack: exit $code, $(cat "$t/err")"
echo "ok: with no pack, xless apps --help exits 0 and xless build exits 2: $(grep -m1 'xless setup' "$t/err")"
# An overlay (a Cargo app) in the xless image, which has no Rust, and no pack here: what is missing is said.
box "$image" bash -c 'set -eu; mkdir /work/HelloCargo; tar -x -C /work/HelloCargo; cd /work/HelloCargo; XLESS_BUILD_NUMBER=1.0.0.2026010101 exec xless run --config xless.overlay.example.yml --to finalize </dev/null' <"$t/HelloCargo.tar"
want="needs, and this machine lacks: an Xcode pack (none here: xless setup), rustup-init or rustup — \`xless run --docker\` has them all"
[[ "$code" == 2 ]] && grep -qF "$want" "$t/err" || fail "an overlay in $image with no pack: exit $code, $(cat "$t/err")"
echo "ok: an overlay in $image says what it lacks: $(grep -m1 -o 'needs, and this machine lacks: [^—]*' "$t/err")"
echo "PASS image-direct ($kit, pack $name, docker context ${shown:-default})"
