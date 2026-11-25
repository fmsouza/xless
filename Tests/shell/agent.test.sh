#!/usr/bin/env bash
# The xless agent (docs/security.md, "Holding an unlock"), with the real binary and real terminals (pseudo-terminals,
# each led by a bash): one unlock serves the later commands of the terminal; the tools xless runs, whatever they do to
# get away from it, are refused; another terminal is served once it types the passphrase; lock, expiry, idle time, a
# changed passphrase, a replaced store and a closed terminal end it. Nothing reaches Apple.
#   Tests/shell/agent.test.sh   (builds xless with `swift build`; XLESS_BIN=<path> uses that binary)
set -euo pipefail
repo="$(cd "$(dirname "$0")/../.." && pwd)"
t=$(mktemp -d /tmp/xat.XXXXXX)   # short: a socket's path is
trap 'rm -rf "$t"' EXIT
x="${XLESS_BIN:-}"
if [[ -z "$x" ]]; then
  (cd "$repo" && env -u DEVELOPER_DIR swift build --product xless -q)
  x="$(cd "$repo" && env -u DEVELOPER_DIR swift build --show-bin-path)/xless"
fi

python3 -I - "$x" "$t" <<'PY'
import fcntl, json, os, pty, re, select, signal, subprocess, sys, termios, time

xless, t = os.path.realpath(sys.argv[1]), os.path.realpath(sys.argv[2])
PROMPT = rb"(assphrase|again): |\[y/N\] "
PASS, NEXT, VALUE = "correct horse battery staple", "another long passphrase here", "the value of NOTE"
keep = {k: os.environ[k] for k in ("PATH", "LD_LIBRARY_PATH", "DYLD_LIBRARY_PATH") if k in os.environ}
env = {**keep, "HOME": t + "/home", "XDG_DATA_HOME": t + "/data", "XDG_CONFIG_HOME": t + "/config", "XDG_RUNTIME_DIR": t + "/run",
       "TMPDIR": t + "/tmp", "TERM": "dumb", "LC_ALL": "C", "X": xless, "T": t}
for d in ("home", "data", "config", "run", "tmp", "bin", "config/xless"):
    os.mkdir(f"{t}/{d}", 0o700)
with open(t + "/config/xless/config.yml", "w") as f:   # what is held here is asked for (the offer: prompts.test.sh)
    f.write("unlock: { keep: never }\n")
failures = 0

def check(ok, what, detail=""):
    global failures
    if not ok:
        failures += 1
    print(("ok   " if ok else "FAIL ") + what + ("" if ok else f"\n     {detail!r}"), flush=True)

class Terminal:
    """A terminal: a bash that leads a session of its own on a fresh pty."""
    def __init__(self):
        self.pid, self.fd = pty.fork()
        if self.pid == 0:
            os.execve("/bin/bash", ["bash", "--noprofile", "--norc", "--noediting"], {**env, "PS1": "", "PS2": ""})
        self.seen = b""
        os.write(self.fd, b"stty -echo; PS1=; PS2=; echo READY$((1))\n")
        self.until(b"READY1")

    def until(self, text, timeout=90):
        end = time.time() + timeout
        while not re.search(text, self.seen):
            ready, _, _ = select.select([self.fd], [], [], max(0, end - time.time()))
            chunk = b""
            if ready:
                try: chunk = os.read(self.fd, 4096)
                except OSError: pass
            if not chunk:
                print(f"FAIL no {text!r}; the terminal shows {self.seen!r}", flush=True)
                subprocess.run([xless, "lock"], env=env)
                sys.exit(1)
            self.seen += chunk
        at = re.search(text, self.seen).end()
        before, self.seen = self.seen[:at], self.seen[at:]
        return before.decode(errors="replace")

    def run(self, command, *answers):
        """Types `command`, and each answer at the next passphrase prompt; (exit code, what was shown, prompts)."""
        os.write(self.fd, (command + "; echo __DONE:$?:\n").encode())
        shown = ""
        for answer in answers:
            shown += self.until(PROMPT)
            # The prompt is written before the echo is turned off: wait for that.
            for _ in range(100):
                if not termios.tcgetattr(self.fd)[3] & termios.ECHO: break
                time.sleep(0.02)
            time.sleep(0.1)
            os.write(self.fd, (answer + "\n").encode())
        shown += self.until(b"__DONE:")
        rc = int(self.until(b":")[:-1])
        return rc, shown, len(re.findall(PROMPT, shown.encode()))

    def close(self):
        os.close(self.fd)
        os.kill(self.pid, signal.SIGHUP)
        try: os.kill(self.pid, signal.SIGKILL)
        except ProcessLookupError: pass
        os.waitpid(self.pid, 0)

