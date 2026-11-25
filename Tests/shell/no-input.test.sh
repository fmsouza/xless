#!/usr/bin/env bash
# `--no-input` (XLESS_NO_INPUT=1) for every command that can ask for something: in a real terminal (a pseudo-terminal), with a
# locked store and no Apple ID session, each first shows that it does ask (so the case is a real one), and then, with
# --no-input, fails with exit code 23, the reason and nothing asked. Every command of xless is in one of the two lists
# below: a new one that is in neither fails the test. Nothing reaches Apple: the question comes first.
#   Tests/shell/no-input.test.sh   (builds xless with `swift build`; XLESS_BIN=<path> uses that binary)
set -euo pipefail
repo="$(cd "$(dirname "$0")/../.." && pwd)"
t=$(mktemp -d /tmp/xni.XXXXXX)
trap 'rm -rf "$t"' EXIT
x="${XLESS_BIN:-}"
if [[ -z "$x" ]]; then
  (cd "$repo" && env -u DEVELOPER_DIR swift build --product xless -q)
  x="$(cd "$repo" && env -u DEVELOPER_DIR swift build --show-bin-path)/xless"
fi

# Nothing may reach Apple, whatever the commands do: a Mac's URL loading heeds no proxy variable, so there a sandbox
# without network.
guard=()
if [[ "$(uname)" == Darwin ]]; then guard=(sandbox-exec -p '(version 1)(allow default)(deny network-outbound (remote ip "*:*"))(deny network-outbound (literal "/private/var/run/mDNSResponder"))'); fi
${guard[@]+"${guard[@]}"} python3 -I - "$x" "$t" "$repo" <<'PY'
import concurrent.futures, json, os, plistlib, pty, re, select, shlex, signal, socket, subprocess, sys, time, zipfile

if sys.platform == "darwin":
    with socket.create_server(("127.0.0.1", 0)) as here:
        try: socket.create_connection(here.getsockname(), 2).close()
        except PermissionError: pass
        else: sys.exit("FAIL the sandbox lets the network through: nothing was run")

xless, t, repo = os.path.realpath(sys.argv[1]), os.path.realpath(sys.argv[2]), sys.argv[3]
PASS = "correct horse battery staple"
PROMPTS = re.compile(rb"(passphrase[^\r\n]{0,60}: |Apple ID[^\r\n]{0,20}: |Password: |again: |\[y/N\] )$")
keep = {k: os.environ[k] for k in ("LD_LIBRARY_PATH", "DYLD_LIBRARY_PATH") if k in os.environ}
env = {**keep, "PATH": os.environ["PATH"], "HOME": t + "/home", "XDG_DATA_HOME": t + "/data", "XDG_CONFIG_HOME": t + "/config", "XDG_RUNTIME_DIR": t + "/run",
       "XDG_CACHE_HOME": t + "/cache", "XLESS_WORK_ROOT": t + "/work", "TMPDIR": t + "/tmp", "TERM": "dumb", "LC_ALL": "C",
       "https_proxy": "http://127.0.0.1:9", "http_proxy": "http://127.0.0.1:9"}
for d in ("home", "data", "config", "run", "cache", "work", "tmp", "app", "appstore"):
    os.mkdir(f"{t}/{d}", 0o700)
if sys.platform == "darwin":   # what signs is there already (nothing is fetched here)
    subprocess.run([repo + "/Tests/shell/fake-signer.sh", repo, t + "/share", t + "/data/xless-native"], check=True)
    env["XLESS_SHARE"] = t + "/share"

failures = 0
def check(ok, what, detail=""):
    global failures
    if not ok:
        failures += 1
        print(f"FAIL {what}\n     {detail!r}", flush=True)

