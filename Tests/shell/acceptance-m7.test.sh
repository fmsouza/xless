#!/usr/bin/env bash
# scripts/acceptance-m7.sh end to end against a stub xless (and stub docker, coredumpctl, keyctl), its pauses answered
# by the harness (XLESS_M7_HUMAN=auto): the first run stops at App Review (exit 75) with steps 0 to 5 recorded; the
# second skips what is done and finishes; the record is redacted (no key, token, Apple ID, team, tester or contact);
# --cleanup removes only what the run made; --dry-run and --status run nothing; a secret in a child's environment, an
# unreadable contract and an xless without `secrets redact` are each reported. From a locked store and no session it
# unlocks once and signs in once, and its watchers print nothing on the terminal.
#   Tests/shell/acceptance-m7.test.sh     (builds xless with `swift build` for `secrets redact`; XLESS_BIN=<path> uses that binary)
set -euo pipefail
export LC_ALL=C
repo="$(cd "$(dirname "$0")/../.." && pwd)"
t=$(mktemp -d)
trap '[[ -n "${KEEP_TMP:-}" ]] || rm -rf "$t"' EXIT   # KEEP_TMP=1 keeps it, to look
fail() { echo "FAIL: $*"; exit 1; }
real="${XLESS_BIN:-}"
if [[ -z "$real" ]]; then
  (cd "$repo" && env -u DEVELOPER_DIR swift build --product xless -q)
  real="$(cd "$repo" && env -u DEVELOPER_DIR swift build --show-bin-path)/xless"
fi

mkdir -p "$t/bin" "$t/stub" "$t/home"
cat > "$t/bin/xless" <<'STUB'
#!/usr/bin/env bash
# The stub: answers as xless would, logs every call to $S/log, and keeps its account in $S.
set -u
S="$STUB_DIR"
[[ "$1 ${2:-}" == "secrets redact" ]] || echo "$*" >> "$S/log"
[[ "$1" != run ]] || echo "run-build ${XLESS_BUILD_NUMBER:-}" >> "$S/log"
leak() { printf '%s\n' '-----BEGIN PRIVATE KEY-----' 'MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgLEAKED' '-----END PRIVATE KEY-----' "token eyJhbGciOi.eyJpc3MiOi.c2lnbmF0" "Signed in to Apple as ada@example.com." "team ZZZZZ99999, tester tess@example.com, contact rev@example.com +55 11 5555 0100"; }
trace() { printf '%s\n' "> GET https://api.appstoreconnect.apple.com/v1/apps" "> Authorization: <redacted>" "< Set-Cookie: <redacted>" >&2
          [[ "${STUB_LEAK_TRACE:-0}" == 0 ]] || echo "> Authorization: Bearer abcdef" >&2; }
