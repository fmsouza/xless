#!/usr/bin/env bash
# Ctrl-C (SIGINT), SIGTERM and SIGHUP end the tool xless runs too, and what that started: it is in a POSIX session of its
# own (docs/security.md), where the terminal's signals do not come. With the real binary and a fake docker.
#   Tests/shell/tool-signals.test.sh   (builds xless with `swift build`; XLESS_BIN=<path> uses that binary)
set -euo pipefail
repo="$(cd "$(dirname "$0")/../.." && pwd)"
t=$(mktemp -d /tmp/xts.XXXXXX)
trap 'rm -rf "$t"' EXIT
x="${XLESS_BIN:-}"
if [[ -z "$x" ]]; then
  (cd "$repo" && env -u DEVELOPER_DIR swift build --product xless -q)
  x="$(cd "$repo" && env -u DEVELOPER_DIR swift build --show-bin-path)/xless"
fi

python3 -I - "$x" "$t" "$repo" <<'PY'
import os, pty, select, signal, subprocess, sys, time

xless, t, repo = os.path.realpath(sys.argv[1]), os.path.realpath(sys.argv[2]), sys.argv[3]
keep = {k: os.environ[k] for k in ("LD_LIBRARY_PATH", "DYLD_LIBRARY_PATH") if k in os.environ}
env = {**keep, "PATH": t + "/bin:" + os.environ["PATH"], "HOME": t + "/home", "XDG_DATA_HOME": t + "/data", "XDG_CONFIG_HOME": t + "/config",
       "XDG_CACHE_HOME": t + "/cache", "XDG_RUNTIME_DIR": t + "/run", "TMPDIR": t + "/tmp", "TERM": "dumb", "LC_ALL": "C"}
for d in ("home", "data", "config", "cache", "run", "tmp", "bin"):
    os.mkdir(f"{t}/{d}", 0o700)
# `xless clean` lists the images with it: it starts a process of its own and takes its time, unless it is told otherwise.
with open(t + "/bin/docker", "w") as f:
    f.write(f"""#!/bin/sh
if [ -e {t}/quick ]; then
  rm {t}/quick
  exit 0
fi
if [ -e {t}/polite ]; then
  sleep 300 &
  echo $! > {t}/child
  trap 'echo told > {t}/told; kill %1; exit 0' INT TERM HUP
  echo $$ > {t}/tool
  wait
else
  echo $$ > {t}/tool
  sh -c 'echo $$ > {t}/child; exec sleep 300'
fi
""")
os.chmod(t + "/bin/docker", 0o755)
failures = 0

def check(ok, what, detail=""):
    global failures
    if not ok:
        failures += 1
    print(("ok   " if ok else "FAIL ") + what + ("" if ok else f"\n     {detail!r}"), flush=True)

def until(condition, seconds=10):
    end = time.time() + seconds
    while time.time() < end:
        if condition(): return True
        time.sleep(0.05)
    return False

def alive(pid):
    out = subprocess.run(["ps", "-o", "stat=", "-p", str(pid)], capture_output=True, text=True).stdout.strip()
    return out != "" and not out.startswith("Z")

def pid_in(name):
    until(lambda: os.path.exists(f"{t}/{name}") and open(f"{t}/{name}").read().strip())
    return int(open(f"{t}/{name}").read())

def dispositions(ignored):
    for s in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        signal.signal(s, signal.SIG_IGN if s == ignored else signal.SIG_DFL)

def clear():
    for name in ("tool", "child", "told", "polite", "quick"):
        if os.path.exists(f"{t}/{name}"): os.unlink(f"{t}/{name}")

def start(ignored=None, polite=False):
    clear()
    if polite: open(t + "/polite", "w").close()
    p = subprocess.Popen([xless, "clean"], env=env, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, preexec_fn=lambda: dispositions(ignored))
    return p, pid_in("tool"), pid_in("child")

def ended(p):
    try: return p.wait(30)
    except subprocess.TimeoutExpired:
        p.kill()
        return "xless goes on"

def end(*pids):
    for pid in pids:
        try: os.kill(pid, signal.SIGKILL)
        except ProcessLookupError: pass

for s in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
    p, tool, child = start()
    check(os.getsid(tool) == tool, "(the tool is in a session of its own)")
    os.kill(p.pid, s)
    rc = ended(p)
    check(rc == -s, f"{s.name} ends xless, by that signal", rc)
    check(until(lambda: not alive(tool) and not alive(child)), f"and the tool it ran, and what that started: {s.name}", (alive(tool), alive(child)))
    end(tool, child)

p, tool, child = start(polite=True)
os.kill(p.pid, signal.SIGINT)
rc = ended(p)
check(rc == -signal.SIGINT and until(lambda: os.path.exists(t + "/told")), "a tool that cleans up on a signal is told it", rc)
end(tool, child)

