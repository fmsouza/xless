#!/usr/bin/env bash
# scripts/ci-session.sh: the command runs in a session of its own whose leader lives, with its arguments, its output and its
# exit code; a signal that stops the script stops the command too.
set -euo pipefail
repo="$(cd "$(dirname "$0")/../.." && pwd)"
t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT
fail() { echo "FAIL: $*"; exit 1; }
s="$repo/scripts/ci-session.sh"

out=$("$s" printf '<%s>' 'a b' '' '$x' "'") || fail "printf failed"
[[ "$out" == "<a b><><\$x><'>" ]] || fail "the arguments: $out"
for code in 0 1 7 99; do rc=0; "$s" sh -c "exit $code" || rc=$?; [[ $rc -eq $code ]] || fail "exit $code became $rc"; done
rc=0; "$s" sh -c 'kill -KILL $$' || rc=$?; [[ $rc -eq 137 ]] || fail "killed: $rc"
rc=0; "$s" "$t/none" 2>"$t/err" || rc=$?; [[ $rc -eq 127 ]] && grep -q "No such file" "$t/err" || fail "no program: $rc $(cat "$t/err")"
rc=0; "$s" 2>"$t/err" || rc=$?; [[ $rc -eq 2 ]] || fail "no command: $rc"

# Another session than this one, whose leader is the process that started the command: also from a session that lost its own.
cat > "$t/who.py" <<'P'
import os
print(os.getsid(0) == os.getppid(), os.getsid(0))
P
here=$(python3 -I -c 'import os; print(os.getsid(0))')
check() { [[ "$1" == "True "* && "$1" != "True $here" ]] || fail "$2: $1"; }
check "$("$s" python3 -I "$t/who.py")" "the session"
check "$(python3 -I -c '
import os, sys
r, w = os.pipe()
if os.fork() == 0:
    os.setsid()
    if os.fork() == 0:
        os.read(r, 1) # the leader has ended
        os.execvp(sys.argv[1], sys.argv[1:])
    os._exit(0)
os.wait(); os.write(w, b"x")
' "$s" python3 -I "$t/who.py")" "from a session without a leader"

"$s" sh -c 'echo $$ > "$0/pid"; exec sleep 100' "$t" & p=$!
for _ in $(seq 100); do [[ -s "$t/pid" ]] && break; sleep 0.1; done
kill -TERM "$p"; rc=0; wait "$p" || rc=$?
[[ $rc -ne 0 ]] || fail "stopped, and says it succeeded"
for _ in $(seq 50); do kill -0 "$(cat "$t/pid")" 2>/dev/null || break; sleep 0.1; done
kill -0 "$(cat "$t/pid")" 2>/dev/null && fail "the command outlived the script"
echo "ci-session.test.sh: OK"
