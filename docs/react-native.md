# React Native / Expo apps (iOS)

xless builds a React Native app that uses Expo on Linux and ships it to TestFlight, with no Mac and no Xcode on the build machine. It runs the same steps as a Mac build: the JS install, `expo prebuild`, `pod install`, then the Xcode workspace. The workspace is built with [Swift Build](https://github.com/swiftlang/swift-build), the open-source engine behind `xcodebuild`, instead of Xcode. The app repository stays untouched: everything xless needs to know lives in an **overlay** file kept outside it.

```sh
xless run --docker --config ~/ci/my-app.overlay.yml
```

## Try the sample

The source repository has a small Expo app with an app extension, `samples/HelloRN`, and its overlay. With the images
from `xless setup --docker` ([README](../README.md#build-in-docker-instead)), build it up to `finalize`, unsigned and with no Apple
account:

```sh
git clone https://github.com/fmsouza/xless.git
xless run --docker --config xless/samples/HelloRN/xless.overlay.yml --build-number 1.0.0.2026101601 --to finalize
```

The first run downloads the JavaScript packages, the gems and the pods, and compiles React Native, which takes a
while. The app stays in a Docker volume; [Getting the build out](#shipping-three-containers) shows how to copy it.

## What is supported

- **Contract.** xless reproduces a Release `xcodebuild` of the Expo-generated workspace for **Expo SDK 57**, **React Native 0.86.x** and **CocoaPods 1.15.2** with **Bundler 2.7.2**.
  - React Native and Expo are read from the installed `node_modules`, the way Node resolves them from the app.
  - CocoaPods and Bundler are read from the nearest `Gemfile.lock` above `<app>/ios`.
  - Another version stops `prepare` with "outside the contract xless supports".
  - The image supplies Node 24, Ruby 3.4, Hermes `hermesc` (built from source, the version React Native 0.86 ships) and Swift Build 6.4. The measurements behind the contract are in [research/react-native-ios-contract.md](research/react-native-ios-contract.md).
- **Native project.** Two layouts are supported:
  - **Expo CNG**: no `ios/` in git. `prepare` runs `expo prebuild --platform ios` in the work copy.
  - **Committed `ios/`**: `ios/Podfile` or an `ios/*.xcodeproj` is tracked. `prepare` runs only `pod install`.

  Either way the app depends on the `expo` package. A React Native app without Expo is refused.
- **Dependencies.**
  - JS: the frozen install of the committed lockfile: `npm ci`, or pnpm or yarn through corepack (which honours `packageManager`). The install runs in the app's directory, or in the nearest one above it with a `package.json` and a lockfile (a monorepo's root).
  - Pods: CocoaPods, with prebuilt xcframeworks and pods built from source.
  - Swift packages referenced by the Xcode project: pinned to a commit revision (see [known gaps](#known-gaps)).
  - Git submodules in the app repository are refused.
- **Build.** Release (or another non-Debug configuration), arm64, device only. JavaScript is bundled and compiled to Hermes bytecode. Every build phase of the app and the pods runs; a phase that calls a command missing from the image fails the build ([`allowMissingCommands`](#overlay-reference)), and so does any call an xless tool shim refuses, even when the phase goes on without it. Pods' asset catalogs (`s.resources`) are compiled by CocoaPods' `[CP] Copy Pods Resources` phase through `xcrun actool`, as on a Mac.
- **App extensions.** The app target and every extension it embeds (`PlugIns/*.appex`, `Extensions/*.appex`) get their bundle IDs from the overlay. Each one is signed with its own provisioning profile and its own entitlements ([signing](#signing-app-extensions)). Watch apps and App Clips are refused at `build`: their target types are not supported.
- **Then the usual stages:** assets (a copy-through: Swift Build already compiled the asset catalogs), finalize, sign, package, upload and TestFlight delivery ([pipeline.md](pipeline.md#stages)).
- **Simulator builds.** `--destination simulator` builds an ad-hoc signed arm64 app for the iOS Simulator, without secrets, so a build can be launched on a Mac before it is uploaded ([below](#simulator-builds)).
- **dSYMs.** A device build keeps the debug symbols Swift Build generates (`DEBUG_INFORMATION_FORMAT = dwarf-with-dsym`, Expo's Release default) and `package` zips them next to the `.ipa` ([below](#dsyms)).
- **Not supported.** Debug builds, x86_64 app binaries (device or simulator; the host may be arm64 or amd64, see [Requirements](#requirements)), Android, dSYM upload, external TestFlight groups, App Store submission.

## Requirements

- To sign and upload: the one-time Apple setup from [bootstrap.md](bootstrap.md) (API key, distribution certificate), and the secrets file described under [One command: TestFlight](signing-and-testflight.md#one-command-testflight).
- The `xless-rn` image. It adds Ruby, Bundler, Swift Build, `hermesc` and the Xcode tool shims to `xless-tauri`. Steps 1 and 3 of `xless run --docker --config` use `xless-base`. `xless setup --docker` builds them all ([README](../README.md#build-in-docker-instead)); to build with another Xcode's SDK, run it with that Xcode ([Pinning the Xcode](#pinning-the-xcode-sdk)).
- A Linux host of either architecture. The `xless-rn` image exists for `linux/arm64` and `linux/amd64` (`xless setup --docker --arch arm64 --arch amd64` builds both; `--arch` replaces the default, this machine's architecture), and the app it builds is the same arm64 iOS app on both; `scripts/arch-compare.sh <app built on arm64> <app built on amd64>` checks that. On an Apple-silicon Mac the amd64 image runs under Rosetta; the Docker VM must have it enabled (`/mnt/lima-rosetta` exists in the VM and `/proc/sys/fs/binfmt_misc/rosetta` is registered). QEMU user-mode emulation is not enough: it crashes gcc and the Swift Build compile at random.
- The app repository is a git checkout. xless copies the **tracked** files of `source:` (and only those) into a work copy; the source is never written to. Commit the lockfiles (`package.json` with its lockfile, `Gemfile` and `Gemfile.lock`) and the files the overlay refers to. Uncommitted edits to tracked files are copied; untracked and ignored files are not.
- A work copy belongs to one source and is named after the overlay file. The first sync records the source, and a later run of an overlay with the same file name but another source stops at `prepare`.
- Network access: `prepare` downloads from npm, RubyGems and CocoaPods (specs and pods), and `build` first clones the project's remote Swift packages, if it has any. Swift Build itself runs offline.

## The overlay

[samples/HelloRN/xless.overlay.yml](../samples/HelloRN/xless.overlay.yml) is a complete example: an Expo app with one app extension. For an app in a monorepo:

```yaml
type: react-native
source: ~/projects/my-repo             # the git checkout (read-only)
app:
  dir: apps/client                     # the app inside it: its package.json, app.json, ios/
env:
  FEATURE_X: enabled                   # read by the app's own config (app.config.js, scripts)
prepare:
  run: [bash tools/gen.sh]             # after the JS install, before expo prebuild
scheme: MyApp
configuration: Release
bundleIDs:
  MyApp: com.example.myapp
  MyAppWidget: com.example.myapp.widget
teamID: ABCDE12345
version: 2.3.0
build: dated
usesNonExemptEncryption: false
testflight: { groups: [Internal] }
```

### Overlay reference

Relative paths in the overlay (`source`, `privacyManifest`) resolve against the **overlay file's directory**; `~` is expanded. Unknown keys are refused, so a misspelt key never goes unnoticed.

| Key | Meaning |
|---|---|
| `type` | Required. Must be `react-native`. |
| `source` | The app repository, read-only. Required unless `--source <dir>` (or `$XLESS_SOURCE` with `xless run --docker`) gives it. It may be a subdirectory of a git checkout. |
| `app.dir` | The app's directory inside the source: where its `package.json`, `app.json` and `ios/` are. Default `.`. A relative path without `..`. |
| `env` | Variables for the app's own tooling. They are set for `prepare.run`, `expo prebuild`, CocoaPods and the build's script phases (Expo evaluates the app config again while building). Names xless sets itself (`PATH`, `HOME`, `SDKROOT`, `DEVELOPER_DIR`, `CI`, `BUNDLE_PATH`, `COREPACK_HOME`, `TAR_OPTIONS`, `EXPO_NO_TELEMETRY` and a few more, every `XLESS_*` and `SWIFT_*`) and the secret names are refused; the error names the key. xless never prints the values (`inspect` lists the names). |
| `prepare.run` | Shell commands (`sh -c`, in order, in the work copy's root) run after the JS install and before `expo prebuild`, for example the app's config generator. They run in the build container, without secrets. A command that patches a file under `node_modules` must replace the file, never edit it in place: with pnpm, the work copy's `node_modules` files are hard links into the store, which every work copy shares, so an in-place edit changes the package for all of them. Write a new file and rename it over the old one (GNU `sed -i` does that), or better, patch through the package manager (`pnpm patch`, `patchedDependencies`). |
| `scheme` | Required. The shared Xcode scheme to build; Expo names it after the app target. |
| `configuration` | Default `Release`. `Debug` is refused: a debug build loads JavaScript from a Metro server. |
| `bundleIDs` | Required. Xcode target name → bundle ID, for the app target **and every extension it embeds**. The build checks that the keys are exactly those targets: a missing, extra or misspelt entry is refused, with the list it expected. Extension IDs must start with the app's ID plus `.`. Before the first `prepare`, the app's entry is the one named like the scheme, else the only one, else the one whose ID every other entry's starts with (plus `.`), so a committed `ios/` whose scheme is named unlike its app target works too. |
| `teamID` | Required. The 10-character Apple team ID. |
| `version` | `CFBundleShortVersionString`. Default: `expo.version` from `app.json`, else `version` from `package.json`. Set it when the version is computed (`app.config.js`) or has a pre-release suffix (`1.2.0-beta` is refused): it must be known before the native project exists. |
| `build` | `dated` (default): `<version>.<YYYYMMDDNN>`, chosen above every build of that version already in App Store Connect, as for [Tauri](tauri.md#build-numbers). Or an explicit build number. The value is set on the app and on every extension. |
| `allowMissingCommands` | Command names a build phase may find missing with only a warning. By default a phase that runs a command the image lacks fails the build: such phases usually exit 0 and silently skip their work. Only list a command whose work the app does not need. It does not cover a shim's `unsupported call`: the tool is there, and that call fails the build. |
| `identifiers.replace` | Literal text → replacement in every string value (nested arrays and dictionaries too; never keys) of every bundle's entitlements, applied at `sign`, **and** of the app's own `Info.plist`s, applied at `finalize` so the signature seals them: the app's and its extensions', and another bundle's (a framework, a resource bundle) only when its own `CFBundleIdentifier` is one of the keys or starts with one (the other team's own code; that bundle ID is kept). Third-party frameworks are left alone. Every string value of those files is covered, URL schemes included (`CFBundleURLSchemes`), and files not named `Info.plist` (`GoogleService-Info.plist`, …) are not. Keys are whole identifiers (4+ characters with a `.`) and match only where an identifier ends: the next character is not a letter, digit or `-` (`com.other.app` matches `group.com.other.app`, `com.other.app.share` and `com.other.app:/cb`, never `com.other.apple`). Values are non-empty; longest match first, one pass. Use it when the app is signed by a team that does not own its identifiers, e.g. `{ com.other.app: com.example.myapp }` maps `group.com.other.app` and the keychain group together, in the entitlements and in Info.plist keys the app reads at run time. `finalize` logs the count and the key path of every Info.plist value it replaced, and records the map (`final/identifiers.json`): `sign` refuses a map changed since (re-run from `finalize`). A replacement that would change the app's or an extension's `CFBundleIdentifier` is refused: bundle IDs come from `bundleIDs`. The former `entitlements.replace` is refused with a pointer here. |
| `entitlements.remove` | Applied at `sign`: top-level entitlement keys dropped from every bundle, e.g. a capability the signing team cannot have. |
| `xcode` | The Xcode whose SDK builds the app, e.g. `xcode: "26.2"` (quote it). Default: the image's SDK. Pin the Xcode of the app's own release pipeline: an SDK changes what UIKit enforces at launch ([below](#pinning-the-xcode-sdk)). |
| `testflight` | `groups`, `whatToTest`, `locale`: as in [xless.yml](xless-yml.md#testflight). |
| `usesNonExemptEncryption` | `ITSAppUsesNonExemptEncryption`, stamped at `finalize`. |
| `privacyManifest` | A `PrivacyInfo.xcprivacy` copied into the app, replacing the app's own. Without it the one Expo generates must be in the bundle (`finalize` checks). |

`xless inspect --config <overlay> [--source <dir>]` prints, read-only, what a build would do:
- the scheme, the app target and the extensions it embeds, each bundle ID next to the project's own;
- the Swift packages;
- the React Native, Expo, CocoaPods and Bundler versions against the contract;
- the names (never the values) of the `env` variables;
- the next dated build number, when App Store Connect credentials are set.

Before the first `prepare` it says what is still unknown.

## The pipeline

| Stage | What happens for `type: react-native` |
|---|---|
| prepare (19) | First refuses an image whose SDK is not the pinned Xcode's, or whose Swift does not match that Xcode's Swift (`[prepare] the overlay pins xcode: …`, [below](#pinning-the-xcode-sdk)), before anything else runs. Checks the contract; syncs the work copy; installs the JS dependencies; runs `prepare.run`; runs `expo prebuild` (CNG) and `bundle install` + `bundle exec pod install`; checks `Pods/Manifest.lock` equals `Podfile.lock`; runs the pods' configuration-switch phases (Expo's precompiled modules, React Native core, its dependencies, Hermes) for the overlay's configuration, so the build never replaces prebuilt frameworks while it runs. Refuses to run outside the `xless-rn` image. |
| build (12) | Checks the image's SDK against `xcode:` again and records it in `.xless/build/ios/sdk.json` ([below](#pinning-the-xcode-sdk)). Finds the scheme's app target and its extensions and checks `bundleIDs`; clones the Swift packages at their pinned revisions; writes the PIF with the bundle IDs and versions as per-target settings; runs Swift Build. Copies the `.app`, stamps every bundle's version and build number, and writes `entitlements.json` and `packages.json` next to it in `.xless/build/ios/`, and every `.dSYM` Swift Build wrote in `.xless/build/ios/dSYMs/` ([dSYMs](#dsyms)). |
| assets (13) | Copy-through. |
| finalize (14) | Replaces `identifiers.replace` in the app's and its extensions' Info.plists (and records the map for `sign`), then Xcode metadata as for every app, stamped from the SDK the build recorded. |
| sign (15) | Every bundle with its own profile and entitlements ([below](#signing-app-extensions)). |
| package, upload (16, 17) | As for every app; `package` also zips the dSYMs into `out/<Product>.app.dSYM.zip`. |

Without the script each stage is a command: `xless prepare|build|assets|finalize|sign|package|upload --config <overlay> [--source <dir>] --platform ios`. `build` runs `prepare` first, and so does `xless ship`, which takes `--from`/`--to`. `xless next-build --config <overlay>` prints the build number the next run would use (read-only).

## Shipping: three containers

```sh
xless run --docker --config ~/ci/my-app.overlay.yml [extra args, e.g. --from upload]
```

The build runs third-party code: npm scripts, `prepare.run`, Expo's config plugins, CocoaPods hooks and every Xcode build phase. So it never runs next to a secret. The script reads the overlay's `type:` and runs three containers:

1. **`xless next-build`**, in `xless-base` (xless and rcodesign, no build tools), with the App Store Connect key only. It prints the next `dated` build number (a read-only query); the version and app bundle ID come from the overlay and the source, so no work copy is needed. Skipped when `XLESS_BUILD_NUMBER` or `--build-number` is given, or when resuming after `build`.
2. **`xless ship --to finalize`**, in `xless-rn`, with that number in `XLESS_BUILD_NUMBER` and **no** secret file or variable: prepare, build, assets, finalize.
3. **`xless ship --from sign`**, in `xless-base`, with the secrets: sign, package, upload. It reads the finalized `.app`, the build's `entitlements.json` and `build-number`, and the overlay, and it parses the work copy's Xcode project and the app's `app.json` / `package.json` for the version; it never runs any of them. No build code runs here.

`--from <stage>` and `--to <stage>` among the extra arguments choose which steps run; other extra arguments go to both `ship` steps. A step's secrets are needed only when it runs:

```sh
# offline, no credentials: build and finalize with an explicit build number, then stop
xless run --docker --config ~/ci/my-app.overlay.yml --build-number 2.3.0.2026101601 --to finalize
# later, with credentials: sign, package and upload what that run built
xless run --docker --config ~/ci/my-app.overlay.yml --from sign
```

`--dry-run` (or `XLESS_TESTFLIGHT_DRY_RUN=1`) prints the docker commands without running them.

**Mounts.**
- **The source** is read-only at `/source`. A source inside a git checkout but not at its top mounts the checkout's top and passes `--source /source/<path>`, because xless lists tracked files with git. The script stops (exit 2) when that directory holds a secret file.
- **The overlay's folder** is read-only at `/config`. Keep the overlay in its own directory: the script stops when the folder holds the secrets file or a secret file, symlinks resolved.
- **The work copy** is in a docker volume at `/cache/work`, in steps 2 and 3: one per overlay file, `xless-rn-work-<overlay name>-<8 hex digits of a hash of its path>` (the script prints it), or `XLESS_RN_WORK_VOLUME`. It holds the work copy, its derived data and the pnpm store. It is a volume, not a host folder: the build needs a case-sensitive file system, and a macOS folder shared into the Docker VM is case-insensitive (the build's lowercase framework links would collide with the frameworks).
- **The caches** of step 2 are the volumes `xless-corepack` (package managers), `xless-bundle` (the app's gems), `xless-cocoapods-home` (the specs repository) and `xless-cocoapods-cache` (pod downloads).

Docker creates every volume on first use.

**Variables** (on top of [One command: TestFlight](signing-and-testflight.md#one-command-testflight)):

| Variable | Meaning |
|---|---|
| `XLESS_IMAGE` | Step 2's image. Default `xless-rn:local-<arch>`. |
| `XLESS_SIGN_IMAGE` | Steps 1 and 3. Default `xless-base:local-<arch>`. It must hold the same xless build as step 2's image: the script compares the two binaries before it starts and stops (exit 2) when they differ. |
| `XLESS_RN_WORK_VOLUME` | The work volume. Default: one per overlay file (above). |
| `XLESS_RN_CLEAN=1` | Passed to step 2: `prepare` reinstalls the JS dependencies and regenerates `ios/` and the pods. |
| `XLESS_SOURCE` | Replaces the overlay's `source:`. |
| `XLESS_BUILD_NUMBER` | Replaces the `dated` lookup (step 1 is skipped). With `build: dated` it must be `<version>.<YYYYMMDDNN>`. |

The script reads `type:` and `source:` from plain top-level `key: value` lines (quotes and a trailing comment are fine); set `XLESS_SOURCE` when `source:` is written another way.

**Getting the build out.** The `.ipa` stays in the volume, at `/cache/work/<overlay name>/.xless/build/ios/out/`. Copy it out with `docker run --rm -v <work volume>:/w -v "$PWD":/out alpine cp /w/<overlay name>/.xless/build/ios/out/<Product>.ipa /out/` (with `--context` as the script chose it: `DOCKER_CONTEXT`, else `colima-xless` when it exists). A build stopped at `finalize` is in `/w/<overlay name>/.xless/build/ios/final/` instead; copy it with `cp -r`.

**Native.** `xless run` refuses an overlay on Linux without `--docker`; from a source checkout, `XLESS_USE_DOCKER=0 make testflight CONFIG=…` runs the three steps without docker. Step 2 needs everything the `xless-rn` image adds (Ruby, Bundler, Swift Build, `hermesc`, the shims in `docker/shims/rn`, `/bin/sh` as bash). Native React Native builds are untested.

## dSYMs

Swift Build runs `dsymutil` for every target whose `DEBUG_INFORMATION_FORMAT` is `dwarf-with-dsym`, as Xcode does. After a device build, `build` copies every `.dSYM` under the products directory (`.xless/derived-data/Products/<configuration>-iphoneos/`) to `.xless/build/ios/dSYMs/`, at the same relative path: the app's and each extension's at the top, those of the frameworks a pod vendors (Expo's precompiled modules) under `XCFrameworkIntermediates/<pod>/`. That is what `xcodebuild archive` collects into an archive's `dSYMs/`, except that only the dSYMs of binaries the app ships are kept (a UUID of the dSYM is one of the app's, its frameworks' or its extensions'): the derived data is kept between builds, so it can still hold the dSYM of a target or pod removed since. `package` zips them into `out/<Product>.app.dSYM.zip`, the name fastlane's `gym` gives it, ready for a crash reporter's upload tool (Crashlytics' `upload-symbols`, `sentry-cli debug-files upload`). xless uploads nothing. Signing, `finalize` and `strip` do not change a Mach-O's `LC_UUID`, so the dSYMs match the shipped binaries. A simulator build keeps none.

## Simulator builds

A build that uploads fine can still die at launch: a missing symbol, an Info.plist the OS refuses, a JavaScript error. Launch every build on the iOS Simulator before uploading it:

```sh
xless run --docker --config ~/ci/my-app.overlay.yml --destination simulator   # on Linux, in docker: build for the simulator
# ==> Simulator app: volume:xless-rn-work-my-app-1a2b3c4d:/cache/work/my-app/.xless/build/ios-simulator/app/MyApp.app
make sim-launch APP=volume:xless-rn-work-my-app-1a2b3c4d:/cache/work/my-app/.xless/build/ios-simulator/app/MyApp.app   # on a Mac, from a source checkout
```

`xless run --docker --config <overlay> --destination simulator` (`make simulator CONFIG=…` from a source checkout) runs only step 2 (`xless ship --destination simulator`: prepare and build) with no secret and no App Store Connect query. A `dated` build number comes from the clock (`<version>.<YYYYMMDD>01`). Without the script: `xless build --config <overlay> --platform ios --destination simulator`.

What differs from a device build, matched to an Xcode 27.0 simulator build of the same workspace:
- **Destination.** Swift Build builds for `iphonesimulator`, arm64 only (`SDKROOT = iphonesimulator`, `ARCHS = arm64`), for an Apple-silicon Mac's simulator. Xcode's generic simulator destination also builds x86_64. CocoaPods' `[CP] Embed Pods Frameworks` phase then strips x86_64 from the vendored fat frameworks with `lipo -remove`, which the `lipo` shim maps to `llvm-lipo -extract` of the remaining slices. Expo's ExpoModulesJSI phase builds its simulator slice through the `xcodebuild` shim (`-sdk iphonesimulator -destination "generic/platform=iOS Simulator"`), also arm64 only. The actool shim takes `--platform iphonesimulator` and writes the same files as for the device, as Xcode's actool does for the asset catalog.
- **Separate outputs.** Derived data in `.xless/derived-data-simulator`, the app and its build number in `.xless/build/ios-simulator/`. The device build's derived data and `.xless/build/ios/` are left alone. The work copy (and so `prepare`) is shared.
- **Entitlements.** The simulator reads an app's entitlements from its executable. Each bundle's executable gets `__TEXT,__entitlements` (XML) and `__TEXT,__ents_der` (DER), linked through Swift Build's simulator-only `LD_ENTITLEMENTS_SECTION(_DER)` settings, as Xcode links its `<product>-Simulated.xcent`. They hold the target's entitlements file with `$(AppIdentifierPrefix)` as `<teamID>.`, the overlay's `identifiers.replace` and `entitlements.remove`, and `application-identifier`. Every bundle's Info.plist gets `identifiers.replace` before the ad-hoc signature (a simulator build has no `finalize`).
- **Signing.** Ad hoc, with no key, by `rcodesign` in the build container: the app and its extensions with empty entitlements, every framework without any, as Xcode's "Sign to Run Locally". The simulator refuses an unsigned arm64 app.
- **Stages.** `build` is the last one. `assets`, `finalize`, `sign`, `package` and `upload` refuse `--destination simulator`. `build` also refuses an image whose LINKEDIT `dyld` would reject, as `finalize` does.

`scripts/sim-launch.sh` (Mac only; `make sim-launch APP=…`) copies the `.app` out of the work volume (or takes a host path). It runs `codesign --verify --deep --strict` on it and boots a simulator named `xless-sim`, created on the newest iOS runtime if missing. It installs and launches the app, then checks that the app is still running after `--seconds` (default 10). It keeps everything in `~/.cache/xless/sim/<App>/`: the app's stdout and stderr (`console.log`), the simulator's log for its process (`device.log`), `screenshot.png`, and the crash reports ReportCrash wrote since the launch (`crash/*.ips`). It exits 0 when the app is running and 1 when it is not.

The simulator runs the same JavaScript bundle, frameworks, Info.plist and entitlements as the device build, so most launch failures show up there. It cannot show what only a device checks: the distribution signature and provisioning profile, entitlements a profile does not grant, or hardware-specific code.

## Signing app extensions

`sign` treats the app and each `PlugIns/*.appex` or `Extensions/*.appex` as its own target. For each one, extensions first, then the app:

1. Register the bundle ID.
2. Enable the capabilities its entitlements need ([below](#capabilities)).
3. Get an App Store profile named `xless <bundle ID> IOS_APP_STORE`.
4. Embed it as `embedded.mobileprovision` in that bundle.

Then one `rcodesign` call signs every bundle, each with its own entitlements. rcodesign signs nested bundles before the app, so the app's seal covers the signed extensions.

The entitlements come from the build's `entitlements.json`: each target's `CODE_SIGN_ENTITLEMENTS` file with build settings expanded. Then:
- `$(AppIdentifierPrefix)` and `$(TeamIdentifierPrefix)` become `<teamID>.`;
- the overlay's `entitlements.remove` and then `identifiers.replace` apply;
- xless adds `application-identifier`, `com.apple.developer.team-identifier`, `get-task-allow` and `beta-reports-active`, and `aps-environment` takes the profile's value.

Before anything is signed, the profiles must grant every key and value:
- a keychain group must match the profile's `<team>.*`;
- an app group must be in the profile's list;
- associated domains must be allowed by the profile.

Refused before any App Store Connect call:
- an extension that is a symlink, has `:` or `@` in its name, or carries its own `Frameworks/` (embed frameworks in the app's);
- an extension bundle ID that does not start with the app's;
- an `entitlements.json` that does not describe exactly the bundles in the app (run `xless build` again).

## Capabilities

| Enabled by xless through the App Store Connect API (iOS) | Portal only |
|---|---|
| Push Notifications (`aps-environment`), Associated Domains, AutoFill Credential Provider, App Groups (the capability, not the group) | App Attest, Declared Age Range, Increased Memory Limit, Extended Virtual Address Space, and any other capability the API has no type for |

**Portal-only capability.** When a profile lacks a key the API cannot enable, `sign` regenerates the profile once, in case it was enabled by hand since. If the key is still missing it stops:

```
[sign] entitlement 'com.apple.developer.devicecheck.appattest-environment' is not granted by the provisioning profile for com.example.myapp; xless cannot enable this capability automatically — enable the matching capability (App Attest) for com.example.myapp at developer.apple.com/account/resources/identifiers, then re-run. Finish every portal step before re-running: each run regenerates the profiles that still lack something
```

1. Go to developer.apple.com/account/resources/identifiers.
2. Open the bundle ID named in the message.
3. Tick the capability under **Capabilities**, then **Save**.
4. Run `sign` (or `xless run --docker --config … --from sign`) again.

To ship a test build without the capability, drop the key with `entitlements.remove` instead.

**App groups.** The API can enable App Groups on an identifier but can neither create a group nor assign one. A group missing from a profile stops `sign` with one message covering every bundle that uses it. At developer.apple.com/account/resources/identifiers:

1. **Identifiers → + → App Groups → Continue**, enter the group identifier (`group.com.example.myapp`), **Register**. Skip this when the group exists.
2. For each bundle ID the message lists: open it, **App Groups → Configure**, select the group, **Save**.
3. Re-run `sign`. xless regenerates the profiles that predate the assignment.

**Finish every portal step before re-running.** Each run that still finds something missing deletes and recreates the affected profiles.

**Another team's identifiers.** An app signed under a team that does not own its app group or keychain group (a test build under a personal team, for example) maps them with `identifiers.replace`, e.g. `{ <original app ID>: <your app ID> }`. The map applies to the entitlements (at `sign`) and to every string value of the app's and its extensions' Info.plists (at `finalize`; for a simulator build, before its ad-hoc signature), so an app that reads its group name from an Info.plist key opens the group it is signed for. `finalize` prints what it replaced:

```
xless: identifiers.replace: 3 Info.plist value(s) replaced: Info.plist: SharedContainerGroup, Info.plist: SharedKeychainGroup, PlugIns/Share.appex/Info.plist: SharedContainerGroup
```

What else changes:
- **URL schemes.** Every string value is rewritten, so a URL scheme that is the original app ID (Expo adds the bundle identifier as a scheme) becomes the new one, which is what Expo would generate for the new bundle ID. Links that open the app with the original scheme then do not reach this build. The log names each one (`CFBundleURLTypes[0].CFBundleURLSchemes[1]`).
- **Embedded bundles.** A framework or resource bundle is rewritten only when its own `CFBundleIdentifier` is one of the map's keys or starts with one (at an identifier boundary); its bundle ID is kept, since its code may look itself up by it. Third-party frameworks are never touched, even when a value of theirs contains a key.
- **Other files.** Only files named `Info.plist` are rewritten: `GoogleService-Info.plist`, JSON configuration and other resources keep the original identifiers.
- **Resuming.** `sign` checks the map against the one `finalize` applied (`final/identifiers.json`). After editing `identifiers.replace`, run again from `finalize` (`--from finalize`); `--from sign` is refused.

A group name compiled into the JavaScript bundle or native code is not rewritten: it still names the original group at run time.

## Pinning the Xcode (SDK)

An SDK decides more than the headers. UIKit enforces some rules only for apps linked against a recent SDK: an app built with the iOS 27 SDK that has not adopted the UIScene life cycle stops at launch on iOS 27 ("UIScene life cycle is required for apps built with this SDK"), while the same app built with the iOS 26.2 SDK launches. To be a drop-in replacement for an app's own release pipeline, xless must build it with the same Xcode's SDK. Pin it in the overlay:

```yaml
xcode: "26.2"      # the Xcode of the app's release pipeline
```

- **Images per Xcode.** Each image chain bakes one SDK. `xless setup --docker --xcode <Xcode .xip | Xcode.app> [--arch …]` (on the Mac, from a source checkout: `make images XCODE=…`, [maintainers.md](maintainers.md#building-the-images-on-the-mac)) builds `xless-base`, `xless`, `xless-tauri` and `xless-rn` from that Xcode and tags them `:local-<arch>-xcode<version>-<build>` (e.g. `xless-rn:local-arm64-xcode26.2-17C52`, never moved by another Xcode build) and `:local-<arch>-xcode<version>` (e.g. `xless-rn:local-arm64-xcode26.2`, what a pin selects). The version is written as major.minor, plus the patch when it is not 0. Two builds of one version (a beta and the release) share the version tag: when it names another build, `xless setup` stops before building, and `XLESS_XCODE_RETAG=1` moves it to this build (the other build keeps its `-xcode<version>-<build>` tags, usable through `XLESS_IMAGE`). The exported SDK stays in `~/.cache/xless/sdk/xcode<version>-<build>/` (`dist/sdk-xcode<version>/` for `make images`) and in the images. When the Xcode is the default one (`XCODE_VERSION`/`XCODE_BUILD` in `versions.env`), the plain `:local-<arch>` tags are set too; they never move to another Xcode.
- **`xless run --docker`** reads the `xcode:` line and runs every step in that Xcode's images. A missing image stops the script with the command that builds it:

  ```
  testflight: …/my-app.yml pins xcode: "26.2", but these images are missing: xless-rn:local-arm64-xcode26.2 xless-base:local-arm64-xcode26.2; build them from Xcode 26.2: xless setup --docker --xcode <path to Xcode 26.2's .app or .xip> --arch arm64
  ```

  The pin is looked up as the tags spell versions: `xcode: "26"` selects `-xcode26.0`, `"26.2.0"` selects `-xcode26.2`. For the default Xcode the plain images serve when no suffixed ones exist. A simulator build (`--destination simulator`) needs only the `xless-rn` image. `XLESS_IMAGE` / `XLESS_SIGN_IMAGE` still win.
- **Prepare and build check the SDK.** The image's toolchain metadata (`/opt/xless/toolchain-meta.json`, written by `xless setup --docker` from the exported SDK) must be the pinned Xcode, and its Swift toolchain record that Xcode's Swift. `prepare` checks first, before the work copy, the JS install, prebuild and CocoaPods run, and refuses with exit 19: `[prepare] the overlay pins xcode: "26.2", but this image has the iphoneos27.0 SDK from Xcode 27.0 (27A266a) — …`. `xless build`, `xless ship` and `xless run --docker` run `prepare` first, so they stop there. `build` checks again (exit 12, `[build] …`), which is what an xless.yml project, which has no prepare stage, prints. The build stage prints the SDK (`xless: SDK: Xcode 27.0 (27A266a), iphoneos27.0 SDK (24A430), pinned by xcode: "27.0"`) and records it in `.xless/build/ios/sdk.json` (`ios-simulator/` for a simulator build).
- **A Swift matching the Xcode's compiles (Ruling R10).** Each image chain also carries an open-source Swift toolchain whose version matches the Swift its Xcode ships (Apple's own toolchain is never in an image): `versions.env` maps the Xcode build to an open-source Swift release (`XCODE_SWIFT_<build>`, e.g. `XCODE_SWIFT_17C52=6.2.3` for Xcode 26.2), measured black-box from the Xcode's own `swift --version` and chosen by one rule: the same major.minor as Apple's Swift and the highest patch release not above it. The image build refuses an Xcode without an entry (`scripts/xcode-swift.sh` prints the line to add) and installs any release other than the image's own Swift (`SWIFT_VERSION`) under `/opt/xless/toolchains/swift-<version>`, recorded in `/opt/xless/swift-toolchain.json`. Every compile of app code uses it:
  - React Native: Swift Build's toolset names its `swiftc`, `clang` and `clang++`, and it is Swift Build's toolchain (first `swift` on PATH: `swift-frontend`, the dependency scanner, `xcrun swiftc` in build phases). Swift Build itself is the same release (6.4) in every image, compiled with that toolchain: its build service loads the toolchain's dependency scanner in process, and that library needs the Swift runtime it was built with. SwiftPM's `dump-pif` for package references stays on the image's own Swift, whose PIF format Swift Build reads.
  - SwiftPM apps (xless.yml) and Tauri: the build stage puts the toolchain before the image's own Swift on PATH, so `xtool`'s `swift build`, Tauri's Swift package aggregate (with that toolchain's SwiftPM), its native compile and link, and cargo's C compilers use it.
  - The clang resource headers are the toolchain's own: Apple's clang headers belong to Apple's clang build (Xcode 26.2's `arm_vector_types.h` uses `__mfp8`, which open-source clang 17 does not know). The Darwin runtime libraries (`lib/darwin/libclang_rt.*`), Swift's resource directory (shims, C++ interop overlays, back-deployment libraries) and the SDK stay the Xcode's. Links stay `ld64.lld` through xless's wrapper (the toolchain's own `ld64.lld` runs the SDK's).
  - The open-source release is not Apple's build of it. Measured differences bridged in the image, in both chains: the 26.2 pin's Swift 6.2.3 (clang 17) against Xcode 26.2's clang 17, and the image's own Swift 6.4 (clang 21) against Xcode 27's clang 21. For a 26.2 pin: the clang resource headers (above); a driver that drops `-fno-cxx-modules` (a C++ `#include` of a module-mapped header then fails: `module 'ReactCodegen' is needed but has not been provided`); and no predefined `TARGET_OS_*` macros (`'TARGET_OS_MACCATALYST' is not defined` under `-Werror=undef-prefix`). With `-fdefine-target-os-macros` the open-source clang 17 derives 17 of them from the triple, with Apple's values; Apple's clang 17 has four more (`TARGET_OS_ARROW`, `_BRIDGE`, `_IOSMAC`, `_XR`). The image's own clang 21 already predefines 19 with Apple's values and lacks five (those four and `TARGET_OS_KERNELKIT`). The image defines the missing ones from the others in either chain (`docker/toolchain/target-os/derived.txt`: `IOSMAC` is `MACCATALYST`, `XR` is `VISION`, `BRIDGE` and `KERNELKIT` are 0, `ARROW` is 1 on arm64 macOS only). The toolchain's `clang`/`clang++` (`/usr/bin` for the image's own Swift) become a small driver (`docker/toolchain/clang-driver`) that, for a Darwin target only (an Apple `-target`, on the command line or in a response file), passes `-fno-cxx-modules` on (where the driver drops it) and adds those flags to compiles. A Linux compile, on arm64 and on amd64 (cargo build scripts, the `cc` crate's host builds, script phases) runs the open-source driver unchanged: `-fdefine-target-os-macros` would define `TARGET_OS_LINUX 1`, `TARGET_OS_MAC 0`, … for it, which neither Apple's clang nor stock clang does. The flags also reach Swift Build as build settings (its in-process dependency scanner, Swift's Clang importer) and SwiftPM builds through the SDK bundle's toolsets; `/opt/xless/swift-toolchain.json` records them as `clangFlags` in either chain. The image build checks the result against the Xcode's own clang, with no exception: `docker/toolchain/target-os/<Xcode build>.txt` records, black-box, the `TARGET_OS_*` macros and values that clang predefines for `arm64-apple-ios`, `arm64-apple-ios-simulator` and arm64/x86_64 `apple-macos` (`scripts/target-os-macros.sh` measures a new Xcode), and the image build fails unless each of those triples gets every one with Apple's value and no other, through the driver and through the build settings, and a Linux triple (aarch64 and x86_64) gets none and the open-source driver's own predefines.
  - The build checks `swiftc --version` against the image's record and the Xcode's Swift (`toolchain-meta.json`), prints it (`xless: compiler: Swift 6.2.3 (swift-6.2.3-RELEASE) from /opt/xless/toolchains/swift-6.2.3, Xcode's Swift 6.2.3`) and records it in `sdk.json`. A pinned project in an image without a toolchain record is refused. `DTCompiler` is Xcode's compiler identifier (`com.apple.compilers.llvm.clang.1_0`) whatever the Swift version, as in Xcode builds.
- **Finalize stamps from that SDK.** `DTXcode`, `DTXcodeBuild`, `DTSDKName`, `DTSDKBuild`, `DTPlatformVersion`, `DTPlatformBuild` and every Mach-O's `LC_BUILD_VERSION` SDK field come from the image's metadata, which must equal the build's record (an image change between `build` and `finalize` is refused) and the pin. Nothing is stamped from a fixed Xcode, and xless never stamps an SDK other than the one the app was linked with.
- **Caches.** The SDK's metadata is part of the toolchain identity: switching to another Xcode's images reinstalls the work copy's JS dependencies once and regenerates `ios/` ([Caching](#caching-and-xless_rn_clean)).

`xcode:` works the same way in a Tauri overlay and in xless.yml (images `xless-tauri:…-xcode<version>` and `xless:…-xcode<version>`).

## Caching and `XLESS_RN_CLEAN`

**prepare.** Every run syncs the work copy and runs the JS install (fast when nothing changed).

Before the install, `prepare` compares the toolchain with the one recorded after the last JS install (`.xless/rn-toolchain` in the work copy). The toolchain is the image (`XLESS_IMAGE_ID`), the Darwin SDK's toolchain metadata (another Xcode's images), the Swift toolchain that compiles (Ruling R10), the xless executable, and the versions of Node, the package manager, Ruby and Bundler. When it differs (or with `XLESS_RN_CLEAN=1`), Swift Build's derived data is deleted too (`.xless/derived-data` and `.xless/derived-data-simulator`): its module caches belong to the previous compiler, and even an image rebuilt from the same Xcode changes the SDK files' times, which explicitly built modules then refuse. When it differs, or when nothing is recorded, `prepare` deletes the work copy's JS dependency trees: the `node_modules` next to every tracked `package.json` at or below the install's root, which covers the root and each workspace package. It logs `toolchain changed: reinstalling JS dependencies (cached build outputs in node_modules were made by another toolchain)`. The install then repopulates them from the package manager's store, a cache volume, so this costs a reinstall but no download. This matters because some packages cache their own build outputs inside `node_modules`, keyed on their sources only. Expo's `expo-modules-jsi`, for example, keeps prebuilt xcframework slices under `apple/Products`. Without the wipe, a new toolchain would reuse binaries the old one made. A `node_modules` that is a symlink is unlinked, never followed, and the source checkout is never touched. `XLESS_RN_CLEAN=1` also deletes the trees. A change to the overlay's `env` alone keeps them and only regenerates `ios/`.

`expo prebuild` and `pod install` are skipped when two things hold:
- a SHA-256 of their inputs equals the one recorded after the last successful prepare (`.xless/rn-prepare.json` in the work copy);
- the pods are installed.

The inputs are:
- the source's tracked files and uncommitted changes;
- the overlay's `env`, `app.dir`, `configuration` and `prepare.run`;
- the toolchain (above);
- the xless version.

Any change regenerates `ios/` from scratch, as `expo prebuild --clean` would. `XLESS_RN_CLEAN=1` forces it and the JS reinstall, for example after a CocoaPods cache problem. A variable the app's tooling reads from the host environment instead of the overlay's `env:` is not part of the fingerprint. With a committed `ios/`, `pod install` always runs (it is quick when the pods are current).

**build.** Swift Build's derived data stays in the work copy (`.xless/derived-data`), so a rebuild is incremental. Delete the work copy (or the volume) for a clean build.

**Volumes.** The work volume and the cache volumes keep the pnpm store, the gems, the CocoaPods specs repository and the pod downloads between runs. Removing them costs only time.

## Linux parity test

From a source checkout, `make test-rn-linux` (`scripts/test-rn-linux.sh`) builds `samples/HelloRN` with its committed overlay through `finalize` in the `xless-rn` image, unsigned and without credentials. It compares the app and its extension with `samples/HelloRN/reference/`, recorded from `xcodebuild` on a Mac (`make rn-reference`): executables, linked libraries, rpaths, embedded frameworks, every file and the Info.plists, with no allowed gaps. The build stage's app is compared as it is; the finalized app also carries the one key the sample's overlay adds (`ITSAppUsesNonExemptEncryption`). The sample includes a local pod (`plugins/HelloAssets`) that ships an asset catalog as a pod resource; the test checks that its image is in the app's `Assets.car`, compiled by CocoaPods' `[CP] Copy Pods Resources` phase. It runs twice:
- once from a fresh prepare (network);
- once with `--network none`: prepare finds the native project up to date and the build runs offline.

Then it builds the same work copy for the simulator (`--destination simulator`, offline). It checks that the result is an arm64 `iphonesimulator` app whose executables carry their simulated entitlements and whose bundles are all signed, and that the device build was left alone: its app, its records (`entitlements.json`, `packages.json`, `sdk.json`, `build-number`) and its derived data. The device build then runs once more, offline, and must still match the reference: both builds share the work copy's `node_modules`, where some packages cache build outputs. On a Mac host it launches the app with `scripts/sim-launch.sh` and requires it to be running after 10 s (`--no-launch` skips that).

`ARCH=amd64 make test-rn-linux` (and `test-tauri-linux`) runs the same test in the amd64 image, against the same references, in work volumes of their own (`xless-rn-test-work-amd64`); `ARCH` defaults to the host's architecture. The build must not depend on the architecture it ran on, so an app built in the arm64 image and one built in the amd64 image are compared byte for byte with `scripts/arch-compare.sh <app-a> <app-b>`: it prints `xless tauri report` of each (the summary `reference.json` is made of), diffs the two, and lists every file whose bytes differ outside `_CodeSignature/` and the Mach-O code-signature blob. For HelloRN (Xcode 27.0 and 26.2, the build stage's app and the finalized app) both comparisons are empty. Two things made the first comparison fail, and both are fixed in the image rather than tolerated:

- Binary property lists (a bundle's `Info.plist`, `Expo.plist`) listed their keys in a different order on every run: Swift seeds its dictionaries per process. The images set `SWIFT_DETERMINISTIC_HASHING=1` (`docker/Dockerfile.base`, and the `xcodebuild` shim restores it for Expo's nested build, which runs under `env -i`).
- `llvm-strip -S` drops local symbols that `ld64.lld` left in an image's indirect symbol table, and writes bytes it never initialised for those entries: zero from the arm64 build of LLVM 21's `llvm-strip`, `0x5555` from the amd64 one. The `strip` shim sets every entry whose symbol was dropped to `INDIRECT_SYMBOL_LOCAL`, as Apple's linker marks an entry for a local symbol (`MachO.normalizeStrippedIndirectSymbols`).

The sample adopts the UIKit scene life cycle (`plugins/withSceneLifecycle.js`, see [known gaps](#known-gaps)). It also pins `expo-modules-jsi` to 57.0.4 (a pnpm override): Expo's precompiled `ExpoModulesCore` 57.0.10 binds `JavaScriptActor.assumeIsolated` from ExpoModulesJSI, which 57.0.8 no longer exports (it became `@_alwaysEmitIntoClient`). With 57.0.8 the app stops in `dyld` at launch, built by Xcode or by xless alike.

## Known gaps

These are measured differences from an Xcode build, or workarounds the Linux toolchain needs. Details: [research/react-native-ios-contract.md](research/react-native-ios-contract.md#gate-g3g4-the-workspace-builds-and-links-on-linux-task-7).

- **`strip -T`.** For `strip -D -S -T` (a framework's Strip task), LLVM's `llvm-strip` also removes exported Swift symbols from the symbol table, which Apple's keeps. Linkers and `dyld` read exports from the export trie, which is identical, so only `nm` sees the difference.
- **LINKEDIT alignment.** LLVM 21's `llvm-strip` puts the string pool right after the indirect symbol table, whose entries are 4 bytes, so with an odd number of them the pool starts 4 bytes off an 8-byte boundary. `dyld` refuses such an image at launch (`mis-aligned LINKEDIT string pool`); Apple's linker and `strip` never write one. After `llvm-strip`, the strip shim moves the string pool (and the code signature after it, if any) to the next 8-byte boundary and grows `__LINKEDIT`; it refuses (exit 70) a layout it does not understand, such as data other than a code signature after the string pool. Archives are left alone, because `dyld` never loads their members. `finalize` refuses any image in the bundle whose LINKEDIT tables `dyld` would reject. Checked black-box with `dyld_info -validate_only`: every non-empty table that `dyld` checks (symbol table, indirect symbol table, string pool, function starts, data in code, exports trie, chained fixups, rebase, bind and lazy-bind opcodes, code signature) must be 8-byte aligned on 64-bit. Empty tables and the string pool's size are not checked.
- **`copypng`.** The shim writes Xcode's iPhone-optimized PNG for 8-bit RGB and RGBA; 16-bit images are copied as they are. Gray and palette PNGs, interlaced PNGs and ancillary chunks other than text are refused, which fails the build.
- **Compiler workarounds** (build settings xless adds):
  - `-enable-experimental-feature AssumeResilientCxxTypes`: open-source Swift (6.4; 6.2.3 accepts the flag too) rejects C++ types in a library-evolution module, which Xcode's compiler accepts. It only turns that diagnostic off.
  - `CLANG_WARN_DOCUMENTATION_COMMENTS = NO`: the toolchain's clang crashes on `-Wdocumentation` for one Objective-C++ pattern. A project that treats warnings as errors fails some builds on Xcode that pass here.
  - `-no_objc_relative_method_lists` on links that name a prebuilt framework without `MH_SUBSECTIONS_VIA_SYMBOLS`, to avoid an `ld64.lld` crash. Only `-framework` inputs are checked.
  - Prelinked package targets (`ld -r`) are approximated with `-force_load`.
- **Case sensitivity.** macOS file systems are case-insensitive; Linux's are not.
  - The image adds lowercase links for the SDK's capitalized headers (`<endian.h>`).
  - The build adds lowercase links for vendored xcframeworks (`openssl.framework` → `OpenSSL.framework`).
  - Any other include or path whose case differs from the file on disk fails to build.
- **Swift package dependencies are not pinned.** The project pins each package to a revision, but a package's own dependencies resolve to the newest allowed versions at `prepare`, as in Xcode for a generated workspace, which has no `Package.resolved`. `packages.json` records what was resolved; nothing enforces it between runs.
- **rcodesign's nested seal.** rcodesign lists an extension's files individually in the app's `CodeResources`. Apple's `codesign` records a nested bundle differently. rcodesign verifies the result. App Store processing of an app with an extension signed this way is not confirmed yet: the milestone's acceptance build checks it, and [acceptance-m3.md](acceptance-m3.md) records the result.
- **Version before prebuild.** The build number is chosen before the native project exists, so the version comes from the overlay or the JSON files, never from a computed `app.config.js`.
- **Not built:** watch apps and App Clips (the build refuses their target types).
- **`abs(Double)` with the iOS 26.2 SDK (resolved: not an xless gap).** Under C++ interoperability the iOS 26.2 SDK's libc++ makes an unqualified `abs(x)` on a `Double` ambiguous (`Swift.abs` against `abs(double)` from `std_math_h`), e.g. in `expo-modules-jsi` 57.0.x's `JavaScriptCodable+Date.swift`. Measured on a Mac: Xcode 26.2 itself rejects the code, its own `swiftc` (and its SwiftPM) with its own SDK (`type of expression is ambiguous without a type annotation`); Xcode 27's `swiftc` with the 26.2 SDK rejects it too (`ambiguous use of 'abs'`); only Xcode 27's `swiftc` with the 27.0 SDK accepts it. Since Ruling R10 an image made from Xcode 26.2 compiles with Swift 6.2.3 and reports exactly Xcode 26.2's error. An app built with Xcode 26.2 therefore already qualifies the call (`Swift.abs`) in its own repository, as Xcode 26.2 requires: an app can carry its own patch of the package, for example with pnpm's `patchedDependencies`, and needs nothing else for xless. xless itself never patches app or dependency code. To patch from the overlay instead, use `prepare.run` and replace the file rather than editing it in place (pnpm's store is hard-linked, see [`prepare.run`](#overlay-reference)).
- **Swift Build and PIF generation are 6.4 in every image.** Xcode 26.2 ships Swift Build 6.2.3; xless's PIF is written for Swift Build 6.4, which runs with any of the mapped toolchains (compiled with it, see [Pinning the Xcode](#pinning-the-xcode-sdk)). Package manifests of Swift package references are evaluated by the image's own SwiftPM (6.4) for `dump-pif`, so a manifest that needs a newer tools version than the pinned Xcode's would load here and not in Xcode. Swift Build embeds swift-driver, so under a 26.2 pin swift-driver 6.4 plans the jobs that Swift 6.2.3's `swift-frontend` runs; Xcode 26.2 pairs the driver and the frontend of one release.
- **The asset and storyboard tools follow the pin, for measured Xcodes only.** The `actool` and `ibtool` shims and the `assets` stage read the image's Xcode build from its toolchain metadata (`/opt/xless/toolchain-meta.json`) and write what that Xcode's tools write, as measured black-box in [docs/research/xcode-tools-by-version.md](research/xcode-tools-by-version.md): `--version` (`27.1`/`25098`, `27.0`/`25098` or `26.2`/`24506`), the `Assets.car` version fields (CoreUI version, `MainVersion`, `AssetStorageVersion`, `Authoring Tool`) and the compiled storyboards' nib encoding, byte for byte against both builds' ibtool output for the storyboard corpus. `copypng` behaves the same in both builds. Profiled builds: Xcode 27.1 (27A9275), Xcode 27.0 (27A266a) and Xcode 26.2 (17C52). An image made from any other Xcode is refused by both shims (exit 70, so the build fails with `[build] … has no measured asset/storyboard tools profile`) and, for an `xless.yml` project, by the `assets` stage (exit 13); it is never given another Xcode's output. Under Xcode 26.2 a launch storyboard whose capability needs a newer Xcode (`minToolsVersion` above 26.2) is refused with ibtool's own words (`This document requires at least Xcode 26.3.`); a stale `toolsVersion` alone is not refused, as ibtool does not refuse it. Two 26.2 encodings were measured only partly and are refused rather than guessed: a storyboard of plain views (no label, no image view) may use only the system colors `labelColor`, `systemBackgroundColor`, `systemBlueColor` and `systemGroupedBackgroundColor`, and italic system fonts of two sizes need sizes of 13 pt or less, 20 pt, or 28 pt or more.
- **amd64 was verified under Rosetta, not on a native x86_64 host.** Milestone 4's amd64 runs (both Xcode chains, the Linux tests, the arm64-against-amd64 comparison) ran on an Apple-silicon Mac whose Docker VM runs `linux/amd64` containers through Rosetta. They have not run on a native x86_64 machine; that comes with the deployment work. The Docker VM must have Rosetta enabled: with Colima that is the `vz` VM type plus Rosetta, and some Colima and Lima releases do not switch it on from Colima's own flags, so check that `/proc/sys/fs/binfmt_misc/rosetta` is registered in the VM and, if it is not, enable `vmOpts.vz.rosetta` (`enabled: true`, `binfmt: true`) in the VM's Lima configuration. Under QEMU user-mode emulation gcc and Swift crashed at random.
- **The HelloTauri reference exists for Xcode 27.0 only.** A Tauri build pinned to Xcode 26.2 or 27.1 differs from it in the SDK-identity entries (`DTPlatformVersion`, `DTSDKName`, the Swift runtime libraries); that is expected, not a regression.
- **Tools profiles exist for three Xcode builds.** Xcode 26.2 (17C52), Xcode 27.0 (27A266a) and Xcode 27.1 (27A9275) are measured. An image chain for any other build is refused (`xless setup` and `make images`, and at run time the `actool` and `ibtool` shims, exit 70) until its tools are measured and its profile added.
- **iOS 27 requires the UIKit scene life cycle.** An app built with the iOS 27 SDK that declares no `UIApplicationSceneManifest` is stopped by UIKit at launch on iOS 27: "Application failed to launch: UIScene life cycle is required for apps built with this SDK" (an `EXC_BREAKPOINT` in `_UIApplicationEvaluateRuntimeIssueForNoSceneLifecycleAdoption`). An Xcode 27 build of the same app stops the same way. Expo SDK 57's app delegate template creates its window in `application(_:didFinishLaunchingWithOptions:)` and declares no scene, so its apps need a config plugin that adopts scenes. [samples/HelloRN/plugins/withSceneLifecycle.js](../samples/HelloRN/plugins/withSceneLifecycle.js) is one: it adds the scene manifest and a `SceneDelegate` that starts React Native in the scene's window. Earlier iOS versions launch such an app as before. An app whose release pipeline uses an older Xcode is not affected there: pin that Xcode with `xcode:` ([Pinning the Xcode](#pinning-the-xcode-sdk)) instead of adopting scenes. xless does not check for this: launch the build on an iOS 27 simulator.

## Troubleshooting

Errors read `[stage] cause — fix`. Exit codes: config 10, prepare 19, build 12, assets 13, finalize 14, sign 15, package 16, upload 17. Exit 2 is `xless run --docker` itself (arguments, a missing secret variable, a secret inside a mounted directory).

| Exit | Stage and message | What to do |
|---|---|---|
| 10 | `[config] overlay …: unknown key …`, `… is invalid` | The overlay does not match [the reference](#overlay-reference); the message names the key. |
| 10 | `[config] … bundleIDs has no entry for the app target …`, `cannot tell which bundleIDs entry is the app` | Name the app target in `bundleIDs` (Expo names it like the scheme), and give every extension an ID that starts with the app's plus `.`. |
| 10 | `[config] cannot determine the app version`, `the app version '…' is not 1–3 dot-separated integers` | Set `version:` in the overlay. |
| 10 | `[config] build: dated needs App Store Connect credentials` | Set the credentials, or pass `XLESS_BUILD_NUMBER=<version>.<YYYYMMDDNN>` / `--build-number`. |
| 10 | `[config] overlay …: entitlements.replace is now identifiers.replace` | Move the map to a top-level `identifiers: { replace: {…} }`. |
| 2 | `testflight: … pins xcode: "…", but these images are missing: …` | Build them: `xless setup --docker --xcode <that Xcode's .xip or .app> --arch <arch>` ([Pinning the Xcode](#pinning-the-xcode-sdk)). |
| 19, 12 | `[prepare] the overlay pins xcode: "…", but this image has the … SDK from Xcode …` (`[build] …` for xless.yml, which has no prepare stage) | Run in that Xcode's images (`xless run --docker` selects them), or change the pin. |
| 14 | `[finalize] the app was built with Xcode …, but this image has Xcode …` | Finalize in the image that built the app, or build again (`--from build`). |
| 19 | `outside the contract xless supports` | React Native, Expo, CocoaPods or Bundler differs from the contract. Use the contract versions, or re-measure. |
| 19 | `Gemfile.lock is BUNDLED WITH …` | Run `bundle _2.7.2_ lock` in the app and commit the lockfile. |
| 19 | `no package.json with a lockfile`, `the expo CLI is not installed` | Commit the lockfile; add `expo` to the app's dependencies. |
| 19 | `is not inside a git repository`, `is a git submodule`, `the work copy … was synced from …` | As for [Tauri](tauri.md#troubleshooting). |
| 19 | a failing `prepare.run` command, `expo prebuild` or `pod install` | Their output is printed. Run `xless prepare` with `XLESS_RN_CLEAN=1` once after changing images or caches. |
| 12 | `[build] the app embeds …, which has no entry in bundleIDs`, `bundleIDs.… names a target the app … does not embed` | Make `bundleIDs` exactly the app target plus the extensions it embeds; the fix lists them. |
| 12 | `[build] a build phase ran a missing command (…)` | The image lacks a tool a phase runs. Report it; if the app is right without it, add the name to `allowMissingCommands`. |
| 12, 13 | `this image's Xcode build … has no measured asset/storyboard tools profile` | The image was made from an Xcode xless has not measured (an old local image, or `XLESS_IMAGE` naming one). Rebuild the images with `xless setup --docker --xcode …` from a profiled Xcode (27A266a, 17C52). |
| 12, 13 | `This document requires at least Xcode X.` | The launch storyboard uses a feature of a newer Xcode than the pinned one, which that Xcode's ibtool refuses too. Re-save it without that feature, or pin a newer Xcode. |
| 12 | `[build] … shim: unsupported call (…): …` | A phase or Swift Build called an Xcode tool (`actool`, `copypng`, `strip`, `PlistBuddy`, `xcrun`, …) in a way the shim has not measured against Xcode's. The failed task's last output lines are printed above. Report the call. |
| 12 | `[build] Swift package … is pinned to '…', which is not a full commit hash` | Pin the package to a 40-character revision in the Xcode project. |
| 12 | `[build] Swift Build failed: …` | The first failed task is named, and each failed task's last 20 output lines are printed; the full log is `swbuild.log` under the work copy's `.xless/derived-data/`. Check the [known gaps](#known-gaps) (case, `copypng`). |
| 12 | `[build] Swift Build failed` on a prebuilt framework header that is there (`file not found`), or `The Xcode build system has crashed` | A pod replaced a prebuilt framework while the build ran. `prepare` runs those configuration switches first; a pod whose switch phase is named differently is not covered: report the phase's name. Run again with `XLESS_RN_CLEAN=1`. |
| 12 | `[build] … has bundle ID …, not the overlay's …` | Make the target's Info.plist use `$(PRODUCT_BUNDLE_IDENTIFIER)`. |
| 14 | `no PrivacyInfo.xcprivacy in the bundle` | Set `privacyManifest:` in the overlay. |
| 12 | `[build] dyld would refuse … image(s) of the simulator app` | Report the binary (as for `finalize`'s LINKEDIT check). |
| 12, 13–17 | `--destination simulator builds stop at build` | Install the `.app` from `.xless/build/ios-simulator/app` with `make sim-launch` (on a Mac); ship a device build without `--destination`. |
| — | the app dies at launch in `make sim-launch` | Read `crash/*.ips` and `console.log`. `dyld … Symbol not found` names the framework that lacks a symbol another one expects: two of the app's dependencies disagree (an Expo precompiled framework and a package built from source at another version). `UIScene life cycle is required` is the [known gap](#known-gaps). |
| 15 | `[sign] entitlement '…' is not granted … enable the matching capability (…)` | A portal-only capability: [enable it by hand](#capabilities), or drop it with `entitlements.remove`. |
| 15 | `[sign] identifiers.replace changed since finalize …` | The Info.plists carry the map `finalize` applied. Run again from `finalize` (`--from finalize`). |
| 15 | `[sign] app group … is not in the provisioning profiles of …` | Create and assign the group in the portal ([steps](#capabilities)), or map it with `identifiers.replace`. |
| 15 | `[sign] entitlement 'keychain-access-groups' value '…' is not allowed` | Write the group as `$(AppIdentifierPrefix)<group>`, or map it with `identifiers.replace`. |
| 15 | `[sign] … entitlements.json … run xless build` | The `.app` and the manifest disagree; run the build again (`--from build`). |
| 15, 16, 17 | | As for any xless project: [troubleshooting.md](troubleshooting.md). |
