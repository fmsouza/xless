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
| Your Apple ID password and two-factor code | typed on the terminal | Everything the Apple ID can do |
| The Apple ID web session (cookies) | the sign-in | The App Store Connect and developer portal web pages, until Apple expires it |
| The secret store's passphrase, and the store's data key once unlocked | typed on the terminal | Open every entry of the store |

## Who xless defends against

- **Someone who gets the disk, a backup or a synced home directory.** Keys are in the encrypted store, never in clear
  files (unless you export one). The Apple ID session and the store unlock are never written to disk.
- **Other users of the machine.** The store, its directory and its lock are yours only (refused otherwise), and the
  kernel keyring's cached keys are readable only by processes of your login session.
- **Code your build runs** (npm scripts, `build.rs`, SwiftPM plugins and macros, CocoaPods hooks, Xcode build phases),
  partly. xless removes every secret variable from the environment of the tools it runs, and runs an overlay app's
  build in a container that has no secret. A project directory built natively is another matter: its build code runs
  as you, in your login session ([below](#the-build-and-your-secrets)).
- **Logs, terminals and bug reports.** No secret is printed, put in an error, in a `--verbose` trace or on a command
  line.
- **A network observer.** Everything goes over HTTPS to Apple's hosts; xless refuses a non-HTTPS request or redirect
  in the Apple ID session, and `xless api` refuses any host but App Store Connect's API.

Out of scope: malware or a person running **as you** while the store is unlocked or a session is kept (it can read
the process's memory, the kernel keyring of your login session, or wait for you to type the passphrase), someone who
has both the store file and its passphrase, and a compromised Apple account or Apple service. Code that runs on your
machine as you can read your files and your login session's keyring: that is why the overlays build in Docker.

## Guarantees

1. **The documented API by default.** Every command that has a documented App Store Connect API (4.6.1) uses it,
   with the API key: a JSON Web Token signed with ES256 for each request, valid for 15 minutes, never stored. The
   Apple ID web session is used only for what that API cannot do ([below](#the-apple-id-web-session)).
2. **No secret in clear on disk.** Keys xless creates or downloads go straight into the encrypted store, sealed before
   any request that could make them unrecoverable (a certificate's key before the certificate is requested; an API or
   auth key's `.p8`, which Apple serves once, in the same process that created it). Writing one to a file is explicit
   (`xless secrets export --out`, `xless sign bootstrap --out`): a new file, opened with `O_EXCL`, mode 0600, never an
   overwrite. Imports offer to delete the file they read.
3. **Nothing kept longer than the command,** unless you opt in: the store's unlock (`--remember`) and the Apple ID
   session (`xless auth login --keep`) can be kept for at most an hour, in the Linux kernel keyring, never on disk.
   `xless secrets lock` and `xless auth logout` drop them at once.
4. **No secret on a command line, in a log, in an error, in a core dump or in a child's environment.** Secrets come
   from the terminal, the store, `NAME` or `NAME_FILE`; no option takes one (a test walks every command and fails on an
   option named like a secret). One exception to the environment: a demo account password given under a name of
   your own (app.yml's `passwordSecret` other than `XLESS_DEMO_PASSWORD`) as an environment variable is not removed
   from the tools' environment; keep it in the store instead.
5. **Least privilege, and a question before anything destructive.** `xless auth api-key create` makes an `APP_MANAGER`
   key unless you ask for more; the commands that revoke, delete, remove or cancel something at Apple ask first, and
   without a terminal they are refused unless `--yes` is given. `xless provision apply` never deletes or revokes
   anything. Two things replace without asking, because that is how they update: `sign` deletes and recreates its
   own `xless <bundle ID> <TYPE>` profile when it lacks the certificate or expires within 7 days, and `xless store
   privacy push` deletes the App Privacy answers app.yml no longer declares.

## The secret store

[secrets.md](secrets.md) has the commands; this is what is in the file.

- **Where.** `$XDG_DATA_HOME/xless/vault/` (`~/.local/share/xless/vault/`): the directory mode 0700, `secrets.vault`
  and the writers' `lock` mode 0600. A symlink, another owner, or any permission bit for the group or others on any of
  them is refused, never repaired.
- **Format.** One JSON file (`"format": "xless-vault"`, `"version": 1`, a random store ID, the KDF and its parameters,
  the wrapped data key, a key check and the entries). A random 256-bit data key seals each entry's secret with
  AES-256-GCM; the data key is sealed with AES-256-GCM under a key derived from the passphrase by scrypt (N = 2^17,
  r = 8, p = 1: about 128 MiB and a fraction of a second per unlock; parameters no xless writes are refused before
  anything is derived). Each entry's name, kind and metadata (team, key ID, issuer ID, certificate ID, type, role,
  services, dates) are in clear so that `xless secrets list` works while the store is locked, and are authenticated as
  the seal's associated data: an altered field makes the entry fail to open, and nothing of it is used.
- **Writes** re-read the file under the lock and replace it in one step (a temporary file in the same directory, then a
  rename), so concurrent commands do not lose each other's entries and a crash never leaves half a file.
- **The passphrase** is read from `/dev/tty` with echo off, never from a pipe, a file, an argument or the environment.
  It cannot be recovered. `passwd` seals the data key again under a new passphrase; the entries are not re-encrypted,
  so an old copy of the file still opens with the old passphrase.
- **What the store does not detect:** someone who can write the file can delete entries, put back an older copy of
  the whole file (with entries you removed since), or strip the optional `role`, `certificateType` and `services`
  fields of an entry (they are authenticated only when present, so that entries written before they existed still
  open). None of it reveals a secret; keep the store's directory yours.

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
by the keyring too (unsealed: their integrity is the keyring's), and two xless commands writing at once are not
serialised.

## Caches: off by default, at most an hour

| Cache | Turned on by | What is kept | Where | Dropped by |
|---|---|---|---|---|
| Store unlock | `--remember <duration>` on `xless secrets unlock`, `init`, `import`, `export` | the store's data key, named after the store's random ID | the session keyring | `xless secrets lock`, the time running out |
| Apple ID session | `xless auth login --keep <duration>` | the session's cookies, sealed with AES-256-GCM under a random key made for them; the sealed cookies and that key are two separate keys | the session keyring | `xless auth logout`, the time running out, or the cookies' own expiry if sooner |

- Durations are `90s`, `30m`, `1h` or seconds, at most one hour (`--keep` at least a minute: a session that would run
  out sooner is not kept). The kernel expires the keys itself; when xless cannot set the bound or the permissions, it
  revokes the key and fails rather than keep it longer or wider.
- The keys are `user` keys in the **session keyring**, readable only by a process that holds that keyring (a
  "possessor"). Which processes those are is the system's choice: usually every process of your login session (on a
  desktop, every terminal of the login), and where no login session keyring was set up, your user's default session
  keyring, which all your processes without one share. Other users cannot read them; the permissions give nothing to
  the user, group or others outside possession. Every process that possesses the keys can read them, including code
  you build ([below](#the-build-and-your-secrets)).
- There is no cache on macOS (it has no kernel keyring) or in containers that block the keyring calls (Docker's default
  seccomp profile does): `--remember` and `--keep` are refused there, and every command asks again.
- `xless auth logout` forgets the kept session on this machine. It does not sign you out at Apple: the cookies stay
  valid on Apple's side until Apple expires them. If you think a session leaked, change the Apple ID's password.
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
  `XLESS_DEMO_PASSWORD`, and each one's `_FILE` form); overlays may not set them. rcodesign, which signs and
  notarizes, gets the keys it needs as files, mode 0600, in a fresh 0700 directory of the temporary directory
  (`$TMPDIR`, else `/tmp`), removed when the call ends: point `TMPDIR` at a tmpfs if that directory is on a disk you
  worry about.
- **The build and your secrets** (see [below](#the-build-and-your-secrets)): an overlay app's build never runs next to
  a secret; a project directory's native build runs in your session.
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

## The build and your secrets

An app's build runs code you did not write. What that code can reach depends on how it is built:

- **An overlay app (Tauri, Cargo, React Native: `xless run --docker --config`)** builds in three containers. The build
  container (step 2) gets no secret and no secret file; the store is in no container. Before the first step, the
  xless on your machine writes the secrets each other step needs to a tmpfs (`$XDG_RUNTIME_DIR/xless/<random>/`,
  0700 and 0600), mounts each step's directory read-only into that step's container only, and removes it when that
  container ends; without a tmpfs the run refuses unless `--allow-disk-secrets`
  ([secrets.md](secrets.md#xless-run-and-docker-builds)). Docker's default seccomp profile also keeps containers out
  of the kernel keyring.
- **A project directory (`xless run <dir>`)** is one `xless ship`: build, sign and upload in one process (one
  container with `--docker`, which gets the secrets the run needs). The secret variables are removed from the build
  tools' environment, but natively its SwiftPM plugins and macros run as you, in your login session: they can read
  your files, the key files a `_FILE` variable names, and **a remembered store unlock or a kept Apple ID session**
  (they possess the session keyring, so they could read the store's data key or the session's cookies).

So before a native build of a project you do not fully trust, drop the caches, and if it matters, keep the signing in
a second run:

```sh
xless secrets lock
xless auth logout
export XLESS_BUILD_NUMBER=$(( $(date +%s) / 60 ))
xless run ~/MyApp --to finalize       # build only: reads no secret, opens no store
xless run ~/MyApp --from sign         # sign and upload what it built: no build code runs
```

(`XLESS_NO_SECRET_STORE=1`, which makes an xless leave the session keyring and never open the store, is set by
`xless run` for the build step of an overlay split; the native project path does not use it.)

## What goes to which host

Every request is HTTPS. xless sends no telemetry.

| Host | What xless sends | Credential | Used by |
|---|---|---|---|
| `api.appstoreconnect.apple.com` | The documented App Store Connect API (`/v1`, `/v2`, `/v3`) | API key (a fresh JWT; the `.p8` itself never leaves the machine) | every account command that has an API, `xless api`, `sign`, `upload`, TestFlight delivery, `next-build`, `store pull`/`push`, `release`, `provision` |
| The upload and download addresses App Store Connect hands out | The bytes of builds, screenshots, previews and documents (`PUT` to the presigned addresses an upload reservation returns); `store pull` downloads media from the addresses Apple lists | none: the address carries Apple's own authorization; xless adds no header | `upload`, `store push`, `store pull` |
| Apple's notary service, through rcodesign | The app or disk image to notarize | API key (a JWT rcodesign makes from the key file) | macOS `package` |
| `idmsa.apple.com` | The Apple ID sign-in: SRP-6a (the password itself is never sent, only proofs derived from it), the two-factor code | the Apple ID | `xless auth login` and every web-session command, `xless xcode download` |
| `appstoreconnect.apple.com` (`/olympus/v1`, `/iris/v1`) | App Store Connect's own web interface: session and team, app record creation, API keys, App Privacy, agreements check | Apple ID session cookies | the [web-session commands](#the-apple-id-web-session) |
| `developer.apple.com` (`/services-account/…`) | The developer portal's web interface: teams, app groups, iCloud containers, assigning them to bundle IDs, auth keys; the Xcode download list | Apple ID session cookies | the [web-session commands](#the-apple-id-web-session), `xless xcode download` |
| `developerservices2.apple.com`, `download.developer.apple.com` | The `.xip` download | Apple ID session cookies | `xless xcode download` only ([xcode-download.md](xcode-download.md)) |
| `download.swift.org`, `github.com` | Downloads of pinned tools, checked by SHA-256 | none | `xless setup`, the installer ([native-install.md](native-install.md)) |

Cookies are sent only to hosts within the domain that set them, and no other header of a request follows a redirect
to another host (but `Accept`, `User-Agent` and `Range`). The App Store
Connect API key's JWT goes only on requests xless addresses to `api.appstoreconnect.apple.com` (and, made by
rcodesign, to the notary service); upload and download addresses get no credential.

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
  sends that assertion once to idmsa.apple.com, never again. Only the keys Apple names are asked, and only after a
  silent check that the key holds one, so a touch never signs for another account. The key's PIN, when the key wants
  one, is read like the password, sent to the key only (encrypted with the FIDO2 PIN protocol), and wiped after use.
- The cookies stay in this process's memory and are forgotten when it ends, unless `--keep` ([above](#caches-off-by-default-at-most-an-hour)).
- xless never accepts legal terms: when Apple wants an agreement accepted, the command stops and names the page.

## Wiping everything

Removing the store removes xless's only copy of the keys it created, and cannot be undone. **First** revoke at Apple
what you no longer use: `xless auth api-key revoke <KEY_ID>`, `xless certs revoke <ID>` (not a Developer ID
certificate you shipped with: the apps it signed stop opening), `xless keys revoke <ID>` (each asks first), and export
what you keep. A key Apple still accepts stays dangerous wherever a copy of it is: an old backup of the store opens
with the passphrase it had then. Then:

```sh
xless secrets lock                       # forget a remembered unlock now
xless auth logout                        # forget a kept Apple ID session (Apple's side expires on its own)
rm -rf ~/.local/share/xless/vault        # the secret store itself ($XDG_DATA_HOME/xless/vault): every key in it is gone
                                         # (with a credential helper: xless secrets list, then xless secrets rm each entry)
rm -f ~/.config/xless/config.yml         # the default team (a preference, not a secret)
```

The kernel keyring's keys also go when the login session's keyring is released (once no process of that session is
left) and at a reboot.

Files xless never deletes for you: exported keys (`xless secrets export`, `sign bootstrap --out`) and the files you
imported from when you declined the offer to delete them. CI keeps its secrets in its own secret store.

## Reporting a problem

A way to read a secret that this page says xless protects is a security bug. Do not put the details in a public issue:
open one that only asks the maintainer for a private channel, and send the details there.
