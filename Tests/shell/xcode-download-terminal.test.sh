#!/usr/bin/env bash
# `xless xcode download` at its password prompt (echo off), run under a pseudo-terminal: SIGTERM, SIGHUP, SIGQUIT and
# SIGINT give the terminal its echo back before the process dies; Ctrl-Z (SIGTSTP) gives it back while stopped and turns
# it off again on SIGCONT. Nothing reaches Apple: the password is asked for before any request.
#   Tests/shell/xcode-download-terminal.test.sh   (builds xless with `swift build`; XLESS_BIN=<path> uses that binary)
set -euo pipefail
repo="$(cd "$(dirname "$0")/../.." && pwd)"
t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT
x="${XLESS_BIN:-}"
if [[ -z "$x" ]]; then
  (cd "$repo" && env -u DEVELOPER_DIR swift build --product xless -q)
  x="$(cd "$repo" && env -u DEVELOPER_DIR swift build --show-bin-path)/xless"
fi

python3 -I - "$x" "$t" <<'PY'
import fcntl, os, select, signal, sys, termios, time

xless, out = sys.argv[1], sys.argv[2]

def fail(msg):
    print(f"FAIL: {msg}", flush=True)
    os._exit(1)

def echo_on(fd):
    return bool(termios.tcgetattr(fd)[3] & termios.ECHO)

def read_until(fd, text, timeout=60):
    buf, end = b"", time.time() + timeout
    while text not in buf:
        ready, _, _ = select.select([fd], [], [], max(0, end - time.time()))
        if not ready:
            fail(f"no {text!r} from xless; it printed {buf!r}")
        try:
            chunk = os.read(fd, 1024)
        except OSError:
            chunk = b""
        if not chunk:
            fail(f"xless exited before {text!r}; it printed {buf!r}")
        buf += chunk

def wait_for(cond, what):
    for _ in range(200):
        if cond():
            return
        time.sleep(0.05)
    fail(what)

def wait(pid, flags=0, timeout=20):
    end = time.time() + timeout
    while time.time() < end:
        got, status = os.waitpid(pid, flags | os.WNOHANG)
        if got:
            return status
        time.sleep(0.05)
    os.kill(pid, signal.SIGKILL)
    fail("xless neither ended nor stopped")

def in_a_shell(check):
    """Runs `check(pid, master)` in a helper that acts as the shell: it leads a new session on a fresh pty and starts
    xless as the foreground job, in a process group of its own (so a stop signal is not discarded as it would be in an
    orphaned group). The helper outlives xless, so the pty stays readable."""
    helper = os.fork()
    if helper == 0:
        os.setsid()
        master, slave = os.openpty()
        fcntl.ioctl(slave, termios.TIOCSCTTY, 0)
        pid = os.fork()
        if pid == 0:
            os.setpgid(0, 0)
            for fd in (0, 1, 2):
                os.dup2(slave, fd)
            os.execv(xless, [xless, "xcode", "download", "27.0", "--output-dir", out])
        try:
            os.setpgid(pid, pid)
        except OSError:
            pass
        signal.signal(signal.SIGTTOU, signal.SIG_IGN)
        os.tcsetpgrp(slave, pid)
        read_until(master, b"Apple ID")
        os.write(master, b"someone@example.com\n")
        read_until(master, b"Password")
        wait_for(lambda: not echo_on(master), "echo still on at the password prompt")
        check(pid, master)
        os._exit(0)
    _, status = os.waitpid(helper, 0)
    if not (os.WIFEXITED(status) and os.WEXITSTATUS(status) == 0):
        sys.exit(1)

def ends_with_echo(sig):
    def check(pid, master):
        os.kill(pid, sig)
        status = wait(pid)
        if not ((os.WIFSIGNALED(status) and os.WTERMSIG(status) == sig) or
                (os.WIFEXITED(status) and os.WEXITSTATUS(status) == 128 + sig)):
            fail(f"{sig.name}: xless did not end by it (status {status})")
        if not echo_on(master):
            fail(f"{sig.name} at the password prompt left the terminal with echo off")
        print(f"ok: {sig.name} restores echo", flush=True)
    return check

def stop_and_resume(pid, master):
    os.kill(pid, signal.SIGTSTP)
    status = wait(pid, os.WUNTRACED)
    if not os.WIFSTOPPED(status):
        fail(f"SIGTSTP did not stop xless (status {status})")
    if not echo_on(master):
        fail("stopped at the password prompt with echo off")
    os.kill(pid, signal.SIGCONT)
    wait_for(lambda: not echo_on(master), "echo not turned off again after SIGCONT")
    os.kill(pid, signal.SIGTERM)
    wait(pid)
    if not echo_on(master):
        fail("SIGTERM after a stop left echo off")
    print("ok: SIGTSTP/SIGCONT restore and re-hide echo", flush=True)

for sig in (signal.SIGTERM, signal.SIGHUP, signal.SIGQUIT, signal.SIGINT):
    in_a_shell(ends_with_echo(sig))
in_a_shell(stop_and_resume)
PY
echo "ok: xcode download terminal"
