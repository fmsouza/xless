#!/bin/sh
# Runs a command in a POSIX session of its own, whose leader waits for it, and ends as it ends:
#   scripts/ci-session.sh <command> [argument…]
# The xless agent serves a session only while its leader runs (docs/security.md), so its tests need one: a terminal's shell is,
# and what a CI service or a job scheduler started may have left its leader behind. (A command cannot help itself: the leader of
# a process group, as `swift test` makes of the tests, cannot start a session.)
[ $# -gt 0 ] || { echo "usage: scripts/ci-session.sh <command> [argument...]" >&2; exit 2; }
exec python3 -I -c '
import os, signal, subprocess, sys
child = os.fork()
if child == 0:
    os.setsid()
    try: code = subprocess.call(sys.argv[1:])
    except OSError as e:
        print("ci-session: %s: %s" % (sys.argv[1], e.strerror), file=sys.stderr)
        code = 127
    os._exit(code if code >= 0 else 128 - code)
def stop(number, frame):
    try: os.killpg(child, number)
    except ProcessLookupError: pass
for number in (signal.SIGHUP, signal.SIGINT, signal.SIGTERM): signal.signal(number, stop)
sys.exit(os.waitstatus_to_exitcode(os.waitpid(child, 0)[1]) & 255)
' "$@"
