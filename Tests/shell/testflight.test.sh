#!/usr/bin/env bash
# Checks scripts/testflight.sh's command construction in dry-run mode (no docker, no network, no secrets).
set -euo pipefail
S="$(cd "$(dirname "$0")/../.." && pwd)/scripts/testflight.sh"
t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT
fail() { echo "FAIL: $*"; exit 1; }
mkdir -p "$t/proj" "$t/bin"
touch "$t/proj/xless.yml"
printf 'x' > "$t/key.p8"; printf 'x' > "$t/dist.pem"; printf 'ISSUER-SECRET-VALUE' > "$t/issuer"
# A fake docker that knows two contexts, so context selection is testable without a daemon.
cat > "$t/bin/docker" <<'D'
#!/usr/bin/env bash
if [[ "$1 $2" == "context ls" ]]; then printf 'default\ncolima-xless\n'; fi
D
chmod +x "$t/bin/docker"
base=(env -i HOME="$t/home" PATH="$t/bin:/usr/bin:/bin" XLESS_TESTFLIGHT_ENV="$t/none.env" XLESS_TESTFLIGHT_DRY_RUN=1 XLESS_USE_DOCKER=1
      ASC_KEY_ID=KEYID ASC_ISSUER_ID_FILE="$t/issuer" ASC_KEY_P8_FILE="$t/key.p8" XLESS_DIST_KEY_FILE="$t/dist.pem")

out=$("${base[@]}" "$S" "$t/proj" 2>/dev/null) || fail "dry run failed"
[[ "$out" == *"--context colima-xless"* ]] || fail "colima-xless context not preferred: $out"
[[ "$out" == *"xless ship --platform ios"* ]] || fail "missing ship command: $out"
[[ "$out" == *"ISSUER-SECRET-VALUE"* ]] && fail "issuer value leaked"
[[ "$out" == *"dst=/secrets/asc.p8,readonly"* && "$out" == *"ASC_KEY_P8_FILE=/secrets/asc.p8"* ]] || fail "p8 not mounted by path: $out"

# explicit context wins, image override, build number override
out=$("${base[@]}" DOCKER_CONTEXT=other XLESS_IMAGE=img:1 XLESS_BUILD_NUMBER=42 "$S" "$t/proj" 2>/dev/null)
[[ "$out" == *"--context other"* && "$out" == *"img:1"* ]] || fail "overrides ignored: $out"
# XLESS_BUILD_NUMBER is passed by name; its value is in the script's environment, not argv
[[ "$out" == *"-e XLESS_BUILD_NUMBER "* ]] || fail "build number not passed by name: $out"

# default build number is a monotonic minutes-since-epoch value
msg=$("${base[@]}" "$S" "$t/proj" 2>&1 >/dev/null) || true
n=$(sed -n 's/.*build number \([0-9]*\)$/\1/p' <<<"$msg" | head -1)
now=$(( $(date +%s) / 60 ))
[[ -n "$n" && $n -ge $((now - 1)) && $n -le $((now + 1)) ]] || fail "default build number '$n' not near $now"

# native mode runs xless in the project directory and forwards extra args
printf '#!/bin/sh\n' > "$t/bin/xless"; chmod +x "$t/bin/xless"
out=$("${base[@]}" XLESS_USE_DOCKER=0 "$S" "$t/proj" --from upload 2>/dev/null)
[[ "$out" == "xless ship --platform ios --from upload " ]] || fail "native command wrong: '$out'"

# without XLESS_USE_DOCKER: docker, unless a native SDK's toolchain-meta.json exists
out=$("${base[@]}" XLESS_USE_DOCKER= "$S" "$t/proj" 2>/dev/null) || fail "auto dry run failed"
[[ "$out" == *"docker "* && "$out" == *"xless ship --platform ios"* ]] || fail "auto without a native SDK does not use docker: $out"
printf '{}' > "$t/meta.json"
out=$("${base[@]}" XLESS_USE_DOCKER= XLESS_TOOLCHAIN_META="$t/meta.json" "$S" "$t/proj" 2>/dev/null) || fail "auto native dry run failed"
[[ "$out" == "xless ship --platform ios "* ]] || fail "auto with a toolchain-meta does not run native: $out"
mkdir -p "$t/home/.config/xless"; printf '{}' > "$t/home/.config/xless/toolchain-meta.json"
out=$("${base[@]}" XLESS_USE_DOCKER= "$S" "$t/proj" 2>/dev/null) || fail "auto native (default meta) failed"
[[ "$out" == "xless ship --platform ios "* ]] || fail "default toolchain-meta path ignored: $out"
rm -rf "$t/home/.config"

# every missing variable is a usage error (exit 2) naming the variable
for v in ASC_KEY_ID ASC_ISSUER_ID_FILE ASC_KEY_P8_FILE XLESS_DIST_KEY_FILE; do
  code=0; "${base[@]}" "$v=" "$S" "$t/proj" >/dev/null 2>"$t/err" || code=$?
  [[ $code -eq 2 ]] || fail "missing $v exits $code, want 2"
  grep -q "$v\|ASC_ISSUER_ID" "$t/err" || fail "error does not name $v"
done
# a project directory run that stops before sign needs no secret at all (the README's sample build)
nosec=(env -i HOME="$t/home" PATH="$t/bin:/usr/bin:/bin" XLESS_TESTFLIGHT_ENV="$t/none.env" XLESS_TESTFLIGHT_DRY_RUN=1 XLESS_USE_DOCKER=1)
for to in "--to finalize" "--to=build" "--build-number 1 --to finalize"; do
  # shellcheck disable=SC2086
  out=$("${nosec[@]}" "$S" "$t/proj" $to 2>"$t/err") || fail "project dir '$to' without secrets failed: $(cat "$t/err")"
  [[ "$out" == *"xless ship --platform ios $to"* ]] || fail "'$to' not passed on: $out"
  [[ "$out" != *"/secrets/"* && "$out" != *"ASC_KEY_ID"* ]] || fail "'$to' mounts secrets: $out"
done
# it says it stopped, not that it delivered, and names the build number xless will use
"${nosec[@]}" "$S" "$t/proj" --build-number 1 --to finalize >/dev/null 2>"$t/err" || fail "--to finalize run failed"
grep -q "stopped after finalize (--to), nothing delivered" "$t/err" || fail "no stop message: $(cat "$t/err")"
grep -q "delivery finished" "$t/err" && fail "a run stopped at finalize claims a delivery: $(cat "$t/err")"
grep -q "build number from --build-number" "$t/err" || fail "the --build-number override is not reported: $(cat "$t/err")"
code=0; "${nosec[@]}" "$S" "$t/proj" --from sign >/dev/null 2>"$t/err" || code=$?
[[ $code -eq 2 ]] && grep -q ASC_KEY_ID "$t/err" || fail "a project dir run through sign without secrets: exit $code"
code=0; "${nosec[@]}" "$S" "$t/proj" --to sign >/dev/null 2>"$t/err" || code=$?
[[ $code -eq 2 ]] || fail "--to sign without secrets: exit $code, want 2"
# with secrets set, a run that stops before sign still mounts none
out=$("${base[@]}" "$S" "$t/proj" --to finalize 2>/dev/null) || fail "--to finalize with secrets failed"
[[ "$out" != *"/secrets/"* ]] || fail "--to finalize mounts secrets: $out"
code=0; "${nosec[@]}" "$S" "$t/proj" --to nowhere >/dev/null 2>"$t/err" || code=$?
[[ $code -eq 2 ]] && grep -q "unknown stage" "$t/err" || fail "unknown --to stage: exit $code"

# relative secret paths are made absolute before mounting
out=$(cd "$t" && "${base[@]}" ASC_KEY_P8_FILE=key.p8 "$S" proj 2>/dev/null) || fail "relative path run failed"
[[ "$out" == *"--mount type=bind,src=$t/key.p8,dst=/secrets/asc.p8,readonly"* || "$out" == *"--mount "*"$t/key.p8,dst=/secrets/asc.p8,readonly"* ]] || fail "relative path not resolved: $out"

# missing pieces are named without printing values
"${base[@]}" ASC_KEY_P8_FILE="$t/missing.p8" "$S" "$t/proj" >/dev/null 2>"$t/err" && fail "missing p8 accepted"
grep -q ASC_KEY_P8_FILE "$t/err" || fail "error does not name ASC_KEY_P8_FILE"
"${base[@]}" "$S" "$t/nodir" >/dev/null 2>&1 && fail "missing project accepted"

