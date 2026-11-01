# Signing and TestFlight

Building an app up to `finalize` needs nothing from Apple but the SDK. Signing it, packaging it and uploading it to
App Store Connect need an Apple Developer Program membership and a few keys. This page covers those last stages, for
an `xless.yml` project and for the overlay apps (Tauri, React Native).

## Before you start

Do the one-time Apple setup in [bootstrap.md](bootstrap.md): an App Store Connect API key, a distribution key (iOS)
or a Developer ID key (macOS), the bundle ID and the app record. In your `xless.yml` (or overlay), set `teamID` to your
team and `bundleID` to the registered bundle ID; the sample's values are placeholders.

## Secrets

Secrets come only from environment variables or from a `NAME_FILE` variable naming a file that holds the value. They
are never command-line flags and are never logged.

| Variable | Purpose | Needed for |
|---|---|---|
| `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_P8` | App Store Connect API key (Admin role) | sign, upload, macOS notarization, `sign bootstrap` |
| `XLESS_DIST_KEY` | Apple Distribution private key (PEM) | iOS sign; the macOS App-Store lane's pkg sign |
| `XLESS_DEVID_KEY` | Developer ID Application private key (PEM) | macOS sign |

Values are tolerant of how CI systems mangle them: IDs are trimmed, and PEM values may have CRLF line endings or
literal `\n` sequences.

xless removes the secrets (and their `_FILE` forms) from the environment of every tool it runs, so package code
executed during `build` (SwiftPM macros and plugins) cannot read them from its environment; rcodesign gets keys
through mode-0600 temporary files. A file named by a `_FILE` variable is another matter: code that runs on the same
machine or in the same container as the build, as the same user, can still read it. That is why overlay apps are
built in [three steps](#the-three-step-split).

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
xless docker ~/MyApp
```

builds, signs, uploads and delivers an iOS `xless.yml` project to TestFlight (`xless ship --platform ios` in the
`xless` image). For an app described by an overlay use `xless docker --config <overlay.yml>`: a Tauri app
([tauri.md](tauri.md#shipping)) or a React Native / Expo app ([react-native.md](react-native.md#shipping-three-containers)).
Arguments after the project or overlay go to `xless ship`, for example `--from upload` to retry only the upload.
`xless docker` runs `share/xless/scripts/testflight.sh`; from a source checkout, `make testflight PROJECT=<dir>` (or
`CONFIG=<overlay.yml>`, with `ARGS="…"`) runs the same script.

- **Secrets file.** The script reads the paths of your secret files from the environment, or from a local file that it
  sources first: `~/.config/xless/testflight.env` (override with `XLESS_TESTFLIGHT_ENV`; it never belongs in git). The
  files are mounted read-only into the container; values are never printed or put on a command line. A run that stops
  before `sign` (`--to finalize`) needs none of them and mounts none.

  ```sh
  # ~/.config/xless/testflight.env
  ASC_KEY_ID=ABC123DEFG                          # the API key's ID
  ASC_ISSUER_ID_FILE=$HOME/keys/asc-issuer-id    # file holding the issuer ID (or set ASC_ISSUER_ID)
  ASC_KEY_P8_FILE=$HOME/keys/AuthKey_ABC123DEFG.p8
  XLESS_DIST_KEY_FILE=$HOME/keys/dist-key.pem    # Apple Distribution private key
  XLESS_DEVID_KEY_FILE=$HOME/keys/devid-key.pem  # Developer ID private key (macOS DMG only)
  ```

- **Images.** `xless:local-<arch>` for this machine's architecture, or the images of the Xcode the project pins with
  `xcode:` ([react-native.md](react-native.md#pinning-the-xcode-sdk)); `XLESS_IMAGE` names another image. The Docker
  context is `DOCKER_CONTEXT` when set, else `colima-xless` when that context exists, else the current one.
  `XLESS_USE_DOCKER=0` runs natively instead, with the `xless` on your `PATH` ([native-install.md](native-install.md)).
- **Build number.** `XLESS_BUILD_NUMBER` if set, else `$(( $(date +%s) / 60 ))`, which is monotonic across machines.
  With `--config` the overlay's `build:` decides instead ([tauri.md](tauri.md#build-numbers)).
- **Paths.** Relative secret paths are resolved against the current directory. The secret files and the project must
  be somewhere Docker can mount (on Linux, any local path).
- **Dry run.** `--dry-run` (or `XLESS_TESTFLIGHT_DRY_RUN=1`) prints the docker commands without running them.
- **Result.** xless prints the build number, each group and `available to N testers`; a group with no testers prints a
  warning. The exit code is xless's (17 for a failed upload or delivery).
- **Testers.** Internal testers must be App Store Connect users. Add them to the group once in the web UI (Users and
  Access, then TestFlight); xless creates missing groups but cannot add users. API details:
  [research/asc-testflight.md](research/asc-testflight.md).

With a project directory everything runs in one container, so package code built there could read the mounted key
files. If that matters to you, build up to `finalize` first, with no secret, then sign and upload what it built. Use
the same build number for both runs:

```sh
export XLESS_BUILD_NUMBER=$(( $(date +%s) / 60 ))
xless docker ~/MyApp --to finalize
xless docker ~/MyApp --from sign
```

## The three-step split

An overlay app's build runs third-party code: npm scripts, `build.rs`, CocoaPods hooks, Xcode build phases. So with
`--config`, `xless docker` never runs that code next to a secret. It uses three containers:

1. `xless next-build` (`xless tauri next-build` for Tauri), with the App Store Connect key only: the next `dated` build
   number, a read-only query. Skipped when `XLESS_BUILD_NUMBER` or `--build-number` is given.
2. `xless ship --to finalize`, with **no** secret file or variable: prepare, build, assets, finalize.
3. `xless ship --from sign`, with the secrets: sign, package, upload. No build code runs here.

`--from` and `--to` choose which steps run, and each step needs only its own secrets: `--build-number <n> --to
finalize` needs none. The overlay's folder and the app source are mounted into the build container, so the script
refuses to start when either holds the secrets file or a secret file. Details: [tauri.md](tauri.md#shipping) and
[react-native.md](react-native.md#shipping-three-containers).

## Notarized DMG (Tauri macOS)

```sh
xless docker --config ~/ci/my-app.overlay.yml --platform macos
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
  [DMG section](#notarized-dmg-tauri-macos) builds it, then the App-Store pkg (signed with
  `XLESS_DIST_KEY_FILE`, uploaded, delivered to the `testflight.groups` block). A failure in either
  channel stops the run with that channel's code; the DMG's bytes never depend on the second ship;
- ASC processing requires the mac app to carry **App Sandbox** (an App-Store/TestFlight
  build); a mac app that is deliberately non-sandboxed must stay on the DMG channel, or ASC rejects
  it.

Without `--to upload`, `--platform macos` is byte-for-byte the DMG run it has always been. Flat pkgs
are assembled by xless itself (there is no productbuild off macOS: payload cpio, Bom written by
xless, `Distribution` file, XAR via the container's xar, signature by rcodesign).

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
