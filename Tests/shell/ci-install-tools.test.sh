#!/usr/bin/env bash
# The workflows' "Install tools" steps: each apt-get runs under `timeout` and the install is tried three times, inside a
# step that has its own timeout-minutes, the same way in every workflow (only the package list differs). A mirror that
# stops answering then costs minutes and a retry, not the job. The steps' run blocks are run here with stand-ins for
# getent, timeout, apt-get and sleep.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT
fail() { echo "FAIL: $*"; exit 1; }

# Every "- name: Install tools" step of the workflows: its timeout-minutes, then its run block, unindented, into $t/<n>.sh.
n=0
for wf in "$root"/.github/workflows/*.yml; do
  while IFS= read -r start; do
    n=$((n + 1))
    awk -v s="$start" 'NR > s && /^      - / { exit } NR > s { print }' "$wf" > "$t/step$n"
    grep -qE '^        timeout-minutes: [0-9]+$' "$t/step$n" || fail "${wf##*/}:$start: Install tools has no timeout-minutes"
    awk '/^        run: \|$/ { on = 1; next } on { sub(/^          /, ""); print }' "$t/step$n" > "$t/$n.sh"
    [[ -s "$t/$n.sh" ]] || fail "${wf##*/}:$start: no run block"
    # Outside the timeouts, no apt-get runs.
    if grep -n 'apt-get' "$t/$n.sh" | grep -v '^[0-9]*: *apt="apt-get ' >/dev/null; then fail "${wf##*/}:$start: apt-get outside \$apt"; fi
    sed -E 's/install -y [a-z0-9 .-]+ >/install -y PACKAGES >/' "$t/$n.sh" > "$t/$n.norm"
    cmp -s "$t/1.norm" "$t/$n.norm" || fail "${wf##*/}:$start: Install tools differs from the first one: $(diff "$t/1.norm" "$t/$n.norm" || true)"
  done < <(grep -n '^      - name: Install tools$' "$wf" | cut -d: -f1)
done
[[ $n -eq 3 ]] || fail "expected the Install tools of pr.yml (2) and release.yml (1), found $n"

# The stand-ins. timeout: checks it bounds the command (-k <grace> <seconds>), then runs it with UNDER_TIMEOUT set.
# apt-get: refuses to run outside timeout, logs its subcommand, and takes its exit status from the next line of $t/plan
# (124 is what timeout returns for a command that hung). sleep: logged, instant.
mkdir -p "$t/bin"
cat > "$t/bin/getent" <<'EOF'
#!/bin/sh
exit 0
EOF
cat > "$t/bin/timeout" <<'EOF'
#!/bin/sh
[ "$1" = -k ] && [ "$2" -gt 0 ] && [ "$3" -gt 0 ] && [ "$3" -le 600 ] || { echo "timeout used without -k <grace> <seconds>: $*" >&2; exit 99; }
shift 3
UNDER_TIMEOUT=1 exec "$@"
EOF
cat > "$t/bin/apt-get" <<'EOF'
#!/bin/sh
[ -n "${UNDER_TIMEOUT:-}" ] || { echo "apt-get without timeout" >&2; exit 98; }
for a in "$@"; do case "$a" in update|install) echo "$a" >> "$T/log" ;; esac; done
rc=$(head -n 1 "$T/plan"); sed -i.bak 1d "$T/plan"
exit "${rc:-0}"
EOF
cat > "$t/bin/sleep" <<'EOF'
#!/bin/sh
echo "sleep $1" >> "$T/log"
EOF
chmod +x "$t/bin/"*

# run <plan…>: the first step's block with apt-get answering the plan; prints the exit status, then the log.
run() {
  printf '%s\n' "$@" > "$t/plan"; : > "$t/log"
  local rc=0
  env -i PATH="$t/bin:/usr/bin:/bin" T="$t" sh -e "$t/1.sh" > "$t/out" 2>&1 || rc=$?
  echo "$rc $(tr '\n' ' ' < "$t/log")"
}

got=$(run 0 0)
[[ "$got" == "0 update install " ]] || fail "a working mirror: $got"
got=$(run 124 0 0)
[[ "$got" == "0 update sleep 20 update install " ]] || fail "an update that hung once: $got"
grep -q '::warning::installing the tools failed (attempt 1 of 3)' "$t/out" || fail "no warning for the retry: $(cat "$t/out")"
got=$(run 0 100 0 124 0 0)
[[ "$got" == "0 update install sleep 20 update install sleep 40 update install " ]] || fail "installs that failed twice: $got"
got=$(run 124 124 124)
[[ "$got" == "1 update sleep 20 update sleep 40 update " ]] || fail "a mirror that never answers: $got"
echo PASS
