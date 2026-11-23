# One-time Apple setup

Everything an app needs from Apple before its first upload, from the terminal: an App Store Connect API key, the
bundle ID and its capabilities, the signing certificates with their private keys, the provisioning profiles and the
app record. The short way is one command, [`xless provision apply`](#4-provision-the-account); the steps after it do
the same one at a time. [account.md](account.md) covers what comes next (devices, testers, releases). The way through
the developer portal and App Store Connect in a browser is kept as an [appendix](#appendix-the-same-in-a-browser).

The account commands are tested against recorded Apple answers, not yet end to end on a real account
([#105](https://github.com/fmsouza/xless/issues/105)): if one fails, its error names the page to use in a browser
meanwhile, and the appendix has the manual step.

Keep every secret in xless's encrypted store on your own machine ([secrets.md](secrets.md)) and in your CI's secret
store; never commit one. (`.gitignore` already excludes `*.p8` and `*.pem`.)

## What you need first

- An Apple Developer Program membership, and an Apple ID that is its Account Holder, or an Admin the Account Holder
  allowed to generate API keys. Two-factor authentication by code (hardware security keys are not supported).
- The agreements accepted and, the first time, App Store Connect API access requested by the Account Holder: both are
  in a browser only ([account.md](account.md#before-you-start)).
- xless installed ([README](../README.md)).

## 1. The secret store and your Apple ID

```sh
xless secrets init                  # a new passphrase, twice; it cannot be recovered
xless auth login --keep 30m         # Apple ID, password and the two-factor code, on the terminal; lists your teams
xless team use ABCDE12345           # the default team of the account commands
```

`--keep 30m` keeps the Apple ID session for the next commands in this terminal, in the Linux kernel keyring, for at
most an hour; nothing of it is written to disk, and `xless auth logout` drops it ([security.md](security.md)). Without
it, each command that needs the session signs in again.

## 2. App Store Connect API key
<a id="1-app-store-connect-api-key"></a>

```sh
xless auth api-key create --role ADMIN    # straight into the secret store, checked, never on disk in clear
```

The first API key can only be made through the [Apple ID web session](apple-account.md#the-apple-id-web-session);
every later step uses the key. `--role ADMIN` because the next steps create bundle IDs, certificates and profiles; a
key that only ships builds can be `APP_MANAGER` (the default). The key is stored as `ASC_KEY_P8@<TEAM_ID>` with its
key ID, issuer ID, team and role ([`xless auth api-key`](apple-account.md#xless-auth-api-key)).

A `.p8` you already have goes in with
`xless auth api-key import --p8-file AuthKey_<KEY_ID>.p8 --issuer-id <ISSUER_ID>`, checked against App Store Connect
first.

## 3. The project

In `xless.yml`, or the overlay of a Tauri, Cargo or React Native app, set `teamID` to the team and `bundleID` to the
app's identifier; the sample's values are placeholders ([xless-yml.md](xless-yml.md)). Its entitlements (push
notifications, app groups, iCloud, Sign in with Apple…) decide the capabilities, groups, containers and keys.

For an App Store app, an `appstore/` directory next to it names the app record: `app.yml` with `primaryLocale` and
`version` (and `sku`, default the bundle ID), and `<locale>/name.txt` ([account.md](account.md#your-first-app-from-zero),
[appstore-manifest.md](appstore-manifest.md)). `xless store validate --draft` checks it offline.

## 4. Provision the account

```sh
xless provision plan                                  # what the account lacks for this project; reads only
xless provision apply --company-name "Example Ltd"    # asks, then does it (--company-name for the team's first app)
```

In dependency order: the bundle IDs (registered as universal, iOS and macOS), their capabilities, the app groups and
iCloud containers the entitlements name, a signing key per lane generated into the store with its certificate (Apple
Distribution for iOS and the Mac App Store, Mac Installer Distribution for a Mac App Store package, Developer ID
Application for a notarized Mac app), an APNs key when push notifications are used, the profiles, the app record,
the listing and App Privacy from `appstore/`, and the TestFlight groups of `xless.yml`. It never deletes or revokes
anything, and running it again does only what is left ([`xless provision`](apple-account.md#xless-provision)).

Then go to [step 6](#6-setup-once-per-xcode-release). Or, instead of `provision`, one at a time:

## 5. The same, one step at a time

### 5a. Bundle ID
<a id="4-bundle-id-before-the-app-record"></a>

```sh
xless bundle-ids create com.example.app     # universal; an identifier the team has is reported, never registered twice
xless bundle-ids capabilities com.example.app enable PUSH_NOTIFICATIONS
```

`sign` also registers the bundle ID and enables the capabilities the entitlements need, at the first run; App Store
Connect needs it registered before the app record ([`xless bundle-ids`](apple-account.md#xless-bundle-ids)).

### 5b. Apple Distribution key (iOS, and the Mac App Store app)
<a id="2-apple-distribution-key-ios"></a>

```sh
xless sign bootstrap --type distribution
```

The key is generated here, sealed into the store as `XLESS_DIST_KEY@<TEAM_ID>` (the team saved by `xless team use`)
before the certificate is requested, and the certificate's ID, type and expiry are recorded with it; `sign` finds it
there. `xless sign bootstrap` is the `xless certs create` of the three certificates `sign` uses
([`xless certs`](apple-account.md#xless-certs) covers every other type). To get a file instead of a store entry, pass
`--out dist-key.pem`.

### 5c. Developer ID Application key (a notarized Mac app)
<a id="3-developer-id-application-key-macos-only"></a>

```sh
xless sign bootstrap --type developer-id
```

Stored as `XLESS_DEVID_KEY@<TEAM_ID>`. Creating Developer ID certificates needs the Account Holder: with another
role, App Store Connect answers 403. Then make the key and its CSR as files:

```sh
xless sign bootstrap --type developer-id --out devid-key.pem --csr-only
```

and have the Account Holder create the certificate from the CSR, with
`xless certs create --type developer-id --csr devid-key.pem.csr`. Store the key with
`xless secrets import XLESS_DEVID_KEY@<TEAM_ID> --file devid-key.pem --team-id <TEAM_ID>`, then delete the file.

### 5d. Mac Installer Distribution key (the Mac App Store package)
<a id="3b-mac-installer-distribution-key-macos-app-store-lane-only"></a>

Only needed to send a macOS app to TestFlight ([the lane](signing-and-testflight.md#macos-app-store-lane-testflight)).
App Store Connect accepts a Mac App Store package only when it is signed with a Mac Installer Distribution certificate
("3rd Party Mac Developer Installer"); the Apple Distribution key signs the app inside it, and cannot sign the package
(App Store Connect refuses it with ITMS-90237).

```sh
xless sign bootstrap --type installer
```

Stored as `XLESS_INSTALLER_KEY@<TEAM_ID>`. If App Store Connect answers 403, make the key and CSR with
`--out … --csr-only` as in 5c, and create the certificate from the CSR with a role that may
(`xless certs create --type installer --csr …`).

### 5e. App record
<a id="5-app-record"></a>

`xless upload` fails until the app record exists; a macOS app signed with Developer ID needs none. The App Store
Connect API cannot create app records, so this uses the Apple ID web session:

```sh
xless apps create --bundle-id com.example.app --name "Example" --sku EXAMPLE1 --locale en-US
```

For iOS, the bundle ID is `platforms.ios.bundleID` if you override it; add `--platform macos` for a Mac App Store app.
An app that already exists is reported instead of created twice, and a bundle ID that 5a did not register is offered
([`xless apps`](apple-account.md#xless-apps)).

Provisioning profiles need no step: `sign` creates and replaces its own (`xless <bundle ID> IOS_APP_STORE`,
`MAC_APP_STORE`, `MAC_APP_DIRECT`). Other types: [`xless profiles`](apple-account.md#xless-profiles).

## How `sign bootstrap` behaves

App Store Connect creates a certificate from a CSR but never returns the private key, so xless generates an RSA-2048 key locally.

- The key is sealed into the secret store (or, with `--out`, written to that file, mode 0600, never overwriting) before any network call, so a store or a disk that cannot keep it cannot cost you a certificate. The store entry records the team, the certificate's ID, its type and its expiry once the certificate exists.
- It refuses to continue if the team already has certificates of that kind, because their keys cannot be downloaded. Reuse the key you stored, or pass `--allow-new` to create another. It also refuses when the store already holds a key under that name for the team.
- Apple documents one limit: five Developer ID Application certificates per team ([Create Developer ID certificates](https://developer.apple.com/help/account/certificates/create-developer-id-certificates/)); xless checks it before generating anything. Apple documents no number for the other types and refuses one too many itself; `xless certs list` and `xless certs revoke` free a slot.
- Certificate creation is never retried. If the request fails in a way that may have succeeded (anything but a definite 4xx refusal: transport error, 429, 5xx, an unreadable response, cancellation), xless keeps the key (in the store, or the file) and tells you to check `xless certs list` before retrying with `--allow-new`. On definite failures the unused key is removed.
- A normal `ship` run later finds the certificate whose public key matches your stored key, registers the bundle ID if needed (as `UNIVERSAL`, so iOS and macOS share it), and finds or creates a matching provisioning profile.

## 6. Setup (once per Xcode release)

On your Linux machine, install the SDK and the toolset from the Xcode download ([README](../README.md#set-up)):

```sh
xless setup --xcode ~/Downloads/Xcode_27.xip
```

or build the Docker images instead, with `xless setup --docker --xcode …` ([README](../README.md#build-in-docker-instead)).
To use the images on other machines (a CI runner, a build server), push them to your own private registry
([maintainers.md](maintainers.md#private-registries)); never to a public one, since they contain Apple's SDK.
`xless xcode download` fetches the `.xip` from the terminal ([xcode-download.md](xcode-download.md)).

## 7. Ship

```sh
xless run <project-dir>             # or, in the images: xless run --docker <project-dir>
```

The keys come from the secret store: one passphrase per run, no secrets file
([signing-and-testflight.md](signing-and-testflight.md#one-command-testflight), which also covers the overlay apps and
running `xless ship` in a container yourself).

**For CI**, which never opens the store: export each key the pipeline needs once, put its contents into the CI's
secret store under the variable's name, and delete the file:

```sh
xless secrets list                                            # the entry names
xless secrets export ASC_KEY_P8@ABCDE12345 --out key.p8       # → ASC_KEY_P8 (with ASC_KEY_ID and ASC_ISSUER_ID from `secrets list`)
xless secrets export XLESS_DIST_KEY@ABCDE12345 --out dist.pem # → XLESS_DIST_KEY
```

The variables are in [signing-and-testflight.md](signing-and-testflight.md#secrets).

## Appendix: the same in a browser

The manual way, for an account where a web-session step fails, or when someone else holds the Apple ID. Put what you
download into the store, never in the repository.

1. **API key.** App Store Connect → Users and Access → Integrations → App Store Connect API → generate a key with the
   **Admin** role, and download its `.p8` (Apple offers it once). Note the key ID (in the list) and the issuer ID (at
   the top). Then `xless auth api-key import --p8-file AuthKey_<KEY_ID>.p8 --issuer-id <ISSUER_ID>`, or for CI the
   secrets `ASC_KEY_ID`, `ASC_ISSUER_ID` and `ASC_KEY_P8` (the file's contents; `ASC_KEY_P8_FILE` names a file
   instead, and every other secret has a `_FILE` form too).
2. **Certificates.** The private keys must be made where you keep them, so generate the key and CSR with xless
   (`xless sign bootstrap --type distribution --out dist-key.pem --csr-only`), create the certificate from
   `dist-key.pem.csr` at developer.apple.com → Certificates, IDs & Profiles → Certificates → + (Apple Distribution;
   Developer ID Application; Mac Installer Distribution), and store the key
   (`xless secrets import XLESS_DIST_KEY@<TEAM_ID> --file dist-key.pem --team-id <TEAM_ID>`).
3. **Bundle ID.** developer.apple.com → Certificates, IDs & Profiles → Identifiers → + → App IDs → App, with the
   `bundleID` as an explicit Bundle ID. (The first `xless run` registers it too, then stops at `upload` with "no app
   record"; after step 4, finish with `XLESS_BUILD_NUMBER=<the number that run printed> xless run <project-dir> --from
   upload`.)
4. **App record.** App Store Connect → Apps → + → New App, choosing that bundle ID.
5. **App groups, iCloud containers, APNs keys.** developer.apple.com → Identifiers (App Groups, iCloud Containers) and
   Keys; assign groups and containers to the bundle ID in its capabilities. Import an APNs `.p8` with
   `xless secrets import XLESS_APNS_KEY@<TEAM_ID> --file AuthKey_<KEY_ID>.p8 --kind auth-key --key-id <KEY_ID> --team-id <TEAM_ID>`.
6. **App Privacy.** App Store Connect → the app → App Privacy.

Profiles still need nothing: `sign` makes them through the API.
