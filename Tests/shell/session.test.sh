#!/usr/bin/env bash
# `xless session -- <command…>` (docs/secrets.md, "One unlock for a script"), with the real binary and real terminals
# (pseudo-terminals): one passphrase for every xless command of a script; the tools xless runs inside it are refused; a
# command that was not told of the session is not served; whatever ends the script or xless (its end, SIGINT, SIGTERM,
# SIGHUP, SIGKILL) ends what is held. Nothing reaches Apple.
#   Tests/shell/session.test.sh   (builds xless with `swift build`; XLESS_BIN=<path> uses that binary)
set -euo pipefail
repo="$(cd "$(dirname "$0")/../.." && pwd)"
t=$(mktemp -d /tmp/xst.XXXXXX)   # short: a socket's path is
trap 'rm -rf "$t"' EXIT
x="${XLESS_BIN:-}"
if [[ -z "$x" ]]; then
  (cd "$repo" && env -u DEVELOPER_DIR swift build --product xless -q)
  x="$(cd "$repo" && env -u DEVELOPER_DIR swift build --show-bin-path)/xless"
fi

# Nothing may reach Apple: a Mac's URL loading heeds no proxy variable, so there the whole test runs in a sandbox without
# network (but `ps`, which is setuid); elsewhere the proxy it is told of is a closed port.
guard=()
if [[ "$(uname)" == Darwin ]]; then
  guard=(sandbox-exec -p '(version 1)(allow default)(deny network-outbound (remote ip "*:*"))(deny network-outbound (literal "/private/var/run/mDNSResponder"))(allow process-exec* (with no-sandbox) (literal "/bin/ps"))')
fi
${guard[@]+"${guard[@]}"} python3 -I - "$x" "$t" <<'PY'
import json, os, pty, re, select, signal, socket, subprocess, sys, termios, time

if sys.platform == "darwin":
    with socket.create_server(("127.0.0.1", 0)) as here:
        try: socket.create_connection(here.getsockname(), 2).close()
        except PermissionError: pass
        else: sys.exit("FAIL the sandbox lets the network through: nothing was run")

xless, t = os.path.realpath(sys.argv[1]), os.path.realpath(sys.argv[2])
PROMPT = rb"(assphrase|again): |\[y/N\] |Apple ID \(email\): "
PASS, VALUE = "correct horse battery staple", "the value of NOTE"
keep = {k: os.environ[k] for k in ("PATH", "LD_LIBRARY_PATH", "DYLD_LIBRARY_PATH") if k in os.environ}
env = {**keep, "HOME": t + "/home", "XDG_DATA_HOME": t + "/data", "XDG_CONFIG_HOME": t + "/config", "XDG_RUNTIME_DIR": t + "/run",
       "TMPDIR": t + "/tmp", "TERM": "dumb", "LC_ALL": "C", "X": xless, "T": t, "https_proxy": "http://127.0.0.1:9", "http_proxy": "http://127.0.0.1:9"}
for d in ("home", "data", "config", "run", "tmp", "bin"):
    os.mkdir(f"{t}/{d}", 0o700)
failures = 0

def check(ok, what, detail=""):
    global failures
    if not ok:
        failures += 1
    print(("ok   " if ok else "FAIL ") + what + ("" if ok else f"\n     {detail!r}"), flush=True)

class Terminal:
    """A terminal: a bash that leads a session of its own on a fresh pty, with job control (as a person's), or `argv`."""
    def __init__(self, argv=None):
        self.pid, self.fd = pty.fork()
        if self.pid == 0:
            if argv: os.execve(argv[0], argv, env)
            os.execve("/bin/bash", ["bash", "--noprofile", "--norc", "--noediting", "-i"], {**env, "PS1": "", "PS2": ""})
        self.seen = b""
        if argv is None:
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

    def answer(self, text):
        """`text` at the next prompt; what was shown until then."""
        shown = self.until(PROMPT)
        if not re.search(rb"\[y/N\] $|email\): $", shown.encode()):
            for _ in range(100): # the prompt is written before the echo is turned off: wait for that
                if not termios.tcgetattr(self.fd)[3] & termios.ECHO: break
                time.sleep(0.02)
        time.sleep(0.1)
        os.write(self.fd, (text + "\n").encode())
        return shown

    def answer_after(self, act, text):
        """`text` at the next prompt, once `act` was done while it asks; what was shown until then."""
        self.seen = self.until(PROMPT).encode() + self.seen
        act()
        return self.answer(text)

    def type(self, command): os.write(self.fd, (command + "; echo __DONE:$?:\n").encode())

    def done(self):
        shown = self.until(b"__DONE:")
        return int(self.until(b":")[:-1]), shown

    def run(self, command, *answers):
        """Types `command`, and each answer at the next prompt; (exit code, what was shown, prompts)."""
        self.type(command)
        shown = "".join(self.answer(a) for a in answers)
        rc, rest = self.done()
        return rc, shown + rest, len(re.findall(PROMPT, (shown + rest).encode()))

    def close(self):
        os.close(self.fd)
        os.kill(self.pid, signal.SIGHUP)
        try: os.kill(self.pid, signal.SIGKILL)
        except ProcessLookupError: pass
        os.waitpid(self.pid, 0)

