#!/usr/bin/env bash
# How often xless asks, with the real binary on real terminals (pseudo-terminals): the one question whether to keep what
# was typed (yes, no, `unlock.keep` in config.yml, CI, --no-input, no terminal), and the prompts of each composite command
# (xless run, provision apply, store push, release submit, auth api-key create): the passphrase once and at most one
# sign-in, as far as a command gets without Apple. What comes after Apple's answers: ProvisionTests (the first-app flow).
#   Tests/shell/prompts.test.sh   (builds xless with `swift build`; XLESS_BIN=<path> uses that binary)
set -euo pipefail
repo="$(cd "$(dirname "$0")/../.." && pwd)"
t=$(mktemp -d /tmp/xpr.XXXXXX)   # short: a socket's path is
trap 'rm -rf "$t"' EXIT
x="${XLESS_BIN:-}"
if [[ -z "$x" ]]; then
  (cd "$repo" && env -u DEVELOPER_DIR swift build --product xless -q)
  x="$(cd "$repo" && env -u DEVELOPER_DIR swift build --show-bin-path)/xless"
fi

# Nothing may reach Apple, whose servers these commands go on to: a Mac's URL loading heeds no proxy variable, so there the
# whole test runs in a sandbox without network; elsewhere the proxy it is told of is a closed port.
guard=()
if [[ "$(uname)" == Darwin ]]; then
  guard=(sandbox-exec -p '(version 1)(allow default)(deny network-outbound (remote ip "*:*"))(deny network-outbound (literal "/private/var/run/mDNSResponder"))')
fi
${guard[@]+"${guard[@]}"} python3 -I - "$x" "$t" "$repo" <<'PY'
import concurrent.futures, json, os, pty, re, select, signal, socket, subprocess, sys, termios, time

if sys.platform == "darwin":
    with socket.create_server(("127.0.0.1", 0)) as here:
        try: socket.create_connection(here.getsockname(), 2).close()
        except PermissionError: pass
        else: sys.exit("FAIL the sandbox lets the network through: nothing was run")

xless, t = os.path.realpath(sys.argv[1]), os.path.realpath(sys.argv[2])
PROMPT = rb"(assphrase|again): |\[y/N\] |Apple ID \(email\): |Password: "
PASS, VALUE = "correct horse battery staple", "the value of NOTE"
keep = {k: os.environ[k] for k in ("PATH", "LD_LIBRARY_PATH", "DYLD_LIBRARY_PATH") if k in os.environ}
env = {**keep, "HOME": t + "/home", "XDG_DATA_HOME": t + "/data", "XDG_CONFIG_HOME": t + "/config", "XDG_RUNTIME_DIR": t + "/run",
       "TMPDIR": t + "/tmp", "TERM": "dumb", "LC_ALL": "C", "X": xless, "T": t, "XLESS_SHARE": sys.argv[3], "https_proxy": "http://127.0.0.1:9", "http_proxy": "http://127.0.0.1:9"}
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
        os.set_inheritable(self.fd, False) # the next terminal's shell would keep this one open
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
        if callable(text): text = text()
        if not re.search(rb"\[y/N\] $|email\): $", shown.encode()):
            for _ in range(100): # the prompt is written before the echo is turned off: wait for that
                if not termios.tcgetattr(self.fd)[3] & termios.ECHO: break
                time.sleep(0.02)
        time.sleep(0.1)
        os.write(self.fd, (text + "\n").encode())
        return shown

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

    def run_ahead(self, command, ahead, *answers):
        """`run` with the passphrase, then `ahead` typed while the store is opened, before what is asked next is shown."""
        self.type(command)
        shown = self.answer(PASS)
        shown += self.until(rb"\n") # the passphrase was read, and what was typed until then thrown away
        os.write(self.fd, ahead.encode())
        shown += "".join(self.answer(a) for a in answers)
        rc, rest = self.done()
        return rc, shown + rest

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