def agents():
    """The agents of this test: those whose socket is in its runtime directory."""
    d = t + "/run/xless-agent"
    return sorted(n for n in os.listdir(d) if n.endswith(".sock")) if os.path.isdir(d) else []

def agent_pids():
    out = subprocess.run(["ps", "-axww", "-o", "pid=,ppid=,tty=,args="], capture_output=True, text=True).stdout
    rows = [l.split(None, 3) for l in out.splitlines()]
    return [(int(r[0]), int(r[1]), r[2]) for r in rows if len(r) == 4 and r[3].startswith("xless __agent") or len(r) == 4 and r[3] == f"{xless} __agent"]

def status(term):
    rc, shown, _ = term.run("$X auth status --json")
    return json.loads(shown[shown.index("{"):shown.rindex("}") + 1])

def gone(seconds=10):
    for _ in range(int(seconds * 10)):
        if not agents(): return True
        time.sleep(0.1)
    return False

# What build code may try: run the program that has the unlock, from here, from a new session, from a double fork (an
# orphan of a new session), back in the terminal's process group, and with the terminal itself.
probe = t + "/bin/probe"
with open(probe, "w") as f:
    f.write(f"#!{sys.executable} -I\n" + r'''
import json, os, subprocess, sys
x, t = os.environ["X"], os.environ["T"]
env = {k: v for k, v in os.environ.items() if k != "XLESS_NO_SECRET_STORE"}
def attempt(name, **kw):
    out = f"{t}/stolen-{sys.argv[1]}-{name}"
    r = subprocess.run([x, "secrets", "export", "NOTE", "--out", out], env=env, stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=60, **kw)
    s = json.loads(subprocess.run([x, "auth", "status", "--json"], env=env, stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=60, **kw).stdout)
    with open(f"{t}/probe-{sys.argv[1]}.log", "a") as log:
        log.write(json.dumps({"name": name, "rc": r.returncode, "stolen": os.path.exists(out), "store": s["store"]["state"], "err": r.stderr, "sid": os.getsid(0)}) + "\n")
attempt("child")
attempt("setsid", start_new_session=True)
def group():
    try: os.setpgid(0, int(os.environ["LEADER"]))
    except OSError: pass
attempt("group", preexec_fn=group)
def orphan():
    os.setsid()
    if os.fork(): os._exit(0)
pid = os.fork()
if pid == 0:
    os.setsid()
    if os.fork(): os._exit(0)
    try: attempt("orphan")
    finally:
        open(f"{t}/probe-{sys.argv[1]}.done", "w").close()
        os._exit(0)
os.waitpid(pid, 0)
import time
for _ in range(600):
    if os.path.exists(f"{t}/probe-{sys.argv[1]}.done"): break
    time.sleep(0.1)
''')
os.chmod(probe, 0o755)
with open(t + "/bin/docker", "w") as f:   # a tool xless runs (`xless clean` lists the images with it)
    f.write(f"#!/bin/sh\nif [ -t 0 ]; then echo terminal; else echo none; fi > {t}/tool-stdin\n[ -e {t}/probe-tool.done ] || {probe} tool >/dev/null 2>&1\nexit 0\n")
os.chmod(t + "/bin/docker", 0o755)
with open(t + "/note", "w") as f:
    f.write(VALUE)

a = Terminal()
rc, shown, _ = a.run("$X secrets init", PASS, PASS)
check(rc == 0, "a store is created", shown)
rc, shown, n = a.run("$X secrets import NOTE --file $T/note", PASS, "n")
check(rc == 0, "a secret is imported", shown)
rc, shown, n = a.run("$X secrets import xless-own --file $T/note", PASS, "n")
check(rc == 0, "a name that starts with xless- is one like any", shown)
rc, shown, n = a.run("$X secrets export xless-own --out $T/out.own", PASS)
check(rc == 0 and open(t + "/out.own").read() == VALUE, "and comes out again", shown)
rc, shown, n = a.run("$X secrets import xless-apple-session --file $T/note")
check(rc != 0 and n == 0 and "choose another name" in shown and open(t + "/note").read() == VALUE, "the saved session's name is refused before anything is asked", shown)