# As under nohup: what is ignored stays so, for both; the rest still ends both.
p, tool, child = start(ignored=signal.SIGHUP)
os.kill(p.pid, signal.SIGHUP)
time.sleep(1)
check(p.poll() is None and alive(tool) and alive(child), "a signal xless was started to ignore (nohup) is not passed on")
os.kill(p.pid, signal.SIGTERM)
rc = ended(p)
check(rc == -signal.SIGTERM and until(lambda: not alive(tool) and not alive(child)), "SIGTERM is", rc)
end(tool, child)

# Whenever it comes, also while the tool is being started.
left = []
def tools():
    out = subprocess.run(["ps", "-axww", "-o", "pid=,stat=,args="], capture_output=True, text=True).stdout
    return [l for l in out.splitlines() if t + "/" in l and "docker" in l and not l.split()[1].startswith("Z")]
for i in range(50):
    clear()
    p = subprocess.Popen([xless, "clean"], env=env, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, preexec_fn=lambda: dispositions(None))
    time.sleep(i * 0.004)
    p.send_signal(signal.SIGTERM)
    if ended(p) != -signal.SIGTERM or not until(lambda: not tools(), 3): left.append((i, tools()))
check(not left, "at whatever moment it comes, nothing is left running", left)

# The end is by that signal also when another thread looks at the handlers meanwhile, as whatever starts a tool does, and when it
# is a thread of a dispatch queue that goes on to it (macOS: such a thread cannot send itself a signal). With the C that xless is
# made of, where they can be made to meet.
with open(t + "/meet.c", "w") as f:
    f.write(r"""
#include <pthread.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdio.h>
#include <unistd.h>
#include "CXlessProcess.h"
#ifdef __APPLE__
#include <dispatch/dispatch.h>
#endif
static atomic_int raising, back, queued, counted, noted;
static void until(atomic_int *flag) { for (int i = 0; i < 500 && !atomic_load(flag); i++) usleep(10000); }
int met_sigaction(int sig, const struct sigaction *new, struct sigaction *old) {
    int r = sigaction(sig, new, old);
    if (atomic_load(&queued) && !atomic_exchange(&counted, 1)) until(&noted); // this start is counted, and what it starts not known
    if (sig == SIGTERM && new != NULL && atomic_load(&raising)) {
        atomic_store(&back, 1);
        usleep(1000000); // this start goes on no further yet
    }
    return r;
}
int met_raise(int sig) {
    if (!atomic_exchange(&raising, 1) && !atomic_load(&queued)) until(&back);
    return raise(sig);
}
static int start(void) {
    char *const none[] = { NULL };
    int pid;
    return xless_spawn_session("/nonexistent", none, none, NULL, -1, -1, &pid);
}
static void *starts(void *unused) {
    until(&raising);
    start();
    return unused;
}
#ifdef __APPLE__
static void starts_on_a_queue(void *unused) {
    atomic_store(&queued, 1);
    start();
}
#endif
int main(int argc, char **argv) {
    pthread_t thread;
    start();
#ifdef __APPLE__
    if (argc > 1) {
        dispatch_async_f(dispatch_get_global_queue(0, 0), NULL, starts_on_a_queue);
        until(&counted);
        pthread_kill(pthread_self(), SIGTERM); // which waits for the start
        atomic_store(&noted, 1);
        sleep(30);
        return 4;
    }
#endif
    if (pthread_create(&thread, NULL, starts, NULL) != 0) return 2;
    pthread_kill(pthread_self(), SIGTERM);
    pthread_join(thread, NULL);
    return 3;
}
""")
c = repo + "/Sources/CXlessProcess"
subprocess.run(["clang", "-I", c + "/include", "-Draise(s)=met_raise(s)", "-Dsigaction(a,b,c)=met_sigaction(a,b,c)", "-Wno-everything",
                "-c", "-o", t + "/process.o", c + "/CXlessProcess.c"], check=True)
subprocess.run(["clang", "-I", c + "/include", "-Wall", "-Werror", "-o", t + "/meet", t + "/meet.c", t + "/process.o", "-lpthread", *(["-lbsm"] if sys.platform == "darwin" else [])], check=True)
for how, what in [([], "another thread ends xless")] + [(["queue"], "a thread of a dispatch queue ends xless then")] * (sys.platform == "darwin"):
    p = subprocess.Popen([t + "/meet", *how], stdin=subprocess.DEVNULL, preexec_fn=lambda: dispositions(None))
    rc = ended(p)
    check(rc == -signal.SIGTERM, f"a signal that comes as a tool is about to be started: {what}, by that signal", rc)

