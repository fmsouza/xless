#!/usr/bin/env bash
# scripts/ci-swift.sh: swift runs again once when it was killed by a signal (a toolchain crash), never when it exited
# non-zero itself (a failing or crashing test), and pr.yml runs both swift test steps through it.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT
fail() { echo "FAIL: $*"; exit 1; }
S="$root/scripts/ci-swift.sh"

# A stand-in swift: logs its arguments, then takes what to do from the next line of $t/plan: segv (killed by SIGSEGV,
# as swift-build's crash), or an exit status.
cat > "$t/swift" <<'SH'
#!/bin/sh
echo "$*" >> "$T/log"
what=$(head -n 1 "$T/plan"); sed -i.bak 1d "$T/plan"
[ "$what" = segv ] && kill -SEGV $$
exit "${what:-0}"
SH
chmod +x "$t/swift"
run() {
  printf '%s\n' "$@" > "$t/plan"; : > "$t/log"
  local rc=0
  T="$t" CI_SWIFT="$t/swift" sh "$S" test --package-path 'Third Party' > "$t/out" 2>&1 || rc=$?
  echo "$rc $(wc -l < "$t/log" | tr -d ' ')"
}

[[ "$(run 0)" == "0 1" ]] || fail "a passing run"
[[ "$(sed -n 1p "$t/log")" == "test --package-path Third Party" ]] || fail "arguments: $(cat "$t/log")"
[[ "$(run 1)" == "1 1" ]] || fail "failing tests are run once and fail"
[[ "$(run segv 0)" == "0 2" ]] || fail "a crash of swift is run again"
grep -q '::warning::.*killed by signal 11' "$t/out" || fail "no warning for the rerun: $(cat "$t/out")"
[[ "$(run segv 1)" == "1 2" ]] || fail "the rerun's failure is the result"
[[ "$(run segv segv)" == "139 2" ]] || fail "two crashes: one rerun only"

# pr.yml: every swift test step goes through the script, but the one of Windows (pwsh), whose build is a step of its own.
grep -nE '^[[:space:]]*run: .*swift test' "$root/.github/workflows/pr.yml" | grep -vE 'scripts/ci-swift.sh test|run: swift test --build-system native --skip-build$' && fail "a swift test step of pr.yml without scripts/ci-swift.sh"
[[ $(grep -c 'run: sh scripts/ci-swift.sh test' "$root/.github/workflows/pr.yml") -eq 2 ]] || fail "pr.yml does not run its two swift test steps through scripts/ci-swift.sh"
echo PASS
