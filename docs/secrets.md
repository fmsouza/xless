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
| `list` | Every entry's name, kind, team, key ID, issuer ID, certificate ID, creation and expiry dates. No passphrase needed. |
| `import <name> --file <path>` | Adds the file's content. `--kind` (default: from the name), `--team-id`, `--key-id`, `--issuer-id`, `--certificate-id`, `--expires YYYY-MM-DD` record what it is. Then offers to delete the file. |
| `export <name> --out <path>` | Writes the secret to a new file (mode 0600; an existing file is never overwritten). That copy is in clear: delete it once used. |
| `rm <name>` | Removes an entry, after asking (`--yes` skips the question). It cannot be recovered. |
| `unlock --remember 30m` | Keeps the store unlocked for at most an hour (see below). |
| `lock` | Forgets a remembered unlock now. |
| `passwd` | Changes the passphrase. |

Kinds: `asc-api-key` (an App Store Connect API key: `.p8`, key ID and issuer ID required), `signing-key` (an RSA
private key PEM from `xless sign bootstrap` or `xless certs create`), `auth-key` (an APNs, Sign in with Apple, DeviceCheck or MusicKit `.p8`),
`password` and `generic`. Keys are checked when imported: a `.p8` must be a P-256 private key, a signing key an RSA one.
A file named `AuthKey_<KEY_ID>.p8`, as Apple names them, gives the key ID.