def agents():
    d = t + "/run/xless-agent"
    return sorted(n for n in os.listdir(d) if n.endswith(".sock")) if os.path.isdir(d) else []

def gone(seconds=10):
    for _ in range(int(seconds * 10)):
        if not agents(): return True
        time.sleep(0.1)
    return False

def wait_for(path, seconds=30):
    for _ in range(int(seconds * 20)):
        if os.path.exists(path): return True
        time.sleep(0.05)
    return False

def script(name, text):
    path = f"{t}/bin/{name}"
    with open(path, "w") as f: f.write(text)
    os.chmod(path, 0o755)
    return path

def status(text):
    return json.loads(text[text.index("{"):text.rindex("}") + 1])

with open(t + "/note", "w") as f: f.write(VALUE)
a = Terminal()
rc, shown, n = a.run("$X secrets init", PASS, PASS, "n")
check(rc == 0, "a store is created", shown)
rc, shown, n = a.run("$X secrets import NOTE --file $T/note", PASS, "n", "n")
check(rc == 0, "a secret is imported", shown)

# ---- one passphrase for a script -----------------------------------------------------------------------------------------
script("two.sh", '#!/bin/sh\nset -e\n$X secrets export NOTE --out "$T/one.$1"\n$X secrets export NOTE --out "$T/two.$1"\n$X auth status --json > "$T/status.$1"\nenv > "$T/env.$1"\nexit 7\n')
rc, shown, n = a.run("$X session -- $T/bin/two.sh a", PASS)
check(n == 1, "a script of xless commands asks for the passphrase once, and for nothing else", shown)
check(rc == 7, "xless session ends with the script's exit code", (rc, shown))
check(open(t + "/one.a").read() == VALUE and open(t + "/two.a").read() == VALUE, "each command had the store")
check("xless session" in shown and "two.sh" in shown and "until" in shown, "it says what is asked, for what and for how long", shown)
s = status(open(t + "/status.a").read())["store"]
check(s["state"] == "unlocked" and s["backend"] == "agent", "auth status inside says what is held", s)
inside = open(t + "/env.a").read()
check("XLESS_SESSION=" in inside and PASS not in inside and VALUE not in inside, "the script's environment has where the session's agent is, and no secret", inside)
check(not agents(), "what was held is dropped when xless session returns", agents())
rc, shown, n = a.run("$X auth status --json")
check(status(shown)["store"]["state"] == "locked", "and the store is locked", shown)

rc, shown, n = a.run("$X session -- sh -c 'sleep 300 & exit 0'", PASS)
check(rc == 0 and not agents(), "a process the script leaves behind keeps nothing held", (rc, agents()))
rc, shown, n = a.run("$X session -- $X session -- $T/bin/two.sh n", PASS)
check(rc == 7 and n == 1, "a session in a session asks nothing", shown)
for command, code in (("$T/bin/nothing-there", 127), ("nothing-there", 127), ("$T/note", 126), ("$T/bin", 126)):
    rc, shown, n = a.run(f"$X session -- {command}")
    check(rc == code and n == 0, f"a command that cannot be run asks for nothing ({command}: {code})", (rc, shown))