case "$1 ${2:-}" in
  "--version "*) echo 0.9.0 ;;
  "secrets redact") [[ "${STUB_NO_REDACT:-0}" == 0 ]] || exit 64; exec "$REAL_XLESS" "$@" ;;
  "secrets init") mkdir -p "$XDG_DATA_HOME/xless/vault"; echo '{"version":2,"entries":[{"name":"ASC_KEY_P8@ZZZZZ99999","sealed":"q83vEjRWeJA="}]}' > "$XDG_DATA_HOME/xless/vault/secrets.vault" ;;
  "unlock "*) touch "$S/unlocked"; echo "The secret store is unlocked for the commands of this terminal." ;;
  "lock "*) rm -f "$S/session" "$S/unlocked"; echo "Locked." ;;
  "secrets list"|"team use"|"store validate"|"store push"|"testflight testers"|"builds list"|"devices disable"|"profiles delete"|"certs revoke"|"keys revoke") echo "ok: $*" ;;
  "auth status")
    if [[ -e "$S/session" ]]; then state=kept; else state=none; fi
    if [[ ! -e "$XDG_DATA_HOME/xless/vault/secrets.vault" ]]; then store=missing; elif [[ -e "$S/unlocked" ]]; then store=unlocked; else store=locked; fi
    [[ "${STUB_SAVED_SESSION:-0}" == 0 || $state == kept ]] || { if [[ $store == locked ]]; then state=saved; else state=kept; touch "$S/session"; fi; }
    if [[ " $* " == *" --json "* ]]; then echo "{\"session\": {\"state\": \"$state\", \"appleID\": \"ada@example.com\"}, \"store\": {\"state\": \"$store\"}}"; else echo "session: $state"; fi ;;
  "auth login") [[ "${STUB_LOGIN_FAIL:-0}" == 0 ]] || { trace; echo "[account] Apple refused the password" >&2; exit 20; }; touch "$S/session"; printf 'Signed in to Apple as ada@example.com.\nTEAM ID     NAME\nZZZZZ99999  Ada Lovelace Personal\n'; [[ " $* " != *" --verbose "* ]] || trace ;;
  "auth logout") rm -f "$S/session"; echo "Signed out." ;;
  "auth api-key")
    case "$3" in
      create) echo '{"keyID": "KEY1234567", "issuerID": "69a6de70-0000-47e3-e053-5b8c7c11a4d1", "entry": "ASC_KEY_P8@ZZZZZ99999", "team": "ZZZZZ99999"}' ;;
      *) echo "ok: $*" ;;
    esac ;;
  "live-check "*)
    [[ "${XLESS_LIVE_APPLE:-}" == 1 ]] || { echo "[account] live-check needs XLESS_LIVE_APPLE=1" >&2; exit 20; }
    echo "ok    api  GET /v1/apps  1 app"; [[ ! -e "$S/session" ]] || echo "ok    web  GET /olympus/v1/session  provider 424242421, publicProviderId present, 1 provider(s)"; [[ "${STUB_LIVE_FAIL:-0}" == 0 ]] || { echo "FAIL  api  GET /v1/devices  bad"; leak; exit 1; }
    [[ "${STUB_NO_REDACT:-0}" == 0 ]] || leak ;;
  "bundle-ids list") echo '{"data": [{"type": "bundleIds", "id": "B0", "attributes": {"identifier": "com.unannounced.secretapp"}}]}' ;;
  "certs list"|"profiles list"|"keys list")
    [[ " $* " != *" --verbose "* ]] || { trace; exit 0; }
    kind="$1"; if [[ -e "$S/provisioned" ]]; then echo "{\"data\": [{\"id\": \"OLD-$kind\"}, {\"id\": \"NEW-$kind\"}]}"; else echo "{\"data\": [{\"id\": \"OLD-$kind\"}]}"; fi ;;
  "team list") if [[ " $* " == *" --json "* ]]; then echo '[{"teamId": "ZZZZZ99999", "name": "Ada Lovelace Personal", "providerId": 424242421, "isDefault": true}]'; else trace; fi ;;
  "apps list") trace ;;
  "provision plan")
    if [[ " $* " == *" --json "* ]]; then
      if [[ -e "$S/applied2" ]]; then echo '{"team": "ZZZZZ99999", "steps": []}'; else echo '{"team": "ZZZZZ99999", "steps": [{"area": "app"}]}'; fi
    else echo "Plan: 9 steps"; fi ;;
  "provision apply") if [[ -e "$S/provisioned" ]]; then touch "$S/applied2"; echo "Nothing to do."; else touch "$S/provisioned"; echo "Done: 9 steps."; fi ;;
  "run "*)
    [[ ! -e "$S/approved" ]] || { echo "ERROR ITMS-90186: Invalid Pre-Release Train. The train version '1.0' is closed for new build submissions" >&2; exit 1; }
    if [[ " $* " == *" --docker "* ]]; then
      half=build; [[ " $* " != *" --from sign "* ]] || half=sign
      echo "$half" > "$S/container"; sleep 2.5; rm -f "$S/container"
      echo "==> TestFlight: build number $XLESS_BUILD_NUMBER ($half)"
    else
      env | grep -q '^ASC_KEY_P8=' && { echo "a secret in my environment" >&2; exit 9; }
      if [[ "${STUB_RUN_FAIL_ONCE:-0}" == 1 && ! -e "$S/failed-once" ]]; then touch "$S/failed-once"; echo "upload failed" >&2; exit 1; fi
      if [[ "${STUB_LEAK_ENV:-0}" == 1 ]]; then env ASC_KEY_P8=leaked python3 -I -c 'import time; time.sleep(2)'; else sleep 1.5; fi
      echo "==> TestFlight: build number $XLESS_BUILD_NUMBER"; leak
    fi ;;
  "release submit")
    [[ " $* " =~ \ --build\ 1\.0\+[0-9]+\  ]] || { echo "[account] the pre-flight failed: version 1.0 has no build" >&2; exit 21; }
    if [[ " $* " == *" --dry-run "* ]]; then echo "pre-flight passed"; else touch "$S/submitted"; echo "submitted"; fi ;;
  "release status")
    st="$(cat "$S/review" 2>/dev/null || echo WAITING_FOR_REVIEW)"
    [[ "$st" != PENDING_DEVELOPER_RELEASE && "$st" != READY_FOR_SALE ]] || touch "$S/approved"
    if [[ " $* " == *" --json "* ]]; then echo "{\"version\": {\"type\": \"appStoreVersions\", \"id\": \"V1\", \"attributes\": {\"appVersionState\": \"$st\"}}, \"submissions\": []}"; else echo "STATE $st"; fi ;;
  "release publish") echo READY_FOR_SALE > "$S/review"; echo "released" ;;
  "devices register") echo '{"registered": [{"type": "devices", "id": "DEV1"}], "existing": []}' ;;
  *) echo "stub xless: unexpected $*" >&2; exit 99 ;;