# ---- nothing is held by default --------------------------------------------------------------------------------------
rc, shown, n = a.run("$X secrets export NOTE --out $T/out0", PASS)
check(rc == 0 and n == 1, "without an unlock each command asks", shown)
check(not agents(), "and no agent runs")
s = status(a)
check(s["store"]["state"] == "locked", "auth status says it is locked", s["store"])

# ---- one unlock, several commands ------------------------------------------------------------------------------------
rc, shown, n = a.run("$X unlock --for 2h", PASS)
check(rc == 0 and n == 1 and "2 h" in shown, "xless unlock asks once and says for how long", shown)
check(len(agents()) == 1, "an agent holds it", agents())
for i in range(3):
    rc, shown, n = a.run(f"$X secrets export NOTE --out $T/out1.{i}")
    check(rc == 0 and n == 0 and open(f"{t}/out1.{i}").read() == VALUE, f"command {i + 1} after it asks nothing", shown)
s = status(a)["store"]
check(s["state"] == "unlocked" and s["backend"] == "agent" and 7000 < s["remainingSeconds"] <= 7200 and s["idleSeconds"] == 7200, "auth status --json says what is held, where and until when", s)
rc, shown, n = a.run("$X auth status")
check("unlocked in the xless agent until" in shown, "auth status says it", shown)

# ---- the agent's process ----------------------------------------------------------------------------------------------
mode = os.stat(t + "/run/xless-agent").st_mode & 0o777
sock = os.stat(f"{t}/run/xless-agent/{agents()[0]}").st_mode & 0o777
check(mode == 0o700 and sock == 0o600, "its directory is 0700 and its socket 0600", (oct(mode), oct(sock)))
mine = [p for p in agent_pids() if os.getsid(p[0]) == a.pid]
check(len(mine) == 1, "one agent is of this terminal's session", agent_pids())
pid, ppid, tty = mine[0]
check(ppid != a.pid and tty in ("?", "??"), "it is nobody's child here and has no terminal", (ppid, tty))
if os.path.isdir("/proc/self/fd"):
    try:
        fds = {int(n): os.readlink(f"/proc/{pid}/fd/{n}") for n in os.listdir(f"/proc/{pid}/fd")}
        check(all(fds[n] == "/dev/null" for n in (0, 1, 2)) and not [v for n, v in fds.items() if n > 2 and not v.startswith(("socket:", "anon_inode:"))], "its descriptors are /dev/null and its socket", fds)
        check(open(f"/proc/{pid}/environ", "rb").read() == b"", "its environment is empty")
    except PermissionError:
        check(True, "its descriptors and environment are closed to its own user (not dumpable)")
    lim = open(f"/proc/{pid}/limits").read() if os.access(f"/proc/{pid}/limits", os.R_OK) else ""
    check(not lim or re.search(r"Max core file size\s+0\s+0", lim), "it dumps no core", lim)
    check(os.stat(f"/proc/{pid}/mem").st_uid == 0, "it is not dumpable: its memory belongs to root", os.stat(f"/proc/{pid}/mem"))
else:
    out = subprocess.run(["ps", "-Eww", "-o", "command=", "-p", str(pid)], capture_output=True, text=True).stdout.strip()
    check(out.endswith("__agent"), "its environment is empty", out)
    out = subprocess.run(["lsof", "-w", "-a", "-p", str(pid), "-d", "0-200", "-Fn"], capture_output=True, text=True).stdout
    names = [l[1:] for l in out.splitlines() if l.startswith("n")]
    check(names.count("/dev/null") == 3 and not [n for n in names if n.startswith("/") and n != "/dev/null" and ".sock" not in n], "its descriptors are /dev/null and its socket", names)

# ---- build code --------------------------------------------------------------------------------------------------------
rc, shown, n = a.run("PATH=$T/bin:$PATH LEADER=$$ $X clean")
log = [json.loads(l) for l in open(t + "/probe-tool.log")]
check(open(t + "/tool-stdin").read() == "none\n", "a tool xless runs does not have the terminal's input (what you type)", open(t + "/tool-stdin").read())
check({l["name"] for l in log} == {"child", "setsid", "group", "orphan"}, "a tool xless runs tried everything", log)
for l in log:
    check(l["rc"] != 0 and not l["stolen"] and l["store"] != "unlocked", f"a tool xless runs is refused: {l['name']}", l)
    check("NOTE" in l["err"] and VALUE not in l["err"], f"  … and the store is simply locked to it: {l['name']}", l["err"])
