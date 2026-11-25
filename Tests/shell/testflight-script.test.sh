#!/usr/bin/env bash
# scripts/testflight.sh, kept for those who call it: it runs `xless run` with the same arguments, says so once, on standard
# error, and finds the xless of this machine. No docker, no network, no secrets.
set -euo pipefail
t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT
. "$(dirname "$0")/run-entry.sh"
fail() { echo "FAIL: $*"; exit 1; }
mkdir -p "$t/bin" "$t/home" "$t/proj" "$t/prefix/bin" "$t/prefix/share/xless/scripts"
cp "$repo/scripts/testflight.sh" "$t/prefix/share/xless/scripts/"
script="$t/prefix/share/xless/scripts/testflight.sh"
cat > "$t/bin/xless" <<'X'
#!/bin/sh
echo "$0 as=${XLESS_RUN_AS_SCRIPT:-} self=${XLESS_SELF:-} docker=${XLESS_USE_DOCKER-unset}"
printf '[%s]' "$@"; echo
exit "${STUB_EXIT:-0}"
X
chmod +x "$t/bin/xless"
cp "$t/bin/xless" "$t/prefix/bin/xless"
cp "$t/bin/xless" "$t/mine"
env=(env -i HOME="$t/home" PATH="/usr/bin:/bin")
# the same arguments, and the exit code
out=$("${env[@]}" PATH="$t/bin:/usr/bin:/bin" "$script" "a b" --to '$(x)' 2>"$t/err") || fail "the script: $(cat "$t/err")"
[[ "$out" == "$t/bin/xless as=1 self="*" docker=unset"$'\n[run][a b][--to][$(x)]' || "$out" == "xless as=1 "*$'\n[run][a b][--to][$(x)]' ]] || fail "it runs: $out"
[[ "$(cat "$t/err")" == "note: scripts/testflight.sh is going away; use: xless run"* && $(wc -l < "$t/err") -eq 1 ]] || fail "one notice: $(cat "$t/err")"
code=0; "${env[@]}" PATH="$t/bin:/usr/bin:/bin" STUB_EXIT=23 "$script" p >/dev/null 2>&1 || code=$?
[[ $code -eq 23 ]] || fail "exit $code, want xless's 23"
# which xless: XLESS_SELF, PATH, the one it came with
out=$("${env[@]}" XLESS_SELF="$t/mine" PATH="$t/bin:/usr/bin:/bin" "$script" p 2>/dev/null) || fail "XLESS_SELF"
[[ "$out" == "$t/mine as=1 self=$t/mine docker=unset"$'\n[run][p]' ]] || fail "XLESS_SELF: $out"
out=$("${env[@]}" "$script" p 2>/dev/null) || fail "the installed xless"
[[ "$out" == *"/bin/xless as=1 self="*"/bin/xless docker=unset"$'\n[run][p]' ]] || fail "the installed xless: $out"
rm "$t/prefix/bin/xless"
code=0; "${env[@]}" "$script" p >"$t/out" 2>"$t/err" || code=$?
[[ $code -eq 2 && ! -s "$t/out" ]] && grep -q "no xless on this machine" "$t/err" || fail "without xless ($code): $(cat "$t/err")"
# an xless that still runs this script would never end
code=0; "${env[@]}" XLESS_RUN_AS_SCRIPT=1 XLESS_SELF="$t/mine" "$script" p >/dev/null 2>"$t/err" || code=$?
[[ $code -eq 2 ]] && grep -q "is older than scripts/testflight.sh" "$t/err" || fail "an older xless ($code): $(cat "$t/err")"
# the real xless, as the script runs it: in the images unless an SDK is installed here, its steps by $XLESS_SELF
printf 'name: App\n' > "$t/proj/xless.yml"
cp "$t/bin/xless" "$t/bin/docker"
run=("${env[@]}" PATH="$t/bin:/usr/bin:/bin" XLESS_SHARE="$repo" XLESS_TESTFLIGHT_ENV="$t/none.env" XLESS_SELF="$XLESS_RUN" DOCKER_CONTEXT=stub)
out=$("${run[@]}" "$script" "$t/proj" --to finalize --dry-run 2>"$t/err") || fail "the script and xless: $(cat "$t/err")"
[[ "$out" == "docker --context stub run "*" xless ship --platform ios --to finalize " ]] || fail "in the images: $out"
[[ $(grep -c "is going away" "$t/err") -eq 1 ]] || fail "one notice: $(cat "$t/err")"
mkdir -p "$t/home/.config/xless"; echo '{}' > "$t/home/.config/xless/toolchain-meta.json"
out=$("${run[@]}" "$script" "$t/proj" --to finalize --dry-run 2>/dev/null) || fail "natively"
[[ "$out" == "$XLESS_RUN ship --platform ios --to finalize " ]] || fail "natively: $out"
echo PASS