esac
STUB
cat > "$t/bin/docker" <<'STUB'
#!/usr/bin/env bash
S="$STUB_DIR"
# the context it was given ("-": none), for each call; its contexts: default and colima-xless
if [[ "${1:-}" == --context ]]; then echo "$2 $3" >> "$S/contexts"; shift 2; else echo "- ${1:-}" >> "$S/contexts"; fi
case "$1" in
  context) printf 'default\ncolima-xless\n'; exit 0 ;;
  image) echo c0ffee; exit 0 ;;
  # the pack volumes, made by hand (no label: a listing filtered by xless's label finds none; xless finds them by name)
  # (STUB_ODD_VOLUME_ONCE: the first listing has only a volume that is no pack's by its name, as xless reads one)
  volume) [[ "${STUB_ODD_VOLUME_ONCE:-0}" != 1 || -e "$S/odd-listed" ]] || { touch "$S/odd-listed"; printf 'xless-xcode-my-backup-arm64\n'; exit 0; }
          [[ "$*" == *label=* ]] || printf 'xless-xcode-26.2-17C52-arm64\nxless-xcode-26.2-17C52-amd64\n'; exit 0 ;;
  ps) [[ -e "$S/container" ]] && echo "c0ffee$(cat "$S/container")" ; exit 0 ;;
  inspect)
    if [[ "$2" == *sign ]]; then mounts='[{"Destination": "/work"}, {"Destination": "/secrets/store"}]'; else mounts='[{"Destination": "/work"}]'; fi
    if [[ "$2" == *build && "${STUB_LEAK_DOCKER:-0}" == 1 ]]; then mounts='[{"Destination": "/work"}, {"Destination": "/secrets/store"}]'; fi
    # as the swift base image has it: the fingerprint of the public key its tarballs are verified with
    key="${STUB_SIGNING_KEY:-52BB7E3DE28A71BE22EC05FFEF80A866B47A981F}"
    echo "[{\"Id\": \"$2\", \"Config\": {\"Image\": \"xless:0.9.0-arm64\", \"Env\": [\"PATH=/usr/bin\", \"SWIFT_SIGNING_KEY=$key\", \"XLESS_BUILD_NUMBER=7\"]}, \"Mounts\": $mounts, \"Args\": [\"xless\", \"ship\"]}]" ;;
  *) echo "stub docker: $*" >&2; exit 99 ;;
