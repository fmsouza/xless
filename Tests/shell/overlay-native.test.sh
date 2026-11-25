#!/usr/bin/env bash
# On a Mac, the built xless builds an overlay's app natively, with the Xcode that is installed and stand-ins for rustup and cargo: the
# stand-in is the app's build code, which looks for everything that it should not have and writes down what it got. Nothing is
# downloaded, no Apple account, no keychain, and the home directory is the test's own; the user's is only asked whether it can be
# listed (it cannot).
#   Tests/shell/overlay-native.test.sh            (builds xless with `swift build`; XLESS_BIN=<path> uses that binary)
#   XLESS_TEST_XCODE=1: it may not be skipped. Without it the test ends early where there is no Xcode.
set -euo pipefail
repo="$(cd "$(dirname "$0")/../.." && pwd)"
if [[ "$(uname -s)" != Darwin ]]; then
  echo "SKIP: an Xcode is installed on a Mac only"
  exit 0
fi
t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT
t="$(cd "$t" && pwd -P)"
fail() { echo "FAIL: $*"; [[ ! -f "$t/err" ]] || tail -40 "$t/err"; exit 1; }
x="${XLESS_BIN:-}"
if [[ -z "$x" ]]; then
  (cd "$repo" && env -u DEVELOPER_DIR swift build --product xless -q)
  x="$(cd "$repo" && env -u DEVELOPER_DIR swift build --show-bin-path)/xless"
fi
mkdir -p "$t/home/.ssh" "$t/home/.config/xless" "$t/home/bin" "$t/tools/bin" "$t/app" "$t/ov" "$t/elsewhere"
developer=()
[[ -z "${DEVELOPER_DIR:-}" ]] || developer=(DEVELOPER_DIR="$DEVELOPER_DIR")
more=()
# stdout → $t/out, stderr → $t/err, exit code → $code
run() {
  code=0
  env -i HOME="$t/home" TMPDIR="$t" PATH="$t/tools/bin:/usr/bin:/bin:/usr/sbin:/sbin" XLESS_SHARE="$repo" AN_EXPORTED_TOKEN=s3cret ASC_KEY_P8=s3cret \
    ${developer[@]+"${developer[@]}"} ${more[@]+"${more[@]}"} "$x" "$@" >"$t/out" 2>"$t/err" </dev/null || code=$?
}

run setup
if [[ "$code" != 0 && -z "${XLESS_TEST_XCODE:-}" ]]; then
  echo "SKIP: xless uses no Xcode of this Mac: $(tail -1 "$t/err")"
  exit 0
fi
[[ "$code" == 0 ]] || fail "xless setup exited $code"

echo s3cret >"$t/home/.ssh/id_test"
echo s3cret >"$t/home/.config/xless/testflight.env.txt"
echo s3cret >"$t/elsewhere/file"
echo open >"$t/app/untracked"
# A socket of the user's, as an agent has one. (Its path is short, and it is gone when the test is.)
socket="$t/s"
/usr/bin/perl -MIO::Socket::UNIX -e 'IO::Socket::UNIX->new(Local => $ARGV[0], Listen => 1) or die; sleep 120' "$socket" &
server=$!
disown "$server"
trap 'kill "$server" 2>/dev/null || true; rm -rf "$t"' EXIT

cat >"$t/tools/bin/rustup" <<'S'
#!/bin/sh
echo aarch64-apple-darwin
S
# What cargo does here: tells where it puts things, and links an executable with the linker that xless named.
cat >"$t/tools/bin/cargo" <<S
#!/bin/bash
real="$t"
user="$(id -un)"
tester=$$
S
cat >>"$t/tools/bin/cargo" <<'S'
if [ "$1" = metadata ]; then
  printf '{"packages":[{"name":"demo","targets":[{"name":"demo","kind":["bin"]}]}],"target_directory":"%s/target"}\n' "$PWD"
  exit
fi
probe() { name="$1"; shift; if "$@" >/dev/null 2>&1; then echo "$name: yes"; else echo "$name: no"; fi; }
{
  probe home ls "$real/home"
  probe passwd-home ls "$(eval echo "~$user")"
  probe key cat "$real/home/.ssh/id_test"
  probe config cat "$real/home/.config/xless/testflight.env.txt"
  probe elsewhere cat "$real/elsewhere/file"
  probe seen test -e "$real/elsewhere/file"
  probe overlay-write touch "$real/ov/x"
  probe source-write touch "$real/app/x"
  probe source-read cat "$real/app/untracked"
  probe signed mkdir -p .xless/build/macos/signed
  probe replaced mv .xless/build .xless/other
  probe socket /usr/bin/perl -MIO::Socket::UNIX -e 'exit(IO::Socket::UNIX->new(Peer => $ARGV[0]) ? 0 : 1)' "$real/s"
  probe keychain /usr/bin/security list-keychains
  # an app of its own, which the system would start outside the sandbox
  mkdir -p Out.app/Contents/MacOS
  printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' '<plist version="1.0"><dict><key>CFBundleExecutable</key><string>out</string><key>CFBundleIdentifier</key><string>com.example.out</string><key>CFBundlePackageType</key><string>APPL</string><key>LSBackgroundOnly</key><true/></dict></plist>' >Out.app/Contents/Info.plist
  printf '#!/bin/sh\ntouch "%s/app/x"\n' "$real" >Out.app/Contents/MacOS/out
  chmod +x Out.app/Contents/MacOS/out
  probe open /usr/bin/open -g "$PWD/Out.app"
  probe again /usr/bin/sandbox-exec -p '(version 1)(allow default)' /usr/bin/true
  probe parent kill -0 "$tester"
  probe terminal sh -c 'echo x >/dev/tty'
  probe token sh -c 'env | grep s3cret'
  probe told sh -c 'env | grep -q XLESS_SESSION='
  probe own sh -c 'echo x >"$HOME/mine" && cat "$HOME/mine" && echo x >"$TMPDIR/mine"'
  echo "home is $HOME"
} >report 2>&1
echo 'int main(void) { return 0; }' >m.c
mkdir -p target/aarch64-apple-darwin/release
"$CC_aarch64_apple_darwin" $CFLAGS_aarch64_apple_darwin -c m.c -o m.o
"$CARGO_TARGET_AARCH64_APPLE_DARWIN_LINKER" m.o -o target/aarch64-apple-darwin/release/demo
# what it leaves running has no part in anything
(sleep 60 >&2 &)
S
chmod +x "$t/tools/bin/rustup" "$t/tools/bin/cargo"