with open(t + "/bin/plain", "w") as f: f.write('echo "plain $1"\n')
os.chmod(t + "/bin/plain", 0o755)
rc, shown, n = a.run("XDG_DATA_HOME=$T/elsewhere PATH=$T/bin:$PATH $X session -- plain script")
check(rc == 0 and "plain script" in shown, "a command is found in PATH, and a script without #! runs as in a shell", (rc, shown))
rc, shown, n = a.run("XDG_DATA_HOME=$T/elsewhere $X session -- sh -c 'kill -TERM $$'")
check(rc == 143, "a script that a signal ends ends xless the same way", (rc, shown))
rc, shown, n = a.run("$X session")
check(rc == 64 and n == 0, "no command is a usage error", (rc, shown))
rc, shown, n = a.run("XDG_DATA_HOME=$T/elsewhere $X session -- echo it ran")
check(rc == 0 and n == 0 and "it ran" in shown and "no secret store" in shown, "with no store there is nothing to unlock, and the script runs", shown)
rc, shown, n = a.run("$X session --no-input -- touch $T/ran")
check(rc == 23 and n == 0 and not os.path.exists(t + "/ran"), "with --no-input a locked store ends it before the script starts", (rc, shown))
# Where no agent can start: found before anything is asked. `xless run` (--if-possible) goes on, each step asking by itself.
os.makedirs(t + "/" + "long" * 30, 0o700)
os.makedirs(t + "/open/xless-agent", 0o755)
os.chmod(t + "/open/xless-agent", 0o755)
os.makedirs(t + "/never/xless", 0o700)
with open(t + "/never/xless/config.yml", "w") as f: f.write("unlock: { keep: never }\n") # a kernel keyring would be offered
blocked = {"a path that is too long for a socket": t + "/" + "long" * 30, "a directory that is not there": t + "/nowhere", "a directory others can use": t + "/open"}
for what, run in blocked.items():
    rc, shown, n = a.run(f"XDG_RUNTIME_DIR={run} $X session -- touch $T/ran")
    check(rc == 10 and n == 0 and not os.path.exists(t + "/ran"), f"{what}: it ends before anything is asked", (rc, shown))
    rc, shown, n = a.run(f"XDG_RUNTIME_DIR={run} $X session --if-possible --purpose 'xless run' -- echo it ran")
    check(rc == 0 and n == 0 and "it ran" in shown and "note: each step asks by itself here" in shown, f"{what}: with --if-possible the script runs, and is told of nothing", (rc, shown))
    rc, shown, n = a.run(f"XDG_CONFIG_HOME=$T/never XDG_RUNTIME_DIR={run} $X session --if-possible -- $X secrets export NOTE --out $T/if-possible", PASS)
    check(rc == 0 and n == 1 and open(t + "/if-possible").read() == VALUE, f"{what}: and its commands ask by themselves", (rc, shown))
    os.unlink(t + "/if-possible")
rc, shown, n = a.run("$X session --sign-in -- touch $T/ran", PASS, "")
check(rc == 20 and n == 2 and not os.path.exists(t + "/ran") and not agents(), "--sign-in signs in before the script starts", (rc, shown))
check("xless session signs in to Apple for the xless commands of touch" in shown, "and says for what", shown)

# ---- who is served ---------------------------------------------------------------------------------------------------------
probe = script("probe", f"#!{sys.executable} -I\n" + r'''
import json, os, subprocess, sys
x, t = os.environ["X"], os.environ["T"]
base = {k: v for k, v in os.environ.items() if k != "XLESS_NO_SECRET_STORE"}
base.setdefault("XLESS_SESSION", sys.argv[2] if len(sys.argv) > 2 else "")
base["XLESS_NO_INPUT"] = "1" # the terminal is there to ask on
def attempt(name, env=base, **kw):
    out = f"{t}/stolen-{sys.argv[1]}-{name}"
    r = subprocess.run([x, "secrets", "export", "NOTE", "--out", out], env=env, stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=60, start_new_session=name == "setsid", **kw)
    with open(f"{t}/probe-{sys.argv[1]}.log", "a") as log:
        log.write(json.dumps({"name": name, "rc": r.returncode, "stolen": os.path.exists(out), "err": r.stderr}) + "\n")
attempt("child")
attempt("setsid")
if sys.argv[1] != "tool": attempt("untold", {k: v for k, v in base.items() if k != "XLESS_SESSION"})
''')
script("docker", f'#!/bin/sh\n[ -e "$T/tool-env" ] || env > "$T/tool-env"\n[ -e $T/probe-tool.log ] || {probe} tool "$(ls $T/run/xless-agent/*.sock)" >/dev/null 2>&1\nexit 0\n')
script("who.sh", f'#!/bin/sh\nPATH=$T/bin:$PATH $X clean >/dev/null 2>&1\n{probe} own\n')
rc, shown, n = a.run("$X session -- $T/bin/who.sh", PASS)
tool = [json.loads(l) for l in open(t + "/probe-tool.log")]
own = {l["name"]: l for l in map(json.loads, open(t + "/probe-own.log"))}
tool_env = open(t + "/tool-env").read()
check("XLESS_SESSION" not in tool_env and "XLESS_NO_SECRET_STORE=1" in tool_env, "a tool that xless runs in a session is not told of it", tool_env)
check(len(tool) == 2 and all(l["rc"] != 0 and not l["stolen"] and VALUE not in l["err"] for l in tool), "a tool that xless runs in a session is refused, told of it or not", tool)
check(own["child"]["stolen"], "(the same probe run by the script itself is served: the test can tell)", own)
check(not own["setsid"]["stolen"], "a process that leaves the script's POSIX session is refused", own)
check(not own["untold"]["stolen"], "a command that was not told of the session does not use it", own)