esac
STUB
printf '#!/bin/sh\necho "No coredumps found."\n' > "$t/bin/coredumpctl"
printf '#!/bin/sh\nexit 0\n' > "$t/bin/keyctl"
# the watchers pause half a second and a second between two looks: what they say would land on a person's prompt
cat > "$t/bin/sleep" <<'STUB'
#!/bin/sh
case "$1" in 0.5|1) echo "watcher noise" >&2 ;; esac
exec /bin/sleep "$@"
STUB
chmod 755 "$t/bin/xless" "$t/bin/docker" "$t/bin/coredumpctl" "$t/bin/keyctl" "$t/bin/sleep"

record_template() {   # the committed record's shape: an introduction, then the markers
  printf '# Milestone 7 acceptance\n\nHow to run it.\n\n<!-- acceptance-m7:record:begin -->\nnot run yet\n<!-- acceptance-m7:record:end -->\n\nAfter the record.\n' > "$1"
}

kit() {   # NAME ARGS…: runs the kit in scenario NAME (its own state, stub account and record); exit code → $code
  local name="$1"; shift
  mkdir -p "$t/$name/stub" "$t/$name/home"
  [[ -f "$t/$name/record.md" ]] || record_template "$t/$name/record.md"
  code=0
  env -i PATH="$t/bin:/usr/bin:/bin" HOME="$t/$name/home" XDG_DATA_HOME="$t/$name/home/.local/share" \
    XDG_CONFIG_HOME="$t/$name/home/.config" STUB_DIR="$t/$name/stub" REAL_XLESS="$real" \
    XLESS_M7_DIR="$t/$name/state" XLESS_M7_RECORD="$t/$name/record.md" XLESS_M7_HUMAN=auto \
    XLESS_M7_TEAM=ZZZZZ99999 XLESS_M7_TESTER=tess@example.com XLESS_M7_BUNDLE_ID=dev.xless.m7.test \
    XLESS_M7_CONTACT_FIRST=Rita XLESS_M7_CONTACT_LAST=Reviewer XLESS_M7_CONTACT_PHONE="+55 11 5555 0100" \
    XLESS_M7_CONTACT_EMAIL=rev@example.com \
    STUB_LOGIN_FAIL="${STUB_LOGIN_FAIL:-0}" STUB_SAVED_SESSION="${STUB_SAVED_SESSION:-0}" STUB_LEAK_ENV="${STUB_LEAK_ENV:-0}" STUB_LEAK_TRACE="${STUB_LEAK_TRACE:-0}" STUB_LIVE_FAIL="${STUB_LIVE_FAIL:-0}" \
    STUB_NO_REDACT="${STUB_NO_REDACT:-0}" STUB_LEAK_DOCKER="${STUB_LEAK_DOCKER:-0}" STUB_SIGNING_KEY="${STUB_SIGNING_KEY:-}" STUB_RUN_FAIL_ONCE="${STUB_RUN_FAIL_ONCE:-0}" STUB_ODD_VOLUME_ONCE="${STUB_ODD_VOLUME_ONCE:-0}" \
    ${DEVICE:+XLESS_M7_DEVICE_UDID=$DEVICE} ${DOCKER_CONTEXT:+DOCKER_CONTEXT=$DOCKER_CONTEXT} \
    bash "$repo/scripts/acceptance-m7.sh" "$@" >"$t/$name/out" 2>"$t/$name/err" </dev/null || code=$?
}
calls() { grep -c -- "$2" "$t/$1/stub/log" || true; }
clean_record() {   # NAME: nothing secret or personal reached the record
  local r="$t/$1/record.md" word
  for word in "PRIVATE KEY" MIGHAgEAMBMG eyJhbGciOi ada@example.com ZZZZZ99999 tess@example.com rev@example.com "5555 0100" Rita Reviewer \
              "Ada Lovelace Personal" 424242421 69a6de70 com.unannounced 00008110-001A2B3C4D5E6F70 "$t"; do
    ! grep -qF -- "$word" "$r" || fail "$1: the record shows '$word': $(grep -nF -- "$word" "$r" | head -3)"
  done
}