def on_a_terminal(argv, answers=(), environment=env, seconds=60):
    """Runs argv as the foreground of a terminal of its own: (exit code or None when it waits for an answer nobody gives, output)."""
    pid, fd = pty.fork()
    if pid == 0:
        os.chdir(t)
        # A terminal's command, not its leader.
        os.execve("/bin/sh", ["sh", "-c", '"$@"; exit $?', "sh", *argv], environment)
    os.set_inheritable(fd, False)
    seen, at, answers, end = b"", 0, list(answers), time.time() + seconds
    while True:
        ready, _, _ = select.select([fd], [], [], 0.3)
        if ready:
            try: chunk = os.read(fd, 4096)
            except OSError: chunk = b""
            if not chunk: break
            seen += chunk
            continue
        asked = PROMPTS.search(seen[at:])
        if asked:
            if answers:
                at = len(seen)
                os.write(fd, (answers.pop(0) + "\n").encode())
                continue
            os.kill(pid, signal.SIGKILL); os.close(fd); os.waitpid(pid, 0)
            return None, seen.decode(errors="replace")
        if time.time() > end:
            os.kill(pid, signal.SIGKILL); os.close(fd); os.waitpid(pid, 0)
            return "timeout", seen.decode(errors="replace")
    _, status = os.waitpid(pid, 0)
    os.close(fd)
    return os.waitstatus_to_exitcode(status), seen.decode(errors="replace")

# ---- a store with an App Store Connect key and signing keys, locked -----------------------------------------------------
def write(path, text):
    with open(path, "w") as f: f.write(text)
while True: # macOS's LibreSSL writes a key that begins with a zero byte (1 of 256) too short: another one then
    subprocess.run(["openssl", "ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", t + "/ec.pem"], check=True, capture_output=True)
    if len(subprocess.run(["openssl", "ec", "-in", t + "/ec.pem", "-outform", "DER"], check=True, capture_output=True).stdout) == 121: break
subprocess.run(["openssl", "pkcs8", "-topk8", "-nocrypt", "-in", t + "/ec.pem", "-out", t + "/AuthKey_ABCDE12345.p8"], check=True, capture_output=True)
subprocess.run(["openssl", "genrsa", "-out", t + "/rsa.pem", "2048"], check=True, capture_output=True)
os.link(t + "/AuthKey_ABCDE12345.p8", t + "/AuthKey_FGHIJ67890.p8")
write(t + "/secret", "a password")
write(t + "/testflight.env", f"XLESS_INSTALLER_KEY_FILE={t}/rsa.pem\n")
write(t + "/devices.txt", "Device ID\tDevice Name\n00008030-001A2B3C4D5E6F70\tPhone\n")
write(t + "/app/xless.yml", "bundleID: com.example.app\nteamID: ABCDE12345\nversion: 1.0.0\nbuild: 1\nplatforms:\n  ios: { minimumOS: '17.0', product: App }\n  macos: { minimumOS: '14.0', product: App, distribution: developer-id }\n")
os.makedirs(t + "/app/.xless/build/ios/final/App.app")
os.makedirs(t + "/app/.xless/build/macos/signed/App.app")
os.makedirs(t + "/app/.xless/build/ios/out")
with zipfile.ZipFile(t + "/app/.xless/build/ios/out/App.ipa", "w") as z:
    z.writestr("Payload/App.app/Info.plist", plistlib.dumps({"CFBundleIdentifier": "com.example.app", "CFBundleVersion": "1", "CFBundleShortVersionString": "1.0.0"}))
for kind, extra in (("cargo", "ios: { package: hello, bin: hello, product: Hello, minimumOS: '17.0', assets: Assets.xcassets }\n"), ("tauri", "ios: { minimumOS: '17.0' }\n")):
    os.makedirs(f"{t}/{kind}/app/src-tauri")
    write(f"{t}/{kind}.yml", f"type: {kind}\nsource: {kind}/app\nbundleID: com.example.app\nteamID: ABCDE12345\nversion: 1.0.0\nbuild: dated\nprivacyManifest: privacy\n{extra}")