script("swiftc", '#!/bin/sh\nenv > "$T/shim-env"\n')
rc, shown, n = a.run("$X session -- sh -c 'PATH=$T/bin:$PATH XLESS_SHIM_DIR= $X shim xcrun swiftc --version'", PASS)
shim_env = open(t + "/shim-env").read() if os.path.exists(t + "/shim-env") else ""
check("PATH=" in shim_env and "XLESS_SESSION" not in shim_env, "nor is one that a shim runs", (rc, shown, shim_env))

a.type("$X session -- sh -c 'echo started > $T/up; while [ ! -e $T/stop ]; do sleep 0.2; done'")
a.answer(PASS)
check(wait_for(t + "/up") and len(agents()) == 1, "a session that runs", agents())
b = Terminal()
rc, shown, n = b.run("$X auth status --json")
s = status(shown)["sessions"]
check(len(s) == 1 and s[0]["command"] == "xless session (sh)" and s[0]["holds"] == ["store"] and not s[0]["thisTerminal"] and 28000 < s[0]["remainingSeconds"] <= 28800,
      "auth status in another terminal shows it: what it holds, whose it is, until when", shown)
rc, shown, n = b.run("$X auth status")
check("xless session (sh) in another terminal: the secret store's unlock" in shown and "(`xless lock` ends it sooner)" in shown, "and so in text", shown)
rc, shown, n = b.run(f"XLESS_SESSION=$(ls $T/run/xless-agent/*.sock) $X auth status --json")
check(status(shown)["store"]["state"] == "locked", "another terminal is not served, told of it or not", shown)
rc, shown, n = b.run("XLESS_SESSION=$(ls $T/run/xless-agent/*.sock) $X secrets export NOTE --out $T/b.out", PASS)
check(rc == 0 and n == 1 and len(agents()) == 1, "nor does its passphrase join it there", (rc, shown))
open(t + "/stop", "w").close()
rc, shown = a.done()
check(rc == 0 and not agents(), "and it ends", (rc, agents()))

a.type("$X session -- sh -c 'echo started > $T/up2; while [ ! -e $T/stop2 ]; do sleep 0.2; done'")
a.answer(PASS)
check(wait_for(t + "/up2"), "a session that is stopped")
os.write(a.fd, b"\x1a")
a.until(rb"__DONE:\d+:")
rc, shown, n = a.run("$X auth status --json")
check(status(shown)["store"]["state"] == "locked" and [s["thisTerminal"] for s in status(shown)["sessions"]] == [True], "its own terminal does not use it outside the script, and sees it", shown)
open(t + "/stop2", "w").close()
a.run("fg >/dev/null")
check(gone(), "and it ends", agents())

# ---- for how long ------------------------------------------------------------------------------------------------------------
os.makedirs(t + "/config/xless")
with open(t + "/config/xless/config.yml", "w") as f: f.write("unlock: { duration: 8s, idle: 8s }\n")
script("long.sh", '#!/bin/sh\n$X secrets export NOTE --out "$T/early" || exit 1\nsleep 11\n$X --no-input secrets export NOTE --out "$T/late"\nexit $?\n')
rc, shown, n = a.run("$X session -- $T/bin/long.sh", PASS)
check("for 8 s at most" in shown and os.path.exists(t + "/early"), "a session is for the time of `unlock.duration` at most, and says so", shown)
check(rc == 23 and not os.path.exists(t + "/late"), "after it what was held is dropped, and the script's next command is asked again", (rc, shown))
os.unlink(t + "/config/xless/config.yml")

