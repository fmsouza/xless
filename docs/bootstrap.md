# One-time Apple setup

Do these in order. Keep every secret in your CI secret store and a password manager; never commit them. (`.gitignore` already excludes `*.p8` and `*.pem`.)

## 1. App Store Connect API key

App Store Connect → Users and Access → Integrations → App Store Connect API → generate a key with the **Admin** role. Download the `.p8` (Apple offers it once).

Store three secrets:

- `ASC_KEY_ID`: the key ID shown in the list.
- `ASC_ISSUER_ID`: the issuer ID shown at the top of the page.
- `ASC_KEY_P8`: the full contents of the `.p8` file.

xless also accepts `ASC_KEY_P8_FILE=/path/to/AuthKey.p8` (and `_FILE` for every other secret).

## 2. Apple Distribution key (iOS)

```sh
xless sign bootstrap --type distribution --out dist-key.pem
```

Store the contents of `dist-key.pem` as `XLESS_DIST_KEY`, then delete the file.

## 3. Developer ID Application key (macOS only)

```sh
xless sign bootstrap --type developer-id --out devid-key.pem
```

Store it as `XLESS_DEVID_KEY`, then delete the file.

If App Store Connect answers 403 (creating Developer ID certificates can require the Account Holder), use `--csr-only` instead:

```sh
xless sign bootstrap --type developer-id --out devid-key.pem --csr-only
```

Then go to developer.apple.com → Certificates, IDs & Profiles → Certificates → + → Developer ID Application, upload `devid-key.pem.csr`, and finish. Store `devid-key.pem` as `XLESS_DEVID_KEY`.

## 3b. Mac Installer Distribution key (macOS App-Store lane only)

Only needed to send a macOS app to TestFlight ([the lane](signing-and-testflight.md#macos-app-store-lane-testflight)). App Store Connect accepts a Mac App Store package only when it is signed with a Mac Installer Distribution certificate ("3rd Party Mac Developer Installer"); the Apple Distribution key of step 2 signs the app inside it, and cannot sign the package (App Store Connect refuses it with ITMS-90237).

```sh
xless sign bootstrap --type installer --out installer-key.pem
```

Store it as `XLESS_INSTALLER_KEY`, then delete the file. If App Store Connect answers 403, create the certificate by hand as in step 3, with `--csr-only`, choosing Mac Installer Distribution at developer.apple.com.

## How `sign bootstrap` behaves

App Store Connect creates a certificate from a CSR but never returns the private key, so xless generates an RSA-2048 key locally.

- The key is written to `--out` (mode 0600, never overwriting an existing file) before any network call, so a write failure cannot cost you a certificate.
- It refuses to continue if the team already has certificates of that kind, because their keys cannot be downloaded. Reuse the key you stored, or pass `--allow-new` to create another.
- It also refuses if the team is at Apple's per-team limit (3 Distribution, 3 Mac Installer Distribution, 5 Developer ID). These limits are unconfirmed against Apple's documentation; revoke unused certificates at developer.apple.com if xless reports the cap.
- Certificate creation is never retried. If the request fails in a way that may have succeeded (anything but a definite 4xx refusal: transport error, 429, 5xx, an unreadable response, cancellation), xless keeps the key file and tells you to check developer.apple.com → Certificates before retrying with `--allow-new`. On definite failures the unused key file is removed.
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
