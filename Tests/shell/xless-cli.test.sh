#!/usr/bin/env bash
# The CLI's refusals for `--destination simulator`, run against the built xless (no docker, no network, no secrets): every
# stage after build exits with its own code and `[stage]` prefix before it reads anything (sign and upload never reach App
# Store Connect: fake credentials are set and must not matter), `ship` refuses a range past build as a usage error, and the
# simulator is refused for a Tauri overlay and for xless.yml. The policy itself is unit-tested in
# Tests/XlessCoreTests/StagePolicyTests.swift; this checks that each command asks it.
#   Tests/shell/xless-cli.test.sh            (builds xless with `swift build`; XLESS_BIN=<path> uses that binary)
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
mkdir -p "$t/home" "$t/work"
base=(env -i HOME="$t/home" PATH=/usr/bin:/bin XLESS_WORK_ROOT="$t/work" XLESS_BUILD_NUMBER=1.0.0.2026101601
      ASC_KEY_ID=FAKE ASC_ISSUER_ID=FAKE ASC_KEY_P8_FILE="$t/none.p8" XLESS_DIST_KEY_FILE="$t/none.pem")
rn=(--config "$repo/samples/HelloRN/xless.overlay.yml" --source "$repo/samples/HelloRN" --platform ios)

expect() {   # CODE PREFIX COMMAND...: exit code and the start of the error line
  local want="$1" prefix="$2" code=0; shift 2
  "${base[@]}" "$x" "$@" >/dev/null 2>"$t/err" || code=$?
  [[ $code -eq $want ]] || fail "xless $* exits $code, want $want: $(cat "$t/err")"
  [[ "$(head -1 "$t/err")" == "$prefix"* ]] || fail "xless $* says: $(head -1 "$t/err"), want ${prefix}…"
}

# Each stage after build: its own exit code, refused as the stage's first step.
expect 13 "error: [assets] --destination simulator builds stop at build" assets "${rn[@]}" --destination simulator
expect 14 "error: [finalize] --destination simulator builds stop at build" finalize "${rn[@]}" --destination simulator
expect 15 "error: [sign] --destination simulator builds stop at build" sign "${rn[@]}" --destination simulator
expect 16 "error: [package] --destination simulator builds stop at build" package "${rn[@]}" --destination simulator
expect 17 "error: [upload] --destination simulator builds stop at build" upload "${rn[@]}" --destination simulator
grep -q "ios-simulator/app/<App>.app" "$t/err" || fail "the refusal does not name the simulator app: $(cat "$t/err")"
# ship: past build is a usage error (ArgumentParser's 64), before anything runs.
for to in assets finalize sign package upload; do
  expect 64 "Error: --to $to: --destination simulator builds stop at build" ship "${rn[@]}" --destination simulator --to "$to"
done
expect 64 "Error: --to build comes before --from sign" ship "${rn[@]}" --destination simulator --from sign
# Nothing was built or signed: only the build number record exists in the work copy.
[[ -z "$(find "$t/work" -type f ! -name build-number)" ]] || fail "files written: $(find "$t/work" -type f)"
# The simulator is for React Native overlays only (and for xless.yml projects, on a Mac with Xcode).
printf 'type: tauri\nsource: .\n' > "$t/tauri.yml"
expect 10 "error: [config] --destination simulator builds React Native overlays only" build --config "$t/tauri.yml" --platform ios --destination simulator
[[ "$(uname)" == Darwin ]] || expect 10 "error: [config] --destination simulator builds React Native overlays only" ship --project "$repo/samples/HelloShip" --platform ios --destination simulator
# xless run and xless docker: the run's steps. Printed (--dry-run), or run by a fake docker that logs what it is asked.
mkdir -p "$t/p" "$t/bin" "$t/home" "$t/share"
cp "$repo/samples/HelloShip/xless.yml" "$t/p/xless.yml"
case "$(uname -m)" in arm64|aarch64) A=arm64 ;; *) A=amd64 ;; esac
cat > "$t/bin/docker" <<'S'
#!/bin/sh
printf '%s\n' "$*" >> "$DLOG"
case "$*" in *" image "*) while [ "$1" != image ]; do shift; done; exec "$FAKE" "$@" ;; esac
case "$*" in *" run "*|"run "*) exit "${STUB_EXIT:-0}" ;; esac
S
chmod +x "$t/bin/docker"
cp "$repo/versions.env" "$t/share/versions.env"; cp -R "$repo/docker" "$t/share/docker"
v="$("${base[@]}" "$x" --version)"
echo "$v" > "$t/share/VERSION"   # a share is from one release: this xless's
# the image is named after this xless: its share's release; the Xcode's pack is in a directory store
FAKE_SHARE="$t/share" "$repo/Tests/shell/fake-images.sh" base "$A" 27.0 27A266a > "$t/images"
"$repo/Tests/shell/fake-images.sh" pack "$t/xcodes" "$A"
runs=("${base[@]}" HOME="$t/home" PATH="$t/bin:/usr/bin:/bin" XLESS_TESTFLIGHT_ENV="$t/none.env" DLOG="$t/dlog" FAKE="$repo/Tests/shell/fake-images.sh" FAKE_IMAGES="$t/images" DOCKER_CONTEXT=stub XLESS_SHARE="$t/share"
      XLESS_XCODES="$t/xcodes")