# 1. The first run: steps 0 to 5 and 8 (Docker, before App Review: Apple takes no build of an approved version), then
#    App Review is pending (exit 75).
DEVICE=00008110-001A2B3C4D5E6F70 kit main
[[ $code == 75 ]] || fail "first run: exit $code, expected 75: $(tail -20 "$t/main/err")"
r="$t/main/record.md"
{ grep -q '^How to run it.$' "$r" && grep -q '^After the record.$' "$r"; } || fail "the text around the markers changed"
! grep -q 'not run yet' "$r" || fail "the old record is still there"
for i in 0 1 2 3 4 5 8; do grep -q "^| $i | .* | \*\*PASS\*\*" "$r" || fail "step $i is not PASS: $(grep "^| $i |" "$r")"; done
grep -q '^| 6 | .* | \*\*PENDING\*\* — in App Review' "$r" || fail "step 6 is not pending: $(grep '^| 6 |' "$r")"
grep -q '^\$ xless provision apply --project ' "$r" || fail "the commands are not recorded"
grep -q 'build number' "$r" || fail "the output of xless run is not recorded"
clean_record main
[[ $(calls main 'live-check') == 3 ]] || fail "the contract check ran $(calls main 'live-check') times, expected 3 (start, after steps 2 and 4)"
[[ $(calls main '^release submit .* --release manual$') == 1 ]] || fail "not submitted once"
[[ $(calls main '^devices register .* 00008110-001A2B3C4D5E6F70') == 1 ]] || fail "the device was not registered"
grep -q 'not recorded: it names every app' "$r" || fail "the bundle ID check is not noted"
app="$t/main/state/app"
{ grep -q '^bundleID: dev.xless.m7.test$' "$app/xless.yml" && grep -q '^teamID: ZZZZZ99999$' "$app/xless.yml"; } || fail "xless.yml placeholders: $(head -5 "$app/xless.yml")"
{ grep -q 'firstName: "Rita"' "$app/appstore/app.yml" && grep -q '^bundleID: dev.xless.m7.test$' "$app/appstore/app.yml"; } || fail "app.yml placeholders"
grep -q '^xless M7 ' "$app/appstore/pt-BR/name.txt" || fail "name placeholder: $(cat "$app/appstore/pt-BR/name.txt")"
! grep -rq 'com\.example\.xless\.m7\|ABCDE12345\|XLESSM7SKU' "$app" --exclude-dir=.git --exclude=README.md || fail "a placeholder was left"
[[ -n "$(find "$t/main/state" -prune -perm 700)" ]] || fail "the state directory is not private"

# From a locked store and no session: one unlock and one sign-in, whose trace is scanned (so that step 7 needs no other);
# the session is dropped before step 5, which has the store only.
[[ $(calls main '^unlock') == 1 ]] || fail "the store was unlocked $(calls main '^unlock') times, expected once"
[[ $(calls main '^auth login') == 1 ]] || fail "signed in $(calls main '^auth login') times, expected once"
grep -q "xless auth login --keep 30m --verbose.: 3 trace line(s), 0 finding(s)" "$r" || fail "the sign-in's trace was not scanned: $(grep 'trace line' "$r")"
order="$(grep -n '^auth logout\|^run ' "$t/main/stub/log" | sed 's/^[0-9]*://; s/ .*//' | head -2 | tr '\n' ' ')"
[[ "$order" == "auth run " ]] || fail "step 5 ran with a kept session: $order"
! grep -q 'watcher noise' "$t/main/err" || fail "a watcher printed on the terminal: $(grep -m1 'watcher noise' "$t/main/err")"

# 2. Run again while still in review: nothing before step 6 runs again; still 75.
before=$(wc -l < "$t/main/stub/log")
kit main
[[ $code == 75 ]] || fail "second run in review: exit $code"
new="$(tail -n +"$((before + 1))" "$t/main/stub/log")"
! grep -q '^provision\|^run \|^auth api-key create\|^testflight testers add' <<< "$new" || fail "finished steps ran again: $new"

