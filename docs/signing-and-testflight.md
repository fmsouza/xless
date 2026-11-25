# Signing and TestFlight

Building an app up to `finalize` needs nothing from Apple but the SDK. Signing it, packaging it and uploading it to
App Store Connect need an Apple Developer Program membership and a few keys. This page covers those last stages, for
an `xless.yml` project and for the overlay apps (Tauri, React Native).

## Before you start

Do the one-time Apple setup from the terminal: an App Store Connect API key (`xless auth api-key create`), then
`xless provision apply`, which registers the bundle ID, creates the distribution key (iOS) or the Developer ID key
(macOS) with its certificate, and, with an `appstore/` listing, the app record ([bootstrap.md](bootstrap.md), [account.md](account.md)). In your
`xless.yml` (or overlay), set `teamID` to your team and `bundleID` to the app's bundle ID; the sample's values are
placeholders.

## Secrets

Secrets come from environment variables, from a `NAME_FILE` variable naming a file that holds the value, or, on your
own machine, from the encrypted secret store ([secrets.md](secrets.md)), in that order. The keys `xless auth api-key
create`, `xless certs create`, `xless sign bootstrap` and `xless provision apply` make are already in the store, under
`NAME@<TEAM_ID>`, and a project's run takes its `teamID`'s entries: nothing to set on your own machine. They are never
command-line flags and are never logged ([security.md](security.md)).

| Variable | Purpose | Needed for |
|---|---|---|
| `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_P8` | App Store Connect API key (Admin role) | sign, upload, macOS notarization, `sign bootstrap` |
| `XLESS_DIST_KEY` | Apple Distribution private key (PEM) | iOS sign; the macOS App-Store lane's app sign |
| `XLESS_DEVID_KEY` | Developer ID Application private key (PEM) | macOS sign |
| `XLESS_INSTALLER_KEY` | Mac Installer Distribution private key (PEM) | the macOS App-Store lane's pkg sign |

Values are tolerant of how CI systems mangle them: IDs are trimmed, and PEM values may have CRLF line endings or
literal `\n` sequences.