write(t + "/privacy", "x")
os.makedirs(t + "/tauri/app/src-tauri/gen/apple")
write(t + "/tauri/app/src-tauri/gen/apple/project.yml", "name: app\ntargets:\n  app_iOS:\n    type: application\n    platform: iOS\n    info: { path: app_iOS/Info.plist, properties: {} }\n")
os.makedirs(t + "/appstore/en-US")
write(t + "/appstore/app.yml", "bundleID: com.example.app\nprivacy: { collectsData: false }\n")
for name, text in (("name", "App"), ("description", "An app."), ("keywords", "app"), ("support_url", "https://example.com")):
    write(f"{t}/appstore/en-US/{name}.txt", text + "\n")
write(t + "/tauri/app/package.json", '{"name": "app", "version": "1.0.0"}')
write(t + "/tauri/app/src-tauri/tauri.conf.json", '{"productName": "App", "version": "1.0.0", "identifier": "com.example.app"}')
os.mkdir(t + "/config/xless", 0o700)
write(t + "/config/xless/config.yml", "unlock: { keep: never }\n")   # the offer to keep it: prompts.test.sh
rc, out = on_a_terminal([xless, "secrets", "init"], [PASS, PASS])
check(rc == 0, "secrets init", out)
rc, out = on_a_terminal([xless, "secrets", "init"], [PASS, PASS], {**env, "XDG_DATA_HOME": t + "/empty"})
check(rc == 0, "secrets init", out)
for args in (["secrets", "import", "ASC_KEY_P8", "--file", t + "/AuthKey_ABCDE12345.p8", "--issuer-id", "69a6de7e-1234-47e3-e053-5b8c7c11a4d1", "--key-id", "ABCDE12345", "--team-id", "ABCDE12345"],
             ["secrets", "import", "XLESS_DIST_KEY", "--file", t + "/rsa.pem"], ["secrets", "import", "NOTE", "--file", t + "/secret"]):
    rc, out = on_a_terminal([xless, *args], [PASS, "n"])
    check(rc == 0, "setting up: " + " ".join(args[:3]), out)

def walk(command, path):
    name = path + [command["commandName"]]
    below = [s for s in command.get("subcommands", []) if s["commandName"] != "help"]
    if not below: yield " ".join(name[1:])
    for s in below: yield from walk(s, name)
commands = list(walk(json.loads(subprocess.run([xless, "--experimental-dump-help"], capture_output=True, text=True, env=env).stdout)["command"], []))