# 3. Approved: the run finishes (publish, security, docker, the question).
echo PENDING_DEVELOPER_RELEASE > "$t/main/stub/review"
kit main
[[ $code == 0 ]] || fail "third run: exit $code: $(tail -20 "$t/main/err")"
for i in 6 7 9; do grep -q "^| $i | .* | \*\*PASS\*\*" "$r" || fail "step $i is not PASS: $(grep "^| $i |" "$r")"; done
[[ $(calls main '^release submit .* --release manual$') == 1 ]] || fail "submitted again"
[[ $(calls main '^release publish') == 1 ]] || fail "not published once"
{ grep -q 'run --docker .* --to finalize' "$t/main/stub/log" && grep -q 'run --docker .* --from sign' "$t/main/stub/log"; } || fail "the docker run was not split"
grep -q 'container c0ffeebuild .*mounts=/work env=' "$r" || fail "the build container was not inspected: $(grep -n container "$r")"
# step 8's docker is the one xless run --docker uses (scripts/docker-context.sh): colima-xless here, for every look at it
for call in ps inspect volume image; do
  grep -q "^colima-xless $call\$" "$t/main/stub/contexts" || fail "step 8 did not use colima-xless for docker $call: $(sort "$t/main/stub/contexts" | uniq -c)"
done
if grep -v '^colima-xless \|^- context$' "$t/main/stub/contexts"; then fail "step 8 looked at another docker"; fi
for c in 'team list --verbose' 'keys list --team <redacted> --verbose' 'apps list --team <redacted> --verbose'; do
  grep -qF "\`xless $c\`: 3 trace line(s), 0 finding(s)" "$r" || fail "the trace of '$c' was not scanned: $(grep 'trace line' "$r")"
done
grep -q 'no xless key after xless lock' "$r" || fail "the keyring was not checked"
[[ $(calls main '^auth login') == 1 && $(calls main '^unlock') == 1 ]] || fail "asked again after App Review: $(calls main '^auth login') sign-ins, $(calls main '^unlock') unlocks"
clean_record main
kit main
[[ $code == 0 ]] || fail "a run after everything is done: exit $code"

# 4. --dry-run and --status run nothing; --cleanup removes only what the run made.
before=$(wc -l < "$t/main/stub/log")
kit main --dry-run; [[ $code == 0 ]] || fail "--dry-run: exit $code"
grep -q 'xless provision apply' "$t/main/out" || fail "--dry-run does not list the commands"
kit main --status; [[ $code == 0 ]] || fail "--status: exit $code"
grep -q '^ 9\. PASS  *Neither' "$t/main/out" || fail "--status: $(cat "$t/main/out")"
[[ $(wc -l < "$t/main/stub/log") == "$before" ]] || fail "--dry-run or --status ran xless: $(tail -n +"$((before + 1))" "$t/main/stub/log")"
kit main --cleanup
[[ $code == 0 ]] || fail "--cleanup: exit $code: $(tail -5 "$t/main/err")"
for c in 'devices disable DEV1' 'certs revoke NEW-certs' 'profiles delete NEW-profiles' 'keys revoke NEW-keys' 'auth api-key revoke KEY1234567' 'testflight testers remove tess@example.com'; do
  grep -q "^$c" "$t/main/stub/log" || fail "--cleanup did not run '$c'"
done
! grep -q 'OLD-' <(grep 'revoke\|delete' "$t/main/stub/log") || fail "--cleanup touched what was there before"
grep -q '^### Cleanup' "$r" || fail "the cleanup is not recorded"
clean_record main