# env file is sourced
printf 'ASC_KEY_ID=FROMFILE\n' > "$t/f.env"
out=$("${base[@]}" XLESS_TESTFLIGHT_ENV="$t/f.env" XLESS_USE_DOCKER=0 "$S" "$t/proj" 2>/dev/null) || fail "env file run failed"

# exit code is xless's
printf '#!/bin/sh\nexit 17\n' > "$t/bin/xless"
"${base[@]}" XLESS_TESTFLIGHT_DRY_RUN=0 XLESS_USE_DOCKER=0 "$S" "$t/proj" >/dev/null 2>&1 && fail "exit code swallowed"
code=0; "${base[@]}" XLESS_TESTFLIGHT_DRY_RUN=0 XLESS_USE_DOCKER=0 "$S" "$t/proj" >/dev/null 2>&1 || code=$?
[[ $code -eq 17 ]] || fail "exit code $code, want 17"
# --config: Tauri overlay instead of a project directory, in three steps (next-build, build without secrets, ship from sign)
mkdir -p "$t/ov/app" "$t/home/.cache/xless"
cat > "$t/ov/my.overlay.yml" <<'Y'
type: tauri
source: app            # relative to this file
bundleID: com.example.x
Y
printf 'p' > "$t/ov/PrivacyInfo.xcprivacy"
line() { grep -F -- "$1" <<<"$out" || true; }   # the dry-run command line of one step
out=$("${base[@]}" "$S" --config "$t/ov/my.overlay.yml" 2>/dev/null) || fail "--config dry run failed"
[[ $(wc -l <<<"$out") -eq 3 ]] || fail "want three steps: $out"
s1=$(line "xless tauri next-build"); s2=$(line "--to finalize"); s3=$(line "--from sign")
[[ "$s1" == *"xless tauri next-build --config /config/my.overlay.yml --source /source " ]] || fail "step 1 wrong: $s1"
[[ "$s2" == *"xless ship --platform ios --config /config/my.overlay.yml --source /source --from build --to finalize "* ]] || fail "step 2 wrong: $s2"
[[ "$s3" == *"xless ship --platform ios --config /config/my.overlay.yml --source /source --from sign --to upload "* ]] || fail "step 3 wrong: $s3"
for l in "$s1" "$s2" "$s3"; do
  [[ "$l" == *"--mount type=bind,src=$t/ov/app,dst=/source,readonly"* ]] || fail "source not mounted from the overlay: $l"
  [[ "$l" == *"--mount type=bind,src=$t/ov,dst=/config,readonly"* ]] || fail "overlay directory not mounted: $l"
  [[ "$l" == *"--context colima-xless"* && "$l" == *"xless-tauri:local-"* ]] || fail "context or tauri image: $l"
  [[ "$l" != *"dst=/work "* ]] || fail "project mount used with --config: $l"
done
# step 2 runs the app's build code: no secret mount, no secret variable
[[ "$s2" != *"/secrets/"* && "$s2" != *"ASC_"* && "$s2" != *"XLESS_DIST_KEY"* ]] || fail "secrets reach the build step: $s2"
[[ "$s2" == *"--mount type=bind,src=$t/home/.cache/xless/work,dst=/cache/work"* && "$s2" == *"--mount type=bind,src=$t/home/.cache/xless/downloads,dst=/cache/downloads"* ]] || fail "caches not mounted: $s2"
[[ "$s2" == *"xless-rustup:/cache/rustup"* && "$s2" == *"xless-cargo:/cache/cargo"* ]] || fail "toolchain volumes missing: $s2"
[[ "$s2" == *"XLESS_CACHE=/cache"* && "$s2" == *"XLESS_SOURCE_ORIGIN=$t/ov/app"* ]] || fail "XLESS_CACHE/XLESS_SOURCE_ORIGIN not set: $s2"
[[ "$s2" == *"-e XLESS_BUILD_NUMBER "* && "$s3" == *"-e XLESS_BUILD_NUMBER "* ]] || fail "step 1's build number not passed by name: $out"
# step 1 has the App Store Connect key only; step 3 has every secret and the work copy
[[ "$s1" == *"dst=/secrets/asc.p8,readonly"* && "$s1" == *"-e ASC_KEY_ID"* && "$s1" != *"dist-key"* && "$s1" != *"/cache/"* ]] || fail "step 1 mounts: $s1"
[[ "$s3" == *"dst=/secrets/asc.p8,readonly"* && "$s3" == *"dst=/secrets/dist-key.pem,readonly"* && "$s3" == *"ASC_ISSUER_ID_FILE=/secrets/asc-issuer-id"* ]] || fail "step 3 secrets: $s3"
[[ "$s3" == *"--mount type=bind,src=$t/home/.cache/xless/work,dst=/cache/work"* && "$s3" != *"xless-cargo"* && "$s3" != *"/cache/downloads"* ]] || fail "step 3 mounts: $s3"
[[ "$out" == *"ISSUER-SECRET-VALUE"* ]] && fail "issuer value leaked"
# no default build number: dated decides in step 1
msg=$("${base[@]}" "$S" --config "$t/ov/my.overlay.yml" 2>&1 >/dev/null) || true
[[ "$msg" =~ "build number "[0-9] ]] && fail "build number defaulted with --config: $msg"
# an explicit XLESS_BUILD_NUMBER (or --build-number) skips step 1 and is passed on
out=$("${base[@]}" XLESS_BUILD_NUMBER=1.0.0.2026101507 "$S" --config "$t/ov/my.overlay.yml" 2>/dev/null)
[[ "$out" != *"next-build"* && $(wc -l <<<"$out") -eq 2 ]] || fail "XLESS_BUILD_NUMBER did not skip step 1: $out"
[[ "$(line "--to finalize")" == *"-e XLESS_BUILD_NUMBER "* && "$(line "--from sign")" == *"-e XLESS_BUILD_NUMBER "* ]] || fail "explicit XLESS_BUILD_NUMBER not passed: $out"
out=$("${base[@]}" "$S" --config "$t/ov/my.overlay.yml" --build-number 1.0.0.2026101507 2>/dev/null)
[[ "$out" != *"next-build"* && "$out" != *"-e XLESS_BUILD_NUMBER"* && "$(line "--to finalize")" == *"--to finalize --build-number 1.0.0.2026101507"* ]] || fail "--build-number: $out"
# --from/--to choose the steps; XLESS_SOURCE wins over source:; other extra args go to both ship steps
out=$("${base[@]}" XLESS_SOURCE="$t/proj" "$S" --config "$t/ov/my.overlay.yml" --from upload 2>/dev/null)
[[ $(wc -l <<<"$out") -eq 1 && "$out" == *"--mount type=bind,src=$t/proj,dst=/source,readonly"* && "$out" == *"--source /source --from upload --to upload "* ]] || fail "XLESS_SOURCE/--from upload: $out"
out=$("${base[@]}" "$S" --config "$t/ov/my.overlay.yml" --to finalize 2>/dev/null)
[[ $(wc -l <<<"$out") -eq 2 && "$out" == *"next-build"* && "$out" == *"--from build --to finalize "* ]] || fail "--to finalize: $out"
out=$("${base[@]}" "$S" --config "$t/ov/my.overlay.yml" --from=assets --to=package --verbose 2>/dev/null)
[[ $(wc -l <<<"$out") -eq 2 && "$out" != *"next-build"* ]] || fail "--from assets runs step 1 or the wrong steps: $out"
[[ "$(line "--to finalize")" == *"--from assets --to finalize --verbose "* && "$(line "--from sign")" == *"--from sign --to package --verbose "* ]] || fail "--from assets --to package: $out"
code=0; "${base[@]}" "$S" --config "$t/ov/my.overlay.yml" --from upload --to build >/dev/null 2>&1 || code=$?
[[ $code -eq 2 ]] || fail "--to before --from exits $code, want 2"
code=0; "${base[@]}" "$S" --config "$t/ov/my.overlay.yml" --from ib >/dev/null 2>&1 || code=$?
[[ $code -eq 2 ]] || fail "unknown stage exits $code, want 2"
# ~ expands in source: and in the overlay path (make testflight CONFIG=~/… under zsh passes it unexpanded)
mkdir -p "$t/home/src" "$t/home/ovh"
printf 'type: tauri\nsource: "~/src"\n' > "$t/ov/tilde.yml"
out=$("${base[@]}" "$S" --config "$t/ov/tilde.yml" 2>/dev/null) || fail "tilde overlay failed"
[[ "$out" == *"--mount type=bind,src=$t/home/src,dst=/source,readonly"* ]] || fail "~ not expanded: $out"
printf 'type: tauri\nsource: %s\n' "$t/home/src" > "$t/home/ovh/h.yml"
out=$("${base[@]}" "$S" --config '~/ovh/h.yml' 2>/dev/null) || fail "~/ overlay path not expanded"
[[ "$out" == *"--mount type=bind,src=$t/home/ovh,dst=/config,readonly"* ]] || fail "~/ overlay path mounted wrongly: $out"
# the overlay's directory must not hold the env file or a secret file (it is mounted into the build container)
mkdir -p "$t/sec/sub" "$t/elsewhere"
printf 'type: tauri\nsource: %s\n' "$t/home/src" > "$t/sec/o.yml"
printf 'x' > "$t/sec/sub/key.p8"; printf '' > "$t/sec/testflight.env"; ln -s "$t/sec/sub/key.p8" "$t/elsewhere/link.p8"
for bad in "ASC_KEY_P8_FILE=$t/sec/sub/key.p8" "XLESS_DIST_KEY_FILE=$t/sec/sub/key.p8" "ASC_ISSUER_ID_FILE=$t/sec/sub/key.p8" \
           "XLESS_TESTFLIGHT_ENV=$t/sec/testflight.env" "ASC_KEY_P8_FILE=$t/elsewhere/link.p8"; do
  code=0; "${base[@]}" "$bad" "$S" --config "$t/sec/o.yml" >/dev/null 2>"$t/err" || code=$?
  [[ $code -eq 2 ]] || fail "secret inside the overlay directory ($bad) exits $code, want 2"
  grep -q "keep the overlay in its own directory" "$t/err" || fail "refusal does not explain ($bad): $(cat "$t/err")"