rc, shown, n = a.run("$X secrets export NOTE --out $T/out2")
check(rc == 0 and n == 0, "the terminal's own commands still are served", shown)
rc, shown, n = a.run("LEADER=$$ $T/bin/probe own")   # the probe itself works: run by the terminal, only its new sessions are refused
own = {json.loads(l)["name"]: json.loads(l) for l in open(t + "/probe-own.log")}
check(own["child"]["stolen"] and own["group"]["stolen"], "(the same probe run by the terminal itself is served: the test can tell)", own)
check(not own["setsid"]["stolen"] and not own["orphan"]["stolen"], "even from a terminal, a process of another session is refused", own)
rc, shown, n = a.run("env XLESS_NO_SECRET_STORE=1 $X auth status --json")
check('"state" : "unlocked"' not in shown and '"state":"unlocked"' not in shown, "XLESS_NO_SECRET_STORE=1 looks for nothing held", shown)

# ---- another terminal --------------------------------------------------------------------------------------------------
b = Terminal()
check(status(b)["store"]["state"] == "locked", "another terminal is not served")
rc, shown, n = b.run("$X unlock", PASS)
check(rc == 0 and n == 1, "until it types the passphrase", shown)
check(len(agents()) == 1, "and the one agent serves both", agents())
rc, shown, n = b.run("$X secrets export NOTE --out $T/out3")
check(rc == 0 and n == 0, "then its commands ask nothing", shown)
left = []
for _ in range(3):
    left.append(status(b)["store"]["idleRemainingSeconds"])
    time.sleep(2)
check(left[0] - left[1] >= 1 and left[1] - left[2] >= 1, "looking at the status does not count as use", left)
a.close()
time.sleep(5)
rc, shown, n = b.run("$X secrets export NOTE --out $T/out4")
check(rc == 0 and n == 0, "closing the first terminal leaves the second one served", shown)

# ---- lock --------------------------------------------------------------------------------------------------------------
rc, shown, n = b.run("$X lock")
check(rc == 0 and "locked" in shown, "xless lock says it dropped it", shown)
check(gone(), "and the agent is gone", agents())
check(status(b)["store"]["state"] == "locked", "auth status says it is locked")
rc, shown, n = b.run("$X lock")
check(rc == 0 and "nothing was held" in shown, "locking again finds nothing", shown)
rc, shown, n = b.run("$X secrets unlock --remember 2h", PASS)
check(rc == 0 and len(agents()) == 1, "xless secrets unlock --remember uses the agent", shown)
rc, shown, n = b.run("$X secrets lock")
check(rc == 0 and gone(), "xless secrets lock ends it", shown)
rc, shown, n = b.run("$X secrets export NOTE --out $T/out5 --remember", PASS)
check(rc == 0 and status(b)["store"]["remainingSeconds"] > 28000, "--remember without a duration holds for the configured one", shown)
b.run("$X lock"); gone()

# ---- expiry, idle time ---------------------------------------------------------------------------------------------------
rc, shown, n = b.run("$X unlock --for 3s", PASS)
check(rc == 0, "an unlock of 3 s", shown)
check(gone(12), "ends by itself", agents())
rc, shown, n = b.run("$X unlock --for 1h --idle 3s", PASS)
check(rc == 0 and "3 s without use" in shown, "an unlock of an hour or less has its idle time too", shown)
check(status(b)["store"].get("backend") == "agent", "and is the agent's")
rc, shown, n = b.run("$X unlock --for 1h --idle 3s")
check(rc == 0 and n == 0, "again: renewed without asking", shown)
check(gone(12), "ends by itself", agents())

# ---- an agent that does not answer ----------------------------------------------------------------------------------------
mac = os.uname().sysname == "Darwin"
def stopped():
    b.run("$X unlock --for 2h", PASS)
    pid = next(p[0] for p in agent_pids() if os.getsid(p[0]) == b.pid)
    os.kill(pid, signal.SIGSTOP)
    return pid
def alive(pid):
    out = subprocess.run(["ps", "-o", "stat=", "-p", str(pid)], capture_output=True, text=True).stdout.strip()
    return out != "" and not out.startswith("Z")
