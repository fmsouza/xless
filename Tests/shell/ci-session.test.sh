#!/usr/bin/env bash
# scripts/ci-session.sh: the command runs in a session of its own whose leader lives, with its arguments, its output and its
# exit code; a signal that stops the script stops the command too.
set -euo pipefail
repo="$(cd "$(dirname "$0")/../.." && pwd)"
t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT
fail() { echo "FAIL: $*"; exit 1; }
s="$repo/scripts/ci-session.sh"
# Not one that has ended and that nothing reaped (a container's first process may not).
alive() { local state; state=$(ps -o stat= -p "$1" 2>/dev/null) || return 1; [[ -n "$state" && "$state" != *Z* ]]; }
alive $$ || fail "ps does not say the state of a process"

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
[[ $rc -eq 143 ]] || fail "stopped by SIGTERM: $rc"
for _ in $(seq 50); do alive "$(cat "$t/pid")" || break; sleep 0.1; done
alive "$(cat "$t/pid")" && fail "the command outlived the script"
# ... also by a signal that comes right after it started the command: here the script is slow to go on from there.
mkdir "$t/slow"
cat > "$t/slow/python3" <<P
#!$(command -v bash)
[[ "\$1 \$2" == "-I -c" && "\$3" == *"child = os.fork()"* ]] || exec $(command -v python3) "\$@"
code="\$3"; shift 3
exec $(command -v python3) -I -c "\${code/child = os.fork()/child = os.fork()
if child: import time; time.sleep(1.5)}" "\$@"
P
chmod +x "$t/slow/python3"; rm "$t/pid"
PATH="$t/slow:$PATH" "$s" sh -c 'echo $$ > "$0/pid"; exec sleep 100' "$t" & p=$!
for _ in $(seq 100); do [[ -s "$t/pid" ]] && break; sleep 0.1; done
kill -TERM "$p"; rc=0; wait "$p" || rc=$?
[[ $rc -eq 143 ]] || fail "stopped early by SIGTERM: $rc"
gone=no; for _ in $(seq 50); do alive "$(cat "$t/pid")" || { gone=yes; break; }; sleep 0.1; done
[[ $gone == yes ]] || { kill "$(cat "$t/pid")"; fail "the command outlived a script that was stopped early"; }   # this test's own sleep
# ... and by one that comes while its leader is about to start it: here the leader is slow to.
cat > "$t/slow/python3" <<P
#!$(command -v bash)
[[ "\$1 \$2" == "-I -c" && "\$3" == *"    os.setsid()"* ]] || exec $(command -v python3) "\$@"
code="\$3"; shift 3
slow='    os.setsid(); import time; open(sys.argv[-1] + "/leads", "w").close(); time.sleep(1.5)'   # not in the expansion: bashes differ on quotes there
exec $(command -v python3) -I -c "\${code/    os.setsid()/\$slow}" "\$@"
P
rm "$t/pid"
PATH="$t/slow:$PATH" "$s" sh -c 'echo $$ > "$0/pid"; exec sleep 100' "$t" & p=$!
for _ in $(seq 100); do [[ -e "$t/leads" ]] && break; sleep 0.1; done
kill -TERM "$p"; rc=0; wait "$p" || rc=$?
[[ $rc -eq 143 ]] || fail "stopped by SIGTERM while it starts: $rc"
[[ ! -s "$t/pid" ]] || ! alive "$(cat "$t/pid")" || { kill "$(cat "$t/pid")"; fail "the command outlived a script that was stopped while it started it"; }   # this test's own sleep
# A command that makes nothing of the signal goes on, and so does the script.
"$s" sh -c 'trap "" TERM; echo > "$0/deaf"; sleep 2; exit 7' "$t" & p=$!
for _ in $(seq 100); do [[ -e "$t/deaf" ]] && break; sleep 0.1; done
kill -TERM "$p"; rc=0; wait "$p" || rc=$?
[[ $rc -eq 7 ]] || fail "a command that ignores SIGTERM and then ends with 7: $rc"
# A command does not inherit what the script does with signals.
[[ "$("$s" python3 -I -c 'import signal; print(signal.pthread_sigmask(signal.SIG_BLOCK, []), signal.getsignal(signal.SIGTERM) == signal.SIG_DFL)')" == "set() True" ]] || fail "the command's signals"
echo "ci-session.test.sh: OK"