done
ln -s "$t/sec" "$t/seclink"
code=0; "${base[@]}" ASC_KEY_P8_FILE="$t/sec/sub/key.p8" "$S" --config "$t/seclink/o.yml" >/dev/null 2>&1 || code=$?
[[ $code -eq 2 ]] || fail "overlay directory reached through a symlink not resolved (exit $code)"
"${base[@]}" "$S" --config "$t/ov/my.overlay.yml" >/dev/null 2>&1 || fail "secrets outside the overlay directory refused"
# native mode: the same three steps; step 2 runs without the secret variables
out=$("${base[@]}" XLESS_USE_DOCKER=0 "$S" --config "$t/ov/my.overlay.yml" 2>/dev/null)
[[ "$(sed -n 1p <<<"$out")" == "xless tauri next-build --config $t/ov/my.overlay.yml " ]] || fail "native step 1 wrong: '$out'"
s2=$(sed -n 2p <<<"$out")
[[ "$s2" == "env -u ASC_KEY_ID -u ASC_KEY_ID_FILE "*" -u XLESS_DIST_KEY -u XLESS_DIST_KEY_FILE "*"xless ship --platform ios --config $t/ov/my.overlay.yml --from build --to finalize " ]] || fail "native step 2 wrong: '$s2'"
[[ "$s2" == *"-u ASC_KEY_P8_FILE "* && "$s2" == *"-u ASC_ISSUER_ID_FILE "* ]] || fail "native step 2 keeps secret variables: '$s2'"
[[ "$(sed -n 3p <<<"$out")" == "xless ship --platform ios --config $t/ov/my.overlay.yml --from sign --to upload " ]] || fail "native step 3 wrong: '$out'"
out=$("${base[@]}" XLESS_USE_DOCKER=0 XLESS_SOURCE="$t/proj" "$S" --config "$t/ov/my.overlay.yml" --from upload 2>/dev/null)
[[ "$out" == "xless ship --platform ios --config $t/ov/my.overlay.yml --source $t/proj --from upload --to upload " ]] || fail "native XLESS_SOURCE command wrong: '$out'"
# native, for real (fake xless): step 1's number reaches steps 2 and 3, step 2 sees no secret, a failure stops the run
cat > "$t/bin/xless" <<'X'
#!/bin/sh
echo "$* | ASC_KEY_ID=${ASC_KEY_ID-unset} ASC_KEY_P8_FILE=${ASC_KEY_P8_FILE-unset} BN=${XLESS_BUILD_NUMBER-unset}" >> "$XLOG"
case "$*" in *next-build*) echo "note on stdout first"; echo 1.0.0.2026101503 ;; esac
case "$*" in *"--to finalize"*) exit "${STEP2_EXIT:-0}" ;; esac
exit 0
X
chmod +x "$t/bin/xless"
real=("${base[@]}" XLESS_TESTFLIGHT_DRY_RUN=0 XLESS_USE_DOCKER=0 XLOG="$t/xlog")
: > "$t/xlog"; "${real[@]}" "$S" --config "$t/ov/my.overlay.yml" >/dev/null 2>&1 || fail "native run failed: $(cat "$t/xlog")"
[[ $(wc -l < "$t/xlog") -eq 3 ]] || fail "native run: want 3 invocations: $(cat "$t/xlog")"
grep -q "^tauri next-build .*ASC_KEY_ID=KEYID" "$t/xlog" || fail "step 1 lacks the key: $(cat "$t/xlog")"
grep -q -- "--to finalize | ASC_KEY_ID=unset ASC_KEY_P8_FILE=unset BN=1.0.0.2026101503$" "$t/xlog" || fail "step 2 env wrong: $(cat "$t/xlog")"
grep -q -- "--from sign --to upload | ASC_KEY_ID=KEYID .* BN=1.0.0.2026101503$" "$t/xlog" || fail "step 3 env wrong: $(cat "$t/xlog")"
: > "$t/xlog"; code=0; "${real[@]}" STEP2_EXIT=12 "$S" --config "$t/ov/my.overlay.yml" >/dev/null 2>&1 || code=$?
[[ $code -eq 12 && $(wc -l < "$t/xlog") -eq 2 ]] || fail "step 2 failure: exit $code, $(cat "$t/xlog")"
# --platform macos: a Tauri DMG. No step 1; step 2 without secrets; step 3 with the Developer ID key and the App Store Connect key
printf 'x' > "$t/devid.pem"
mac=("${base[@]}" XLESS_DEVID_KEY_FILE="$t/devid.pem")
out=$("${mac[@]}" "$S" --config "$t/ov/my.overlay.yml" --platform macos 2>/dev/null) || fail "macos dry run failed"
[[ $(wc -l <<<"$out") -eq 2 && "$out" != *"next-build"* ]] || fail "macos wants two steps, no next-build: $out"
s2=$(line "--to finalize"); s3=$(line "--from sign")
[[ "$s2" == *"xless ship --platform macos --config /config/my.overlay.yml --source /source --from build --to finalize "* ]] || fail "macos step 2 wrong: $s2"
[[ "$s3" == *"xless ship --platform macos --config /config/my.overlay.yml --source /source --from sign --to package "* ]] || fail "macos step 3 wrong: $s3"
[[ "$s2" != *"/secrets/"* && "$s2" != *"ASC_"* && "$s2" != *"DEVID"* && "$s2" != *"DIST"* ]] || fail "secrets reach the macos build step: $s2"
[[ "$s2" != *"XLESS_BUILD_NUMBER"* ]] || fail "macos passes a build number it does not have: $s2"
[[ "$s3" == *"--mount type=bind,src=$t/devid.pem,dst=/secrets/devid-key.pem,readonly"* && "$s3" == *"-e XLESS_DEVID_KEY_FILE=/secrets/devid-key.pem"* ]] || fail "devid key not mounted: $s3"
[[ "$s3" == *"dst=/secrets/asc.p8,readonly"* && "$s3" == *"ASC_KEY_P8_FILE=/secrets/asc.p8"* && "$s3" == *"-e ASC_KEY_ID"* ]] || fail "asc key not mounted in macos step 3: $s3"
[[ "$s3" != *"dist-key"* && "$s3" == *"--mount type=bind,src=$t/home/.cache/xless/work,dst=/cache/work"* && "$s3" != *"xless-cargo"* ]] || fail "macos step 3 mounts: $s3"
[[ "$out" == *"ISSUER-SECRET-VALUE"* ]] && fail "issuer value leaked"
# --from package: only step 3, from package (the signed app is reused)
out=$("${mac[@]}" "$S" --config "$t/ov/my.overlay.yml" --platform=macos --from package 2>/dev/null)
[[ $(wc -l <<<"$out") -eq 1 && "$out" == *"--from package --to package "* && "$out" == *"devid-key.pem"* ]] || fail "macos --from package: $out"
# an explicit build number is passed by name to both steps
out=$("${mac[@]}" XLESS_BUILD_NUMBER=1.0.0.202610160000 "$S" --platform macos --config "$t/ov/my.overlay.yml" 2>/dev/null)
[[ "$(line "--to finalize")" == *"-e XLESS_BUILD_NUMBER "* && "$(line "--from sign")" == *"-e XLESS_BUILD_NUMBER "* ]] || fail "macos build number: $out"
# the default platform stays ios; the dist key is not needed on macos, the Developer ID key is
out=$("${base[@]}" "$S" --config "$t/ov/my.overlay.yml" --platform ios 2>/dev/null)
[[ $(wc -l <<<"$out") -eq 3 && "$out" == *"xless ship --platform ios"* && "$out" != *"devid"* ]] || fail "--platform ios: $out"
"${mac[@]}" XLESS_DIST_KEY_FILE= "$S" --config "$t/ov/my.overlay.yml" --platform macos >/dev/null 2>&1 || fail "macos needs the dist key"
# the mac App-Store lane: --to upload = the DMG ship plus the pkg ship under the Apple Distribution key.
printf 'x' > "$t/dist.pem"
out=$("${mac[@]}" XLESS_DIST_KEY_FILE="$t/dist.pem" "$S" --config "$t/ov/my.overlay.yml" --platform macos --to upload 2>/dev/null)
[[ $(wc -l <<<"$out") -eq 3 ]] || fail "macos --to upload: want three steps: $out"
dmgship=$(line "--to package "); pkgship=$(line "--distribution app-store")
[[ "$dmgship" == *"xless ship --platform macos --config /config/my.overlay.yml --source /source --from sign --to package "* ]] || fail "the DMG ship changed with the lane on: $dmgship"
[[ "$pkgship" == *"xless ship --platform macos --config /config/my.overlay.yml --source /source --distribution app-store --from sign --to upload "* ]] || fail "pkg ship wrong: $pkgship"
[[ "$dmgship" == *"dst=/secrets/devid-key.pem,readonly"* && "$dmgship" != *"dst=/secrets/dist-key.pem"* ]] || fail "the DMG ship must carry only its own key: $dmgship"
[[ "$pkgship" == *"dst=/secrets/dist-key.pem,readonly"* && "$pkgship" == *"-e XLESS_DIST_KEY_FILE=/secrets/dist-key.pem"* ]] || fail "pkg ship dist key: $pkgship"
[[ "$pkgship" != *"dst=/secrets/devid-key.pem"* ]] || fail "the pkg ship must not carry the Developer ID key: $pkgship"
[[ "$out" == *"ISSUER-SECRET-VALUE"* ]] && fail "issuer value leaked"