[`xless auth api-key create`](apple-account.md#xless-auth-api-key) puts a new App Store Connect API key straight into
the store (as `ASC_KEY_P8@<TEAM_ID>`, with its key ID, issuer ID, team and role), and `xless auth api-key import`
checks a `.p8` against App Store Connect before storing it. The role is part of what the seal authenticates when it is
recorded; an xless older than the one that added it reads such an entry as altered.

[`xless certs create`](apple-account.md#xless-certs) and `xless sign bootstrap` generate a certificate's private key
and seal it into the store before the certificate is requested (as `XLESS_DIST_KEY`, `XLESS_DEVID_KEY`,
`XLESS_INSTALLER_KEY` or `XLESS_<TYPE>_KEY`, with `@<TEAM_ID>` when a team is selected), then record the certificate's
ID, type and expiry with it. The type is authenticated the same way as an API key's role.

[`xless keys create`](apple-account.md#xless-keys) puts a new APNs, Sign in with Apple, DeviceCheck or MusicKit key
straight into the store (as `XLESS_APNS_KEY@<TEAM_ID>`, `XLESS_SIWA_KEY`, `XLESS_DEVICECHECK_KEY`, `XLESS_MUSICKIT_KEY`
or `XLESS_AUTH_KEY`, kind `auth-key`, with its key ID, team and services); `xless keys revoke` removes it again. The
services are authenticated the same way as an API key's role.

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
  the store holds every secret the run needs, so a missing key stops the run before the build. A project directory is
  one process: one passphrase. With `--config`, steps 1 and 3 are two processes on either side of the build, and each
  asks it: nothing unlocked stays in a process while the build code runs. The build step runs with
  `XLESS_NO_SECRET_STORE=1`: its xless never opens the store, and it leaves the session keyring, so the build code it
  runs cannot reach a remembered unlock. This keeps xless itself from handing out a secret there; it is no sandbox:
  code that runs on your machine as you can read your files, which is why the overlays build in Docker.
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

CI keeps using the environment and `_FILE` variables, and never opens the store.

The passphrase is read from the terminal (`/dev/tty`) only, never from a pipe, a file, an argument or the
environment. A command that needs the store when it is locked and has no terminal (a script, `nohup`) stops with an
error that says so.

## Staying unlocked

By default each command that needs the store asks the passphrase, and forgets the unlocked store when it exits.
`--remember <duration>` (on `unlock`, `init`, `import` and `export`; at most `1h`) keeps it unlocked in the Linux kernel
keyring instead: later commands in the same login session (the same terminal and its children) read the store without
asking, until the time runs out or `xless secrets lock`. Other users, and other login sessions of yours, cannot read the
cached key. macOS has no kernel keyring, and containers often block it; there `--remember` is refused.

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
| `secret-tool` | One keyring item labelled `xless <NAME>`, with the attributes `application=xless`, `xless-name=<NAME>` and `xless-username=<its kind and IDs>`. A locked keyring asks to be unlocked in its own window. |
| `pass` | `xless/<NAME>/secret` (the value) and `xless/<NAME>/username` (its kind and IDs), both encrypted to your pass key. GnuPG asks your key's passphrase through its agent; `export GPG_TTY=$(tty)` for a terminal prompt. `xless secrets list` reads every entry's `username`. |

Every `xless secrets` command works the same with a helper, and so does everything that reads or writes secrets
(`xless ship`, `xless run`, `xless auth api-key create`, `xless certs create`, `xless keys create`, `xless provision`,
`sign bootstrap`). A few have nothing to do: `init` checks that the helper answers, `unlock` and `lock` leave locking
to the keyring, `--remember` is ignored, and `passwd` is refused (change the keyring's or the GnuPG key's password with
their own tools). Moving from the vault to a helper is done entry by entry: `xless secrets export <name> --out <file>`
with `backend: vault`, then `xless secrets import <name> --file <file> …` with `backend: helper`, then delete the file.

What xless does to keep the helper honest: it runs only `xless-credential-<name>` from an absolute directory on PATH,
and refuses it when the file, the directory it is in, or the PATH directory it was found in can be written by anyone
but you (or root), or belongs to another user: whoever can change the helper can read every secret. The helper gets
only its verb as argument; its environment is cut down to what a keyring needs (`HOME`, `PATH`, the locale, `XDG_*`,
`DBUS_SESSION_BUS_ADDRESS`, `DISPLAY`, `WAYLAND_DISPLAY`, `XAUTHORITY`, `GNUPGHOME`, `GPG_TTY`, `PASSWORD_STORE_*`,
`TMPDIR`, `TERM`, `TZ`, `USER`, `LOGNAME`), never a secret variable, and it inherits no open file of xless's. Secrets
go only through its stdin and stdout pipes; xless reads at most 4 MiB of answer into memory it zeroes afterwards, and
stops the helper (and anything it started) after 120 seconds. Its stderr is xless's, so the keyring's or GnuPG's own
messages reach you; xless never quotes what a failed `get` printed. With a helper, the integrity of the names and IDs
is the keyring's, and there is no lock between two xless commands writing at the same time.

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
  and IDs, such as `{"keyID":"2X9R4HXF34","kind":"asc-api-key","teamID":"ABCDE12345"}`. `list` must return it without
  reading any secret, so that `xless secrets list` and lookups by team need no unlock.
- The value is text (UTF-8 without NUL bytes) and must come back byte for byte, trailing newlines included. xless writes
  the request on one line and escapes only `"`, `\` and control characters (as `\n`, `\t`, `\r`, `\b`, `\f`,
  `\u00XX`); other characters come as UTF-8. It reads any valid JSON answer.
- Keep the secret out of argv, the environment and files in clear: give it to your keyring through a pipe.

`share/xless/credential-helpers/` has the two shipped helpers, in POSIX sh and awk, as examples.

## The file

The store is `$XDG_DATA_HOME/xless/vault/secrets.vault` (`~/.local/share/xless/vault/secrets.vault` by default), in a
directory of mode 0700, with mode 0600. xless refuses to use it if the directory or the file is a symlink, belongs to
another user, or can be read or written by anyone else; it never fixes the permissions itself. With the default
install prefix that directory is inside the install's `~/.local/share/xless`: running the install line again keeps it,
and removing the install by hand removes it with the rest ([uninstall.md](uninstall.md#uninstall)).

Each entry is encrypted with AES-256-GCM under a random 256-bit data key; the data key is encrypted with a key derived
from the passphrase by scrypt (N = 2^17, r = 8, p = 1, recorded in the file). The names, kinds and IDs are in clear (so
`list` works without the passphrase) but authenticated with the secret: an entry whose file was altered fails to open,
with an error, and nothing of it is used. Writes go to a temporary file in the same directory that replaces the store
in one step, under a lock, so concurrent commands do not lose each other's changes and a crash never leaves half a
file.

`passwd` encrypts the data key again under the new passphrase; it does not encrypt the entries again. A copy of the old
file (a backup) still opens with the old passphrase, so after a passphrase leak, revoke the keys at Apple too.

## What it protects against, and what it does not

[security.md](security.md) has the whole model: the caches, process hardening, and which host gets what.

The store protects keys at rest: a stolen disk or laptop, a backup or a synced home directory, and other users of the
machine. It does not protect against malware running as you while the store is unlocked (it can read the process's
memory or the unlocked key in the kernel keyring, or wait for you to type the passphrase), nor against someone who
has both the file and the passphrase.