# Every command that can ask for something, with arguments that take it to its question. %T is the test's directory.
A, E, B = "--app 1234567890", "a@example.com", "com.example.app"
P = "--project %T/app --platform ios"
ASKS = {
    # the store's passphrase, for a value
    "sign run": P, "upload": P, "ship": P + " --from sign", "next-build": "--config %T/cargo.yml", "tauri next-build": "--config %T/tauri.yml",
    "inspect": "--config %T/tauri.yml", "tauri inspect": "--config %T/tauri.yml", "package": "--project %T/app --platform macos",
    "sign bootstrap": "--type developer-id",
    "secrets init": "", "secrets import": "OTHER --file %T/secret", "secrets import-env": "%T/testflight.env", "secrets export": "NOTE --out %T/new", "secrets rm": "NOTE", "secrets passwd": "",
    "secrets unlock": "--remember 1h", "unlock": "", "session": "-- true", "secrets materialize": "sign=XLESS_DIST_KEY --allow-disk",
    "live-check": "",
    # a confirmation
    "clean": "--old",
    # … or for the App Store Connect key
    "devices list": "", "devices register": "Phone 00008030-001A2B3C4D5E6F70", "devices import": "%T/devices.txt", "devices enable": "D1", "devices disable": "D1",
    "devices rename": "D1 Other",
    "bundle-ids list": "", "bundle-ids show": B, "bundle-ids create": B, "bundle-ids delete": B, "bundle-ids capabilities": B + " enable PUSH_NOTIFICATIONS",
    "merchant-ids list": "", "merchant-ids create": "merchant.com.example.app --name Shop", "merchant-ids delete": "merchant.com.example.app",
    "certs list": "", "certs create": "--type distribution --name OTHER_KEY", "certs show": "C1", "certs download": "C1 --out %T/new", "certs revoke": "C1", "certs link": "",
    "profiles list": "", "profiles create": f"--type IOS_APP_STORE --bundle-id {B} --cert C1", "profiles download": "P1 --out %T/new", "profiles renew": "P1", "profiles delete": "P1",
    "apps list": "", "apps show": B, "apps update": B + " --primary-locale en-US", "apps price-points": B,
    "store pull": f"--app {B} --dir %T/newstore", "store push": "--dir %T/appstore --only text",
    "builds list": "", "builds show": "1.0+1", "builds wait": "1.0+1", "builds update": "1.0+1 --uses-non-exempt-encryption false", "builds expire": "1.0+1",
    "users list": "", "users show": E, "users invite": E + " --first-name A --last-name B --role DEVELOPER --all-apps", "users update": E + " --role DEVELOPER", "users remove": E,
    "users invitations list": "", "users invitations cancel": E,
    "testflight groups list": A, "testflight groups create": "Group " + A, "testflight groups update": "Group --name Other " + A, "testflight groups delete": "Group " + A,
    "testflight testers list": A, "testflight testers add": f"{E} --group Group {A}", "testflight testers remove": f"{E} {A}", "testflight testers invite": f"{E} {A}",
    "testflight builds add": "1.0+1 --group Group", "testflight builds remove": "1.0+1 --group Group", "testflight whats-new show": "1.0+1", "testflight whats-new set": "1.0+1 --text New",
    "testflight beta-info show": A, "testflight beta-info set": A + " --description Text", "testflight beta-review submit": "1.0+1", "testflight beta-review status": "1.0+1",
    "testflight public-link show": "Group " + A, "testflight public-link enable": "Group " + A, "testflight public-link disable": "Group " + A,
    "release create": f"1.0 {A} --platform ios", "release attach": f"1.0+1 {A} --platform ios", "release submit": A, "release status": A, "release cancel": A, "release publish": A,
    "release phased pause": A, "release phased resume": A, "release phased complete": A,
    "iap list": A, "iap show": "product " + A, "iap price-points": "product " + A,
    "subscriptions list": A, "subscriptions show": "product " + A, "subscriptions price-points": "product " + A,
    "sandbox-testers list": "", "sandbox-testers clear-history": "--all",
    "reviews list": A, "reviews respond": "R1 --text Thanks", "reviews delete-response": "R1",
    "reports sales download": "--vendor 12345678 --date 2026-01-01 --out %T/newdir", "reports finance download": "--vendor 12345678 --date 2026-01 --out %T/newdir",
    "webhooks list": A, "webhooks create": A + " --url https://example.com/hook --events BUILD_UPLOAD_STATE_UPDATED", "webhooks delete": "W1",
    "provision plan": "--project %T/app", "provision apply": "--project %T/app",
    "api": "GET /v1/apps",
    # the Apple ID, its password and a code
    "xcode download": "27.0 --output-dir %T/tmp",
    "auth login": "", "auth api-key create": "", "auth api-key list": "", "auth api-key revoke": "ABCDE12345",
    "auth api-key import": "--p8-file %T/AuthKey_FGHIJ67890.p8 --issuer-id 69a6de7e-1234-47e3-e053-5b8c7c11a4d1",
    "team list": "",
    "app-groups list": "", "app-groups create": "group.com.example.app", "app-groups assign": B + " group.com.example.app", "app-groups unassign": B + " group.com.example.app",
    "icloud-containers list": "", "icloud-containers create": "iCloud.com.example.app", "icloud-containers assign": B + " iCloud.com.example.app",
    "icloud-containers unassign": B + " iCloud.com.example.app",
    "keys list": "", "keys create": "--service apns", "keys show": "ABCDE12345", "keys revoke": "ABCDE12345",
    "apps create": f"--bundle-id {B} --name App --sku SKU1 --locale en-US", "store privacy pull": f"--app {B} --dir %T/newstore", "store privacy push": "--dir %T/appstore",
}
# What each asks first. A command that Apple's API covers never signs in, so it asks for the store's passphrase (its key);
# one that keeps a new key opens the store before Apple makes it. (The inventory of #183; the rest of what a composite
# command asks, and how often: prompts.test.sh and ProvisionTests.)
SIGN_IN_FIRST = {"xcode download", "auth login", "auth api-key list", "auth api-key revoke", "team list", "keys list", "keys show", "keys revoke",
                 "store privacy pull", "store privacy push",
                 *(f"{group} {verb}" for group in ("app-groups", "icloud-containers") for verb in ("list", "create", "assign", "unassign"))}