# the lane without the Apple Distribution key is refused before anything runs
code=0; "${mac[@]}" XLESS_DIST_KEY_FILE= "$S" --config "$t/ov/my.overlay.yml" --platform macos --to upload >/dev/null 2>"$t/lanerr" || code=$?
[[ $code -eq 2 ]] && grep -q "XLESS_DIST_KEY_FILE" "$t/lanerr" || fail "the lane needs the dist key: exit $code: $(cat "$t/lanerr")"

code=0; "${mac[@]}" XLESS_DEVID_KEY_FILE= "$S" --config "$t/ov/my.overlay.yml" --platform macos >/dev/null 2>"$t/err" || code=$?
[[ $code -eq 2 ]] && grep -q XLESS_DEVID_KEY_FILE "$t/err" || fail "missing devid key exits $code: $(cat "$t/err")"
code=0; "${mac[@]}" "$S" "$t/proj" --platform macos >/dev/null 2>&1 || code=$?
[[ $code -eq 2 ]] || fail "macos with a project directory exits $code, want 2"
code=0; "${mac[@]}" "$S" --config "$t/ov/my.overlay.yml" --platform tvos >/dev/null 2>&1 || code=$?
[[ $code -eq 2 ]] || fail "unknown platform exits $code, want 2"
# the devid key inside the overlay's directory is refused too
cp "$t/devid.pem" "$t/sec/devid.pem"
code=0; "${mac[@]}" XLESS_DEVID_KEY_FILE="$t/sec/devid.pem" "$S" --config "$t/sec/o.yml" --platform macos >/dev/null 2>"$t/err" || code=$?
[[ $code -eq 2 ]] && grep -q "keep the overlay in its own directory" "$t/err" || fail "devid key inside the overlay directory: exit $code"
# native, for real (fake xless): the DMG path is reported, the build step sees no secret
cat > "$t/bin/xless" <<'X'
#!/bin/sh
echo "$* | DEVID=${XLESS_DEVID_KEY_FILE-unset} ASC_KEY_ID=${ASC_KEY_ID-unset}" >> "$XLOG"
case "$*" in *"--to package"*) echo "==> package"; echo "/work/out/App_1.0.0_universal.dmg" ;; esac
exit 0
X
: > "$t/xlog"; msg=$("${real[@]}" XLESS_DEVID_KEY_FILE="$t/devid.pem" "$S" --config "$t/ov/my.overlay.yml" --platform macos 2>&1 >/dev/null) || fail "native macos run failed: $msg"
[[ $(wc -l < "$t/xlog") -eq 2 ]] || fail "native macos: want 2 invocations: $(cat "$t/xlog")"
grep -q -- "--platform macos .*--to finalize | DEVID=unset ASC_KEY_ID=unset$" "$t/xlog" || fail "macos step 2 env: $(cat "$t/xlog")"
grep -q -- "--from sign --to package | DEVID=$t/devid.pem ASC_KEY_ID=KEYID$" "$t/xlog" || fail "macos step 3 env: $(cat "$t/xlog")"
[[ "$msg" == *"==> DMG: /work/out/App_1.0.0_universal.dmg"* ]] || fail "DMG path not reported: $msg"
# --config with a React Native overlay: step 1 (`xless next-build`) and step 3 in the base image, step 2 in xless-rn with
# its caches on docker volumes (a case-sensitive work copy); no Rust volumes, no host work folder
mkdir -p "$t/rn/app"
cat > "$t/rn/app.yml" <<'Y'
type: "react-native"    # quoted, with a comment
source: app
Y
out=$("${base[@]}" "$S" --config "$t/rn/app.yml" 2>/dev/null) || fail "react-native dry run failed"
# the work volume is per overlay file: its name and a hash of its path
vol="xless-rn-work-app-$(printf '%s' "$t/rn/app.yml" | shasum -a 256 | cut -c1-8)"
[[ $(wc -l <<<"$out") -eq 3 ]] || fail "react-native: want three steps: $out"
s1=$(line "next-build"); s2=$(line "--to finalize"); s3=$(line "--from sign")
[[ "$s1" == *" xless-base:local-"*" xless next-build --config /config/app.yml --source /source " ]] || fail "rn step 1: $s1"
[[ "$s1" == *"dst=/secrets/asc.p8,readonly"* && "$s1" != *"dist-key"* && "$s1" != *"/cache/"* ]] || fail "rn step 1 mounts: $s1"
[[ "$s2" == *" xless-rn:local-"*" xless ship --platform ios --config /config/app.yml --source /source --from build --to finalize "* ]] || fail "rn step 2: $s2"
[[ "$s2" != *"/secrets/"* && "$s2" != *"ASC_"* && "$s2" != *"XLESS_DIST_KEY"* ]] || fail "secrets reach the rn build step: $s2"
for v in $vol:/cache/work xless-corepack:/cache/corepack xless-bundle:/cache/bundle xless-cocoapods-home:/root/.cocoapods \
         xless-cocoapods-cache:/root/Library/Caches/CocoaPods; do
  [[ "$s2" == *"-v $v "* ]] || fail "rn step 2 lacks $v: $s2"
