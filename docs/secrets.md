# The secret store (`xless secrets`)

On your own machine, xless keeps Apple keys in an encrypted file rather than in plain `.p8` and `.pem` files, or in
your desktop keyring or pass through a [credential helper](#keeping-the-secrets-in-your-keyring-or-pass-credential-helpers).
When a command needs a secret that the environment does not provide, it reads it from this store. CI keeps using environment
variables and `_FILE` variables ([signing-and-testflight.md](signing-and-testflight.md#secrets)), and never opens the
store.

```sh
xless secrets init                                   # asks a new passphrase, twice
xless secrets import ASC_KEY_P8 --file AuthKey_ABC123DEFG.p8 --issuer-id 69a6de7e-...
xless secrets import XLESS_DIST_KEY --file dist-key.pem
xless secrets list                                   # names, kinds and IDs; never a value
xless ship --platform ios                            # asks the passphrase once, when it needs a key
```

## Commands

| Command | What it does |
|---|---|
| `init` | Creates the store and asks its passphrase twice (at least 8 characters). The passphrase cannot be recovered. |
| `status` | Where the store is, how many entries it has, and whether it is unlocked. |
| `list` | Every entry's name, kind, team, key ID, issuer ID, certificate ID, certificate type, API key role, auth key services, creation and expiry dates. No passphrase needed. |
| `import <name> --file <path>` | Adds the file's content. `--kind` (default: from the name), `--team-id`, `--key-id`, `--issuer-id`, `--certificate-id`, `--expires YYYY-MM-DD`, `--role` (an API key's), `--services` (an auth key's: `apns,siwa`) record what it is. Then offers to delete the file. |
| `export <name> --out <path>` | Writes the secret to a new file (mode 0600; an existing file is never overwritten). That copy is in clear: delete it once used. |
| `rm <name>` | Removes an entry, after asking (`--yes` skips the question). It cannot be recovered. |
| `unlock --remember 30m` | Keeps the store unlocked for that long, or without a duration for the default time: the same as [`xless unlock`](#staying-unlocked). |
| `lock` | Forgets the store's unlock now (`xless lock` forgets everything held). |
| `passwd` | Changes the passphrase. |

Kinds: `asc-api-key` (an App Store Connect API key: `.p8`, key ID and issuer ID required), `signing-key` (an RSA
private key PEM from `xless sign bootstrap` or `xless certs create`), `auth-key` (an APNs, Sign in with Apple, DeviceCheck or MusicKit `.p8`),
`password` and `generic`. Keys are checked when imported: a `.p8` must be a P-256 private key, a signing key an RSA one.
A file named `AuthKey_<KEY_ID>.p8`, as Apple names them, gives the key ID. One name is xless's own,
`xless-apple-session` (kind `apple-session`): the Apple ID session that `xless auth login --across-reboots` saves
([security.md](security.md#across-reboots)).

[`xless auth api-key create`](apple-account.md#xless-auth-api-key) puts a new App Store Connect API key straight into
the store (as `ASC_KEY_P8@<TEAM_ID>`, with its key ID, issuer ID, team and role), and `xless auth api-key import`
checks a `.p8` against App Store Connect before storing it. Like every recorded field, the role is part of what the
seal authenticates ([the file](#the-file)).

[`xless certs create`](apple-account.md#xless-certs) and `xless sign bootstrap` generate a certificate's private key
and seal it into the store before the certificate is requested (as `XLESS_DIST_KEY`, `XLESS_DEVID_KEY`,
`XLESS_INSTALLER_KEY` or `XLESS_<TYPE>_KEY`, with `@<TEAM_ID>` when a team is selected), then record the certificate's
ID, type and expiry with it.

[`xless keys create`](apple-account.md#xless-keys) puts a new APNs, Sign in with Apple, DeviceCheck or MusicKit key
straight into the store (as `XLESS_APNS_KEY@<TEAM_ID>`, `XLESS_SIWA_KEY`, `XLESS_DEVICECHECK_KEY`, `XLESS_MUSICKIT_KEY`
or `XLESS_AUTH_KEY`, kind `auth-key`, with its key ID, team and services); `xless keys revoke` removes it again.

[`xless webhooks create`](apple-account.md#xless-webhooks) makes a webhook's signing secret and keeps it in the store
as `XLESS_WEBHOOK_SECRET.<webhook ID>` (with `@<TEAM_ID>` when a team is selected, kind `generic`); `xless webhooks
delete` removes it again. `xless secrets export <entry> --out <file>` hands it to the server that checks the
signatures.

The App Review demo account's password, which [`xless store push`](appstore-manifest.md#xless-store-push) sends, is the
secret `app.yml` names (`review.demoAccount.passwordSecret`, `XLESS_DEMO_PASSWORD` by default):
`xless secrets import XLESS_DEMO_PASSWORD --file demo-password.txt` stores it as a `password`.

## How the pipeline finds a secret

For each secret, xless looks at `NAME`, then at the file named by `NAME_FILE`, then at the store's entry `NAME`. The
store is only opened when it has such an entry, so a command that needs no key never asks the passphrase.

| Secret | Store entry |
|---|---|
| `ASC_KEY_P8` | `ASC_KEY_P8` (kind `asc-api-key`) |
| `ASC_KEY_ID`, `ASC_ISSUER_ID` | the key ID and issuer ID recorded with `ASC_KEY_P8` |
| `XLESS_DIST_KEY`, `XLESS_DEVID_KEY`, `XLESS_INSTALLER_KEY` | the entry of the same name (kind `signing-key`) |
| `XLESS_DEMO_PASSWORD` (or the name in `passwordSecret`) | the entry of the same name (kind `password`) |

With several teams, name the entries `NAME@<TEAM_ID>` (for example `XLESS_DIST_KEY@ABCDE12345`) and record the team
with `--team-id`. While only one entry stands for a name, it is used whatever its suffix; with several, xless stops and
names them. A project's run (`xless ship`, the stage commands, `next-build`, `xless run`) prefers the entries of the
project's `teamID`: that team's (`NAME@<TEAM_ID>`, or recorded with `--team-id`), else one recorded for no team;
another team's entry is never used for it. (Account commands given `--team`, such as `sign bootstrap`, are stricter: they take
only entries recorded for that team.)

The commands that run the pipeline in this process read the store: `xless ship` and the stage commands (`sign`,
`package`, `upload`, …), `sign bootstrap` and `next-build`, each asking the passphrase at most once.

### `xless run` and Docker builds

`xless run` ([signing-and-testflight.md](signing-and-testflight.md#one-command-testflight)) needs no `testflight.env` once the
keys are in the store. A secret whose `NAME_FILE` is set (in the environment or `testflight.env`, which still wins)
comes from that file; every other one the run needs comes from the store. The App Store Connect key and its two IDs
come from one place: set all of them, or none (`ASC_KEY_ID` without `ASC_KEY_P8_FILE` is refused).

- **Natively**, xless reads the store itself. The script first checks, from the names alone (no passphrase), that
  the store holds every secret the run needs, so a missing key stops the run before the build. Then it asks the
  passphrase, once, before the first step and saying for which secrets, and every step of the run has the store: the run
  is a script in [a session of its own](#one-unlock-for-a-script), which ends with it. (A dry run, and a run whose
  secrets all come from files, ask nothing.) The build gets none of it: with `--config` its step runs with
  `XLESS_NO_SECRET_STORE=1` and is not told of the session, and it leaves the session keyring, so the build code it
  runs cannot reach a held unlock. What that means for the store while the build runs, and how to have nothing held then:
  [security.md](security.md#while-xless-run-builds). Where nothing can be held, a note says why and each step asks by
  itself. (Every tool any xless runs, in a project directory's single process too,
  starts in a POSIX session of its own and an empty session keyring, with `XLESS_NO_SECRET_STORE=1`:
  [security.md](security.md#the-build-and-your-secrets).) This keeps xless itself from handing out a secret there; it
  is no sandbox: code that runs on your machine as you can read your files, which is why the overlays build in Docker.
- **With `--docker`**, the store is not in any container. Before the first step, the xless on your machine (asking the
  passphrase once) writes the secrets each container needs into a fresh `$XDG_RUNTIME_DIR/xless/<random>/` (a tmpfs on
  systemd hosts: never on disk), one directory per container (step 1 gets the App Store Connect key; step 3, or the
  project's one container, that key and the signing keys; the macOS App-Store ship its own two keys), directories 0700
  and files 0600. Each directory is mounted read-only into its container only (`/secrets/store`, with
  `NAME_FILE=/secrets/store/NAME`) and removed when that container ends; the rest goes when the run ends, on an error
  and when it is stopped (Ctrl-C, SIGTERM, SIGHUP). The build container (step 2) never sees them, and the run refuses
  to start if they would be inside a folder mounted into it. Without a tmpfs (no `XDG_RUNTIME_DIR`, as on macOS, or
  one on a disk) the run refuses, unless you pass `--allow-disk-secrets`: then they go to
  `~/.cache/xless/secrets/<random>/` (under your home directory, which Colima and Docker Desktop share with their VM)
  for the length of the run. The script runs this as `xless secrets materialize` (not listed in `--help`).
- **The TestFlight demo account's password** (a run that uploads with `testflight.external.review.demoAccount` in
  [xless.yml](xless-yml.md#testflight) or the overlay) goes to the container that uploads only: step 3, the project's
  one container, or the macOS App-Store ship; never to step 1 or the build. Its secret is `passwordSecret`
  (`XLESS_DEMO_PASSWORD` by default), a name of your own if you like (`NAME@<TEAM_ID>` too; not a key's or token's,
  nor a variable the system or xless uses, such as `PATH`, `HOME`, `ENV` or `XLESS_*`); the xless on your machine
  reads it from the configuration (`xless secrets named-by`, not listed in `--help`). `NAME_FILE` wins, mounted
  read-only into that container; otherwise it comes from the store like the keys, from an entry of kind `password`.
  Apple never gives the password back, so xless sends it only when the demo account is new, renamed or newly required:
  a store without it stops nothing up front (the run says so, and asks the passphrase only if the store holds it or
  something else the run needs), and only an upload that must send it fails. A demo account with `required: false` is
  never sent a password, and nothing is given. Without xless on your machine (all secrets as files), only
  `XLESS_DEMO_PASSWORD_FILE` is passed: the configuration's own `passwordSecret` cannot be read there.

CI keeps using the environment and `_FILE` variables, and never opens the store.

The passphrase is read from the terminal (`/dev/tty`) only, never from a pipe, a file, an argument or the
environment. A command that needs the store when it is locked and has no terminal (a script, `nohup`) stops with an
error that says so; with `--no-input` it stops with exit code 23 even where there is one
([security.md](security.md#asking-for-nothing---no-input)).

## Staying unlocked

A command asks the passphrase only when it reads or writes a secret, never to list or check names, and once however many
it needs (the App Store Connect API key and a new certificate's key, say). It says which command asks, what for and how long
it is kept: until the command ends, unless you keep it. After the passphrase, or a sign-in to Apple, xless offers that
with one question:

```text
xless provision apply opens the secret store (the secret ASC_KEY_ID). The passphrase is asked once for this command, and forgotten when it ends unless you keep it.
Secret store passphrase:
The next commands of this terminal need not ask again: the secret store can stay unlocked, and the Apple ID session of a sign-in be kept, for 8 h (2 h without use). `xless lock` ends it.
Keep both for this terminal? [y/N]
```

A yes covers both: the next commands of this terminal ask neither the passphrase nor a sign-in, for that long at most. It
is of this terminal: another one is asked by itself, also when it shares the unlock.
Enter, or anything else, keeps nothing, and what was typed before the question was shown is no answer to it (nor to any
other question of xless's). It is not asked in CI, with `--no-input`, inside `xless session` or without a
terminal, nor where nothing can be held. To be asked no more, say it in `~/.config/xless/config.yml`:

```yaml
unlock: { keep: ask }       # the default; always: keep both without the question (it says so); never: neither
```

`xless unlock` keeps the store unlocked beforehand (and asks whether a sign-in is to be kept too, once one is needed):

```sh
xless unlock                # the passphrase, once: the store stays unlocked for this terminal
xless unlock --for 2d       # … for two days; --idle 4h: … and 4 h without use
xless run . && xless release submit
xless auth status           # what is held, where, until when (--json for a script)
xless lock                  # forget everything held, now
```

- **How long:** 8 hours and at most 2 hours without use, unless you say otherwise; never more than 7 days. Set your own
  times, and a lower maximum, in `~/.config/xless/config.yml`:

  ```yaml
  unlock: { duration: 8h, idle: 2h, maximum: 7d }
  ```
- **Where:** in memory only, in the xless agent (Linux and macOS). Where none can run (xless says why: started without a
  shell, as by `ssh host xless …`, Linux before 5.3, a container that blocks `pidfd_open`, or no place for its socket) the Linux kernel keyring keeps it, if it works, for an hour at most.
  There only that hour and `xless lock` in the same login end it: not a time without use (`--idle` is refused), a closed
  terminal, sleep or a locked screen.
  `--remember [<duration>]` on `unlock`, `init`, `import` and `export` does the same while it does its own work.
- **For whom:** the commands you run in the same terminal, and the scripts they are in. Another terminal shares it after an
  `xless unlock` of its own; cron jobs and services are not served. Closing the terminals, putting the
  machine to sleep and locking the screen (macOS) end what the agent holds; `passwd` and a replaced store end it
  everywhere. Other users, and the tools xless
  runs (the build's plugins and scripts, npm), never reach it, nor does a container. The whole model, what it does not stop, and how to
  lock with a Linux screen locker: [security.md](security.md#holding-an-unlock-off-by-default-in-memory).

### One unlock for a script
<a id="one-unlock-for-a-script"></a>

`xless session` runs a script whose xless commands ask for nothing: the passphrase once, before it starts, and with
`--sign-in` at most one sign-in (none when a session is kept and Apple still takes it).

```sh
xless session -- ./release.sh
xless session --sign-in -- sh -c 'xless provision apply --yes && xless run . && xless release submit'
```

What was typed for it is held by an xless agent of its own, which ends with the script: when the command returns, when
xless or the terminal goes away, on a signal (`SIGTERM` and `SIGHUP` are passed on to the script; Ctrl-C reaches it as
without xless), even when xless is killed outright. `xless lock`, sleep and (macOS) a locked screen end it sooner, and so
does the time of `unlock.duration` in config.yml (8 hours unless you lower it; a time without use does not): the script
runs on, and its next command that needs the store asks, or stops with `--no-input`. `xless auth status`, in any of your
terminals, shows the sessions that run: which command, what is held for it, until when. Where nothing can be held, it
stops before it asks for anything. The exit code is the script's. Nothing is offered inside, and a session in a
session asks nothing again. A store that was unlocked before stays so, for as long as it was. With `--no-input`, a locked
store stops it (exit 23) before the script starts; with a credential helper there is nothing to hold, and the script runs.

**Who else has it:** what `xless unlock` gives a terminal, for the time of the script: the xless commands that the script
and the programs it starts run in its POSIX session, and only those told of it (`XLESS_SESSION`, a socket's path, in the
script's environment; no secret). The tools that xless itself runs (compilers, SwiftPM plugins, npm, cargo, hooks) are in
sessions of their own and refused, told of it or not. A tool that **the script runs directly** (`npm install`, `make`) is in
the script's session, as it would be in your terminal's, and code it runs could run xless: keep those out of the script, or
run them before it. `xless run` uses the same for its own steps, and runs no code of the project itself.

## Keeping the secrets in your keyring or pass (credential helpers)

If you already keep secrets in a desktop keyring (GNOME Keyring, KWallet or KeePassXC, through the Secret Service) or
in [pass](https://www.passwordstore.org/), xless can keep its secrets there instead of in its own encrypted file. xless
is a static binary and does not link libsecret or GnuPG: it runs a small helper program, `xless-credential-<name>`,
which talks to your keyring. Choose it in `~/.config/xless/config.yml` (`$XDG_CONFIG_HOME/xless/config.yml`):

```yaml
secrets:
  backend: helper        # or vault, the default: the encrypted file described below
  helper: secret-tool    # runs xless-credential-secret-tool, found on PATH
```

xless ships two helpers in `share/xless/credential-helpers/` (`~/.local/share/xless/credential-helpers/` with the
default install prefix). Put the one you want on PATH:

```sh
ln -s ~/.local/share/xless/credential-helpers/xless-credential-secret-tool ~/.local/bin/   # needs secret-tool (libsecret-tools)
ln -s ~/.local/share/xless/credential-helpers/xless-credential-pass ~/.local/bin/          # needs pass
```

| Helper | Where each secret goes |
|---|---|
| `secret-tool` | One keyring item per secret, with the attributes `application=xless` and `xless-name=<NAME>`, labelled `xless <NAME> <its kind and IDs>`. A locked keyring asks to be unlocked in its own window. secret-tool takes values of less than 8 KiB (keys and passwords are far smaller); the helper refuses longer ones. |
| `pass` | `xless/<NAME>/secret` (the value) and `xless/<NAME>/username` (its kind and IDs), both encrypted to your pass key. GnuPG asks your key's passphrase through its agent; `export GPG_TTY=$(tty)` for a terminal prompt. `xless secrets list` reads every entry's `username`. |

Every `xless secrets` command works the same with a helper, and so does everything that reads or writes secrets
(`xless ship`, `xless run`, `xless auth api-key create`, `xless certs create`, `xless keys create`, `xless provision`,
`sign bootstrap`). A few have nothing to do: `init` checks that the helper answers, `unlock` and `lock` leave locking
to the keyring (`xless unlock` too), `--remember` is ignored, and `passwd` is refused (change the keyring's or the GnuPG key's password with
their own tools). Moving from the vault to a helper is done entry by entry: `xless secrets export <name> --out <file>`
with `backend: vault`, then `xless secrets import <name> --file <file> …` with `backend: helper`, then delete the file.

What xless does to keep the helper honest: it runs only `xless-credential-<name>` from an absolute directory on PATH,
and refuses it when the file, the directory it is in, or the PATH directory it was found in can be written by the group
or others, or belongs to someone other than you or root: whoever can change the helper can read every secret. (With a
umask of 002, as on distributions that give each user a group of their own, `~/.local/bin` is group-writable:
`chmod g-w ~/.local/bin`, or link the helper from a directory that is not. Keep the directories above it yours too.) The helper gets
only its verb as argument; its environment is cut down to what a keyring needs (`HOME`, `PATH`, the locale, `XDG_*`,
`DBUS_SESSION_BUS_ADDRESS`, `DISPLAY`, `WAYLAND_DISPLAY`, `XAUTHORITY`, `GNUPGHOME`, `GPG_TTY`, `PASSWORD_STORE_*`,
`TMPDIR`, `TERM`, `TZ`, `USER`, `LOGNAME`), never a secret variable, and it inherits no open file of xless's. Secrets
go only through its stdin and stdout pipes; xless reads at most 4 MiB of answer into memory it zeroes afterwards, and
stops the helper (and anything it started) after 120 seconds. Its stderr is xless's, so the keyring's or GnuPG's own
messages reach you; xless never quotes what a failed `get` or `store` printed. While it runs, the helper has the
terminal (when xless has it): it may prompt on `/dev/tty`, and Ctrl-C stops it. With a helper, the integrity of the names and IDs
is the keyring's.

Two xless commands writing through the helper at the same time take turns: each write (list, then store or erase)
holds the vault's writers' lock, `$XDG_DATA_HOME/xless/vault/lock` (the directory is created, mode 0700, when it does
not exist yet), so neither works from a list the other has changed.

### When the helper cannot keep a key Apple offers once

An App Store Connect API key's and an auth key's private key can be downloaded once only. So before `xless auth
api-key create`, `xless keys create` or `xless provision apply` asks Apple for one (and before `xless certs create`,
`sign bootstrap`, `xless webhooks create` and `xless auth api-key import` store anything), xless checks that the helper
works: it stores a throwaway entry `xless-helper-probe.<random>`, reads it back and erases it (once per command; GnuPG
or the keyring may ask to be unlocked for it). A helper that fails any of the three stops the command before anything is
created at Apple. If it could not erase the entry, the error names it: remove it with `xless secrets rm <name>` once the
helper works.

If the store still fails after Apple created the key (with either backend: the keyring locked meanwhile, a full disk),
xless keeps the private key in memory and writes it to a new file instead of dropping it: `$XDG_RUNTIME_DIR/xless-rescued-AuthKey_<KEY_ID>.p8`
when `$XDG_RUNTIME_DIR` is a directory only you can enter (a tmpfs emptied when you log out, on systemd hosts), else
a path it asks on the terminal (Enter gives up). The file is new (an existing file is never overwritten, a symlink
never followed) and has mode 0600. The command still fails, and its error gives the exact command that puts the key
into the store with its IDs, for example:

```sh
xless secrets import ASC_KEY_P8@ABCDE12345 --file /run/user/1000/xless-rescued-AuthKey_2X9R4HXF34.p8 \
  --kind asc-api-key --team-id ABCDE12345 --key-id 2X9R4HXF34 --issuer-id 69a6de7e-… --role APP_MANAGER
```

`import` offers to delete the file afterwards. With neither a usable `$XDG_RUNTIME_DIR` nor a terminal, the key is
lost and the error says so: revoke it (`xless auth api-key revoke <KEY_ID>`, `xless keys revoke <KEY_ID>`).

### Writing a credential helper

A helper is any executable named `xless-credential-<name>` (`<name>`: lower-case letters, digits, `.`, `_`, `-`). It
speaks the shape of Docker's credential helpers: xless runs `xless-credential-<name> <verb>`, writes the request on its
stdin and closes it, and reads the answer on its stdout. Exit 0 on success. On a failure, say why on stderr and exit
non-zero.

| Verb | stdin | stdout |
|---|---|---|
| `store` | `{"ServerURL":"xless:<NAME>","Username":"<description>","Secret":"<value>"}` | nothing; replaces what it had for that ServerURL |
| `get` | `xless:<NAME>` | `{"ServerURL":"xless:<NAME>","Username":"<description>","Secret":"<value>"}`; if it has none: `credentials not found in native keychain` and exit 1 |
| `erase` | `xless:<NAME>` | nothing |
| `list` | nothing | `{"xless:<NAME>":"<description>",…}` for every credential it holds (`{}` for none) |

- `<NAME>` is the entry's name (`ASC_KEY_P8@ABCDE12345`): letters, digits and `. _ @ -`, starting with a letter or a
  digit. ServerURLs that do not start with `xless:` are not xless's: xless ignores them in `list`.
- The description (Username) is xless's, not secret, and must come back unchanged: compact JSON of the entry's kind
  and IDs, such as `{"keyID":"2X9R4HXF34","kind":"asc-api-key","teamID":"ABCDE12345"}`. `list` returns it for every
  credential without giving any value; keep it cheap, since xless lists once per command (the shipped pass helper
  decrypts each description, so GnuPG may ask for its key once).
- The value is text (UTF-8 without NUL bytes) and must come back byte for byte, trailing newlines included. xless writes
  the request on one line and escapes only `"`, `\` and control characters (as `\n`, `\t`, `\r`, `\b`, `\f`,
  `\u00XX`); other characters come as UTF-8. It reads any valid JSON answer.
- Keep the secret out of argv, the environment and files in clear: give it to your keyring through a pipe. Errors go
  to stderr; never print the request back.

`share/xless/credential-helpers/` has the two shipped helpers, in POSIX sh and awk, as examples.

## The file

The store is `$XDG_DATA_HOME/xless/vault/secrets.vault` (`~/.local/share/xless/vault/secrets.vault` by default), in a
directory of mode 0700, with mode 0600. xless refuses to use it if the directory or the file is a symlink, belongs to
another user, or can be read or written by anyone else; it never fixes the permissions itself. With the default
install prefix that directory is inside the install's `~/.local/share/xless`: running the install line again keeps it,
and removing the install by hand removes it with the rest ([uninstall.md](uninstall.md#uninstall)).

Each entry is encrypted with AES-256-GCM under a random 256-bit data key; the data key is encrypted with a key derived
from the passphrase by scrypt (N = 2^17, r = 8, p = 1, recorded in the file). The names, kinds, IDs and the rest of
each entry's metadata are in clear (so `list` works without the passphrase) but authenticated with the secret, every
field whether it is set or not: an entry whose name, kind or metadata was altered, added or removed in the file fails
to open, with an error, and nothing of it is used. Writes go to a temporary file in the same directory that replaces the store
in one step, under a lock, so concurrent commands do not lose each other's changes and a crash never leaves half a
file.

### Store format and older xless releases

The file says which format it has (`"version"`) and the oldest format an xless must know to change it
(`"minimumReaderVersion"`). This release writes format 2. A store made by an earlier release (format 1, where the
type, role and services were authenticated only when set) still opens as it is; the first command that changes the
store with it unlocked (`import`, `passwd`, `xless auth api-key create`, `xless certs create`, …; a remembered
unlock counts, and nothing extra is asked) seals every entry again with all its fields and moves the file to format 2.
Commands that only read it change nothing.

An xless older than a store's `minimumReaderVersion` still reads the entries it knows, but refuses to change the file
(`import`, `rm`, `passwd`, and the account commands that store keys), before asking anything or creating anything at
Apple, with an error that says to upgrade xless (`[config]`, exit 10 from `xless secrets`; `[account]`, exit 20 from
the account commands); the file is left as it was. Fields it does not know are written back unchanged whenever it does
change the file. A key revoked (or a webhook deleted) at Apple before that refusal stays revoked: `xless auth api-key
revoke`, `xless keys revoke`, `xless webhooks delete` and `xless certs revoke` say so, and that the entry is removed with
`xless secrets rm` once xless is upgraded. A [saved Apple ID
session](security.md#across-reboots) is an entry of a format of its own (3): a release that does not know it lists it as
`generic`, keeps it and says that a newer xless wrote it. Releases before format 2 do not open a format-2 store at all ("the secret store is format version 2;
this xless reads version 1"): after an upgrade has moved the store, going back to such a release means restoring a
copy of the old file.

`passwd` encrypts the data key again under the new passphrase; it does not encrypt the entries again (except to move
a store of the first format to format 2). A copy of the old
file (a backup) still opens with the old passphrase, so after a passphrase leak, revoke the keys at Apple too.

## What it protects against, and what it does not

[security.md](security.md) has the whole model: the caches, process hardening, and which host gets what.

The store protects keys at rest: a stolen disk or laptop, a backup or a synced home directory, and other users of the
machine. It does not protect against malware running as you outside what xless starts, while the store is unlocked
([what it can do](security.md#what-an-attacker-who-runs-as-you-can-do)), nor against someone who has both the file and
the passphrase.