# 5. A secret in the environment of a process of the run fails step 7; a build container with a secret fails step 8.
mkdir -p "$t/leak/stub"; echo PENDING_DEVELOPER_RELEASE > "$t/leak/stub/review"
STUB_LEAK_ENV=1 kit leak
[[ $code == 1 ]] || fail "leak: exit $code, expected 1"
grep -q '^| 7 | .* | \*\*FAIL\*\*' "$t/leak/record.md" || fail "a secret in a child's environment passed step 7"
grep -q 'FOUND [^ ]*[Pp]ython[^ ]*(.*environment variable ASC_KEY_P8' "$t/leak/record.md" || fail "the finding is not recorded"
! grep -q 'leaked' "$t/leak/record.md" || fail "the value was recorded"
mkdir -p "$t/dock/stub"; echo PENDING_DEVELOPER_RELEASE > "$t/dock/stub/review"
STUB_LEAK_DOCKER=1 kit dock
[[ $code == 1 ]] || fail "docker leak: exit $code"
grep -q '^| 8 | .* | \*\*FAIL\*\*' "$t/dock/record.md" || fail "a build container with the store passed step 8"
# a DOCKER_CONTEXT that docker does not have fails step 8 before anything runs, as xless would refuse it
before=$(grep -c '^run-build ' "$t/dock/stub/log")
DOCKER_CONTEXT=gone kit dock
[[ $code == 1 ]] || fail "a DOCKER_CONTEXT docker does not have: exit $code"
grep -q '^| 8 | .* | \*\*FAIL\*\*.*DOCKER_CONTEXT is gone (set in the environment), but docker has no context of that name' "$t/dock/record.md" \
  || fail "the missing context is not step 8's failure: $(grep '^| 8 |' "$t/dock/record.md")"