printf '%s\n' '[package]' 'name = "demo"' 'version = "1.2.3"' 'edition = "2021"' >"$t/app/Cargo.toml"
printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' '<plist version="1.0"><dict><key>CFBundleName</key><string>Demo</string></dict></plist>' >"$t/app/Info.plist"
printf '%s\n' 'type: cargo' 'source: ../app' 'bundleID: com.example.demo' 'teamID: ABCDE12345' 'version: cargo' 'build: "7"' 'usesNonExemptEncryption: false' \
  'macos: { package: demo, product: Demo, minimumOS: "13.0", infoPlist: Info.plist, architectures: [arm64] }' >"$t/ov/demo.yml"
git -C "$t/app" init -q
git -C "$t/app" add Cargo.toml Info.plist
git -C "$t/app" -c user.name=x -c user.email=x@example.com -c commit.gpgsign=false commit -qm one

work="$t/home/.cache/xless/work/demo"
begin=$SECONDS
run run --config "$t/ov/demo.yml" --platform macos --to finalize
[[ "$code" == 0 ]] || fail "xless run exited $code"
(( SECONDS - begin < 50 )) || fail "what the build left running held it"
grep -q "the app's build code runs in a sandbox" "$t/err" || fail "nothing says that there is a sandbox"
app="$work/.xless/build/macos/final/Demo.app"
[[ "$(lipo -archs "$app/Contents/MacOS/Demo")" == arm64 ]] || fail "no app"
want='home: no
passwd-home: no
key: no
config: no
elsewhere: no
seen: no
overlay-write: no
source-write: no
source-read: yes
signed: no
replaced: no
socket: no
keychain: no
open: no
again: no
parent: no
terminal: no
token: no
told: no
own: yes
home is '"$t/home/.cache/xless/build-home"
[[ "$(cat "$work/report")" == "$want" ]] || fail "the build code got something else: $(diff <(echo "$want") "$work/report")"
[[ ! -e "$t/ov/x" && ! -e "$t/app/x" ]] || fail "it wrote where it may not"

# Without the sandbox nothing of it runs: not when it is said to be there and is not, and not when the tool is gone (the rules
# cannot be put on in another sandbox: the same).
rm "$work/report"
more=(XLESS_BUILD_SANDBOX=1)
run ship --config "$t/ov/demo.yml" --platform macos --to build
[[ "$code" == 19 ]] || fail "xless went on without the sandbox ($code)"
grep -q 'not in force' "$t/err" || fail "xless went on without the sandbox ($code)"
more=()
sandboxed="$x"
x=/usr/bin/sandbox-exec
run -p '(version 1)(allow default)' "$sandboxed" ship --config "$t/ov/demo.yml" --platform macos --to build
x="$sandboxed"
[[ "$code" != 0 && ! -e "$work/report" ]] || fail "the build code ran where it cannot have its sandbox ($code)"

# The build's failure is xless's, once.
printf '%s\n' '#!/bin/sh' 'echo it broke >&2' 'exit 3' >"$t/tools/bin/cargo"
run build --config "$t/ov/demo.yml" --platform macos
[[ "$code" == 12 && "$(grep -c '^error:' "$t/err")" == 1 ]] || fail "a build that fails exits $code"
[[ -z "$(cat "$t/out")" ]] || fail "xless build printed $(cat "$t/out")"

# A home directory is not opened, and a secret that is in what is opened is refused.
cp "$t/ov/demo.yml" "$t/home/demo.yml"
run ship --config "$t/home/demo.yml" --source "$t/app" --platform macos --to build
[[ "$code" == 10 ]] || fail "an overlay in the home directory: $code"
grep -q 'would open a home directory' "$t/err" || fail "an overlay in the home directory: $code"
echo s3cret >"$t/ov/key.pem"
more=(XLESS_DEVID_KEY_FILE="$t/ov/key.pem")
run run --config "$t/ov/demo.yml" --platform macos --to finalize
[[ "$code" == 2 ]] || fail "a key beside the overlay: $code"
grep -q "readable to the app's build code" "$t/err" || fail "a key beside the overlay: $code"

echo "ok: overlay-native"