def asked(shown): return re.findall(r"assphrase[^\r\n.]{0,40}: |(?<!ask )again: |\[y/N\] |Apple ID \(email\): |Password: ", shown)

def write(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f: f.write(text)

def config(text): write(t + "/config/xless/config.yml", text)

# ---- a store with an App Store Connect key, a signing key and a secret, locked ------------------------------------------
write(t + "/note", VALUE)
while True: # macOS's LibreSSL writes a key that begins with a zero byte (1 of 256) too short: another one then
    subprocess.run(["openssl", "ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", t + "/ec.pem"], check=True, capture_output=True)
    if len(subprocess.run(["openssl", "ec", "-in", t + "/ec.pem", "-outform", "DER"], check=True, capture_output=True).stdout) == 121: break
subprocess.run(["openssl", "pkcs8", "-topk8", "-nocrypt", "-in", t + "/ec.pem", "-out", t + "/AuthKey_ABCDE12345.p8"], check=True, capture_output=True)
subprocess.run(["openssl", "genrsa", "-out", t + "/rsa.pem", "2048"], check=True, capture_output=True)
write(t + "/app/xless.yml", "bundleID: com.example.app\nteamID: ABCDE12345\nversion: 1.0.0\nbuild: 1\nplatforms:\n  ios: { minimumOS: '17.0', product: App }\n")
os.makedirs(t + "/app/.xless/build/ios/final/App.app")
write(t + "/appstore/app.yml", "bundleID: com.example.app\nprivacy: { collectsData: false }\n")
for name, text in (("name", "App"), ("description", "An app."), ("keywords", "app"), ("support_url", "https://example.com")):
    write(f"{t}/appstore/en-US/{name}.txt", text + "\n")
write(t + "/cargo.yml", "type: cargo\nsource: cargo/app\nbundleID: com.example.app\nteamID: ABCDE12345\nversion: 1.0.0\nbuild: dated\nprivacyManifest: privacy\n"
      "ios: { package: hello, bin: hello, product: Hello, minimumOS: '17.0', assets: Assets.xcassets }\n")
write(t + "/privacy", "x")
write(t + "/cargo/app/Cargo.toml", "[package]\nname = 'hello'\nversion = '1.0.0'\n")
config("unlock: { keep: never }\n")
a = Terminal()
rc, shown, n = a.run("cd $T; $X secrets init", PASS, PASS)
check(rc == 0 and n == 2, "a store is created", shown)
for what in ("ASC_KEY_P8 --file $T/AuthKey_ABCDE12345.p8 --issuer-id 69a6de7e-1234-47e3-e053-5b8c7c11a4d1 --key-id ABCDE12345 --team-id ABCDE12345",
             "XLESS_DIST_KEY --file $T/rsa.pem", "NOTE --file $T/note"):
    rc, shown, n = a.run("$X secrets import " + what, PASS, "n")
    check(rc == 0, "a secret is imported", shown)
EXPORT = "$X secrets export NOTE --out $T/out.$RANDOM"

# ---- the offer -------------------------------------------------------------------------------------------------------------
rc, shown, n = a.run(EXPORT, PASS)
check(rc == 0 and len(asked(shown)) == 1 and not agents(), "keep: never: the passphrase, and no question", shown)
config("")
write(t + "/never/xless/config.yml", "unlock: { keep: never }\n")
rc, shown, n = a.run(EXPORT, PASS, "")
check(rc == 0 and len(asked(shown)) == 2 and "Keep both for this terminal? [y/N] " in shown, "by default it offers, once, to keep what was typed", shown)
check("xless secrets export opens the secret store (" in shown and "asked once for this command, and forgotten when it ends unless you keep it" in shown and "8 h (2 h without use)" in shown,
      "and says for which command it asks, why, and how long it would be kept", shown)
check(not agents() and "Nothing is kept" in shown, "Enter keeps nothing", (shown, agents()))
for answer in ("n", "Y e s", "maybe"):
    rc, shown, n = a.run(EXPORT, PASS, answer)
    check(rc == 0 and not agents(), f"only yes keeps ({answer!r})", shown)
for ahead in ("y\n", "y"):
    rc, shown = a.run_ahead(EXPORT, ahead, "")
    check(rc == 0 and not agents() and "Nothing is kept" in shown, f"what is typed before the question is shown does not answer it ({ahead!r})", shown)
write(t + "/ahead", VALUE)
rc, shown = a.run_ahead("XDG_CONFIG_HOME=$T/never $X secrets import AHEAD --file $T/ahead", "y\n", "")
check(rc == 0 and "Delete" in shown and os.path.exists(t + "/ahead"), "nor a question whose yes deletes something", shown)
def yes_to_what_cannot_be():
    """A yes, when the agents' directory has become one that others can use: nothing can be held any more."""
    os.makedirs(t + "/run/xless-agent", exist_ok=True)
    os.chmod(t + "/run/xless-agent", 0o755)
    return "y"
for command, answers in ((EXPORT, (PASS,)), ("XDG_DATA_HOME=$T/init.$RANDOM $X secrets init", (PASS, PASS))):
    rc, shown, n = a.run(command, *answers, yes_to_what_cannot_be)
    check(rc == 0 and "note: the store is not kept unlocked" in shown and "Kept." not in shown, "nothing is said to be kept that is not, and the command goes on", (rc, shown))
    rc, shown, n = a.run(EXPORT, PASS)
    check(rc == 0 and len(asked(shown)) == 1, "where nothing can be held nothing is offered", shown)
    os.chmod(t + "/run/xless-agent", 0o700)
write(t + "/always/xless/config.yml", "unlock: { keep: always }\n")
os.chmod(t + "/run/xless-agent", 0o755)
rc, shown, n = a.run("XDG_CONFIG_HOME=$T/always " + EXPORT, PASS)
check(rc == 0 and len(asked(shown)) == 1 and "note:" in shown and "Kept" not in shown, "with keep: always it says why nothing is kept", shown)
os.chmod(t + "/run/xless-agent", 0o700)
rc, shown, n = a.run("CI=1 " + EXPORT, PASS)
check(rc == 0 and len(asked(shown)) == 1 and not agents(), "in CI it is not offered", shown)
rc, shown, n = a.run("XLESS_NO_INPUT=1 " + EXPORT)
check(rc == 23 and not asked(shown), "with --no-input nothing is asked", shown)
rc, shown, n = a.run(EXPORT + " </dev/null 2>&1 | cat", PASS, "y")
check(rc == 0 and len(asked(shown)) == 2, "the questions are the terminal's, whatever the output is", shown)
rc, shown, n = a.run(EXPORT)
check(rc == 0 and not asked(shown), "a yes: the next command asks nothing", shown)
rc, shown, n = a.run("$X auth status --json")
check("keepUntil" in status(shown) and status(shown)["store"]["state"] == "unlocked", "auth status says what is kept, and that the rest will be", shown)
b = Terminal()
rc, shown, n = b.run("cd $T; " + EXPORT, PASS, "n")
check(rc == 0 and len(asked(shown)) == 2, "in another terminal it is another question", shown)
rc, shown, n = b.run("$X unlock", PASS, "n")
check(rc == 0 and "Keep the Apple ID session too" in shown and len(agents()) == 1, "also when it shares the first one's agent", (shown, agents()))
rc, shown, n = b.run("$X auth status --json")
check("keepUntil" not in status(shown) and status(shown)["store"]["state"] == "unlocked", "whose yes is not this terminal's", shown)
b.close()
rc, shown, n = a.run("$X lock; $X auth status --json")
check(gone() and "keepUntil" not in status(shown) and status(shown)["store"]["state"] == "locked", "xless lock forgets the store's unlock and the yes", shown)
rc, shown, n = a.run("$X unlock", PASS, "y")
check(rc == 0 and "Keep the Apple ID session too" in shown and len(asked(shown)) == 2, "xless unlock asks whether the sign-in is kept too", shown)
rc, shown, n = a.run("$X unlock")
check(rc == 0 and not asked(shown), "and not again", shown)
a.run("$X lock")
config("unlock: { keep: always }\n")
rc, shown, n = a.run(EXPORT, PASS)
check(rc == 0 and len(asked(shown)) == 1 and len(agents()) == 1 and "keep: always" in shown, "keep: always: no question, and it says what it keeps", shown)
rc, shown, n = a.run(EXPORT)
check(rc == 0 and not asked(shown), "the next command asks nothing", shown)
a.run("$X lock")
check(gone(), "nothing is held", agents())
alone = subprocess.run([xless, "secrets", "export", "NOTE", "--out", t + "/none"], env=env, start_new_session=True, stdin=subprocess.DEVNULL, capture_output=True, text=True)
check(alone.returncode != 0 and not asked(alone.stdout + alone.stderr) and not agents(), "without a terminal nothing is asked or kept", alone)

# ---- the composite commands, each from a locked store and no session ---------------------------------------------------------
config("unlock: { keep: never }\n")
SIGN_IN = ("me@example.com", "not-a-password")
def on_a_terminal_of_its_own(command, *answers):
    terminal = Terminal()
    terminal.run("cd $T")
    result = terminal.run(command, *answers)
    terminal.close()
    return result
EMPTY = "XDG_DATA_HOME=$T/empty "
a.run(EMPTY + "$X secrets init", PASS, PASS)
COMMANDS = [(command, answers) for command, answers in (
    ("provision plan --project $T/app", ()), ("provision apply --project $T/app --yes", ()), ("release submit --dir $T/appstore", ()),
    ("ship --project $T/app --platform ios --from sign", ()), ("store push --dir $T/appstore --yes --only text", ()),
    ("store push --dir $T/appstore --yes", SIGN_IN),   # with App Privacy details, which have no API
    ("auth api-key create", SIGN_IN), ("run $T/app", ()))]
if sys.platform == "darwin": COMMANDS.append(("run --config $T/cargo.yml", ()))   # elsewhere an overlay builds in Docker only
with concurrent.futures.ThreadPoolExecutor(len(COMMANDS)) as pool:   # each retries a while when Apple does not answer
    results = list(pool.map(lambda c: on_a_terminal_of_its_own((EMPTY if c[0].startswith("auth") else "") + "$X " + c[0], PASS, *c[1]), COMMANDS))
for (command, answers), (rc, shown, n) in zip(COMMANDS, results):
    name = "xless " + " ".join(command.split()[:3 if command.startswith("auth") else 1 if command.startswith(("run", "ship")) else 2])
    check(rc not in (0, 2, 23) and len(asked(shown)) == 1 + len(answers) and name + " opens the secret store (" in shown,
          f"`{command}` asks for the passphrase once{' and signs in once' if answers else ''}, and says why (exit {rc})", shown)
    if answers: check(name + " signs in to Apple: Apple's documented API does not cover what it does. Asked once for this command" in shown, "and why it signs in", shown)
for (command, _), (rc, shown, n) in zip(COMMANDS, results):
    if not command.startswith("run"): continue
    check("(reading ASC_KEY_P8, ASC_KEY_ID, ASC_ISSUER_ID, XLESS_DIST_KEY)" in shown, f"`{command}` says for which secrets it asks, before its first step", shown)
    check("==> " in shown[shown.index("passphrase: "):] and "==> TestFlight: step" not in shown[:shown.index("passphrase: ")], "and goes on from there", shown)
check(gone(), "and nothing is held when they end", agents())
a.close()
sys.exit(1 if failures else 0)
PY
echo "prompts.test.sh: passed"