xless removes the secrets (and their `_FILE` forms) from the environment of every tool it runs, so package code
executed during `build` (SwiftPM macros and plugins) cannot read them from its environment; rcodesign gets keys
through mode-0600 temporary files. A file named by a `_FILE` variable is another matter: code that runs on the same
machine or in the same container as the build, as the same user, can still read it. That is why overlay apps are
built in [three steps](#the-three-step-split).

Once xless reads a secret (`sign`, `package`, `upload`, `next-build`, `sign bootstrap`), core dumps are off for the
rest of the command and for the tools it runs, so a crash cannot write a key to disk; on Linux the process is also
marked non-dumpable, so another process of the same user cannot read its memory (ptrace, `/proc/<pid>/mem`).

## Build numbers

The build number comes from `build` in `xless.yml`, overridden by `XLESS_BUILD_NUMBER` or `--build-number` (the flag
wins). App Store Connect requires it to increase within a version across every machine that uploads, your laptop and
every CI system (ITMS-90062), so use one monotonic scheme everywhere, for example
`XLESS_BUILD_NUMBER=$(( $(date +%s) / 60 ))` (minutes since 1970). Don't use a CI run number: it restarts at 1 and
collides with numbers uploaded from elsewhere. `upload` declares the version and build found in the `.ipa`; if you
pass an override that disagrees with it (for example when resuming in a later minute), it stops and asks you to re-run
from `finalize` or drop the override. Overlays have their own `build: dated` scheme ([tauri.md](tauri.md#build-numbers)).

## One command: TestFlight

```sh
xless run ~/MyApp
```

builds, signs, uploads and delivers an iOS `xless.yml` project to TestFlight (`xless ship --platform ios`, natively
with what `xless setup` installed; with `--docker`, in the `xless` image). For an app described by an overlay use
`xless run --docker --config <overlay.yml>`: a Tauri app ([tauri.md](tauri.md#shipping)) or a React Native / Expo app
([react-native.md](react-native.md#shipping-three-containers)); overlays build in the images only. Arguments after the
project or overlay go to `xless ship`, for example `--from upload` to retry only the upload. `xless run` runs
`share/xless/scripts/testflight.sh` (`xless docker` is the same as `xless run --docker`); from a source checkout, `make testflight PROJECT=<dir>` (or
`CONFIG=<overlay.yml>`, with `ARGS="…"`) runs the same script.

- **Secrets.** With the keys in the encrypted store ([secrets.md](secrets.md#xless-run-and-docker-builds)), a run
  needs no secrets file: what it does not find in the environment comes from the store, one passphrase per run, before its
  first step, or none while the store is kept unlocked ([staying unlocked](secrets.md#staying-unlocked)) (with
  `--docker`, written to a tmpfs for the run and mounted only into the containers that sign and upload;
  `--allow-disk-secrets` where there is no tmpfs, as on macOS). Otherwise, or to override the store, the script reads
  the paths of your secret files from the environment, or from a local file that it sources first:
  `~/.config/xless/testflight.env` (override with `XLESS_TESTFLIGHT_ENV`; it never belongs in git), and a `NAME_FILE`
  set there wins over the store. The files are mounted read-only into the container (natively, read where they are);
  values are never printed or put on a command line. A run that stops before `sign` (`--to finalize`) needs none of
  them, mounts none and never opens the store.

  ```sh
  # ~/.config/xless/testflight.env
  ASC_KEY_ID=ABC123DEFG                          # the API key's ID
  ASC_ISSUER_ID_FILE=$HOME/keys/asc-issuer-id    # file holding the issuer ID (or set ASC_ISSUER_ID)
  ASC_KEY_P8_FILE=$HOME/keys/AuthKey_ABC123DEFG.p8
  XLESS_DIST_KEY_FILE=$HOME/keys/dist-key.pem    # Apple Distribution private key
  XLESS_DEVID_KEY_FILE=$HOME/keys/devid-key.pem  # Developer ID private key (macOS DMG only)
  XLESS_INSTALLER_KEY_FILE=$HOME/keys/installer-key.pem  # Mac Installer Distribution private key (macOS App-Store lane only)
  XLESS_DEMO_PASSWORD_FILE=$HOME/keys/demo-password  # TestFlight demo account's password (testflight.external.review.demoAccount)
  ```

  The TestFlight demo account's password (`<passwordSecret>_FILE` when xless.yml or the overlay names its own secret)
  is needed only by a run that uploads with `testflight.external.review.demoAccount`, and only the upload gets it
  ([secrets.md](secrets.md#xless-run-and-docker-builds)).

- **Native or images.** Natively (the default) the build uses the SDK and Swift `xless setup` installed
  ([native-install.md](native-install.md)); a project pinning another Xcode with `xcode:` is refused until you run
  `xless setup` with that Xcode. With `--docker`: `xless:local-<arch>` for this machine's architecture, or the images
  of the Xcode the project pins ([react-native.md](react-native.md#pinning-the-xcode-sdk)); `XLESS_IMAGE` names another
  image. The Docker context is `DOCKER_CONTEXT` when set, else `colima-xless` when that context exists, else the
  current one.
- **Build number.** `XLESS_BUILD_NUMBER` if set, else `$(( $(date +%s) / 60 ))`, which is monotonic across machines.
  With `--config` the overlay's `build:` decides instead ([tauri.md](tauri.md#build-numbers)).
- **Paths.** Relative secret paths are resolved against the current directory. With `--docker`, the secret files and
  the project must be somewhere Docker can mount (on Linux, any local path).
- **Dry run.** `--dry-run` (or `XLESS_TESTFLIGHT_DRY_RUN=1`) prints the commands without running them.
- **Stopping.** Stopping `xless run` (Ctrl-C, or SIGTERM or SIGHUP, as a CI runner does when it cancels a job) takes
  effect at once, whichever step is running: with `--docker` it removes its containers, natively it stops xless, and it
  exits with code 130, 143 or 129. A SIGKILL cannot be caught: after one, remove what is left with
  `docker rm -f $(docker ps -q --filter label=xless.run)`.
- **Result.** xless prints the build number, each group and `available to N testers`; a group with no testers prints a
  warning. The exit code is xless's (17 for a failed upload or delivery). Then it prints the `xless release submit` command
  that sends this build to App Review ([from TestFlight to the App Store](account.md#release-a-version)); nothing is
  sent there without it. Afterwards,
  [`xless builds`](apple-account.md#xless-builds) lists the build, waits for its processing, answers its export
  compliance and expires old builds.
- **One run per work copy.** A run holds a lock on the work copy it builds (the project directory; for an overlay,
  `~/.cache/xless/work/<overlay name>`, or its work volume for React Native in Docker) in `~/.cache/xless/locks`. A
  second run on the same work copy is refused (exit 2) while the first is running; runs on other work copies are not
  affected, and a dry run takes no lock. After a SIGKILL, which leaves no chance to clean up, the next run on that work
  copy sees that the run holding the lock is gone, and stops what it left before it starts: its containers (labelled
  `xless.work=<hash>`) and, natively, the xless it was running.
- **Testers.** Internal testers must be App Store Connect users of the team: invite them with
  [`xless users invite`](apple-account.md#xless-users) (an Admin API key). List them in `testflight.testers` of
  [xless.yml](xless-yml.md#testflight) and every run adds the missing ones to the groups, or add them once with
  [`xless testflight testers add`](apple-account.md#xless-testflight). External testing (external groups, beta app
  review, public links): `testflight.external` and `xless testflight`. API details:
  [research/asc-testflight.md](research/asc-testflight.md).

With a project directory everything runs in one process (one container with `--docker`), so package code built there
could read the key files. If that matters to you, build up to `finalize` first, with no secret, then sign and upload what it built. Use
the same build number for both runs:

```sh
export XLESS_BUILD_NUMBER=$(( $(date +%s) / 60 ))
xless run ~/MyApp --to finalize
xless run ~/MyApp --from sign
```

## The three-step split

An overlay app's build runs third-party code: npm scripts, `build.rs`, CocoaPods hooks, Xcode build phases. So with
`--config`, `xless run --docker` never runs that code next to a secret. It uses three containers:

1. `xless next-build` (`xless tauri next-build` for Tauri), with the App Store Connect key only: the next `dated` build
   number, a read-only query. Skipped when `XLESS_BUILD_NUMBER` or `--build-number` is given.
2. `xless ship --to finalize`, with **no** secret file or variable: prepare, build, assets, finalize.
3. `xless ship --from sign`, with the secrets: sign, package, upload. No build code runs here.

`--from` and `--to` choose which steps run, and each step needs only its own secrets: `--build-number <n> --to
finalize` needs none. Secrets from the store ([secrets.md](secrets.md#xless-run-and-docker-builds)) are written
once, before step 1, one directory per step, each mounted into its own step only. The overlay's folder and the app
source are mounted into the build container, so the script refuses to start when either holds the secrets file or a
secret file. Details: [tauri.md](tauri.md#shipping) and
[react-native.md](react-native.md#shipping-three-containers).

## Notarized DMG (Tauri macOS)

```sh
xless run --docker --config ~/ci/my-app.overlay.yml --platform macos
```

builds a Tauri v2 macOS app, universal (arm64 and x86_64), signs it with your Developer ID key, notarizes and staples a
DMG, and prints its path. The build runs without any secret; then `sign` and `package` run with
`XLESS_DEVID_KEY_FILE` and the App Store Connect key. From a source checkout, `make dmg CONFIG=<overlay.yml>` does the
same. Details, prerequisites and known gaps: [tauri.md](tauri.md#macos).

## macOS App-Store lane (TestFlight)

A macOS app can be delivered to TestFlight like the iOS one: an App-Store-signed .app packed into a
flat distribution package (`.pkg`) and uploaded to App Store Connect. The lane is opt-in:

- the overlay (or xless.yml) must ask for the mac distribution explicitly:
  `platforms.macos.distribution: app-store` — or `xless ship --platform macos --distribution app-store`;
- `--to upload` reaches it: the run ships **both** channels — the Developer-ID DMG exactly as the
  [DMG section](#notarized-dmg-tauri-macos) builds it, then the App-Store pkg (the app signed with
  `XLESS_DIST_KEY_FILE` under a `MAC_APP_STORE` provisioning profile embedded as
  `Contents/embedded.provisionprofile`, the pkg signed with `XLESS_INSTALLER_KEY_FILE`, uploaded, delivered to the
  `testflight.groups` block). Only that second ship has the two keys; the DMG ship has the Developer ID key. A
  failure in either channel stops the run with that channel's code; the DMG's bytes never depend on the second ship;
- App Store Connect refuses a package that is not signed with a Mac Installer Distribution certificate
  (ITMS-90237), which is why the lane has its own key: [bootstrap.md](bootstrap.md#5d-mac-installer-distribution-key-the-mac-app-store-package);
- ASC processing requires the mac app to carry **App Sandbox** (an App-Store/TestFlight
  build); a mac app that is deliberately non-sandboxed must stay on the DMG channel, or ASC rejects
  it.

Without `--to upload`, `--platform macos` is byte-for-byte the DMG run it has always been, and neither the
Apple Distribution nor the installer key need exist. Flat pkgs are assembled by xless itself (there is no
productbuild off macOS: payload cpio, Bom, `Distribution` file and the XAR container all written by xless, signature
by rcodesign); no `xar` tool is needed on the machine.

The app's `CFBundleVersion` is the dated build number. On macOS that is `<version>.<YYYYMMDDHHmm>`
([build numbers](tauri.md#macos)); Apple documents at most three period-separated integers for a Mac App Store
build, so if App Store Connect refuses it, set a fixed `build:` of up to three integers in the overlay.

## What `sign` changes on the account

`sign` needs three things on the account for each bundle it signs: its bundle ID, the capabilities its entitlements
use, and a profile named `xless <bundle ID> <TYPE>`. Before it changes anything it reads them all and prints, on
standard error, what is missing (or that nothing is), then does just that:

```
xless: sign: 3 changes on the account:
  enable PUSH_NOTIFICATIONS (Push Notifications) on com.example.app
  replace profile xless com.example.app IOS_APP_STORE (8U3T4X5YZA, which xless made): it does not carry PUSH_NOTIFICATIONS, enabled above
  create profile xless com.example.app.Widget IOS_APP_STORE (iOS App Store Connect for PlugIns/Widget.appex, with certificate 5B2C9D7E1F)
```

- It asks nothing and needs no Apple ID: the App Store Connect API key makes these changes, in CI too.
- It registers bundle IDs, enables capabilities (a capability that is enabled keeps its settings) and creates
  profiles. The only thing it ever deletes is a profile of that name, which xless made, when the profile cannot be
  used: expired or about to (within 7 days), invalid, for another certificate or bundle ID, or made before a capability
  the app uses. The plan gives the reason.
- It never makes or revokes a certificate (`xless sign bootstrap`), and never touches any other profile, app group,
  iCloud container, device or the app record. `xless provision` plans and makes those
  ([apple-account.md](apple-account.md#xless-provision)), from the same checks.
- A request whose answer is lost (a dropped connection, HTTP 5xx) is not sent again blindly: `sign` looks whether the
  bundle ID or the profile was made, and sends it again only when it was not.

To let `sign` change nothing, pass `--no-provisioning-updates` (`xless sign`, `xless ship`, `xless run …
--no-provisioning-updates`), or set `provisioningUpdates: false` in xless.yml or the overlay. `sign` then only reads:
when the account lacks something, it fails with exit code **24** and the list of it, and signs nothing. Make the
changes where that is wanted (`xless provision apply`, `xless profiles renew <id>`, or a `sign` without the
restriction), then run again. The flag only restricts: nothing on the command line turns the config's `false` off. A
missing certificate is exit 15 either way.

## Running `xless ship` yourself

You can also run xless directly in the image, passing secrets by name (`-e NAME`) so their values stay out of your
shell history and process list:

```sh
docker run --rm -v "$PWD":/work -w /work \
  -e ASC_KEY_ID -e ASC_ISSUER_ID -e ASC_KEY_P8 -e XLESS_DIST_KEY -e XLESS_BUILD_NUMBER=$(( $(date +%s) / 60 )) \
  xless:local-amd64 xless ship --platform ios
```

Use `xless:local-arm64` on an arm64 machine. Output ends up in `.xless/build/ios/out/`. The container runs as root, so
the files it creates in your project (`.xless/`, and for iOS builds `.build/`, `.bsp/`, `xtool/` and `xtool.yml`)
belong to root on a Linux host. Remove them with `sudo rm -rf .xless .build .bsp xtool xtool.yml`, or hand them back
with `docker run --rm -v "$PWD":/work -w /work alpine chown -R "$(id -u):$(id -g)" .xless .build .bsp xtool xtool.yml`.

## Continuous integration

[examples/example-ios.yml](examples/example-ios.yml) is a GitHub Actions workflow to copy into your app's repository
and adapt. It runs an image from your own private registry as the job container and ships with `xless ship`. It needs the repository variable `XLESS_IMAGE` and
the secrets `XLESS_REGISTRY_TOKEN`, `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_P8` and `XLESS_DIST_KEY`. It has not been
run yet. Images hold Apple's SDK, so they may only go to a registry that is private:
[maintainers.md](maintainers.md#private-registries).