done
[[ "$s2" != *".cache/xless"* && "$s2" != *"xless-cargo"* && "$s2" != *"/cache/downloads"* ]] || fail "rn step 2 mounts Tauri caches: $s2"
[[ "$s2" == *"XLESS_SOURCE_ORIGIN=$t/rn/app "* && "$s2" == *"-e XLESS_BUILD_NUMBER "* && "$s2" != *"XLESS_RN_CLEAN"* ]] || fail "rn step 2 env: $s2"
[[ "$s3" == *" xless-base:local-"*" xless ship --platform ios --config /config/app.yml --source /source --from sign --to upload "* ]] || fail "rn step 3: $s3"
[[ "$s3" == *"-v $vol:/cache/work -e XLESS_WORK_ROOT=/cache/work -e XLESS_WORK_VOLUME=$vol "* && "$s3" == *"dst=/secrets/dist-key.pem,readonly"* ]] || fail "rn step 3 mounts: $s3"
[[ "$s3" != *"cocoapods"* && "$s3" != *"corepack"* && "$s3" != *".cache/xless"* ]] || fail "rn step 3 mounts build caches: $s3"
# image and volume overrides; XLESS_RN_CLEAN reaches the build
out=$("${base[@]}" XLESS_IMAGE=rn:1 XLESS_SIGN_IMAGE=keys:1 XLESS_RN_WORK_VOLUME=w1 XLESS_RN_CLEAN=1 "$S" --config "$t/rn/app.yml" 2>/dev/null)
[[ "$(line "next-build")" == *" keys:1 xless next-build "* ]] || fail "rn step 1 image override: $out"
[[ "$(line "--to finalize")" == *"-v w1:/cache/work "*"-e XLESS_RN_CLEAN "*" rn:1 xless ship "* ]] || fail "rn step 2 overrides: $out"
[[ "$(line "--from sign")" == *"-v w1:/cache/work "*" keys:1 xless ship "* ]] || fail "rn step 3 overrides: $out"
# offline: --build-number with --to finalize needs no secret at all (--dry-run is XLESS_TESTFLIGHT_DRY_RUN=1)
bare=(env -i HOME="$t/home" PATH="$t/bin:/usr/bin:/bin" XLESS_TESTFLIGHT_ENV="$t/none.env" XLESS_USE_DOCKER=1)
out=$("${bare[@]}" "$S" --config "$t/rn/app.yml" --dry-run --build-number 1.0.0.2026101601 --to finalize 2>/dev/null) || fail "offline rn run needs secrets"
[[ $(wc -l <<<"$out") -eq 1 && "$out" == *"--from build --to finalize --build-number 1.0.0.2026101601 "* && "$out" != *"/secrets/"* ]] || fail "offline rn run: $out"
# ... step 3 does, and step 1 needs the App Store Connect key only
code=0; "${bare[@]}" "$S" --config "$t/rn/app.yml" --dry-run --build-number 1.0.0.2026101601 >/dev/null 2>"$t/err" || code=$?
[[ $code -eq 2 ]] && grep -q ASC_KEY_ID "$t/err" || fail "step 3 without secrets: exit $code"
code=0; "${bare[@]}" "$S" --config "$t/rn/app.yml" --dry-run --to finalize >/dev/null 2>"$t/err" || code=$?
[[ $code -eq 2 ]] && grep -q ASC_KEY_ID "$t/err" || fail "step 1 without the App Store Connect key: exit $code"
out=$("${base[@]}" XLESS_DIST_KEY_FILE= "$S" --config "$t/rn/app.yml" --to finalize 2>/dev/null) || fail "--to finalize needs the dist key"
[[ $(wc -l <<<"$out") -eq 2 && "$out" != *"dist-key"* ]] || fail "--to finalize: $out"
# React Native is iOS only
code=0; "${base[@]}" XLESS_DEVID_KEY_FILE="$t/devid.pem" "$S" --config "$t/rn/app.yml" --platform macos >/dev/null 2>&1 || code=$?
[[ $code -eq 2 ]] || fail "react-native --platform macos exits $code, want 2"
# --destination simulator: step 2 only, no secret, no App Store Connect (bare environment), stopping at build
out=$("${bare[@]}" "$S" --config "$t/rn/app.yml" --dry-run --destination simulator 2>/dev/null) || fail "simulator run needs secrets"
[[ $(wc -l <<<"$out") -eq 1 && "$out" == *" xless-rn:local-"*" xless ship --platform ios --config /config/app.yml --source /source --destination simulator --from build --to build "* ]] || fail "simulator: $out"
[[ "$out" != *"/secrets/"* && "$out" != *"ASC_"* && "$out" != *"next-build"* && "$out" == *"-v $vol:/cache/work "* ]] || fail "simulator mounts: $out"
out=$("${bare[@]}" "$S" --config "$t/rn/app.yml" --dry-run --destination=simulator --to prepare 2>/dev/null) || fail "simulator --to prepare"
[[ "$out" == *"--destination simulator --from prepare --to prepare "* ]] || fail "simulator --to prepare: $out"
for bad in "--to finalize" "--from sign" "--to upload"; do
  code=0; "${bare[@]}" "$S" --config "$t/rn/app.yml" --dry-run --destination simulator $bad >/dev/null 2>&1 || code=$?
  [[ $code -eq 2 ]] || fail "simulator $bad exits $code, want 2"
done
code=0; "${bare[@]}" "$S" --config "$t/rn/app.yml" --dry-run --destination tv >/dev/null 2>&1 || code=$?
[[ $code -eq 2 ]] || fail "--destination tv exits $code, want 2"
code=0; "${base[@]}" "$S" "$t/proj" --destination simulator >/dev/null 2>&1 || code=$?
[[ $code -eq 2 ]] || fail "simulator for a project directory exits $code, want 2"
code=0; "${base[@]}" "$S" --config "$t/ov/my.overlay.yml" --destination simulator >/dev/null 2>&1 || code=$?
[[ $code -eq 2 ]] || fail "simulator for a Tauri overlay exits $code, want 2"
# natively: the app's path is reported as it is, for scripts/sim-launch.sh
printf '#!/bin/sh\necho "==> build"\necho /w/.xless/build/ios-simulator/app/App.app\n' > "$t/bin/xless"
msg=$("${bare[@]}" XLESS_USE_DOCKER=0 "$S" --config "$t/rn/app.yml" --destination simulator 2>&1 >/dev/null) || fail "native simulator run failed"
[[ "$msg" == *"==> Simulator app: /w/.xless/build/ios-simulator/app/App.app"* ]] || fail "simulator app not reported: $msg"
# the sim-launch.sh hint is Mac-only
if [[ "$(uname -s)" == Darwin ]]; then [[ "$msg" == *"sim-launch.sh /w/.xless/build/ios-simulator/app/App.app"* ]] || fail "no launch hint on a Mac: $msg"
else [[ "$msg" != *"sim-launch.sh"* ]] || fail "launch hint off a Mac: $msg"; fi
# a source inside a git checkout: the checkout's top is mounted, --source names the app below it
git init -q "$t/repo"; mkdir -p "$t/repo/apps/one"
printf 'type: react-native\nsource: %s\n' "$t/repo/apps/one" > "$t/rn/sub.yml"
out=$("${base[@]}" "$S" --config "$t/rn/sub.yml" 2>/dev/null) || fail "subdirectory source failed"
top=$(cd "$t/repo" && pwd -P)
for l in "$(line "next-build")" "$(line "--to finalize")" "$(line "--from sign")"; do
  [[ "$l" == *"--mount type=bind,src=$top,dst=/source,readonly "*"--source /source/apps/one "* ]] || fail "checkout top not mounted: $l"