pid = stopped()
begin = time.time()
rc, shown, n = b.run("$X secrets export NOTE --out $T/out6", PASS)
check(rc == 0 and n == 1 and str(pid) in shown and time.time() - begin < 12, "a stopped agent: a command says so, asks, and waits for it once", (shown, time.time() - begin))
for command in ("secrets lock", "auth logout"):
    rc, shown, n = b.run("$X " + command)
    check(rc != 0 and f"process {pid}" in shown and "nothing" not in shown, f"xless {command} says what it could not drop", (rc, shown))
check(alive(pid), "and leaves it to xless lock")
rc, shown, n = b.run("$X lock")
if mac:
    check(rc == 0 and "locked" in shown and not alive(pid) and not agents(), "xless lock ends it (the kernel says it is this very program)", (rc, shown))
else:
    check(rc != 0 and f"kill -9 {pid}" in shown and "nothing was held" not in shown, "xless lock says that it did not answer, and fails", (rc, shown))
    os.kill(pid, signal.SIGKILL)
    for name in agents(): os.unlink(t + "/run/xless-agent/" + name) # what it left
    rc, shown, n = b.run("$X lock")
    check(rc == 0, "and once it is ended, it does not", (rc, shown))
pid = stopped()
b.run("$X unlock --for 2h", PASS)
check(len(agents()) == 2, "with one stopped, another agent is started", agents())
rc, shown, n = b.run("$X lock")
check((rc == 0) == mac and ("locked" in shown if mac else "dropped what could be dropped" in shown and str(pid) in shown), "xless lock ends the one that answers whatever the other does", (rc, shown))
if alive(pid): os.kill(pid, signal.SIGCONT)
check(gone(), "a stopped agent that goes on finds what it was told, and ends", agents())

# ---- a changed passphrase, a replaced store --------------------------------------------------------------------------------
b.run("$X unlock --for 2h", PASS)
rc, shown, n = b.run("$X secrets passwd", PASS, NEXT, NEXT)
check(rc == 0 and gone(), "a changed passphrase drops the unlock", shown)
b.run("$X unlock --for 2h", NEXT)
check(len(agents()) == 1, "unlocked with the new one")
os.rename(t + "/data/xless/vault/secrets.vault", t + "/old.vault")
rc, shown, n = b.run("$X secrets init", PASS, PASS)
check(rc == 0 and gone(), "a store created in the place of another drops the other's unlock", shown)

# ---- a closed terminal, a killed agent, a socket of somebody else's making --------------------------------------------------
b.run("$X unlock --for 2h", PASS)
check(len(agents()) == 1, "unlocked")
b.close()
check(gone(15), "closing the last terminal ends the agent", agents())
c = Terminal()
c.run("$X unlock --for 2h", PASS)
for p in agent_pids():
    if os.getsid(p[0]) == c.pid: os.kill(p[0], signal.SIGKILL)
rc, shown, n = c.run("$X unlock --for 2h", PASS)
check(rc == 0 and n == 1, "after an agent was killed, unlock starts another", shown)
c.run("$X lock")
os.system(f"rm -rf {t}/run/xless-agent")
os.symlink(t + "/tmp", t + "/run/xless-agent")
rc, shown, n = c.run("$X unlock --for 2h", PASS)
check(rc != 0 and "xless-agent" in shown and not os.listdir(t + "/tmp"), "a directory that is a link is refused", shown)
os.unlink(t + "/run/xless-agent")
os.mkdir(t + "/run/xless-agent"); os.chmod(t + "/run/xless-agent", 0o755)
rc, shown, n = c.run("$X unlock --for 2h", PASS)
check(rc != 0 and "xless-agent" in shown, "a directory others can enter is refused", shown)
os.rmdir(t + "/run/xless-agent")
check(status(c)["store"]["state"] == "locked", "nothing is held at the end")
c.run("$X lock")
c.close()
for root, _, files in os.walk(t):
    for f in files:
        p = os.path.join(root, f)
        if f.startswith(("out", "stolen-own", "note")): continue
        if os.path.isfile(p):
            data = open(p, "rb").read()
            if VALUE.encode() in data or PASS.encode() in data: check(False, f"a secret is in clear in {p}")
print("agent.test.sh: " + ("passed" if not failures else f"{failures} FAILED"), flush=True)
sys.exit(1 if failures else 0)
PY
