#!/bin/sh
# Runs a command in a POSIX session of its own, whose leader waits for it, and ends as it ends:
#   scripts/ci-session.sh <command> [argument…]
# The xless agent serves a session only while its leader runs (docs/security.md), so its tests need one: a terminal's shell is,
# and what a CI service or a job scheduler started may have left its leader behind. (A command cannot help itself: the leader of
# a process group, as `swift test` makes of the tests, cannot start a session.)
[ $# -gt 0 ] || { echo "usage: scripts/ci-session.sh <command> [argument...]" >&2; exit 2; }
exec python3 -I -c '
import os, signal, subprocess, sys
# A signal waits from before the fork until it can be passed on: the script passes it to the leader, and the leader, once the command
# is there, to its group (a group that is signalled while it forks may miss what is forked: so the leader does it, and goes on).
stops = (signal.SIGHUP, signal.SIGINT, signal.SIGTERM)
before = signal.pthread_sigmask(signal.SIG_BLOCK, stops)
def pass_on(send):
    def stop(number, frame):
        try: send(number)
        except ProcessLookupError: pass
    for number in stops: signal.signal(number, stop)
    signal.pthread_sigmask(signal.SIG_SETMASK, before)
def to_group(number):
    mine = signal.signal(number, signal.SIG_IGN)
    os.killpg(0, number)
    signal.signal(number, mine)
child = os.fork()
if child == 0:
    os.setsid()
    if signal.getsignal(signal.SIGINT) is signal.default_int_handler: signal.signal(signal.SIGINT, signal.SIG_DFL)
    try:
        command = subprocess.Popen(sys.argv[1:], preexec_fn=lambda: signal.pthread_sigmask(signal.SIG_SETMASK, before))
        pass_on(to_group)
        code = command.wait()
    except OSError as e:
        print("ci-session: %s: %s" % (sys.argv[1], e.strerror), file=sys.stderr)
        code = 127
    os._exit(code if code >= 0 else 128 - code)
pass_on(lambda number: os.kill(child, number))
code = os.waitstatus_to_exitcode(os.waitpid(child, 0)[1])
sys.exit(code if code >= 0 else 128 - code)
' "$@"