done
[[ "$(line "--to finalize")" == *"XLESS_SOURCE_ORIGIN=$t/repo/apps/one "* ]] || fail "origin: $out"
# ... so a secret inside the checkout is refused
printf 'x' > "$t/repo/key.p8"
code=0; "${base[@]}" ASC_KEY_P8_FILE="$t/repo/key.p8" "$S" --config "$t/rn/sub.yml" >/dev/null 2>"$t/err" || code=$?
[[ $code -eq 2 ]] && grep -q "keep secrets out of the source" "$t/err" || fail "secret inside the mounted checkout: exit $code"
# another overlay file gets another work volume
cp "$t/rn/app.yml" "$t/rn/app2.yml"
out2=$("${base[@]}" "$S" --config "$t/rn/app2.yml" 2>/dev/null)
[[ "$out2" == *"-v xless-rn-work-app2-"* && "$out2" != *"-v $vol:"* ]] || fail "work volume not per overlay: $out2"
# --from sign: step 3 only, in the base image, on the work volume; --from build: all three steps
out=$("${base[@]}" "$S" --config "$t/rn/app.yml" --from sign 2>/dev/null)
[[ $(wc -l <<<"$out") -eq 1 && "$out" == *"-v $vol:/cache/work "*" xless-base:local-"*"--from sign --to upload "* ]] || fail "rn --from sign: $out"
out=$("${base[@]}" "$S" --config "$t/rn/app.yml" --from build 2>/dev/null)
[[ $(wc -l <<<"$out") -eq 3 && "$out" == *"xless next-build"* && "$out" == *"--from build --to finalize"* ]] || fail "rn --from build: $out"
# XLESS_BUILD_NUMBER skips step 1; so does a fixed build: (and then no App Store Connect key is needed to build)
out=$("${base[@]}" XLESS_BUILD_NUMBER=1.0.0.2026101601 "$S" --config "$t/rn/app.yml" 2>/dev/null)
[[ $(wc -l <<<"$out") -eq 2 && "$out" != *"next-build"* ]] || fail "rn XLESS_BUILD_NUMBER did not skip step 1: $out"
printf 'type: react-native\nsource: app\nbuild: 42   # fixed\n' > "$t/rn/fixed.yml"
out=$("${bare[@]}" "$S" --config "$t/rn/fixed.yml" --dry-run --to finalize 2>/dev/null) || fail "a fixed build needs App Store Connect for step 1"
[[ $(wc -l <<<"$out") -eq 1 && "$out" != *"next-build"* && "$out" != *"/secrets/"* ]] || fail "fixed build: $out"
# --to prepare alone starts at prepare
out=$("${bare[@]}" "$S" --config "$t/rn/fixed.yml" --dry-run --to prepare 2>/dev/null) || fail "--to prepare refused"
[[ "$out" == *"--from prepare --to prepare "* ]] || fail "--to prepare: $out"
code=0; "${bare[@]}" "$S" --config "$t/rn/fixed.yml" --dry-run --from build --to prepare >/dev/null 2>&1 || code=$?
[[ $code -eq 2 ]] || fail "an explicit --from build --to prepare exits $code, want 2"
# a path with a comma is CSV-quoted in --mount
mkdir -p "$t/a,b/app"; printf 'type: react-native\nsource: app\nbuild: 1\n' > "$t/a,b/o.yml"
out=$("${bare[@]}" "$S" --config "$t/a,b/o.yml" --dry-run --to finalize 2>/dev/null) || fail "comma path refused"
[[ "$out" == *"--mount 'type=bind,\"src=$t/a,b/app\",dst=/source,readonly'"* ]] || fail "comma path not quoted: $out"
# a secret inside a mounted directory is found whatever the spelling (macOS file systems ignore case) and through symlinks
mkdir -p "$t/cs/app"; printf 'type: react-native\nsource: app\n' > "$t/cs/o.yml"; printf 'x' > "$t/cs/key.p8"
if [[ -e "$t/CS/o.yml" ]]; then   # a case-insensitive file system
  code=0; "${base[@]}" ASC_KEY_P8_FILE="$t/cs/key.p8" "$S" --config "$t/CS/o.yml" >/dev/null 2>"$t/err" || code=$?
  [[ $code -eq 2 ]] && grep -q "keep the overlay in its own directory" "$t/err" || fail "secret reached by another case: exit $code $(cat "$t/err")"