[[ $(grep -c '^run-build ' "$t/dock/stub/log") == "$before" ]] || fail "xless run --docker ran with a missing context"
kit dock   # step 8 starts again: its failure is not judged a second time from the old containers
[[ $code == 0 ]] || fail "step 8 again without the leak: exit $code: $(tail -5 "$t/dock/err")"
builds=(); while IFS= read -r line; do builds+=("$line"); done < <(grep '^run-build ' "$t/dock/stub/log" | tail -4)   # two halves, then two halves
[[ ${#builds[@]} == 4 && "${builds[0]}" == "${builds[1]}" && "${builds[2]}" == "${builds[3]}" && "${builds[1]}" != "${builds[2]}" ]] ||
  fail "step 8 did not run again with a new build number: ${builds[*]}"
mkdir -p "$t/dockkey/stub"; echo PENDING_DEVELOPER_RELEASE > "$t/dockkey/stub/review"
STUB_SIGNING_KEY=not-a-fingerprint STUB_ODD_VOLUME_ONCE=1 kit dockkey
[[ $code == 1 ]] || fail "SWIFT_SIGNING_KEY holding something else: exit $code"
# (and a volume whose name is no pack's, as xless reads one, is not taken for the pack step 8 needs)
grep -q 'There is no xless image of this xless, or no Xcode pack' "$t/dockkey/record.md" "$t/dockkey/out" "$t/dockkey/err" || fail "xless-xcode-my-backup-arm64 was taken for a pack"
grep -q '^| 8 | .* | \*\*FAIL\*\*' "$t/dockkey/record.md" || fail "SWIFT_SIGNING_KEY holding something else passed step 8"

# 6. --contract alone: a FAIL from live-check stops with 1, recorded; without `secrets redact` the fallback redacts.
STUB_LIVE_FAIL=1 kit contract --contract
[[ $code == 1 ]] || fail "--contract with a failing endpoint: exit $code"
grep -q '^| 0 | .* | \*\*FAIL\*\*' "$t/contract/record.md" || fail "the contract failure is not recorded"
[[ $(calls contract 'provision\|api-key') == 0 ]] || fail "--contract wrote something"
clean_record contract
STUB_NO_REDACT=1 kit fallback --contract
[[ $code == 0 ]] || fail "--contract with the fallback redaction: exit $code: $(tail -5 "$t/fallback/err")"
grep -q 'build number\|ok    api' "$t/fallback/record.md" || fail "the fallback recorded nothing"
clean_record fallback

# A session that is already kept is used, whoever kept it; one saved in the store is there once the store is unlocked; a
# sign-in that fails says why; a secret in the trace of the sign-in is found.
mkdir -p "$t/kept/stub"; touch "$t/kept/stub/session"
kit kept --contract
[[ $code == 0 && $(calls kept '^auth login') == 0 ]] || fail "signed in although a session is kept (exit $code)"
mkdir -p "$t/saved/stub" "$t/saved/home/.local/share/xless/vault"; echo '{}' > "$t/saved/home/.local/share/xless/vault/secrets.vault"
STUB_SAVED_SESSION=1 kit saved --contract
[[ $code == 0 && $(calls saved '^auth login') == 0 && $(calls saved '^unlock') == 1 ]] || fail "signed in although a session is saved in the store (exit $code): $(cat "$t/saved/stub/log")"
STUB_LOGIN_FAIL=1 kit refused --contract
[[ $code != 0 ]] || fail "a sign-in that failed went on"
grep -q 'Apple refused the password' "$t/refused/err" || fail "a failed sign-in does not say why: $(tail -5 "$t/refused/err")"
STUB_LEAK_TRACE=1 kit trace --contract
grep -q 'xless auth login --keep 30m --verbose.: 4 trace line(s), 1 finding(s)' "$t/trace/record.md" || fail "a token in the sign-in's trace was not found: $(grep 'trace line' "$t/trace/record.md")"
! grep -q 'Bearer abcdef' "$t/trace/record.md" || fail "the token was recorded"

# 7. A run of step 5 that fails takes a new build number next time; a rejection (76) resubmits once fixed.
mkdir -p "$t/retry/stub"; echo REJECTED > "$t/retry/stub/review"
STUB_RUN_FAIL_ONCE=1 kit retry
[[ $code == 1 ]] || fail "retry: exit $code, expected 1"
grep -q '^| 5 | .* | \*\*FAIL\*\*' "$t/retry/record.md" || fail "the failed run is not recorded"
STUB_RUN_FAIL_ONCE=1 kit retry
[[ $code == 76 ]] || fail "rejected: exit $code, expected 76: $(tail -5 "$t/retry/err")"
builds=(); while IFS= read -r line; do builds+=("$line"); done < <(grep '^run-build ' "$t/retry/stub/log" | head -2)
[[ ${#builds[@]} == 2 && "${builds[0]}" != "${builds[1]}" ]] || fail "step 5 ran again with the same build number: ${builds[*]}"
grep -q '^| 6 | .* | \*\*PENDING\*\* — Apple rejected it (REJECTED)' "$t/retry/record.md" || fail "the rejection is not recorded"
echo PENDING_DEVELOPER_RELEASE > "$t/retry/stub/review"
kit retry
[[ $code == 0 ]] || fail "after the fix: exit $code: $(tail -5 "$t/retry/err")"
[[ $(calls retry '^release submit .* --release manual$') == 2 ]] || fail "not resubmitted after the rejection"

# 8. What a person typed before a question was shown does not answer it.
{ echo 'HUMAN=ask; note() { echo "NOTE $*"; }; die() { echo "$*"; exit 1; }'
  sed -n '/^# ---- people/,/^# ---- helpers/p' "$repo/scripts/acceptance-m7.sh"
  echo 'echo READY; sleep 1; ask_yes "Submit it?" || true; ask_yes "Sure?" || true'; } > "$t/people.sh"
python3 -I - "$t/people.sh" <<'PY' || fail "typed-ahead input answered a question"
import os, pty, re, sys
pid, fd = pty.fork()
if pid == 0: os.execv("/bin/bash", ["bash", sys.argv[1]])
seen = b""
def until(text):
    global seen
    while not re.search(text, seen):
        try: chunk = os.read(fd, 4096)
        except OSError: chunk = b""
        if not chunk: sys.exit(f"no {text!r} in {seen!r}")
        seen += chunk
until(b"READY")
os.write(fd, b"y\n")
until(rb"Submit it\? \[y/N\] ")
os.write(fd, b"\n")
until(rb"Sure\? \[y/N\] ")
os.write(fd, b"yes\n") # (one that is answered is heard)
until(rb'"Sure\?" [^\n]*yes')
sys.exit(b'"Submit it?" \xe2\x80\x94 no.' not in seen)
PY

echo "acceptance-m7: ok"