# ---- what is kept inside, and what was held before --------------------------------------------------------------------------
rc, shown, n = a.run("$X session -- sh -c '$X unlock && $X secrets export NOTE --out $T/kept'", PASS)
check(rc == 0 and n == 1 and not agents(), "an unlock inside a session is dropped with it", (rc, shown, agents()))
a.run("$X unlock --for 2h", PASS, "n")
rc, shown, n = a.run("$X session -- $T/bin/two.sh b")
check(rc == 7 and n == 0, "with the store unlocked already nothing is asked", shown)
rc, shown, n = a.run("$X auth status --json")
check(len(agents()) == 1 and 7000 < status(shown)["store"]["remainingSeconds"] <= 7200, "and what was unlocked before stays so, for as long as it was", shown)
a.run("$X lock")
check(gone(), "until it is locked", agents())

# ---- whatever ends it ----------------------------------------------------------------------------------------------------------
def started(name):
    for f in ("pid", "child"):
        if os.path.exists(f"{t}/{f}.{name}"): os.unlink(f"{t}/{f}.{name}")
    a.type(f"$X session -- sh -c 'echo $PPID > $T/pid.{name}; echo $$ > $T/child.{name}; exec sleep 300'")
    a.answer(PASS)
    for f in ("pid", "child"): check(wait_for(f"{t}/{f}.{name}"), f"a session for {name} runs")
    time.sleep(0.2)
    check(len(agents()) == 1, "and is held", agents())
    return int(open(f"{t}/pid.{name}").read()), int(open(f"{t}/child.{name}").read())

def ended(pid):
    for _ in range(100):
        out = subprocess.run(["ps", "-o", "stat=", "-p", str(pid)], capture_output=True, text=True).stdout.strip()
        if out == "" or out.startswith("Z"): return True
        time.sleep(0.1)
    return False

pid, child = started("ctrl-c")
os.write(a.fd, b"\x03")
check(ended(child) and ended(pid) and gone(), "Ctrl-C ends the script and drops what is held", (pid, child, agents()))
a.run("true")
# (On macOS nothing tells a SIGINT of the terminal's from one sent to xless alone.)
for name in ("TERM", "HUP") + (("INT",) if sys.platform == "linux" else ()):
    pid, child = started(name)
    os.kill(pid, getattr(signal, "SIG" + name))
    check(ended(child) and ended(pid) and gone(), f"SIG{name} to xless alone ends the script too, and drops what is held", (pid, child, agents()))
    a.run("true")
pid, child = started("KILL")
os.kill(pid, signal.SIGKILL)
check(gone(), "xless killed: what is held is dropped, the script's life or not", agents())
os.kill(child, signal.SIGKILL)
a.run("true")
pid, child = started("lock")
rc, shown, n = b.run("$X lock")
check(gone(), "`xless lock` in another terminal ends it at once", agents())
shown = b.run("XLESS_SESSION=$T/run/xless-agent/0000000000000000.sock $X unlock", PASS)[1]
check("holds nothing" in shown and "unset XLESS_SESSION" in shown, "a command still in a session that ended keeps nothing, and says what a shell that outlived it does", shown)
os.kill(child, signal.SIGTERM)
a.run("true")
for option, code, ran in (("", 10, False), ("--if-possible ", 0, True)):
    a.type(f"$X session {option}-- sh -c 'touch $T/asked-away'")
    shown = a.answer_after(lambda: (b.run("$X lock"), gone()), PASS)
    rc, rest = a.done()
    shown += rest
    check(rc == code and os.path.exists(t + "/asked-away") == ran and "the session ended before the command started" in shown and "unset XLESS_SESSION" not in shown,
          f"`xless lock` elsewhere while it asks: {option or 'nothing runs, and '}it says what happened", (rc, shown))
os.remove(t + "/asked-away")
pid, child = started("close")
a.close()
check(gone(15), "closing the terminal ends it", agents())
try: os.kill(child, signal.SIGKILL)
except ProcessLookupError: pass

# ---- xless as its own session's leader (ssh -t host xless session -- …) --------------------------------------------------------
c = Terminal([xless, "session", "--", t + "/bin/two.sh", "leader"])
c.answer(PASS)
try:
    while os.read(c.fd, 4096): pass # macOS ends a terminal's last process only once its output was read
except OSError: pass
_, code = os.waitpid(c.pid, 0)
check(os.waitstatus_to_exitcode(code) == 7 and open(t + "/two.leader").read() == VALUE and gone(), "xless may lead the session: it ends with the script", agents())
b.close()

print("session.test.sh: " + ("passed" if not failures else f"{failures} FAILED"), flush=True)
sys.exit(1 if failures else 0)
PY