fi
# never mount /, the home directory or a directory above it
printf 'type: react-native\nsource: %s\n' "$t/home" > "$t/rn/home.yml"
code=0; "${base[@]}" "$S" --config "$t/rn/home.yml" >/dev/null 2>"$t/err" || code=$?
[[ $code -eq 2 ]] && grep -q "holds your home directory" "$t/err" || fail "home directory as source: exit $code"
printf 'type: react-native\nsource: %s\n' "$t" > "$t/rn/up.yml"
code=0; "${base[@]}" "$S" --config "$t/rn/up.yml" >/dev/null 2>"$t/err" || code=$?
[[ $code -eq 2 ]] && grep -q "holds your home directory" "$t/err" || fail "a parent of the home directory as source: exit $code"
# natively nothing is mounted: neither the home directory as source nor a secret beside the overlay is refused
out=$("${base[@]}" XLESS_USE_DOCKER=0 "$S" --config "$t/rn/home.yml" 2>"$t/err") || fail "native: home directory as source refused: $(cat "$t/err")"
[[ "$(sed -n 1p <<<"$out")" == "xless next-build --config $t/rn/home.yml " ]] || fail "native home source: '$out'"
out=$("${base[@]}" XLESS_USE_DOCKER=0 ASC_KEY_P8_FILE="$t/cs/key.p8" "$S" --config "$t/cs/o.yml" 2>"$t/err") || fail "native: secret beside the overlay refused: $(cat "$t/err")"
code=0; "${base[@]}" ASC_KEY_P8_FILE="$t/cs/key.p8" "$S" --config "$t/cs/o.yml" >/dev/null 2>"$t/err" || code=$?
[[ $code -eq 2 ]] && grep -q "is inside the overlay's directory" "$t/err" || fail "docker: secret beside the overlay: exit $code $(cat "$t/err")"
# native: step 1 is `xless next-build`
out=$("${base[@]}" XLESS_USE_DOCKER=0 "$S" --config "$t/rn/app.yml" 2>/dev/null)
[[ "$(sed -n 1p <<<"$out")" == "xless next-build --config $t/rn/app.yml " ]] || fail "native rn step 1: '$out'"
# --config with a cargo overlay: the Tauri image and caches, step 1 = `xless next-build`, an inputs cache, and path inputs
# (listed by the host xless: `xless cargo inputs`) mounted read-only on step 2 only
mkdir -p "$t/cg/app" "$t/fonts"
printf 'type: cargo\nsource: app\n' > "$t/cg/o.yml"
cat > "$t/bin/xless" <<X
#!/bin/sh
echo "\$*" >> "$t/xinputs.log"
if [ "\$1 \$2" = "cargo inputs" ]; then printf 'fonts\t%s\n' "\$FONTS_DIR"; fi
X
chmod +x "$t/bin/xless"
cg=("${base[@]}" FONTS_DIR="$t/fonts")
: > "$t/xinputs.log"
out=$("${cg[@]}" "$S" --config "$t/cg/o.yml" 2>"$t/err") || fail "cargo dry run failed: $(cat "$t/err")"
[[ $(wc -l <<<"$out") -eq 3 ]] || fail "cargo: want three steps: $out"
s1=$(line "xless next-build"); s2=$(line "--to finalize"); s3=$(line "--from sign")
[[ "$s1" == *"xless next-build --config /config/o.yml --source /source " && "$s1" == *"xless-tauri:local-"* ]] || fail "cargo step 1: $s1"
[[ "$s1" == *"dst=/secrets/asc.p8,readonly"* && "$s1" != *"dist-key"* && "$s1" != *"/cache/"* && "$s1" != *"/inputs/"* ]] || fail "cargo step 1 mounts: $s1"
[[ "$s2" == *"xless-tauri:local-"* && "$s2" == *"--mount type=bind,src=$t/home/.cache/xless/inputs,dst=/cache/inputs"* ]] || fail "cargo step 2 image or inputs cache: $s2"
[[ "$s2" == *"dst=/cache/work"* && "$s2" == *"dst=/cache/downloads"* && "$s2" == *"xless-rustup:/cache/rustup"* && "$s2" == *"xless-cargo:/cache/cargo"* ]] || fail "cargo step 2 caches: $s2"
[[ "$s2" != *"/secrets/"* && "$s2" != *"ASC_"* && "$s2" != *"XLESS_DIST_KEY"* ]] || fail "secrets reach the cargo build step: $s2"
[[ "$s3" == *"xless ship --platform ios --config /config/o.yml --source /source --from sign --to upload "* && "$s3" == *"dst=/secrets/dist-key.pem,readonly"* ]] || fail "cargo step 3: $s3"
[[ "$s3" != *"/inputs"* && "$s3" != *"XLESS_INPUTS_MOUNTED"* && "$s3" != *"xless-cargo"* ]] || fail "cargo step 3 mounts inputs or build caches: $s3"
# the path input: read-only on step 2 only, and the container is told
[[ "$s2" == *"--mount type=bind,src=$t/fonts,dst=/inputs/fonts,readonly"* && "$s2" == *"-e XLESS_INPUTS_MOUNTED=1"* ]] || fail "cargo path input not mounted on step 2: $s2"
[[ $(grep -c "dst=/inputs/fonts,readonly" <<<"$out") -eq 1 ]] || fail "cargo path input not on step 2 only: $out"
[[ "$s1" != *"XLESS_INPUTS_MOUNTED"* ]] || fail "step 1 told about inputs: $s1"
grep -q "^cargo inputs --config $t/cg/o.yml --source $t/cg/app\$" "$t/xinputs.log" || fail "cargo inputs not asked of the host xless: $(cat "$t/xinputs.log")"
# XLESS_SELF names the host xless
printf '#!/bin/sh\nprintf "fonts\\t%%s\\n" "$FONTS_DIR"; echo self >> "%s/xself.log"\n' "$t" > "$t/self"; chmod +x "$t/self"
: > "$t/xself.log"; out=$("${cg[@]}" XLESS_SELF="$t/self" "$S" --config "$t/cg/o.yml" 2>/dev/null) || fail "XLESS_SELF run failed"
[[ -s "$t/xself.log" && "$out" == *"dst=/inputs/fonts,readonly"* ]] || fail "XLESS_SELF not used for cargo inputs: $out"
# no path inputs: nothing mounted at /inputs
printf '#!/bin/sh\nexit 0\n' > "$t/bin/xless"
out=$("${base[@]}" "$S" --config "$t/cg/o.yml" 2>/dev/null) || fail "cargo without inputs failed"
[[ "$out" != *"dst=/inputs/"* ]] || fail "inputs mounted without any: $out"
# a failing `xless cargo inputs` stops the run (exit 2) before docker is shown anything
printf '#!/bin/sh\necho "bad overlay" >&2; exit 10\n' > "$t/bin/xless"
code=0; "${cg[@]}" "$S" --config "$t/cg/o.yml" >/dev/null 2>"$t/err" || code=$?
[[ $code -eq 2 ]] && grep -q "cargo inputs" "$t/err" || fail "failing cargo inputs: exit $code $(cat "$t/err")"
cat > "$t/bin/xless" <<X
#!/bin/sh
echo "\$*" >> "$t/xinputs.log"
if [ "\$1 \$2" = "cargo inputs" ]; then printf 'fonts\t%s\n' "\$FONTS_DIR"; fi
X
# a path input holding a secret, or the home directory (or what holds it), or / : refused (exit 2) naming the input
printf 'x' > "$t/fonts/key.p8"
code=0; "${cg[@]}" ASC_KEY_P8_FILE="$t/fonts/key.p8" "$S" --config "$t/cg/o.yml" >/dev/null 2>"$t/err" || code=$?
[[ $code -eq 2 ]] && grep -q "ASC_KEY_P8_FILE" "$t/err" && grep -q "fonts" "$t/err" || fail "secret inside a path input: exit $code $(cat "$t/err")"
rm -f "$t/fonts/key.p8"
code=0; "${base[@]}" FONTS_DIR="$t/home" "$S" --config "$t/cg/o.yml" >/dev/null 2>"$t/err" || code=$?
[[ $code -eq 2 ]] && grep -q "fonts" "$t/err" && grep -q "home directory" "$t/err" || fail "\$HOME as a path input: exit $code $(cat "$t/err")"
code=0; "${base[@]}" FONTS_DIR="$t" "$S" --config "$t/cg/o.yml" >/dev/null 2>"$t/err" || code=$?
[[ $code -eq 2 ]] && grep -q "home directory" "$t/err" || fail "a parent of \$HOME as a path input: exit $code $(cat "$t/err")"
code=0; "${base[@]}" FONTS_DIR=/ "$S" --config "$t/cg/o.yml" >/dev/null 2>"$t/err" || code=$?
[[ $code -eq 2 ]] || fail "/ as a path input: exit $code"
# a path input that is the secret file itself
code=0; "${base[@]}" FONTS_DIR="$t/key.p8" "$S" --config "$t/cg/o.yml" >/dev/null 2>"$t/err" || code=$?
[[ $code -eq 2 ]] && grep -q "ASC_KEY_P8_FILE" "$t/err" || fail "a secret file as a path input: exit $code $(cat "$t/err")"
code=0; "${base[@]}" FONTS_DIR="$t/nowhere" "$S" --config "$t/cg/o.yml" >/dev/null 2>"$t/err" || code=$?
[[ $code -eq 2 ]] && grep -q "fonts" "$t/err" || fail "a missing path input: exit $code $(cat "$t/err")"
# a step 3 only run asks for no inputs (and mounts none)
: > "$t/xinputs.log"; out=$("${cg[@]}" "$S" --config "$t/cg/o.yml" --from sign 2>/dev/null) || fail "cargo --from sign failed"
[[ $(wc -l <<<"$out") -eq 1 && "$out" != *"/inputs"* && ! -s "$t/xinputs.log" ]] || fail "cargo --from sign: $out"
# natively xless reads the paths directly: nothing is mounted or listed
: > "$t/xinputs.log"; out=$("${cg[@]}" XLESS_USE_DOCKER=0 "$S" --config "$t/cg/o.yml" 2>/dev/null) || fail "native cargo failed"
[[ "$(sed -n 1p <<<"$out")" == "xless next-build --config $t/cg/o.yml " && "$out" != *"/inputs"* && ! -s "$t/xinputs.log" ]] || fail "native cargo: '$out'"
# macOS: the same steps as a Tauri DMG; the path input reaches the build step
out=$("${mac[@]}" FONTS_DIR="$t/fonts" "$S" --config "$t/cg/o.yml" --platform macos 2>"$t/err") || fail "cargo macos failed: $(cat "$t/err")"
[[ $(wc -l <<<"$out") -eq 2 && "$out" != *"next-build"* ]] || fail "cargo macos: want two steps, no next-build: $out"
s2=$(line "--to finalize"); s3=$(line "--from sign")
[[ "$s2" == *"xless ship --platform macos "* && "$s2" == *"dst=/inputs/fonts,readonly"* && "$s2" == *"dst=/cache/inputs"* ]] || fail "cargo macos step 2: $s2"
[[ "$s3" == *"--from sign --to package "* && "$s3" == *"devid-key.pem"* && "$s3" != *"/inputs"* ]] || fail "cargo macos step 3: $s3"
# usage errors
code=0; "${base[@]}" "$S" --config "$t/ov/none.yml" >/dev/null 2>&1 || code=$?
[[ $code -eq 2 ]] || fail "missing overlay exits $code, want 2"
code=0; "${base[@]}" "$S" --config "$t/ov/my.overlay.yml" "$t/proj" >/dev/null 2>&1 || code=$?
[[ $code -eq 2 ]] || fail "--config with a project dir exits $code, want 2"
code=0; "${base[@]}" "$S" "$t/proj" --config "$t/ov/my.overlay.yml" >/dev/null 2>&1 || code=$?
[[ $code -eq 2 ]] || fail "project dir then --config exits $code, want 2"
printf 'type: tauri\n' > "$t/ov/nosrc.yml"
code=0; "${base[@]}" "$S" --config "$t/ov/nosrc.yml" >/dev/null 2>&1 || code=$?
[[ $code -eq 2 ]] || fail "overlay without source exits $code, want 2"
# xcode: pin (Ruling R8): every step in the images made from that Xcode (xless setup), *:local-<arch>-xcode<pin>
case "$(uname -m)" in arm64|aarch64) A=arm64 ;; *) A=amd64 ;; esac
mkdir -p "$t/fd"
cat > "$t/fd/docker" <<'D'
#!/usr/bin/env bash
# A fake docker whose images are the lines of $FAKE_IMAGES.
if [[ "$1 $2" == "context ls" ]]; then printf 'default\ncolima-xless\n'; exit 0; fi
[[ "$1" != --context ]] || shift 2
if [[ "$1 $2" == "image inspect" ]]; then grep -qxF -- "$3" "$FAKE_IMAGES"; exit $?; fi
D
chmod +x "$t/fd/docker"
pinned=(env -i HOME="$t/home" PATH="$t/fd:/usr/bin:/bin" XLESS_TESTFLIGHT_ENV="$t/none.env" XLESS_TESTFLIGHT_DRY_RUN=1 XLESS_USE_DOCKER=1
        ASC_KEY_ID=KEYID ASC_ISSUER_ID_FILE="$t/issuer" ASC_KEY_P8_FILE="$t/key.p8" XLESS_DIST_KEY_FILE="$t/dist.pem" FAKE_IMAGES="$t/images")