# At the two moments no test meets by chance (Linux, where a preloaded library can make them).
if sys.platform == "linux":
    with open(t + "/moments.c", "w") as f:
        f.write(r"""
#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <pthread.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <sys/syscall.h>
#include <unistd.h>
static atomic_int once, raising, installed, forked; // forked: the tool of that moment
static int is(const char *moment) {
    const char *m = getenv("XLESS_TEST_MOMENT");
    return m != NULL && strcmp(m, moment) == 0 && strcmp(program_invocation_short_name, "xless") == 0;
}
static int until(atomic_int *flag, int tenths) {
    while (!atomic_load(flag) && tenths-- > 0) usleep(100000);
    return atomic_load(flag);
}
static void *signalled(void *unused) {
    sigset_t none;
    sigemptyset(&none);
    pthread_sigmask(SIG_SETMASK, &none, NULL);
    pthread_kill(pthread_self(), SIGTERM);
    return unused;
}
static void signal_elsewhere(void) {
    pthread_t thread;
    if (!atomic_exchange(&once, 1) && pthread_create(&thread, NULL, signalled, NULL) == 0) until(&raising, 10);
}
int raise(int sig) {
    int (*real)(int) = (int (*)(int))dlsym(RTLD_NEXT, "raise");
    if (is("deaf")) return 0; // as for process 1 of a container
    atomic_store(&raising, 1);
    if (is("start") || is("again")) until(&forked, 20);
    return real(sig);
}
// Once the last handler is there (start), as the next tool is about to be started (again), or when one just was (forked),
// the signal comes on another thread ...
int sigaction(int sig, const struct sigaction *new, struct sigaction *old) {
    int (*real)(int, const struct sigaction *, struct sigaction *) = (int (*)(int, const struct sigaction *, struct sigaction *))dlsym(RTLD_NEXT, "sigaction");
    int r = real(sig, new, old);
    if (sig == SIGHUP && new != NULL && new->sa_handler != SIG_DFL && new->sa_handler != SIG_IGN) {
        atomic_store(&installed, 1);
        if (is("start")) signal_elsewhere();
    }
    return r;
}
pid_t getpid(void) {
    if (atomic_load(&installed) == 2 && is("again")) signal_elsewhere();
    return (pid_t)syscall(SYS_getpid);
}
// ... and ends the process when the tool runs and nobody knows its number yet.
pid_t fork(void) {
    pid_t (*real)(void) = (pid_t (*)(void))dlsym(RTLD_NEXT, "fork");
    pid_t pid = real();
    int first = 1;
    if (pid > 0 && is("again") && atomic_compare_exchange_strong(&installed, &first, 2)) return pid; // the one before
    if (pid > 0 && is("forked")) signal_elsewhere();
    if (pid > 0 && (is("start") || is("again"))) { atomic_store(&forked, 1); usleep(2000000); }
    return pid;
}
""")
    subprocess.run(["clang", "-shared", "-fPIC", "-o", t + "/moments.so", t + "/moments.c", "-ldl", "-lpthread"], check=True)
    def at(moment):
        clear()
        if moment == "again": open(t + "/quick", "w").close()
        return subprocess.Popen([xless, "clean"], env={**env, "LD_PRELOAD": t + "/moments.so", "XLESS_TEST_MOMENT": moment}, stdin=subprocess.DEVNULL,
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, preexec_fn=lambda: dispositions(None))
    for moment, what in (("start", "is about to be started"), ("again", "is about to be started, not the first"), ("forked", "was started")):
        p = at(moment)
        rc = ended(p)
        check(rc == -signal.SIGTERM and until(lambda: not tools(), 3) and not os.path.exists(t + "/quick"), f"a signal that another thread takes as a tool {what} leaves none behind", (rc, tools()))
        subprocess.run(["pkill", "-9", "-f", t + "/bin/docker"])

    p = at("deaf")
    tool, child = pid_in("tool"), pid_in("child")
    p.send_signal(signal.SIGTERM)
    rc = ended(p)
    check(rc == 128 + signal.SIGTERM and until(lambda: not alive(tool) and not alive(child)), "where a signal does not end it (process 1), xless ends all the same", rc)
    end(tool, child)

# Typed: Ctrl-C reaches xless by the terminal, and the tool by xless.
clear()
pid, fd = pty.fork()
if pid == 0:
    dispositions(None)
    os.execve(xless, [xless, "clean"], env)
tool, child = pid_in("tool"), pid_in("child")
os.write(fd, b"\x03")
check(until(lambda: not alive(tool) and not alive(child)), "Ctrl-C ends the tool")
end(tool, child)
os.kill(pid, signal.SIGKILL) if not until(lambda: not alive(pid), 5) else None
os.waitpid(pid, 0)

print("tool-signals.test.sh: " + ("passed" if not failures else f"{failures} FAILED"), flush=True)
sys.exit(1 if failures else 0)
PY
