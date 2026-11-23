# One-time Apple setup

Do these in order. Keep every secret in your CI secret store and, on your own machine, in xless's encrypted secret store
([secrets.md](secrets.md): `xless secrets import <NAME> --file <path>`); never commit them. (`.gitignore` already
excludes `*.p8` and `*.pem`.)

## 1. App Store Connect API key

On your own machine, let xless create it (the Apple ID of the Account Holder, or of an Admin allowed to generate keys,
signs in once on the terminal):

```sh
xless secrets init                         # once
xless auth api-key create --role ADMIN     # the key goes straight into the secret store, checked, never on disk in clear
```

`--role ADMIN` because step 2 onwards creates certificates and, later, users; a key that only ships builds can be
`APP_MANAGER` (the default). See [apple-account.md](apple-account.md#xless-auth-api-key). An existing `.p8` goes in with
`xless auth api-key import --p8-file AuthKey_<KEY_ID>.p8 --issuer-id <ISSUER_ID>`.

By hand instead (and for CI): App Store Connect → Users and Access → Integrations → App Store Connect API → generate a key with the **Admin** role. Download the `.p8` (Apple offers it once).

Store three secrets:

- `ASC_KEY_ID`: the key ID shown in the list.
- `ASC_ISSUER_ID`: the issuer ID shown at the top of the page.
- `ASC_KEY_P8`: the full contents of the `.p8` file.

xless also accepts `ASC_KEY_P8_FILE=/path/to/AuthKey.p8` (and `_FILE` for every other secret).

## 2. Apple Distribution key (iOS)

Create the secret store first, once (`xless secrets init`, [secrets.md](secrets.md)). Then:

```sh
xless sign bootstrap --type distribution
```

The key goes straight into the store as `XLESS_DIST_KEY` (`XLESS_DIST_KEY@<TEAM_ID>` with the team saved by
`xless team use`), where `sign` finds it. For CI, export it once (`xless secrets export <entry> --out <file>`, with the
entry name the command printed)
and store its contents as the CI secret `XLESS_DIST_KEY`. To get a file instead of a store entry, as before, pass
`--out dist-key.pem`; store its contents as `XLESS_DIST_KEY`, then delete the file.

`xless sign bootstrap` is the `xless certs create` of the three certificates `sign` uses
([apple-account.md](apple-account.md#xless-certs) covers every other type).

## 3. Developer ID Application key (macOS only)

```sh
xless sign bootstrap --type developer-id
```

Stored as `XLESS_DEVID_KEY`. Creating Developer ID certificates needs the Account Holder: with another role, App Store
Connect answers 403. Then make the key and its CSR as files:

```sh
xless sign bootstrap --type developer-id --out devid-key.pem --csr-only
```

and have the Account Holder create the certificate from `devid-key.pem.csr`, with
`xless certs create --type developer-id --csr devid-key.pem.csr` or at developer.apple.com → Certificates, IDs &
Profiles → Certificates → + → Developer ID Application. Store `devid-key.pem` as `XLESS_DEVID_KEY`
(`xless secrets import XLESS_DEVID_KEY --file devid-key.pem`).

## 3b. Mac Installer Distribution key (macOS App-Store lane only)

Only needed to send a macOS app to TestFlight ([the lane](signing-and-testflight.md#macos-app-store-lane-testflight)). App Store Connect accepts a Mac App Store package only when it is signed with a Mac Installer Distribution certificate ("3rd Party Mac Developer Installer"); the Apple Distribution key of step 2 signs the app inside it, and cannot sign the package (App Store Connect refuses it with ITMS-90237).

```sh
xless sign bootstrap --type installer
```

Stored as `XLESS_INSTALLER_KEY`. If App Store Connect answers 403, make the key and CSR with `--out … --csr-only` as in
step 3, and create the certificate from the CSR with a role that may (`xless certs create --type installer --csr …`).

## How `sign bootstrap` behaves

App Store Connect creates a certificate from a CSR but never returns the private key, so xless generates an RSA-2048 key locally.

- The key is sealed into the secret store (or, with `--out`, written to that file, mode 0600, never overwriting) before any network call, so a store or a disk that cannot keep it cannot cost you a certificate. The store entry records the team, the certificate's ID, its type and its expiry once the certificate exists.
- It refuses to continue if the team already has certificates of that kind, because their keys cannot be downloaded. Reuse the key you stored, or pass `--allow-new` to create another. It also refuses when the store already holds a key under that name for the team.
- Apple documents one limit: five Developer ID Application certificates per team ([Create Developer ID certificates](https://developer.apple.com/help/account/certificates/create-developer-id-certificates/)); xless checks it before generating anything. Apple documents no number for the other types and refuses one too many itself; `xless certs list` and `xless certs revoke` free a slot.
- Certificate creation is never retried. If the request fails in a way that may have succeeded (anything but a definite 4xx refusal: transport error, 429, 5xx, an unreadable response, cancellation), xless keeps the key (in the store, or the file) and tells you to check `xless certs list` before retrying with `--allow-new`. On definite failures the unused key is removed.
- A normal `ship` run later finds the certificate whose public key matches your stored key, registers the bundle ID if needed (as `UNIVERSAL`, so iOS and macOS share it), and finds or creates a matching provisioning profile.

## 4. Bundle ID (before the app record)

App Store Connect's New App dialog only offers bundle IDs that are already registered, so register the `bundleID` from `xless.yml` first. Either:

- by hand: developer.apple.com → Certificates, IDs & Profiles → Identifiers → + → App IDs → App, with the `bundleID` as an explicit Bundle ID; or
- with xless, once step 6 is done: run the build once (`xless run <project-dir>`, or `xless run --docker <project-dir>` with the images). The `sign` stage registers the bundle ID (as a universal identifier, usable by both the iOS and the macOS build), and the run then stops at `upload` with "no app record". After step 5, finish with `XLESS_BUILD_NUMBER=<the number that run printed> xless run <project-dir> --from upload` (add `--docker` if you build in the images).

## 5. App record

App Store Connect → My Apps → + → New App, choosing the bundle ID registered in step 4 (for iOS, `platforms.ios.bundleID` if you override it). The API cannot create app records; `xless upload` fails until this exists. macOS Developer ID builds do not need an app record.

## 6. Setup (once per Xcode release)

On your Linux machine, install the SDK and the toolset from the Xcode download ([README](../README.md#set-up)):

```sh
xless setup --xcode ~/Downloads/Xcode_27.xip
```

or build the Docker images instead, with `xless setup --docker --xcode …` ([README](../README.md#build-in-docker-instead)).
To use the images on other machines (a CI runner, a build server), push them to your own private registry
([maintainers.md](maintainers.md#private-registries)); never to a public one, since they contain Apple's SDK.

## 7. Ship

From that machine, with the secrets in `~/.config/xless/testflight.env`:

```sh
xless run <project-dir>             # or, in the images: xless run --docker <project-dir>
```

[signing-and-testflight.md](signing-and-testflight.md) covers the secrets file, the overlay apps (Tauri, React Native)
and running `xless ship` in a container yourself.
