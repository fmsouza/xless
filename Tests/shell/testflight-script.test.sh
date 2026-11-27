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
# one that is not there is refused at once: no other xless runs with it (its steps would fail later)
: > "$t/noprogram"
for self in "$t/none" none -v --help "$t/noprogram"; do
  code=0; "${env[@]}" XLESS_SELF="$self" PATH="$t/bin:/usr/bin:/bin" "$script" p >"$t/out" 2>"$t/err" || code=$?
  [[ $code -eq 2 && ! -s "$t/out" ]] && grep -qF "XLESS_SELF ($self) is not a program on this machine" "$t/err" || fail "XLESS_SELF=$self ($code): $(cat "$t/out" "$t/err")"
done
out=$("${env[@]}" XLESS_SELF= PATH="$t/bin:/usr/bin:/bin" "$script" p 2>/dev/null) || fail "an empty XLESS_SELF"
[[ "$out" == *"xless as=1 "*$'\n[run][p]' ]] || fail "an empty XLESS_SELF: $out"
# where the script is, whatever CDPATH holds and however it is named
out=$(cd "$t/prefix/share" && mkdir -p "$t/cd/xless/scripts" && "${env[@]}" CDPATH="$t/cd" sh xless/scripts/testflight.sh p 2>/dev/null) || fail "with a CDPATH"
[[ "$out" == *"$t/prefix/share/xless/scripts/../../../bin/xless as=1 "* ]] || fail "with a CDPATH: $out"
out=$(cp -R "$t/prefix/share/xless/scripts" "$t/prefix/share/xless/-scripts" && cd "$t/prefix/share/xless" && "${env[@]}" sh -- -scripts/testflight.sh p 2>/dev/null) || fail "in a folder named -scripts"
[[ "$out" == *"/../../../bin/xless as=1 "* ]] || fail "in a folder named -scripts: $out"
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
# an Xcode pack in the store (its build is in no table, so no recipe of this xless makes it stale)
case "$(uname -m)" in arm64|aarch64) pa=arm64 ;; *) pa=amd64 ;; esac
pk="$t/home/.local/share/xless-native/xcodes/99.0-99Z99-$pa"; mkdir -p "$pk"; echo '{}' > "$pk/toolchain-meta.json"
printf '{"format":1,"xcode":"99.0","build":"99Z99","arch":"%s","swift":"6.4.0","mode":"own","parts":{"sdk":"h"}}' "$pa" > "$pk/pack.json"
out=$("${run[@]}" "$script" "$t/proj" --to finalize --dry-run 2>/dev/null) || fail "natively"
[[ "$out" == "$XLESS_RUN ship --platform ios --to finalize " ]] || fail "natively: $out"
echo PASS