ship="ship --platform ios --build-number 1 --to finalize"
xr="$(cd "$(dirname "$x")" && pwd -P)/$(basename "$x")"
# xless docker: in the images unless XLESS_USE_DOCKER says otherwise; ship's arguments, with or without the `--` that may
# introduce them; docker's exit code
"${base[@]}" "$x" docker --help >/dev/null 2>"$t/err" || fail "xless docker --help failed: $(cat "$t/err")"
"${runs[@]}" "$x" docker "$t/p" --build-number 1 --to finalize -- --verbose >/dev/null 2>"$t/err" || fail "xless docker failed: $(cat "$t/err")"
[[ "$(grep -c " run .* xless $ship --verbose$" "$t/dlog")" -eq 1 ]] || fail "xless docker runs: $(cat "$t/dlog")"
[[ $(grep -c "^note: xless docker is xless run --docker now" "$t/err") -eq 1 ]] || fail "xless docker's notice: $(cat "$t/err")"
"${runs[@]}" XLESS_RUN_UNLOCKED=1 "$x" docker "$t/p" --to finalize >/dev/null 2>"$t/err" || fail "xless docker, started again: $(cat "$t/err")"
! grep -q "^note: " "$t/err" || fail "the notice again: $(cat "$t/err")"
out=$("${runs[@]}" XLESS_USE_DOCKER=0 "$x" docker "$t/p" --dry-run --to finalize 2>/dev/null) || fail "xless docker with XLESS_USE_DOCKER=0 failed"
[[ "$out" == "$xr ship --platform ios --to finalize " ]] || fail "XLESS_USE_DOCKER=0 overridden: $out"
code=0; "${runs[@]}" STUB_EXIT=23 "$x" docker "$t/p" --to finalize >/dev/null 2>&1 || code=$?
[[ $code -eq 23 ]] || fail "xless docker exits $code, want the container's 23"
# A share from another release is refused before anything runs, naming both releases and the share;
# XLESS_ALLOW_SHARE_MISMATCH=1 runs it anyway, with a warning.
echo 9.9.9 > "$t/share/VERSION"; : > "$t/dlog"
code=0; "${runs[@]}" "$x" docker "$t/p" --to finalize >"$t/out" 2>"$t/err" || code=$?
[[ $code -eq 11 ]] || fail "a share of another release: exit $code, want 11: $(cat "$t/err")"
grep -qF "this xless is $v, but its share directory $t/share (XLESS_SHARE) is from xless 9.9.9" "$t/err" || fail "mismatch message: $(cat "$t/err")"
grep -qF "XLESS_ALLOW_SHARE_MISMATCH=1" "$t/err" || fail "the refusal does not name the escape hatch: $(cat "$t/err")"
[[ ! -s "$t/out" && ! -s "$t/dlog" ]] || fail "something ran with a share of another release: $(cat "$t/out" "$t/dlog")"
cp "$t/images" "$t/images.keep"; FAKE_SHARE="$t/share" "$repo/Tests/shell/fake-images.sh" base "$A" 27.0 27A266a > "$t/images" # the image of the share's release
"${runs[@]}" XLESS_ALLOW_SHARE_MISMATCH=1 "$x" docker "$t/p" --to finalize >/dev/null 2>"$t/err" || fail "XLESS_ALLOW_SHARE_MISMATCH=1 still refused: $(cat "$t/err")"
grep -q " run .* xless ship --platform ios --to finalize$" "$t/dlog" || fail "XLESS_ALLOW_SHARE_MISMATCH=1 runs: $(cat "$t/dlog")"
grep -qF "warning: this xless is $v, but its share directory $t/share (XLESS_SHARE) is from xless 9.9.9" "$t/err" || fail "no warning: $(cat "$t/err")"
mv "$t/images.keep" "$t/images"; echo "$v" > "$t/share/VERSION"
# xless run: natively by default, in the images with --docker (taken out of the arguments, but not after `--`), an
# XLESS_USE_DOCKER already set wins over the default only; the steps run this xless, whatever XLESS_SELF says.
"${base[@]}" "$x" run --help >/dev/null 2>"$t/err" || fail "xless run --help failed: $(cat "$t/err")"
out=$("${runs[@]}" XLESS_SELF=/bin/false "$x" run "$t/p" --dry-run --build-number 1 --to finalize 2>"$t/err") || fail "xless run failed: $(cat "$t/err")"
[[ "$out" == "$xr $ship " ]] || fail "xless run runs: $out"
! grep -q "^note: " "$t/err" || fail "xless run has a notice: $(cat "$t/err")"
out=$("${runs[@]}" "$x" run --docker "$t/p" --dry-run --to finalize -- --docker 2>"$t/err") || fail "xless run --docker failed: $(cat "$t/err")"
[[ "$out" == "docker --context stub run "*" xless ship --platform ios --to finalize --docker " ]] || fail "xless run --docker runs: $out"
out=$("${runs[@]}" "$x" run "$t/p" --dry-run --to finalize --docker 2>/dev/null) || fail "xless run p --docker failed"
[[ "$out" == docker*" xless ship --platform ios --to finalize " ]] || fail "--docker after the project: $out"
out=$("${runs[@]}" XLESS_USE_DOCKER=1 "$x" run "$t/p" --dry-run --to finalize 2>/dev/null) || fail "xless run with XLESS_USE_DOCKER=1 failed"
[[ "$out" == docker* ]] || fail "XLESS_USE_DOCKER=1 overridden by run's default: $out"
out=$("${runs[@]}" XLESS_USE_DOCKER=0 "$x" run --docker "$t/p" --dry-run --to finalize 2>/dev/null) || fail "xless run --docker with XLESS_USE_DOCKER=0 failed"
[[ "$out" == docker* ]] || fail "--docker lost to XLESS_USE_DOCKER=0: $out"
code=0; "${runs[@]}" STUB_EXIT=23 "$x" run --docker "$t/p" --to finalize >/dev/null 2>&1 || code=$?
[[ $code -eq 23 ]] || fail "xless run exits $code, want the container's 23"
# natively: the exit code of this xless's ship, which refuses an option that the run passes on to it
code=0; "${runs[@]}" "$x" run "$t/p" --to finalize --no-such-option >/dev/null 2>"$t/err" || code=$?
[[ $code -eq 64 ]] && grep -q "Usage: xless ship " "$t/err" || fail "xless run exits $code, want its ship's 64: $(cat "$t/err")"
# an xless.yml that is not YAML: the run itself says so, before ship does
code=0; echo 'nonsense: [' > "$t/p/xless.yml"; "${runs[@]}" "$x" run "$t/p" --to finalize >/dev/null 2>"$t/err" || code=$?
[[ $code -eq 10 ]] || fail "xless run of an unreadable xless.yml exits $code, want 10: $(cat "$t/err")"
# On Linux, an overlay builds in the images only: refused natively, naming --docker, before anything runs.
if [[ "$(uname)" == Linux ]]; then
  : > "$t/dlog"
  code=0; "${runs[@]}" "$x" run --config "$t/tauri.yml" >"$t/out" 2>"$t/err" || code=$?
  [[ $code -eq 10 ]] || fail "native overlay exits $code, want 10: $(cat "$t/err")"
  grep -q -- '--docker' "$t/err" || fail "the overlay refusal does not name --docker: $(cat "$t/err")"
  [[ ! -s "$t/out" && ! -s "$t/dlog" ]] || fail "something ran for a refused overlay: $(cat "$t/out" "$t/dlog")"