mkdir -p "$t/pin/app"
printf 'type: react-native\nsource: app\nxcode: "26.2"   # the release pipeline'"'"'s Xcode\n' > "$t/pin/rn.yml"
printf '%s\n' "xless-rn:local-$A-xcode26.2" "xless-base:local-$A-xcode26.2" "xless-rn:local-$A" "xless-base:local-$A" > "$t/images"
out=$("${pinned[@]}" "$S" --config "$t/pin/rn.yml" 2>"$t/err") || fail "pinned rn dry run: $(cat "$t/err")"
[[ "$(line "next-build")" == *" xless-base:local-$A-xcode26.2 xless next-build "* ]] || fail "pinned rn step 1: $out"
[[ "$(line "--to finalize")" == *" xless-rn:local-$A-xcode26.2 xless ship "* ]] || fail "pinned rn step 2: $out"
[[ "$(line "--from sign")" == *" xless-base:local-$A-xcode26.2 xless ship "* ]] || fail "pinned rn step 3: $out"
grep -q 'xcode: "26.2" (pinned)' "$t/err" || fail "pin not reported: $(cat "$t/err")"
# a missing image is refused (exit 2) with the command that builds it; the default images never stand in for another Xcode
printf '%s\n' "xless-rn:local-$A" "xless-base:local-$A" "xless-base:local-$A-xcode26.2" > "$t/images"
code=0; "${pinned[@]}" "$S" --config "$t/pin/rn.yml" >/dev/null 2>"$t/err" || code=$?
[[ $code -eq 2 ]] || fail "missing pinned image exits $code, want 2"
grep -qF "pins xcode: \"26.2\", but these images are missing: xless-rn:local-$A-xcode26.2; build them from Xcode 26.2: xless setup --xcode <path to Xcode 26.2's .app or .xip> --arch $A" "$t/err" \
  || fail "missing image message: $(cat "$t/err")"
# The pin is looked up as image tags spell it (major.minor, the patch when not 0): "26.2.0" → -xcode26.2, "26" → -xcode26.0
printf '%s\n' "xless-rn:local-$A-xcode26.2" "xless-base:local-$A-xcode26.2" "xless-rn:local-$A-xcode26.0" "xless-base:local-$A-xcode26.0" \
  "xless-rn:local-$A-xcode26.0.1" "xless-base:local-$A-xcode26.0.1" > "$t/images"
for pair in "26.2.0 26.2" "26 26.0" "26.0.0 26.0" "26.0.1 26.0.1"; do
  set -- $pair
  printf 'type: react-native\nsource: app\nxcode: "%s"\n' "$1" > "$t/pin/canon.yml"
  out=$("${pinned[@]}" "$S" --config "$t/pin/canon.yml" 2>"$t/err") || fail "pin $1: $(cat "$t/err")"
  [[ "$(line "--to finalize")" == *" xless-rn:local-$A-xcode$2 xless ship "* && "$(line "--from sign")" == *" xless-base:local-$A-xcode$2 xless ship "* ]] \
    || fail "pin $1 does not select -xcode$2: $out"
done
# A simulator build with a pin needs only the build image (step 2): the App Store Connect image is not required.
printf '%s\n' "xless-rn:local-$A-xcode26.2" > "$t/images"
out=$("${pinned[@]}" "$S" --config "$t/pin/rn.yml" --destination simulator 2>"$t/err") || fail "pinned simulator without xless-base: $(cat "$t/err")"
[[ $(wc -l <<<"$out") -eq 1 && "$out" == *" xless-rn:local-$A-xcode26.2 xless ship "*"--destination simulator"* ]] || fail "pinned simulator: $out"
grep -q "xless-base" "$t/err" && fail "pinned simulator names the App Store Connect image: $(cat "$t/err")"
printf '%s\n' "xless-rn:local-$A" "xless-base:local-$A" > "$t/images"
# versions.env's Xcode: the plain default images serve it when no suffixed image exists
dx="$(sed -n 's/^XCODE_VERSION=//p' "$(dirname "$S")/../versions.env")"
printf 'type: react-native\nsource: app\nxcode: %s\n' "$dx" > "$t/pin/def.yml"
out=$("${pinned[@]}" "$S" --config "$t/pin/def.yml" 2>"$t/err") || fail "default pin: $(cat "$t/err")"
[[ "$(line "--to finalize")" == *" xless-rn:local-$A xless ship "* && "$(line "--from sign")" == *" xless-base:local-$A xless ship "* ]] || fail "default pin images: $out"
# explicit images win over the pin; no pin: the plain images, never inspected
out=$("${pinned[@]}" XLESS_IMAGE=rn:2 XLESS_SIGN_IMAGE=keys:2 "$S" --config "$t/pin/rn.yml" 2>/dev/null) || fail "pinned with explicit images"
[[ "$(line "--to finalize")" == *" rn:2 xless ship "* && "$(line "--from sign")" == *" keys:2 xless ship "* ]] || fail "explicit images and a pin: $out"
: > "$t/images"
out=$("${pinned[@]}" "$S" --config "$t/rn/app.yml" 2>/dev/null) || fail "unpinned rn with no images listed"
[[ "$(line "--to finalize")" == *" xless-rn:local-$A xless ship "* ]] || fail "unpinned rn image: $out"
# Tauri overlays and xless.yml projects take the pin too
printf 'type: tauri\nsource: app\nbundleID: com.example.x\nxcode: 26.2\n' > "$t/pin/tauri.yml"
printf '%s\n' "xless-tauri:local-$A-xcode26.2" "xless:local-$A-xcode26.2" > "$t/images"
out=$("${pinned[@]}" "$S" --config "$t/pin/tauri.yml" 2>/dev/null) || fail "pinned tauri"
[[ $(grep -c " xless-tauri:local-$A-xcode26.2 xless " <<<"$out") -eq 3 ]] || fail "pinned tauri images: $out"
mkdir -p "$t/pinproj"; printf 'xcode: "26.2"\n' > "$t/pinproj/xless.yml"
out=$("${pinned[@]}" "$S" "$t/pinproj" 2>/dev/null) || fail "pinned project"
[[ "$out" == *" xless:local-$A-xcode26.2 xless ship --platform ios"* ]] || fail "pinned project image: $out"
# a pin that is no version is a usage error; natively the pin selects nothing (prepare and the build stage check the SDK)
printf 'type: react-native\nsource: app\nxcode: latest\n' > "$t/pin/bad.yml"
code=0; "${pinned[@]}" "$S" --config "$t/pin/bad.yml" >/dev/null 2>"$t/err" || code=$?
[[ $code -eq 2 ]] && grep -q "is not an Xcode version" "$t/err" || fail "bad pin: exit $code $(cat "$t/err")"
out=$("${base[@]}" XLESS_USE_DOCKER=0 "$S" --config "$t/pin/rn.yml" 2>/dev/null) || fail "native pinned"
[[ "$(sed -n 1p <<<"$out")" == "xless next-build --config $t/pin/rn.yml " ]] || fail "native pinned: '$out'"
# Every docker run is --pull=never, and a real run with a missing local image gets the script's own message (exit 2), not Docker Hub's
out=$("${pinned[@]}" "$S" "$t/pinproj" 2>/dev/null) || fail "pull=never dry run"
[[ "$out" == *" run --rm --pull=never "* ]] || fail "docker run without --pull=never: $out"
: > "$t/images"
real=(env -i HOME="$t/home" PATH="$t/fd:/usr/bin:/bin" XLESS_TESTFLIGHT_ENV="$t/none.env" XLESS_USE_DOCKER=1
      ASC_KEY_ID=KEYID ASC_ISSUER_ID_FILE="$t/issuer" ASC_KEY_P8_FILE="$t/key.p8" XLESS_DIST_KEY_FILE="$t/dist.pem" FAKE_IMAGES="$t/images")
code=0; "${real[@]}" "$S" "$t/proj" >/dev/null 2>"$t/err" || code=$?
[[ $code -eq 2 ]] && grep -qF "is not built on this machine" "$t/err" && grep -qF "xless setup --xcode <Xcode.xip>" "$t/err" \
  || fail "missing image on a real run: exit $code $(cat "$t/err")"
grep -qi "pull access denied" "$t/err" && fail "docker's own pull error reached the user"
echo PASS
