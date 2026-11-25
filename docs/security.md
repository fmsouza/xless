# Security: what xless keeps, where, and what it sends

xless holds the keys to your Apple developer account: an App Store Connect API key can change your apps, a signing key
can ship code under your name, and an Apple ID session can do everything the account's web pages can. This page says
what xless stores, where and for how long, what protects it, which Apple host each secret goes to, and what xless
does **not** protect against. The commands themselves are in [apple-account.md](apple-account.md) and
[secrets.md](secrets.md); this page is the model behind them.

The guarantees below describe the code. They are checked by tests with recorded Apple answers, not yet end to end on a
real Apple account ([acceptance: #105](https://github.com/fmsouza/xless/issues/105)); where Apple's side matters (how long
its sessions live, what it accepts), the text says what xless does and leaves Apple's behaviour to Apple.

## What there is to protect

| Secret | Where it comes from | What it can do |
|---|---|---|
| App Store Connect API key (`.p8`, with its key ID and issuer ID) | `xless auth api-key create` or `import`; CI's `ASC_KEY_*` | Whatever its role allows through the App Store Connect API, until it is revoked |
| Signing keys (`XLESS_DIST_KEY`, `XLESS_DEVID_KEY`, `XLESS_INSTALLER_KEY`, other certificates' keys) | `xless certs create`, `xless sign bootstrap`, `xless provision apply` | Sign apps and packages as your team, until the certificate expires or is revoked |
| Auth keys (APNs, Sign in with Apple, DeviceCheck, MusicKit `.p8`) | `xless keys create`, `xless provision apply` | Send push notifications to your apps' users, sign tokens as your apps |
| The App Review demo account's password (`XLESS_DEMO_PASSWORD` or the name app.yml gives) | `xless secrets import`, the environment | Sign in to your app's demo account |
| Webhook signing secrets (`XLESS_WEBHOOK_SECRET.<webhook ID>`) | `xless webhooks create` (random, made on this machine) | Sign requests that your webhook receiver takes as coming from App Store Connect |
| Your Apple ID password and two-factor code | typed on the terminal | Everything the Apple ID can do |
| The Apple ID web session (cookies, a device trust cookie among them) | the sign-in | The App Store Connect and developer portal web pages, until Apple expires it |
| The secret store's passphrase, and the store's data key once unlocked | typed on the terminal | Open every entry of the store |

## Who xless defends against

- **Someone who gets the disk, a backup or a synced home directory.** Keys are in the encrypted store, never in clear
  files (unless you export one). The store unlock is never written to disk, and the Apple ID session only sealed in the
  store, when you ask for that (`--across-reboots`).
- **Other users of the machine.** The store, its directory and its lock are yours only (refused otherwise); the xless
  agent answers no other user, and the kernel keyring's cached keys are readable only by processes of your login session.
- **Code your build runs** (npm scripts, `build.rs`, SwiftPM plugins and macros, CocoaPods hooks, Xcode build phases),
  partly. Every tool xless runs starts without a secret variable, in a POSIX session of its own (which the xless agent
  refuses) and in an empty session keyring (no held unlock, no kept Apple ID session), and unable to open the store, and
  an overlay app's build runs in a container that has no secret. It still runs as you and can read your files
  ([below](#the-build-and-your-secrets)).
- **Logs, terminals and bug reports.** No secret is printed, put in an error, in a `--verbose` trace or on a command
  line.
- **A network observer.** Everything goes over HTTPS to Apple's hosts; xless refuses a redirect from HTTPS to anything
  else, a non-HTTPS request in the Apple ID session, and `xless api` refuses any host but App Store Connect's API.

Out of scope: malware or a person running **as you**, outside what xless starts, while the store is unlocked or a
session is kept ([what it can do](#what-an-attacker-who-runs-as-you-can-do)), someone who has both the store file and its
passphrase, and a compromised Apple account or Apple service. Code that runs on your machine as you can read your files
and wait for you to type the passphrase: that is why the overlays build in Docker.

## Guarantees

1. **The documented API by default.** Every command that has a documented App Store Connect API (4.6.1) uses it,
   with the API key: a JSON Web Token signed with ES256 for each request, valid for 15 minutes, never stored. The
   Apple ID web session is used only for what that API cannot do ([below](#the-apple-id-web-session)).
2. **No secret in clear on disk.** Keys xless creates or downloads go straight into the encrypted store, sealed before
   any request that could make them unrecoverable (a certificate's key before the certificate is requested; an API or
   auth key's `.p8`, which Apple serves once, in the same process that created it). Writing one to a file is explicit
   (`xless secrets export --out`, `xless sign bootstrap --out`): a new file, opened with `O_EXCL`, mode 0600, never an
   overwrite. Imports offer to delete the file they read. Two things need a file for a moment: rcodesign its key, and a
   container its secrets. Each is mode 0600 in a fresh directory of mode 0700 (the containers' on a tmpfs, unless you allow a
   disk), and is removed when the tool or the container ends, on an error, and when a signal ends xless (Ctrl-C, Ctrl-\\,
   SIGTERM, a fault of its own: any that can be caught; a stack that overflows is, in the threads that start tools or make such
   files). A `kill -9` leaves them; the next run on the same work copy removes the containers' and their secrets.
3. **Nothing kept longer than the command,** unless you opt in: the store's unlock (`xless unlock`, `--remember`) and
   the Apple ID session (`xless auth login --keep`) can be held in memory, for 8 hours and 2 without use unless you say
   otherwise, and never more than 7 days. `xless auth status` shows what is held, where and until when, also for a script that runs; `xless lock`
   drops all of it at once. Only `--across-reboots` puts a session on disk, sealed in the store.
4. **No secret on a command line, in a log, in an error, in a core dump or in a child's environment.** Secrets come
   from the terminal, the store, `NAME` or `NAME_FILE`; no option takes one (a test walks every command and fails on an
   option named like a secret). A secret under a name of your own (a demo account's `passwordSecret`) is removed from
   the tools' environment too. `xless run` gives no secret variable to an overlay's build step, to the build of a project
   that has an image of its own, to a run that stops before it signs, or to the programs it starts for itself (the docker client
   gets the API key's two IDs at most, and none where it builds a kit or is asked about an image), and starts every program with
   its arguments as they are, never through a shell.
5. **Least privilege, and a question before anything destructive.** `xless auth api-key create` makes an `APP_MANAGER`
   key unless you ask for more; the commands that revoke, delete, remove or cancel something at Apple ask first, and
   without a terminal they are refused unless `--yes` is given. `xless provision apply` never deletes or revokes
   anything. Two things replace without asking, because that is how they update: `sign` deletes and recreates its
   own `xless <bundle ID> <TYPE>` profile when it cannot be used (and prints what it will change first; with
   `--no-provisioning-updates` it changes nothing:
   [signing-and-testflight.md](signing-and-testflight.md#what-sign-changes-on-the-account)), and `xless store privacy
   push` deletes the App Privacy answers app.yml no longer declares. Nothing is sent to App Review but by `xless release
   submit`; a build it picks itself is one App Store Connect calls the version's newest valid build (what is on disk,
   where build code can write, is only a hint), and is named before anything is sent.

## The secret store

[secrets.md](secrets.md) has the commands; this is what is in the file.

- **Where.** `$XDG_DATA_HOME/xless/vault/` (`~/.local/share/xless/vault/`): the directory mode 0700, `secrets.vault`
  and the writers' `lock` mode 0600. A symlink, another owner, or any permission bit for the group or others on any of
  them is refused, never repaired.
- **Format.** One JSON file (`"format": "xless-vault"`, `"version": 2`, `"minimumReaderVersion": 2`, a random store
  ID, the KDF and its parameters, the wrapped data key, a key check and the entries). A random 256-bit data key seals
  each entry's secret with AES-256-GCM; the data key is sealed with AES-256-GCM under a key derived from the passphrase by scrypt (N = 2^17,
  r = 8, p = 1: about 128 MiB and a fraction of a second per unlock; parameters no xless writes are refused before
  anything is derived). Each entry's name, kind and metadata (team, key ID, issuer ID, certificate ID, type, role,
  services, dates) are in clear so that `xless secrets list` works while the store is locked, and are authenticated as
  the seal's associated data, every field whether it is set or not: an altered, added or removed field makes the entry
  fail to open, and nothing of it is used. A store of the first format (version 1, where the type, role and services
  were authenticated only when set) is sealed again this way by the first change made with the data key at hand, and
  an entry of the first format put into a newer store never opens. An xless older than the file's
  `minimumReaderVersion` refuses to rewrite it, and every xless writes back the fields it does not know, so an older
  release cannot drop a field a newer one recorded ([secrets.md](secrets.md#store-format-and-older-xless-releases)).
- **Writes** re-read the file under the lock and replace it in one step (a temporary file in the same directory, then a
  rename), so concurrent commands do not lose each other's entries and a crash never leaves half a file.
- **The passphrase** is read from `/dev/tty` with echo off, never from a pipe, a file, an argument or the environment.
  It cannot be recovered. `passwd` seals the data key again under a new passphrase; the entries are not re-encrypted
  (except to move a first-format store to format 2), so an old copy of the file still opens with the old passphrase.
- **What the store does not detect:** someone who can write the file can delete entries, put back an older copy of
  the whole file (with entries you removed since) or of an entry. None of it reveals a secret; keep the store's
  directory yours.

CI does not use the store: it gives secrets as `NAME` or `NAME_FILE` variables, which xless reads the same way.

### With a credential helper

With `secrets: { backend: helper, helper: <name> }` in config.yml, the secrets are in your keyring or pass instead of
this file, and their protection at rest is the keyring's
([secrets.md](secrets.md#keeping-the-secrets-in-your-keyring-or-pass-credential-helpers)). The helper,
`xless-credential-<name>`, sees every secret xless stores or reads, so xless runs it only from an absolute PATH
directory, and refuses it when the file, its directory or that PATH directory can be written by the group or others or
belongs to someone other than you or root. It gets its verb as its only argument, a cut-down environment with no secret
variable, no open file of xless's, the terminal while it runs, the secret on a pipe only; its answer is read into at most 4 MiB of memory that is
zeroed afterwards, and it is killed with its process group after 120 seconds. The entries' names, kinds and IDs are kept
by the keyring too (unsealed: their integrity is the keyring's). Two xless commands writing at once take turns under
the vault's writers' lock file. Before Apple creates a key it offers once, the helper must store, read back and erase a
throwaway entry; and a key the store fails to keep after all is written to a new 0600 file in `$XDG_RUNTIME_DIR` (or
a path asked on the terminal) with the `xless secrets import` command to run, rather than dropped
([secrets.md](secrets.md#when-the-helper-cannot-keep-a-key-apple-offers-once)).

## Holding an unlock: off by default, in memory
<a id="caches-off-by-default-at-most-an-hour"></a>

Without any of this, a command that needs the store asks its passphrase and a web-session command signs in, and both
forget everything when they end. Holding is asked for, never a default:

| What is held | Turned on by | What it is | Dropped by |
|---|---|---|---|
| Store unlock | `xless unlock`; a yes to [the offer](secrets.md#staying-unlocked) after the passphrase (or a sign-in), or `unlock: { keep: always }` in config.yml; `xless session` and a native `xless run`, for their script only; `--remember [<duration>]` on `xless secrets unlock`, `init`, `import`, `export` | the store's data key, named after the store's random ID | `xless lock`, `xless secrets lock`, `passwd`, another store in its place, the end of its time, its idle time, and the [events below](#when-it-ends) |
| Apple ID session | `xless auth login --keep [<duration>]`; the same yes, or `keep: always`; `xless session --sign-in`, for its script only | the session's cookies, sealed with AES-256-GCM under a random key made for them; the sealed cookies and that key are two separate items | `xless lock`, `xless auth logout`, the end of its time (or the cookies' own expiry, if sooner), its idle time, and the same events |

They are held in one of two places, in memory only; `xless auth status` says which:

- **The xless agent** (Linux and macOS): a small process of xless's, started by the first command that holds something.
- **The Linux kernel keyring**, only where no agent can run and the keyring works: for an hour at most, and
  [with less to end it](#the-kernel-keyring), which xless says.

Durations are `90s`, `30m`, `8h`, `2d` or seconds. `unlock:` in config.yml sets the defaults and lowers the maximum:

```yaml
unlock:
  duration: 8h              # without a duration on the command line
  idle: 2h                  # dropped after this long without use
  maximum: 7d               # the most that can be asked for; never more than 7d
  lockOnSleep: true         # drop everything when the machine sleeps
  lockOnScreenLock: true    # … and when the screen is locked (macOS)
  keep: ask                 # after a passphrase or a sign-in: ask whether to keep both; always, never
```

The offer is one question, whose Enter is no; it is never asked, and nothing is ever kept by it, in CI, with `--no-input`,
inside `xless session`, in the environment of build code (`XLESS_NO_SECRET_STORE=1`) or without a terminal. A yes is for both
the unlock and the session, for this terminal (the POSIX session it was given in: an agent that also serves another
terminal does not take it there), and lasts no longer than it was given for; what is kept by it is said each
time, once it is, and `xless lock` forgets the yes too (the agent holds it as an item with no secret in it; `auth status` shows it).
With `keep: always` the same is done without the question, and said. Input typed before a question is shown is thrown away,
before this one and every other question of xless's: nothing typed ahead agrees to anything.

A kept Apple ID session replaces the one held where it goes: the agent of this terminal (or of the `xless session` it runs
in). Those of other terminals, and of scripts that run, go on; `xless lock` and `xless auth logout` drop all of them.

Nothing lives longer than the maximum counted from when the passphrase or the password was last **typed**: a renewal, or a
move from the kernel keyring to the agent, takes that time along (and where it is not known, the passphrase is asked). The
clock keeps running while the machine sleeps. The settings count for what is held already, from the next command that uses
it: a lowered maximum ends it sooner, and `lockOnSleep` or `lockOnScreenLock` switched on (or set for a second terminal
that joins) holds for the agent from then on. They never loosen a hold: a raised maximum or a lock switched off counts for
the next unlock after `xless lock`.

### Who may use what the agent holds

An agent serves a process only when **all** of these hold, each taken from the kernel, never from what the process says:

1. It runs as **you**: the same user ID.
2. It belongs to a **POSIX session that was granted**: the session (the shell of a terminal, tab, tmux pane or SSH login)
   in which you typed the passphrase or the password. The agent lists the granted sessions by their leader's process ID
   **and** start time, so a process ID used again later is not taken for it. Another terminal is granted once the store
   is unlocked there too (`xless unlock` in it): it must show the agent that it knows the store's data key, which takes the
   passphrase, and can add only the session the kernel says it is in.
3. On macOS, it runs **the same xless executable** as the agent: the same file (the one mapped as its program, by device
   and inode, so a moved or renamed `xless` is still the same one), and the same code: the hash of the code directory that
   the kernel started it with (`SecCodeCheckValidity` for its audit token), which must also be the hash of the file at its
   path. A program can have xless's file mapped and at its own path; it cannot have the hash. What is not signed, or cannot
   be told, is refused, and an agent that cannot tell its own program does not start (releases are signed ad hoc, and so is
   a build from source, by the linker). After an upgrade, the new `xless` is another program: it says so, and `xless lock`
   ends the agent of the old one.

   This keeps other programs, and other builds of xless, from speaking to the agent themselves. It keeps out nobody who is
   in a granted session (they can run xless), and in a build of your own, where macOS takes `DYLD_INSERT_LIBRARIES` and
   debuggers, the code of another program can be in an xless with the right hash.

Who speaks is taken once, pinned, and looked at again before every answer:

- On Linux the kernel names the sender of every piece of a message (`SCM_CREDENTIALS`), and a pidfd opened at the first
  one keeps hold of that process.
- On macOS the kernel keeps only the process ID of whoever used the other end last, and says (`LOCAL_PEERTOKEN`) whose
  that ID is *at the moment it is asked*. So the whole audit token, process version included, is read when the first
  message comes; every later look must find the very same token. A process that has ended, or whose ID another one has
  since, is refused, and the connection with it.

Only then is a one-time challenge sent, which that process has to answer: so it was there when it was looked at, and not
another one that had its ID by then. The command looks at the agent in the same way, and looks again before it sends a
secret and before it takes one.

**What refuses build code is rule 2.** Every tool xless runs (a compiler, swift-build, npm, cargo, pod, a hook, rcodesign)
is started in a POSIX session of its own. A process can leave a session, for a new one, but no system call enters
an existing one: so nothing that a build starts, however it forks, daemonizes or calls `setsid`, and not even the `xless`
binary itself run by it, is in a granted session. It also starts with `XLESS_NO_SECRET_STORE=1`, with which
xless looks for nothing held; that one the code could unset, the session it could not. `Tests/shell/agent.test.sh` runs
such code against a real agent, every way of getting away included. What stays in the terminal's session runs no code of
the project: `xless run` (its build step is an `xless ship`, whose tools are not), with `--docker` the docker client which
it runs (the build is in the container), and a
[credential helper](#with-a-credential-helper), which may ask something on the terminal and already sees every secret.

A session of its own has no terminal, so Ctrl-C and a closed window do not reach a tool by themselves: xless passes SIGINT,
SIGTERM and SIGHUP on to the process group of each tool that runs (SIGTERM for any other signal that ends it), and ends as it
would. (A `kill -9` of xless it cannot pass on.)

Containers: xless never mounts the agent's socket. One mounted by hand gives nothing: on Linux a container's process is in
no granted session; on macOS a socket does not cross into the VM.

The other direction: the client gives a secret to an agent only when the agent's process is yours, and is in the client's
own session or has shown (with a MAC) that it knows this store's data key; on macOS also only to its own executable. The
directory of the sockets (`$XDG_RUNTIME_DIR/xless-agent`, your own temporary directory's `xless-agent` on macOS, else
`/run/user/<uid>/xless-agent` or `/tmp/xless-agent-<uid>`) must be yours, mode 0700 and no symlink, or nothing is bound or
connected to. A data key that does not open the store is never used.

The agent process: no controlling terminal, no file of yours open, stdin, stdout and stderr on `/dev/null`, an empty
environment, `/` as its directory, core dumps off; non-dumpable on Linux, `PT_DENY_ATTACH` on macOS; secrets
in memory locked against swap (where the limit allows), in no forked child, left out of core dumps on Linux (macOS has
none to leave them out of: they are off), and zeroed when dropped. It writes no log. It holds at most 8 items of 128 KiB, for at most 64 sessions, and gives a connection 10 seconds and 4 KiB before it
knows who it is. An agent of another xless version is never misunderstood: the command says so, and `xless lock` ends it.

### An agent for a script

`xless session -- <command…>` (and `xless run` natively, for its steps) holds what was typed in an agent of its own, on a
*lease*: it ends when the process that started it does, however that ends (the kernel closes the connection between the two,
which nothing else has), besides everything that ends any agent. Its socket has a random name, and only a command that was
told it, by `XLESS_SESSION` in the script's environment, asks it; a terminal's commands never find it by themselves. The
rules above hold for it unchanged: the variable is no credential, and a process that has it and is not in a granted
POSIX session is refused (`Tests/shell/session.test.sh`: the tools xless runs, another terminal, a process that left the
session). It is granted the script's session, which is the terminal's: the script and every program it runs directly may
run `xless`, as in a terminal with the store unlocked, and an `npm install` or a `make` in the script is such a program. So
**run only what you would run in an unlocked terminal**; what xless runs for the script is refused as ever. No tool that
xless runs is told of the lease (every xless takes the variable out of its own environment, `xless run`'s script out of its
own, and what xless starts never gets it), and each is refused all the same.

A lease lasts `unlock.duration` at most (8 hours unless you lower it), whatever was put in it meanwhile and however long the
script runs; its idle time does not end it, for a build may take long. `xless auth status` lists the leases that hold
something, in every terminal of yours: the command, what kind of thing is held and until when. A process that a lease does
not serve is told no more than that: not which store, nor where it is. (An `xless session` leaves no other trace: the
variable points at nothing once it has ended. A shell that outlived it, in a tmux server started there, say, is told to
`unset XLESS_SESSION`.)

### While `xless run` builds
<a id="while-xless-run-builds"></a>

`xless run` asks the passphrase up front, so that nothing is asked once its first step has started. The price, natively:
**the store's data key is in the lease's agent while the build's code runs**, on the same machine, as the same user. (With
`--docker` it is not: the build is in a container, and what its steps need is on a tmpfs, mounted into the containers that
sign and upload.) What keeps that code from it:

- **Everywhere:** the agent answers only a process of the run's own POSIX session, by the kernel's word, and the build step's
  tools are in other ones, which cannot enter it ([rule 2](#who-may-use-what-the-agent-holds)); they are not told of it, and
  their `XLESS_NO_SECRET_STORE=1` has an xless they run look for nothing. The key is in memory locked against swap and left
  out of core dumps, in a process with no file of yours open, and is zeroed when the run ends.
- **Linux:** the agent is not dumpable: no process of yours can read its memory, attach a debugger to it or look into its
  `/proc` entry. It and the tools are out of the login's session keyring.
- **macOS:** `PT_DENY_ATTACH` on the agent, the peer's whole audit token looked at before every answer, and the same
  program as the agent's: its file, and its code by the hash that the kernel started it with
  ([rule 3](#who-may-use-what-the-agent-holds)).

What it does not keep out is what nothing of xless's does: root, the kernel, and a program that can make your terminal, or
a program in it, run a command ([below](#what-an-attacker-who-runs-as-you-can-do)). To have nothing held while code of the
project runs, run the steps apart, with the store locked:

```sh
xless lock
xless ship --to finalize     # the build: needs no secret, and asks for none
xless ship --from sign       # signing and the upload: asks the passphrase once, and runs no code of the project
```

A lease ends as every agent does when the machine sleeps or (macOS) the screen is locked, during a build too: then the step
after it asks the passphrase, or stops with `--no-input`. `lockOnScreenLock: false` in config.yml leaves a locked screen out.

Ctrl-C is the terminal's, to the script and xless alike. SIGTERM and SIGHUP sent to xless are passed on to the script. A
SIGINT sent to xless alone is passed on on Linux; on macOS nothing tells it from the terminal's, so it is not while the
script is in the foreground (end the script, or send SIGTERM).

### When it ends

- The time given, the idle time, `xless lock` (every agent of yours, in every terminal, the keyring and a saved session:
  every step is taken, whatever the others came to). `xless auth logout` drops the Apple ID session, `xless secrets lock`
  the store's unlock.
- An agent that **does not answer** (a stopped process, say) is never taken for nothing held, also when its queue is full
  and the system refuses a connection as if nobody listened (macOS): its socket's name says which process made it. `xless
  lock` ends that process where it can ask who listens and the kernel says that it is the one, and this very xless
  (macOS); else it names the agent and fails, as `xless secrets lock`, `xless auth logout` and `passwd` do. A command
  that looks for something held says so, waits for it once (1.5 s) and goes on.
- **The terminals are closed**: when no granted session's leader is left (you closed the window, logged out of SSH, quit
  the shell), the agent ends within 2 seconds. Logging out ends every session.
- **The machine sleeps**: the agent compares a clock that stops during sleep with one that does not, and drops everything
  when it wakes, before it answers anything (`lockOnSleep`).
- **The screen is locked**, on macOS, within 2 seconds (`lockOnScreenLock`). On Linux a screen locker says so on D-Bus
  only, which xless does not speak: let the locker run `xless lock`, for example with
  `swayidle lock 'xless lock'`, `xss-lock -- sh -c 'xless lock; exec i3lock -n'`, or a systemd user unit for your desktop.
- `passwd` (every unlock of that store), a store put in its place (the data key is named after the store's ID and checked
  against the store before use), the agent's socket or its directory removed, and the agent process killed.

No agent can be used where xless itself leads its POSIX session (`ssh host xless …`, `docker exec … xless`, without a
shell: nothing of it would be left to serve), where there is no pidfd (Linux before 5.3, or a container whose seccomp profile
refuses `pidfd_open`: for good, so it counts as the same; any other failure of it is of the moment, and an error), nor where
its directory or socket cannot be made at all (a read-only file system, a path too long, no Unix sockets). There, and only
there, `xless unlock` uses the kernel keyring if it works, for at most an hour, and says so and what that lacks; else it is
refused with the reason. All that can be told beforehand is found before anything is asked: `xless session` stops then, and
`xless run` goes on with a note, each of its steps asking by itself. An agent that could run and did not start this time,
or whose directory others can use, is an error: the keyring does not stand in for it.

### The kernel keyring

- The keys are `user` keys in the **session keyring**, readable only by a process that holds that keyring (a
  "possessor"). Which processes those are is the system's choice: usually every process of your login session (on a
  desktop, every terminal of the login), and where no login session keyring was set up, your user's default session
  keyring, which all your processes without one share. Other users cannot read them; the permissions give nothing to
  the user, group or others outside possession. Every process that possesses the keys can read them; the tools xless
  runs, and so the code you build, do not ([below](#the-build-and-your-secrets)).
- The kernel expires the keys itself, after at most one hour; when xless cannot set the bound or the permissions, it
  revokes the key and fails rather than keep it longer or wider.
- **What ends a hold in the agent and not here:** a time without use (so an `--idle` is refused, and the configured one is
  said not to be kept), sleep, a locked screen, a closed terminal. And `xless lock` drops the keys of the session keyring
  it is run in: a screen locker, or a service of your login, may well have another one. The hour is the bound.
- Beside the key is a note of when it ends and when the passphrase was typed, so the [maximum](#holding-an-unlock-off-by-default-in-memory)
  is counted from there when the hold moves to an agent.

A **longer keyring** was considered instead of an agent and left out: macOS and containers have none, a possessor is every
process of the login rather than of a terminal, and it has no idle time, no sleep and no terminal to end with.

### Across reboots

`xless auth login --keep 3d --across-reboots` also saves the Apple ID session as an entry of the encrypted store
(`xless-apple-session`), sealed under the store's data key as every entry is: after a reboot, a command that needs the
session opens it once the store is unlocked, so the passphrase is asked, and not the Apple ID's password and code. It is
off by default, needs xless's own encrypted store, ends at the time given at the latest, and is removed by `xless auth
logout`, `xless lock`, a later `--keep` without it, or its end. It is an entry of a kind of its own, which no command
imports, and which is never read as a secret by name, exported, or given to a build or a container; an older xless lists
it and cannot open it. That one name is xless's: an import under it is refused, and an entry of your own that has had the
name since before is left alone (and `--across-reboots` refused until it is renamed).

The **macOS Keychain** and the **Secret Service** (GNOME Keyring, KWallet) were considered for the key that would open it
without a passphrase, and are not used: they cannot keep it from build code.

- *Keychain*: an item can be limited to one program by its code signature. xless is signed ad hoc, so that is the hash of
  one build of it: every process of yours, build code included, can run that very xless with the environment and the
  standard input of its choice (and, without the hardened runtime, with a library of its choice), and the Keychain then
  gives *it* the key, without asking.
- *Secret Service*: any process on your session bus reads every unlocked item; there is no rule per program.

Both would let code that builds an app have a session that lasts across reboots, which nothing xless holds may. The same
holds for a [credential helper](secrets.md#keeping-the-secrets-in-your-keyring-or-pass-credential-helpers), which any
process of yours can run: there `--across-reboots` is refused.

### What an attacker who runs as you can do

A program that runs as you is not shut out by any of this, only by not running as you. How far it gets:

- **In the same terminal session** as an unlock (something you started there yourself, not through xless: a background job
  of that shell, a daemon that stayed in its session, `npm install` by hand), it can do what your next command there can:
  run xless, or ask the agent itself, while it holds something.
- **In any other session, as a native build's code is,** the agent refuses it. What it can still do is what it could
  before there was an agent, held unlock or not: get into a granted session through something that is in it or drives it
  (type into that terminal with `tmux send-keys`, terminal automation or, on macOS, an accessibility permission; attach to
  your shell with `ptrace`, where the system allows it: Linux with `kernel.yama.ptrace_scope=0`, or as root), read what
  you type from the terminal's device, or replace the `xless` you run and your shell's startup files.
- It can always **drop** what is held: `xless lock` needs no grant, and it can kill the agent. That costs you a passphrase,
  nothing else.
- **With the disk only**, it has the sealed store, and needs the passphrase.

So the agent and the sessions keep a build from helping itself to an unlock; they are no sandbox. Run builds you do not
trust in Docker, or where nothing is held.

### Asking for nothing: `--no-input`

Every command takes `--no-input` (or `XLESS_NO_INPUT=1`, which the xless processes of a script inherit). Where it would
ask for a passphrase, a sign-in, a code, a choice or a confirmation, it stops at once with `[input] …`, the fix, and exit
code **23**, whatever else it was doing: no prompt goes around it (one gate stands before all of them, and a test runs every
command of xless against it, in a terminal). A credential helper is started without a terminal or a display then, and
stopped after 20 seconds. `xless auth status --json` says beforehand what is held and until when
([fields](apple-account.md#xless-auth)).

### What Apple decides

- `xless auth logout` forgets the kept session on this machine. It does not sign you out at Apple: the cookies stay
  valid on Apple's side until Apple expires them. If you think a session leaked, change the Apple ID's password.
- A session is kept for no longer than Apple's own session cookie says it lives, when it says so. How long Apple really
  accepts a session is **not known**: it is undocumented and xless has not measured it. When Apple refuses a kept session
  before its time, the command says so and signs in again for the rest of it, with the password only where Apple still
  trusts this device (its `DES…` cookie is kept with the session for that) and with a code when Apple asks for one.
- A kept session that cannot be opened (expired, altered, half gone) is dropped and treated as none.

## Process hardening

- **Core dumps off.** Once a command reads a secret (a sign-in, an API key, a signing key; any value `Secrets` hands
  out), its core file limit is set to zero for the rest of the command and the tools it runs, and on Linux the process
  is marked non-dumpable, so another process of yours cannot attach to it (ptrace) or read `/proc/<pid>/mem`.
- **Zeroed buffers where Swift allows.** The Apple ID password, downloaded `.p8` keys and store entries are held in a
  buffer that is zeroed when released and never prints. Copies that Swift and Foundation make on their own (PEM text
  handed to the crypto library, HTTP headers, JSON bodies, environment variables) cannot be zeroed; they are kept short
  and local.
- **Scrubbed child environments.** Every tool xless runs gets an environment without the secret variables
  (`ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_P8`, `XLESS_DIST_KEY`, `XLESS_DEVID_KEY`, `XLESS_INSTALLER_KEY`,
  `XLESS_DEMO_PASSWORD`, every other name the run reads a secret from, such as xless.yml's or app.yml's
  `passwordSecret`, and each one's `_FILE` form), with `XLESS_NO_SECRET_STORE=1`; overlays may not set them. rcodesign, which signs and
  notarizes, gets the keys it needs as files, mode 0600, in a fresh 0700 directory of the temporary directory
  (`$TMPDIR`, else `/tmp`), removed when the call ends: point `TMPDIR` at a tmpfs if that directory is on a disk you
  worry about.
- **Tools start in a POSIX session of their own and an empty session keyring** (see
  [below](#the-build-and-your-secrets)), without a file of xless's open and with no terminal as their standard input
  (their output may be one, and code that runs as you can open its device), and xless makes itself non-dumpable before it
  starts one, so the tool cannot attach to xless or read its memory or environment (on macOS that is the signature's
  work: [the table](#linux-and-macos)).
- **`--verbose` traces are redacted** so you can paste them into an issue: the `Authorization` header, cookies, any
  header named like an auth, token, secret, session, password, CSRF or signature header, every query string but the
  App Store Connect API's own (so a presigned upload address's signature never shows), the SRP exchange's values, and
  any JSON or form field named `key` or like a password, passphrase, secret, token, private key, API key, cookie,
  session or security code read `<redacted>`; a body that is neither JSON nor a form (a PEM, a certificate, an
  upload) shows only its size.
  A secret xless sends in a body (a demo account's password) is hidden from the rest of the trace too, and scrubbed
  from Apple's error messages.
- **Errors never contain a secret.** A failed unlock, a refused key or a broken store entry says what failed and what
  to do, never part of the value.

### Linux and macOS

What protects xless's memory and what it holds, on each system:

| Against | Linux | macOS, a release | macOS, a build of your own |
|---|---|---|---|
| A core dump on disk | core limit 0, non-dumpable | core limit 0 | core limit 0 |
| Another process of yours attaching to a command or reading its memory | non-dumpable from the first secret, and before the first tool starts | the hardened runtime, always: macOS refuses debuggers | nothing of xless's: a debugger you run may attach |
| The same, to the agent | non-dumpable from its start | the hardened runtime and `PT_DENY_ATTACH` | `PT_DENY_ATTACH` (no debugger; a program with a debugger's rights to the task port still) |
| Another process of yours reading a command's environment | non-dumpable: `/proc/<pid>/environ` is refused | the signature's `restrict` flag: macOS hides it (`ps -E`) | nothing: `ps -E` shows it |
| A library put into xless (`LD_PRELOAD`, `DYLD_INSERT_LIBRARIES`) | a release is static and loads none; a build of your own does | ignored | not ignored |
| Held secrets in swap | `mlock`, where the limit allows; never for the Swift heap | the same; macOS encrypts its swap | the same |
| Held secrets in a forked child | `MADV_DONTFORK` | `VM_INHERIT_NONE` | `VM_INHERIT_NONE` |
| Held secrets in a core dump | `MADV_DONTDUMP` | no dumps | no dumps |
| A build's tool asking the agent | POSIX session of its own (rule 2) | the same, and the program, by file and code hash (rule 3) | the same, where rule 3 does not keep out a library put into xless |
| Who speaks to the agent | pidfd and `SCM_CREDENTIALS` | audit token, at the first message and before each answer | the same |
| A build's tool reading the kernel keyring | an empty session keyring | there is no keyring | there is no keyring |
| The machine sleeps | dropped when it wakes | the same | the same |
| The screen is locked | your locker runs `xless lock` | dropped within 2 seconds | the same |

What none of them does: root, and on macOS a program you gave the rights of a debugger or of accessibility to where the
table says so, is not shut out; a secret variable you export is in your shell's environment, which is not xless's to hide
(on macOS `ps -E` shows the environment of your other programs to all your processes, as `/proc` does on Linux).

A **release for macOS is signed ad hoc**: the signature carries the hardened runtime and the `restrict` flag, and is the
hash of that build. It names no one, and is not notarized by Apple: it is no proof of who made it. That is what the
checksum (which the installer always checks) and the provenance attestation are for
([how to check a download](../README.md#install)). The installer needs no such check of macOS's: `curl` and `tar` set no
quarantine mark, so Gatekeeper is not asked. A tarball downloaded in a browser is marked, and macOS refuses an xless
unpacked from it with the Finder: use the install line.

On macOS a path can be spelled in more than one way (upper and lower case, Unicode forms, `/private/tmp` and `/tmp`,
`/System/Volumes/Data`). Where xless refuses a mount or looks whether one path is in another, it asks the kernel which file it
is, not how it is written. What the kernel does not tell (a folder that you may not search, on either system) is not taken for
one that is not there: the run stops.

## The build and your secrets

An app's build runs code you did not write. What that code can reach depends on how it is built:

- **An overlay app (Tauri, Cargo, React Native: `xless run --docker --config`)** builds in three containers. The build
  container (step 2) gets no secret and no secret file, and is the only one that runs in an image with the app's
  toolchains (the kit, or an image you name); the next-build and signing containers run in the xless image, where no
  Node, Rust, Ruby or Hermes is. The store is in no container. Before the first step, the
  xless on your machine writes the secrets each other step needs to a tmpfs (`$XDG_RUNTIME_DIR/xless/<random>/`,
  0700 and 0600), mounts each step's directory read-only into that step's container only, and removes it when that
  container ends; without a tmpfs the run refuses unless `--allow-disk-secrets`
  ([secrets.md](secrets.md#xless-run-and-docker-builds)). Docker's default seccomp profile also keeps containers out
  of the kernel keyring.
- **A project directory (`xless run <dir>`)** is one `xless ship`: build, sign and upload in one process (one
  container with `--docker`, which gets the secrets the run needs). xless keeps what it holds out of the build tools'
  reach: they start without the secret variables (and without any name of your own the run reads a secret from),
  in a POSIX session of their own, which [the xless agent refuses](#who-may-use-what-the-agent-holds), and a fresh, empty
  session keyring, so a held store unlock or a kept Apple ID session is not theirs to read, and with
  `XLESS_NO_SECRET_STORE=1`, so an xless they run never opens the store. Before it starts a tool, xless
  makes itself non-dumpable: the tool cannot attach to it or read its memory or its environment. Natively the build
  still runs as you: its SwiftPM plugins and macros can read your files, including the key files a `_FILE` variable
  names (the store keeps keys sealed on disk), and the environment of your shell, or of any other process of yours
  (`xless run` itself is not one: it is non-dumpable too, and a macOS release hides its environment) that exported a
  secret variable (`/proc/<pid>/environ`; `ps -E` on macOS): keep keys in the store rather than in exported variables.
- **A project directory on a Mac, natively**, is two `xless ship`: the first builds, without a secret variable and unable to open
  the store, and the second signs, packages and uploads what it left, in `/`, with the secrets. Each takes
  only the xless.yml that the run read when it began, by its SHA-256, and the run looks at it between them too: when it is another
  one, nothing is signed. (What it says is compared; it may be a link, if it was one.) More is in
  [With an installed Xcode](#with-an-installed-xcode).

**Which image a container runs in.** An image with toolchains of other languages never holds a secret. The table is
each step of `xless run --docker`:

| | Next build number (API key) | Build (no secret) | Sign and upload (the secrets) |
|---|---|---|---|
| Tauri, Cargo | xless image | `tauri` kit, or your `image:` | xless image |
| React Native, Expo | xless image | `react-native` kit, or your `image:` | xless image |
| `xless.yml`, no `image:` | (none) | xless image, in the one container with the secrets | the same container |
| `xless.yml` with `image:` or `XLESS_IMAGE` | (none) | your image, without a secret | xless image |

`XLESS_SIGN_IMAGE`, from before, may only name the xless image itself: anything with more in it is refused. A container is
started from an image on your machine (`docker run --pull=never`), by the ID of the one that was checked, so a tag that moves
during a run changes nothing, and a name that is not on your machine stops the run instead of asking a registry. (A kit's
`docker build` starts `FROM` the local image by its name; what it made is checked, layers and all, before it is used.)
xless checks an image's labels (its Xcode, architecture and xless) and that an image of your own starts with the
layers of the xless image. That finds an image left behind by an upgrade or built on the wrong one; it is not a proof of
what the image holds, since whoever can write to your Docker can make one that passes. Only the Dockerfiles shipped with
xless are ever built by a run, from its own share directory, with no secret in the context, an argument or a layer.

**What the build decides in the step that signs.** The app, its Info.plists (with the version and the build number), its
extensions and its entitlements are the build's: the step with the secrets signs and uploads what the build left, in the work
copy (an overlay) or in the project (`.xless/`, and the entitlements files that xless.yml names). So are the capabilities that
those entitlements need, which signing turns on for the bundle ID on your account unless `--no-provisioning-updates`
(`provisioningUpdates: false`) is set. What it signs the app *as* is not: the team, the app's bundle ID, the distribution,
whether the account may be changed, and the app that the upload goes to come from the configuration.

- What it signs and packages is looked at as a tree first, and it is a copy of the app that is looked at and signed: directories,
  files, and links that stay in it. A link that leads out of the app, a pipe or a device, a name with a control character (a line
  break), or a path that rcodesign would read as an option, is refused. Of the dSYMs only those of the app's own binaries are packed, and
  a record of the build that is a link, no file, or huge is not read.
- An overlay, and the app's source, are mounted read-only into every container.
- A project directory is the build's to write. Its containers get the xless.yml that was read when the run began, read-only, from
  a directory of the run's own outside of the project (`~/.cache/xless/run/<random>/`), over the one in the project. (It goes with
  the run. Of a run that was killed outright, the next run on that project removes it; it holds no secret.) The container that
  signs runs in `/`, not in the project. When xless.yml in the project has another text after the build, the run says so (on a
  Mac's file system a build can write it under another spelling of its name).
- Docker mounts over what a link names, which may be a file of the image. So a run in containers refuses a project whose xless.yml
  is a link, and, when there is an image of your own for the build, stops before the container with the secrets if the build left
  anything else than a file in its place.
- Signing tools read no configuration of the directory they run in: rcodesign is started with `-C /dev/null`, in `/`. Where the
  steps with the secrets list the files of an overlay's source (a Cargo or React Native one), git reads the index and starts none
  of the programs that the repository's configuration may name for that: the file system monitor is off (`core.fsmonitor`), and
  nothing is fetched (a partial clone fetches what it lacks when it is listed, over `core.sshCommand` or a helper). So
  fetch what a partial clone lacks before the run (`git ls-files` in it does): without it the listing fails, or an older git leaves
  those files out. This holds natively too.
- Natively the build runs as you, and can write what you can: the overlay and xless.yml as well. What is above is of the
  containers (but on a Mac a run signs with the xless.yml that it read first, or not at all).

When you do not fully trust the code of an `xless.yml` project, name an image of your own for its build (the last line of the
table), or keep the signing in a second run, so no build code runs while a key is in use:

```sh
export XLESS_BUILD_NUMBER=$(( $(date +%s) / 60 ))
xless run ~/MyApp --to finalize       # build only: reads no secret, opens no store
xless run ~/MyApp --from sign         # sign and upload what it built: no build code runs
```

The second run reads the project's files as the first left them. In containers (`--docker`) the first one's build has xless.yml
read-only, and the run says when it is another one afterwards; natively nothing keeps a build from changing it. Look at the
project (`git diff`, `git status`) before the second, if you would not let its build code choose the team and the bundle ID.

### With an installed Xcode

On a Mac, xless builds an `xless.yml` project with the Xcode that is installed
([native-install.md](native-install.md#on-a-mac)). It runs Apple's command-line programs (`swift`, `actool`, `ibtool`,
`install_name_tool`, `codesign`…) where they are, as programs. It links no framework of Xcode's, calls no private interface, and
copies nothing of Xcode's into an image, a cache or a release; an app's own build products stay in the project's `.xless/`.

- **Which Xcode is used.** Only one with a signature of Apple's: the app's, as the App Store or developer.apple.com ship it, and
  that of each program in it that xless starts (`swift`, `actool`, `ibtool`, `xcodebuild`, `install_name_tool`) or that those are
  known to start (`swift-build`, `clang`, `ld`, `swift-plugin-server`, the build service…). Each has to be a program signed by
  Apple, not a script, and under its own name where xless knows it. Those programs and the top directories of their libraries
  (`usr/bin`, `usr/lib`, `usr/libexec`, `Library/Xcode`, `SharedFrameworks` and `Frameworks` themselves, not what is in them), with
  every directory from `/` to them, have to belong to root or to you and to be writable by nobody else but the administrators of
  the Mac (the groups `wheel` and `admin`), by their mode and their access control list, on a volume that keeps owners. (A disk
  that ignores them shows every file as yours.) `DEVELOPER_DIR` may choose an Xcode, not go around the checks. Every command that
  builds makes them, before it starts anything of that Xcode, so macOS asks you nothing about a program that is refused.
- **What that does not cover.** The other files of Xcode: the SDKs and platforms, the headers, modules and libraries in them, and
  the libraries that the programs load, are not compared with a signature (that takes minutes), and of the SDKs and platforms
  nobody looks at who can write them. So a genuine Xcode to which somebody *added* something there passes, as XcodeGhost
  was spread: install Xcode from the App Store or from developer.apple.com yourself. Some of what is there is code that the build
  runs: the compiler plugins of a platform or of the toolchain (`usr/lib/swift/host/plugins`). In an Xcode that you unpacked from a
  `.xip`, some of these directories can be written by the group `staff`, which is every user of the Mac: on a Mac with several, any
  of them can so run code in your builds. `chmod -R go-w <Xcode.app>` ends that. And what belongs to you, every program of yours
  can change, also between the check and the build; xless itself is no different there.
- **The build runs as you**, as natively on Linux: its code can read your files. SwiftPM's own sandbox stays on
  (`sandbox-exec`): a package's manifest, and the plugins and tools that a build runs, write only to the directories of the build and
  the temporary ones (not into the project, nor into your home directory) and reach no network. A project that is itself in a
  temporary directory (`/tmp`, `$TMPDIR`) they can write. It does not keep them from
  *reading* your files, and the compilers and the linker are not in it, nor what flags make them do (`unsafeFlags`, in a package that
  may have them).
- **xless adds no sandbox of its own.** `sandbox-exec` is deprecated and its profile language is not documented. A profile that
  lets a compiler, Xcode's services and an unknown package work would have to allow reading almost everything, and a sandbox
  cannot be put into SwiftPM's (it would have to be turned off). What keeps the secrets from a build is that they come after it:
  the process that builds never has them, and the store stays sealed. What such code starts can outlive the
  build, in that sandbox or out of it, and do what any program of yours can: read the signer's key file while it is there, for one. When you do not trust a project's code, build it with `--docker`, which shows it
  nothing of yours but the project.
- **The signing key never enters a keychain.** `codesign` takes a key from a keychain only: in yours, or in a temporary one, any
  program of yours can ask to sign with it while it is unlocked. So xless signs with rcodesign on a Mac too, whose key file is
  readable by you only, is written after the build and is removed when the signature is made. rcodesign's release is pinned by
  SHA-256 in `versions.env`; it is fetched by the first command that signs, before that reads a secret, or before the build of a run
  that will sign. It is kept, with the archive that was fetched, in a directory that only you can enter. Each command that signs
  compares the archive with the pin and the program with the archive, stops where somebody else could write to the place, and starts
  that file: an rcodesign on your `PATH` is not used. The app store's `.pkg`, disk images, notarization and uploads are xless's own
  as on Linux.
- A simulator build is signed ad hoc with `/usr/bin/codesign --sign -`: no identity, no key, no keychain.

Where the kernel keyring is unavailable (macOS, a container whose seccomp profile blocks it) there is nothing in it to
hide; where it is available but a tool cannot be given an empty keyring, xless does not start the tool. Nor does it start
one that cannot be given a session of its own.

## What goes to which host

Every request is HTTPS. xless sends no telemetry.

| Host | What xless sends | Credential | Used by |
|---|---|---|---|
| `api.appstoreconnect.apple.com` | The documented App Store Connect API (`/v1`, `/v2`, `/v3`) | API key (a fresh JWT; the `.p8` itself never leaves the machine) | every account command that has an API, `xless api`, `sign`, `upload`, TestFlight delivery, `next-build`, `store pull`/`push`, `release`, `iap`, `subscriptions`, `sandbox-testers`, `reviews`, `reports`, `webhooks`, `provision` |
| The upload and download addresses App Store Connect hands out | The bytes of builds, screenshots, previews and documents (`PUT` to the presigned addresses an upload reservation returns); `store pull` downloads media from the addresses Apple lists | none: the address carries Apple's own authorization; xless adds no header | `upload`, `store push`, `store pull` |
| Apple's notary service, through rcodesign | The app or disk image to notarize | API key (a JWT rcodesign makes from the key file) | macOS `package` |
| `idmsa.apple.com` | The Apple ID sign-in: SRP-6a (the password itself is never sent, only proofs derived from it), the two-factor code | the Apple ID | `xless auth login` and every web-session command, `xless xcode download` |
| `appstoreconnect.apple.com` (`/olympus/v1`, `/iris/v1`) | App Store Connect's own web interface: session and team, app record creation, API keys, App Privacy, agreements check | Apple ID session cookies | the [web-session commands](#the-apple-id-web-session) |
| `developer.apple.com` (`/services-account/…`) | The developer portal's web interface: teams, app groups, iCloud containers, assigning them to bundle IDs, auth keys; the Xcode download list | Apple ID session cookies | the [web-session commands](#the-apple-id-web-session), `xless xcode download` |
| `developerservices2.apple.com`, `download.developer.apple.com` | The `.xip` download | Apple ID session cookies | `xless xcode download` only ([xcode-download.md](xcode-download.md)) |
| `download.swift.org`, `github.com` | Downloads of pinned tools, checked by SHA-256 | none | `xless setup`, the installer; on a Mac the first command that signs (rcodesign) ([native-install.md](native-install.md)) |

Cookies are sent only to hosts within the domain that set them, and no other header of a request follows a redirect
to another host (but `Accept`, `User-Agent` and `Range`). The App Store
Connect API key's JWT goes only on requests xless addresses to `api.appstoreconnect.apple.com` (and, made by
rcodesign, to the notary service); upload and download addresses get no credential. xless follows every redirect
itself (URLSession never does it for xless, since it would resend every header), at most 10 hops: the `Authorization`
header stays with the origin (scheme, host and port) it was made for, a request's body is never sent on to another
origin, and nothing goes from HTTPS to plain HTTP.

## The Apple ID web session

Some of what an account needs has no documented API: creating App Store Connect API keys, the app record, App Privacy
answers, app groups and iCloud containers, and auth keys (APNs, Sign in with Apple, DeviceCheck, MusicKit). For those,
xless uses your Apple ID and the web interfaces Apple's own pages call, as fastlane, the open-source App Store Connect
CLI and RevenueCat's CLI do ([research/asc-account-coverage.md](research/asc-account-coverage.md) lists every endpoint
and where it comes from). They are undocumented: Apple can change them without notice, and xless's errors then name
the interface and the page to use in a browser meanwhile.

| Command | Why it needs the web session |
|---|---|
| `xless auth login`, `xless team list` | to sign in, and to list the teams (the API key belongs to one team) |
| `xless auth api-key create`, `list`, `revoke` | the API cannot create, list or revoke its own keys (`import` needs no Apple ID) |
| `xless apps create` | the API reads and updates app records but cannot create them |
| `xless store privacy pull`, `push`; the privacy part of `xless store push` | the API has no App Privacy |
| `xless app-groups …`, `xless icloud-containers …` | the API can neither create them nor assign them to a bundle ID |
| `xless keys …` | the API has no auth keys |
| `xless provision apply` (and `plan`, with a kept session only) | for the app groups, containers, APNs key, app record and App Privacy it plans |
| `xless release submit` (a kept session only, never a sign-in) | to check that the App Privacy answers are published |
| `xless xcode download` | Apple's developer downloads ([xcode-download.md](xcode-download.md)) |

Each of these says so in its `--help`. After the first setup, only creating apps, keys and App Privacy answers needs it:
everything else a release needs runs on the API key.

- The sign-in is Apple's own SRP-6a and two-factor code, typed on the terminal; never read from a pipe, a file, an
  argument or the environment. Accounts with the old two-step verification are refused.
- With a security key, the key signs Apple's challenge for `apple.com` (origin `https://idmsa.apple.com`), and xless
  sends that assertion once to idmsa.apple.com, never again. The key is asked only for the credentials Apple names for
  this Apple ID (first silently, to pick the key that holds one), and for no other relying party, so a touch never
  signs for another site or account. The key's PIN, when the key wants one, is read like the password, sent to the key
  only (encrypted with the FIDO2 PIN protocol), and wiped after use. `--verbose` traces hide the challenge, the
  credential IDs, the user handle and the signature.
- The cookies stay in this process's memory and are forgotten when it ends, unless `--keep` ([above](#holding-an-unlock-off-by-default-in-memory)).
- xless never accepts legal terms: when Apple wants an agreement accepted, the command stops and names the page.

## Wiping everything

Removing the store removes xless's only copy of the keys it created, and cannot be undone. **First** revoke at Apple
what you no longer use: `xless auth api-key revoke <KEY_ID>`, `xless certs revoke <ID>` (not a Developer ID
certificate you shipped with: the apps it signed stop opening), `xless keys revoke <ID>` (each asks first), and export
what you keep. A key Apple still accepts stays dangerous wherever a copy of it is: an old backup of the store opens
with the passphrase it had then. Then:

```sh
xless lock                               # forget everything held, a session saved across reboots included
                                         # (Apple's side of a session expires on its own)
rm -rf ~/.local/share/xless/vault        # the secret store itself ($XDG_DATA_HOME/xless/vault): every key in it is gone
                                         # (with a credential helper: xless secrets list, then xless secrets rm each entry)
rm -f ~/.config/xless/config.yml         # the default team and the unlock times (preferences, not secrets)
```

The agent ends with the terminals it serves; the kernel keyring's keys also go when the login session's keyring is
released (once no process of that session is left). Neither survives a reboot.

Files xless never deletes for you: exported keys (`xless secrets export`, `sign bootstrap --out`) and the files you
imported from when you declined the offer to delete them. CI keeps its secrets in its own secret store.

## Reporting a problem

A way to read a secret that this page says xless protects is a security bug. Do not put the details in a public issue:
open one that only asks the maintainer for a private channel, and send the details there.