fi
mkdir "$t/ov"; cp "$t/tauri.yml" "$t/ov/tauri.yml"
out=$("${runs[@]}" "$x" run --docker --config "$t/ov/tauri.yml" --dry-run --build-number 1 --to finalize 2>"$t/err") || fail "xless run --docker --config failed: $(cat "$t/err")"
[[ "$out" == docker* ]] || fail "run --docker --config: $out"
# sign bootstrap: what it is called now, on standard error, and the same outcome as before
code=0; "${runs[@]}" "$x" sign bootstrap --type distribution >"$t/out" 2>"$t/err" </dev/null || code=$?
[[ $code -eq 15 && $(grep -c "^note: xless sign bootstrap is xless certs create now" "$t/err") -eq 1 && ! -s "$t/out" ]] || fail "sign bootstrap's notice ($code): $(cat "$t/err")"
"${runs[@]}" "$x" sign bootstrap --type distribution --out "$t/key.pem" --csr-only >/dev/null 2>"$t/err" || fail "sign bootstrap --csr-only: $(cat "$t/err")"
[[ ! -s "$t/err" && -s "$t/key.pem.csr" ]] || fail "sign bootstrap --csr-only: $(cat "$t/err")"
# package: of what a build left in dSYMs, only what is of the app is shipped, and a tree with a pipe or a link out of it is refused
if command -v zip >/dev/null; then
  pkg="$t/pkg" ios="$t/pkg/.xless/build/ios"
  mkdir -p "$ios/signed/App.app" "$ios/dSYMs"
  printf 'bundleID: com.example.app\nteamID: ABCDE12345\nversion: "1.0"\nbuild: 1\nplatforms:\n  ios: { minimumOS: "17.0", product: App }\n' > "$pkg/xless.yml"
  echo x > "$ios/signed/App.app/App"; echo x > "$ios/dSYMs/loose"
  base+=(XLESS_BUILD_NUMBER=1)
  "${base[@]}" "$x" package --platform ios --project "$pkg" >/dev/null 2>"$t/err" || fail "package: $(cat "$t/err")"
  [[ -f "$ios/out/App.ipa" && ! -e "$ios/out/App.app.dSYM.zip" ]] || fail "package made: $(ls "$ios/out")"
  mv "$ios/out/App.ipa" "$t/App.ipa"; ln -s "$t/App.ipa" "$ios/out/App.ipa"
  expect 17 "error: [upload] App.ipa in " upload --platform ios --project "$pkg"
  grep -q "is not a file" "$t/err" || fail "a linked .ipa: $(cat "$t/err")"
  ln -s "$t" "$ios/dSYMs/link"
  expect 16 "error: [package] link in dSYMs is a link that leads out of it" package --platform ios --project "$pkg"
  mkfifo "$ios/signed/App.app/pipe"
  expect 16 "error: [package] pipe in App.app is neither a file" package --platform ios --project "$pkg"
fi

# The xcrun shim beside a pack that cannot be used: xcrun's own form of error (exit 1), with the pack's fix.
case "$(uname -m)" in arm64|aarch64) pa=arm64 ;; *) pa=amd64 ;; esac
mkdir -p "$t/xcodes/99.0-99Z99-$pa"
printf '{"format":1,"xcode":"99.0","build":"99Z99","arch":"%s","swift":"6.4.0","mode":"own","parts":{}}' "$pa" > "$t/xcodes/99.0-99Z99-$pa/pack.json"
code=0; "${base[@]}" XLESS_XCODES="$t/xcodes" "$x" shim xcrun --show-sdk-path >/dev/null 2>"$t/err" || code=$?
[[ $code == 1 && "$(cat "$t/err")" == "xcrun: error: the pack 99.0-99Z99-$pa has no Darwin SDK; xless setup --sdk "* ]] \
  || fail "the xcrun shim beside a pack that cannot be used: exit $code: $(cat "$t/err")"
echo PASS