def asks_first(shown): return "the Apple ID" if re.search(r"Apple ID[^\r\n]{0,20}: $", shown) else "a new passphrase" if re.search(r"New [^\r\n]*: $", shown) else "the passphrase" if re.search(r"assphrase: $", shown) else "a confirmation" if shown.endswith("[y/N] ") else shown[-200:]

# A docker that has an image of an older xless.
os.mkdir(t + "/docker", 0o755)
write(t + "/docker/docker", """#!/bin/sh
case "$*" in
  *label=*) ;;
  "image ls"*) echo xless-base:local-arm64 ;;
  "image inspect"*) echo '{"Id":"sha256:1","Architecture":"arm64","Config":{"Labels":{}},"RootFS":{"Layers":[]}}' ;;
esac
""")
os.chmod(t + "/docker/docker", 0o755)

# The environment of some: another (empty) store, where the question is about what is not there yet.
EMPTY = {"XDG_DATA_HOME": t + "/empty"}
MORE = {"live-check": {"XLESS_LIVE_APPLE": "1"}, "secrets init": {"XDG_DATA_HOME": t + "/none"},
        "clean": {"PATH": t + "/docker:" + env["PATH"]},
        **{c: EMPTY for c in ("auth api-key create", "auth api-key import")}}

# Those that never ask for anything.
NEVER = {
    "offline": "sdk meta; sdk export; nib dump; storyboard compile; tauri report; tauri compare; cargo inputs; store validate; secrets status; secrets list; "
               "secrets named-by; secrets redact; setup; sdk install; lock; secrets lock; auth logout; auth status; team use",
    "the build: no secret is read, and its tools have no terminal": "prepare; build; assets; finalize; xcode pif; xcode swbuild; xcode packages; shim xcrun; shim actool; shim ibtool; "
        "shim plistbuddy; shim dmg-build; shim xcodebuild; shim strip; shim ld64; shim embedded-binary-validation; shim ditto; shim copypng; shim prepare-clang",
    "asks through the commands above (sign, next-build, secrets materialize), which inherit the variable": "run; docker",
}
never = {c.strip() for names in NEVER.values() for c in names.split(";")}
if os.uname().sysname != "Darwin": never -= {"sdk export"}   # a Mac's command
check(sorted(commands) == sorted(set(ASKS) | never), "every command is in one of the lists",
      {"in neither": sorted(set(commands) - set(ASKS) - never), "not a command": sorted((set(ASKS) | never) - set(commands)), })
check(not set(ASKS) & never, "no command is in both lists", sorted(set(ASKS) & never))

# Asks only once Apple has answered: without input it says so before.
LATE = {"auth api-key import"}

def both(command):
    e = {**env, **MORE.get(command, {})}
    argv, rest = [xless, *command.split()], shlex.split(ASKS[command].replace("%T", t))
    return command, (None, "") if command in LATE else on_a_terminal(argv + rest, environment=e), on_a_terminal([*argv, "--no-input", *rest], environment=e), \
        on_a_terminal(argv + rest, environment={**e, "XLESS_NO_INPUT": "1"})
with concurrent.futures.ThreadPoolExecutor(min(8, (os.cpu_count() or 2) * 2)) as pool:
    for command, (rc, out), (off, refused), (variable, _) in pool.map(both, ASKS):
        check(rc is None, f"`xless {command}` asks", (rc, out[-400:]))
        if command not in LATE:
            first = "a new passphrase" if command == "secrets init" else "a confirmation" if command in ("secrets rm", "clean") else "the Apple ID" if command in SIGN_IN_FIRST else "the passphrase"
            check(asks_first(out) == first, f"`xless {command}` asks for {first} first", asks_first(out))
        check(off == 23, f"`xless {command} --no-input` ends with exit code 23", (off, refused[-400:]))
        check(variable == 23, f"XLESS_NO_INPUT=1 xless {command} ends with exit code 23", variable)
        check("[input] --no-input (XLESS_NO_INPUT): xless would ask for " in refused, f"`xless {command} --no-input` says why", refused[-400:])
        check(not PROMPTS.search(refused.encode()) and not re.search(r"(?m)(passphrase|Password|Apple ID[^\r\n]*|again): ?$", refused), f"`xless {command} --no-input` asks nothing", refused[-400:])

# With the store unlocked, the same commands need no input: --no-input is no refusal of secrets.
unlocked = f"{shlex.quote(xless)} unlock --for 2h && {shlex.quote(xless)} secrets export NOTE --out {t}/exported --no-input; code=$?; {shlex.quote(xless)} lock; exit $code"
rc, out = on_a_terminal(["/bin/sh", "-c", unlocked], [PASS])
check(rc == 0 and open(t + "/exported").read() == "a password", "an unlocked store serves --no-input", (rc, out))

# A confirmation, which --yes gives beforehand.
rc, out = on_a_terminal(["/bin/sh", "-c", f"{shlex.quote(xless)} secrets rm NOTE --yes --no-input"])
check(rc == 0, "--yes needs no input", (rc, out))

# A credential helper has no terminal to ask on.
os.mkdir(t + "/helpers", 0o755)
write(t + "/helpers/xless-credential-ask", f"#!/bin/sh\nif (: < /dev/tty) 2>/dev/null; then echo terminal; else echo none; fi >> {t}/helper.log\nexit 1\n")
os.chmod(t + "/helpers/xless-credential-ask", 0o755)
write(t + "/config/xless/config.yml", "unlock: { keep: never }\nsecrets: { backend: helper, helper: ask }\n")
e = {**env, "PATH": t + "/helpers:" + env["PATH"]}
on_a_terminal([xless, "secrets", "list"], environment=e)
on_a_terminal([xless, "secrets", "list", "--no-input"], environment=e)
check(open(t + "/helper.log").read().split() == ["terminal", "none"], "a helper has a terminal, and none with --no-input", open(t + "/helper.log").read())

# The question is asked in one place: whatever opens the terminal is known here.
found = sorted(os.path.relpath(os.path.join(r, f), repo) for r, _, files in os.walk(repo + "/Sources") for f in files
               if f.endswith((".swift", ".c")) and re.search(r'"/dev/tty"|readLine\(strippingNewline|getpass\(|readpassphrase\(', open(os.path.join(r, f), errors="replace").read()))
check(found == ["Sources/CXlessProcess/CXlessProcess.c", "Sources/XlessVault/CredentialHelper.swift", "Sources/xless/TerminalPrompter.swift"], "only the known places open the terminal (the C: to leave it, and to run a helper on it)", found)

print("no-input.test.sh: " + (f"passed ({len(ASKS)} commands that ask, {len(never)} that never do)" if not failures else f"{failures} FAILED"), flush=True)
sys.exit(1 if failures else 0)
PY
