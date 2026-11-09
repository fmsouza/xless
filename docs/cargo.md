# Plain Cargo apps (iOS and macOS)

xless builds an app that is just a Cargo workspace on Linux, with no Mac and no Xcode on the build machine: an iOS app that it ships to TestFlight, and a macOS app that it ships as a notarized DMG or, from the App-Store lane, to TestFlight ([macOS](#macos)). The app has no Xcode project, no Tauri and no Swift. Its binary crate runs the platform's event loop itself (winit, eframe/egui, objc2…), and the repository holds an `Info.plist` and an icon. The app repository stays untouched: everything xless needs to know lives in an **overlay** file kept outside it.

```sh
xless run --docker --config ~/ci/my-app.overlay.yml
```

## Try the sample

The source repository has a small winit app, `samples/HelloCargo`, with an overlay. With the images from
`xless setup --docker` ([README](../README.md#build-in-docker-instead)), build it up to `finalize`, unsigned and with no Apple account:

```sh
git clone https://github.com/fmsouza/xless.git
xless run --docker --config xless/samples/HelloCargo/xless.overlay.example.yml --build-number 1.0.0.2026101601 --to finalize
xless run --docker --config xless/samples/HelloCargo/xless.overlay.example.yml --platform macos --build-number 1.0.0.202610160000 --to finalize
```

The first build downloads Rust and compiles the app's dependencies, which takes several minutes. The apps end up in
the work copy under `~/.cache/xless/work/`, in `.xless/build/ios/final/` and `.xless/build/macos/final/`.

## What is supported

- **Build.** `cargo build --release --locked -p <package> --bin <bin> --target <triple>` (plus `--features` when the overlay lists some). iOS: `aarch64-apple-ios`, device only. macOS: `aarch64-apple-darwin` and `x86_64-apple-darwin`, merged into one universal executable (the `x86_64` slice first, as `lipo` does). Rust links against Apple's SDK from the xless image, with the same linker and `xcrun` set-up as the Tauri builds ([tauri.md](tauri.md)). Then the usual stages: assets, finalize, sign, package, upload and TestFlight delivery ([pipeline.md](pipeline.md#stages)).
- **Bundle.** xless writes the `.app` itself: the executable, an `Info.plist` made from the app's own file, the resources the overlay lists, the privacy manifest (iOS) and the icon. iOS is a flat bundle; macOS is `Contents/MacOS`, `Contents/Resources`, `Contents/Info.plist` and `PkgInfo`.
- **Overlay only.** The app need not change: no `build.rs`, no crate, no `Cargo.toml` key for xless. If a Cargo app needs something xless lacks, that is an xless gap ([known gaps](#known-gaps)).
- **Not supported.** Simulator and debug builds, x86_64 iOS, Android, Windows and Linux packaging, embedded frameworks and app extensions, external TestFlight groups, App Store submission.

## Requirements

- To sign and upload: the one-time Apple setup from [bootstrap.md](bootstrap.md) (API key, distribution certificate; for macOS the Developer ID certificate), plus the secrets file described under [One command: TestFlight](signing-and-testflight.md#one-command-testflight).
- The `xless-tauri` image, which carries Rust's installer, LLVM binutils and the tools that build a DMG. `xless setup --docker` builds it ([README](../README.md#build-in-docker-instead)).
- The app repository is a git checkout, and `Cargo.lock` is committed and up to date (`--locked`). xless copies the **tracked** files of `source:` (and only those) into a work copy under `~/.cache/xless/work/<overlay name>`; the source is never written to. Commit the lockfile, the plist, the icon or asset catalog and every file the overlay refers to. Untracked and ignored files are not copied: a file the app's `build.rs` reads from the tree and git ignores is missing in the work copy. Data that lives outside the repository goes in as a [build input](#build-inputs).
- `source:` may be a directory inside a git checkout (a workspace in a monorepo). The version lookup and the `GIT_SHA` placeholder read that checkout's git data.
- A work copy belongs to one source. The first sync records the source in `.xless/source` of the work copy, and a later run of an overlay with the same file name but another source stops at `prepare`; rename one overlay file or delete the work copy.

## The overlay

A starting point is [samples/HelloCargo/xless.overlay.example.yml](../samples/HelloCargo/xless.overlay.example.yml):

```yaml
type: cargo
source: ~/projects/my-app               # the workspace (or a directory inside a git checkout)
bundleID: com.example.hello             # the macos block may override it
teamID: ABCDE12345
version: cargo                          # the package's version from Cargo.toml (default)
build: dated
privacyManifest: PrivacyInfo.xcprivacy  # next to this file
usesNonExemptEncryption: false
testflight: { groups: [Internal] }
rust:
  toolchain: "1.97.0"                   # default: the repository's rust-toolchain file, else stable
env:
  HELLO_FEATURE_FLAG: "1"               # plain variables for the build, never secrets
inputs:
  - { name: fonts, git: "https://example.com/fonts.git", rev: 0123456789abcdef0123456789abcdef01234567, env: FONTS_DIR }
ios:
  package: hello-mobile                 # cargo -p
  bin: hello                            # cargo --bin
  product: Hello                        # the .app and CFBundleName
  minimumOS: "17.0"
  infoPlist: apps/mobile/ios/Info.plist
  assets: apps/mobile/Assets.xcassets   # required on iOS
macos:
  package: hello-desktop
  bundleID: com.example.hello.mac
  product: Hello
  minimumOS: "12.0"
  infoPlist: apps/desktop/Info.plist.in
  icon: apps/desktop/hello.icns
  entitlements: apps/desktop/entitlements.plist
  resources:
    - { from: "input:fonts/licenses/*/OFL.txt", to: Licenses/ }
```

An unknown key is refused with its path (`unknown key 'ios.feature'`), so a misspelling cannot be dropped silently. Errors are `[config]` errors (exit 10).

### Overlay reference

**Paths.** `source` and `privacyManifest` resolve against the **overlay file's directory** (`~` is expanded), so the privacy manifest may live next to the overlay, outside the repository. Every other path in the overlay is relative to the **source root** (the app, as it is in the work copy) and may not start with `/` or `~` or leave it with `..`. The exceptions are the path inputs ([inputs](#build-inputs)). `infoPlist`, `icon` and `resources[].from` may instead be `input:<name>/<path>`, a path inside a declared input. `assets` and `entitlements` may not: the assets and sign stages read them from the work copy, where no input is.

| Key | Meaning |
|---|---|
| `type` | Required. Must be `cargo`. |
| `source` | The app repository, read-only. Required unless `--source <dir>` (or `$XLESS_SOURCE` with `xless run --docker`) gives it. It may be a subdirectory of a git checkout. |
| `bundleID` | Required. The bundle ID of both apps unless a platform block sets its own. |
| `teamID` | Required. The 10-character Apple team ID. |
| `version` | `cargo` (default): the package's version ([below](#the-version)). Or an explicit version: 1 to 3 integers with an optional `-prerelease`. |
| `build` | `dated` (default): `CFBundleVersion` is `<version>.<YYYYMMDDNN>` on iOS and `<version>.<YYYYMMDDHHmm>` on macOS ([build numbers](#build-numbers)). Or an explicit build number of 1 to 3 integers. |
| `usesNonExemptEncryption` | `ITSAppUsesNonExemptEncryption`, stamped at `finalize`. App Store Connect asks about export compliance when it is missing. |
| `privacyManifest` | A `PrivacyInfo.xcprivacy` copied into the iOS app, relative to the overlay file. `finalize` requires one for App Store builds. The macOS app does not get it. |
| `testflight` | `groups`, `whatToTest`, `locale`: as in [xless.yml](xless-yml.md#testflight). iOS only. |
| `xcode` | The Xcode whose SDK must build the app, e.g. `"26.2"`; as for Tauri ([react-native.md](react-native.md#pinning-the-xcode-sdk)). Default: the image's SDK. |
| `rust.toolchain` | A rustup toolchain name (`"1.97.0"`, `stable`). xless sets it as `RUSTUP_TOOLCHAIN` on every cargo call, which beats the repository's `rust-toolchain` file. Quote version numbers. Without it, that file decides, and without a file, `stable`. |
| `env` | Plain build variables, passed to cargo and so to `build.rs`. Never secrets: a name xless sets itself (`PATH`, `HOME`, `SDKROOT`, `DEVELOPER_DIR`, `CARGO_HOME`, `RUSTUP_HOME`, `RUSTUP_TOOLCHAIN`, the deployment targets, `CARGO_PROFILE_RELEASE_STRIP`), one that starts with `XLESS_`, `SWIFT_`, `ASC_` or `CARGO_TARGET_`, and any name xless scrubs as a secret is refused. |
| `inputs` | Extra read-only directories the build needs: see [build inputs](#build-inputs). |
| `plistVars` | Values for `@NAME@` placeholders in the app's `Info.plist`: see [Info.plist](#infoplist-and-placeholders). |
| `ios`, `macos` | The platform blocks. At least one is required; `--platform` picks the one built, and a platform without its block is refused. |

Platform block keys (the same in `ios` and `macos`):

| Key | Meaning |
|---|---|
| `package` | Required. The cargo package (`cargo -p`). Its `Cargo.toml` gives the version. |
| `bin` | `cargo --bin`. Default: the package's only binary; if it has several, the one named like the package. The executable in the bundle is named after `product`, whatever `bin` is. |
| `features` | Cargo features, as `cargo --features`. Default none. |
| `product` | Required. The `.app` name, `CFBundleName` (unless the plist sets one) and `CFBundleExecutable`. A plain file name. |
| `minimumOS` | Required. Quoted, 1 to 3 integers. `MinimumOSVersion` on iOS, `LSMinimumSystemVersion` and the deployment target of the Rust build on macOS. |
| `bundleID` | Overrides the top-level `bundleID` for this platform. |
| `infoPlist` | The app's `Info.plist`, or a template of it. Optional: without it xless writes the keys it owns and nothing else. |
| `assets` | An asset catalog (`.xcassets`). **Required on iOS** (the App Store needs an icon); compiled to `Assets.car` at the `assets` stage. On macOS it is the alternative to `icon`. In the source root only. |
| `icon` | macOS only: a ready `.icns`. iOS refuses it. Setting both `icon` and `assets` on macOS is refused. |
| `entitlements` | A plist of entitlements for the signature. In the source root only. |
| `resources` | A list of `{ from, to }` copies into the bundle: see [resources](#resources). |

### The version

With `version: cargo` (or no `version`), the version is the one in the `Cargo.toml` of the platform's `package`. xless reads the **tracked** manifests of the source (`git ls-files`), with a line-based reader for the few keys it needs rather than a TOML parser, so the app need not build for this. `version = "1.2.0"` is read as written. `version.workspace = true` (or `version = { workspace = true }`) follows to the `[workspace.package]` table of the nearest manifest above that declares a workspace. A package that no tracked manifest declares, one that two manifests declare, one without a version and an inherited version the workspace does not state are all `[config]` errors that tell you to fix the manifest or set `version:` in the overlay.

A prerelease or build suffix does not reach Apple: `0.2.0-rc.1` gives `CFBundleShortVersionString` `0.2.0` and the build number `0.2.0.<date>`. The full string stays available to the Info.plist template as `@VERSION@`.

### Info.plist and placeholders

`infoPlist` is the base. xless sets the keys it owns over it: `CFBundleIdentifier`, `CFBundleExecutable`, `CFBundlePackageType`, `CFBundleShortVersionString`, `CFBundleVersion`, `CFBundleInfoDictionaryVersion`, `CFBundleName` (from `product` when the plist has none), and per platform `MinimumOSVersion`, `CFBundleSupportedPlatforms` and `UIDeviceFamily` (`[1, 2]` when the plist has none) on iOS, `LSMinimumSystemVersion` on macOS (and `CFBundleIconFile` when `icon` is set). `finalize` then stamps Xcode's `DT*` keys, the SDK version and `ITSAppUsesNonExemptEncryption`, as for every xless build. Every other key stays as the app wrote it, so the file need not be edited for xless.

A template may hold `@NAME@` placeholders in its string values, at any depth. A name is an upper-case letter followed by upper-case letters, digits and `_`; any other text with an `@` in it (`user@example.com`) is left alone. xless replaces them at the **build** stage:

| Name | Value |
|---|---|
| `VERSION` | The full version, prerelease included. |
| `SHORT_VERSION` | The version Apple sees (`CFBundleShortVersionString`). |
| `BUILD_NUMBER` | The build number (`CFBundleVersion`). |
| `GIT_SHA` | `git rev-parse HEAD` of the source checkout. |
| `plistVars` entries | Your own: `plistVars: { COPYRIGHT_YEAR: "2026" }` fills `@COPYRIGHT_YEAR@`. A value may use the built-in names, but not other `plistVars`; one pass is made. A `plistVars` name wins over a built-in of the same name. |

A placeholder with no value stops the **build** with exit 12: `Info.plist placeholders without a value: BUILD_SHA`, listing every missing name. Define it under `plistVars:`.

### Resources

`resources` copies files into `Contents/Resources/<to>` on macOS and `<to>` at the root of the iOS bundle. `from` is a path in the source root, or `input:<name>/<path>`. Each entry is one of:

- A file or directory, with `to` the new name (`to: Credits.txt`), or with `to` ending in `/`, a directory that receives it under its own name (`to: Licenses/`).
- A glob, when `to` ends in `/`. `*` stands for any run of characters inside one path component, never across `/`, and does not match names starting with `.` unless the pattern component does. `*` may not stand in the input's name. Every match lands in `to` as `<its directory's name>-<its file name>`, so `from: "input:fonts/licenses/*/OFL.txt"` gives `Licenses/Inter-OFL.txt`, `Licenses/Lora-OFL.txt`… A glob that matches nothing, or two matches that land on one name, stops the build.

A copy may not replace the bundle's own files (the executable, `Info.plist`, `PkgInfo`, `PrivacyInfo.xcprivacy`, `<product>.icns`) or leave the bundle. A missing `from` stops the build (exit 12).

### Icons

- **iOS:** `ios.assets` is compiled with the asset compiler into `Assets.car` and the icon keys.
- **macOS with `icon`:** the `.icns` is copied as `Contents/Resources/<product>.icns` and `CFBundleIconFile` is `<product>`.
- **macOS with `assets`:** the catalog's `AppIcon` becomes `Contents/Resources/AppIcon.icns`.
- **macOS with neither:** no icon.

## Build inputs

A `build.rs` may read a directory named by an environment variable, for example fonts kept outside the repository. `inputs` declares such directories; each has a `name` (letters, digits, `.`, `_`, `-`), an `env` variable that carries its directory into the build (it follows the same rules as `env:` and must not repeat another input's or an `env:` name) and one source:

- **`path:`** a directory on the host, absolute, `~`-prefixed or relative to the source root. It may be outside the source. In docker it is mounted **read-only** at `/inputs/<name>` in the build container only (step 2 of [Shipping](#shipping)), and the variable holds that container path. Natively nothing is mounted and the variable holds the host path. The path may not contain a tab or a line break. `xless cargo inputs --config <overlay> [--source <dir>]` prints `name<TAB>path` for each path input: the list `scripts/testflight.sh` mounts.
- **`git:` and `rev:`.** An `https://` URL and the full, lowercase 40-character commit (`git rev-parse HEAD`); a branch, tag or short hash is refused because it moves. xless clones the input into `$XLESS_CACHE/inputs/<name>-<rev>` during `prepare` and reuses the clone while it is at that commit; with `xless run --docker` that is `~/.cache/xless/inputs` on the host. The overlay then needs nothing on the build machine but network access for the first clone. git never prompts for credentials, so a private repository fails with a clone error.

`input:<name>/<path>` in `infoPlist`, `icon` and `resources[].from` reads from the input. A `path:` that is not a directory stops `prepare` (exit 19).

`xless run --docker` applies to every path input the checks it applies to the source and the overlay's folder: it refuses (exit 2) a path that is `/`, your home directory or a directory above it, and a path that holds the secrets file or one of the secret files (compared by inode, so a symlink does not hide one).

## Build numbers

`build: dated` works as for Tauri ([tauri.md](tauri.md#build-numbers)). On iOS, `prepare` and `build` ask App Store Connect for the builds of this version and pick `<version>.<YYYYMMDDNN>` above all of them; the number is recorded in the work copy and reused by every later stage, so credentials are needed from `prepare` on. `XLESS_BUILD_NUMBER` or `--build-number` replaces the lookup, and under `build: dated` it must itself have the dated form for the app's version (`1.0.0.2026101501`). On macOS there is no App Store Connect build: the number is `<version>.<YYYYMMDDHHmm>` (UTC) from the clock when the run starts.

`xless next-build --config <overlay>` handles cargo overlays: it prints the number the next iOS run would use (the version from the overlay or the package's `Cargo.toml`, the bundle ID from `ios.bundleID` or `bundleID`), a read-only App Store Connect query. `scripts/testflight.sh` runs it as step 1. `xless inspect --config` refuses a cargo overlay, and `xless tauri inspect` is for Tauri overlays only.

## Creating the App Store Connect app record

As for Tauri ([tauri.md](tauri.md#creating-the-app-store-connect-app-record)), with the bundle ID of the iOS app (`ios.bundleID`, else `bundleID`). Try a new overlay against a separate test app record first: a build number uploaded to a record cannot be reused or lowered.

## Shipping

```sh
xless run --docker --config ~/ci/my-app.overlay.yml [extra xless ship args, e.g. --from upload]
```

The script and its options are those of Tauri ([tauri.md](tauri.md#shipping)): three containers in the `xless-tauri` image, so the app's build code (`build.rs`, proc-macros) never runs next to a secret.

1. `xless next-build --config <overlay> --source <source>`, with the App Store Connect key only. Skipped when `XLESS_BUILD_NUMBER` or `--build-number` is given, when resuming after `build`, and for macOS.
2. `xless ship --to finalize` with no secret file or variable: prepare, build, assets, finalize.
3. `xless ship --from sign` with the secrets: sign, package, upload. No build code runs here.

What differs for cargo:

- **Mounts.** As for Tauri, plus `~/.cache/xless/inputs` at `/cache/inputs` (the clones of git inputs) and each path input read-only at `/inputs/<name>`, with `XLESS_INPUTS_MOUNTED=1`, in step 2 only. The script lists the path inputs by running `xless cargo inputs` on the host (`$XLESS_SELF`, else `xless` on `PATH`); `make testflight CONFIG=…` and `make dmg CONFIG=…` call the script directly, so for a cargo overlay they need `xless` on `PATH` (or `XLESS_SELF` set to a built one). Its refusals (exit 2) are in [build inputs](#build-inputs).
- **Caches.** `~/.cache/xless/work`, `~/.cache/xless/downloads` and the docker volumes `xless-rustup` and `xless-cargo`: the Rust toolchains and the crates survive between runs. The first build downloads Rust and compiles the whole dependency graph, which takes several minutes and several GB.
- **Stages.** `xless prepare|build|assets|finalize|sign|package|upload --config <overlay> [--source <dir>] --platform ios|macos`. Exit codes are the ones in [pipeline.md](pipeline.md#stages): config 10, prepare 19, build 12, assets 13, finalize 14, sign 15, package 16, upload 17.
- **Native.** As for Tauri: `xless run` refuses an overlay on Linux without `--docker`; from a source checkout, `XLESS_USE_DOCKER=0 make testflight CONFIG=…` runs the same three steps without docker, with the limits described there. Native cargo builds are untested in this milestone.

## macOS

`xless run --docker --config ~/ci/my-app.overlay.yml --platform macos` (from a source checkout: `make dmg CONFIG=…`) builds the `macos` block for both Apple Silicon and Intel, merges the executables into one universal `.app`, signs it with a Developer ID Application certificate and the hardened runtime, wraps it in a DMG, notarizes the DMG with Apple, staples the ticket and checks that the stapled ticket is in the DMG. It prints the path of `<product>_<version>_universal.dmg` last. The prerequisites (the Developer ID key, `XLESS_DEVID_KEY_FILE`, the App Store Connect key for notarization), the two-step key separation and the exit codes are those of [Tauri on macOS](tauri.md#macos). `macos.entitlements` supplies the entitlements of the signature; without it the app is signed with none.

### macOS App Store (TestFlight)

`xless run --docker --config ~/ci/my-app.overlay.yml --platform macos --distribution app-store --to upload` (`xless ship` takes the same two options) runs the macOS App-Store lane ([signing-and-testflight.md](signing-and-testflight.md#macos-app-store-lane-testflight)) for the `macos` block, after the DMG: it signs the universal app with the Apple Distribution certificate and a `MAC_APP_STORE` provisioning profile that it embeds as `Contents/embedded.provisionprofile`, packs it into a flat `.pkg` signed with a Mac Installer Distribution certificate, uploads the package and delivers the build to the overlay's `testflight.groups`. The overlay has no distribution key of its own: the option picks it, and without it the macOS build stays Developer ID.

- **App Sandbox.** App Store Connect rejects a Mac App Store build without `com.apple.security.app-sandbox`, so `macos.entitlements` must carry it, plus whatever the app needs inside the sandbox (`com.apple.security.network.client`, file access…). Entitlements gated by a capability must be enabled for the bundle ID; xless enables the ones the API can, and says which one to enable in the portal otherwise. The hardened runtime is not applied to this build.
- **Three keys.** `XLESS_DIST_KEY_FILE` (Apple Distribution, signs the app), `XLESS_INSTALLER_KEY_FILE` (Mac Installer Distribution, signs the package: [bootstrap.md](bootstrap.md#3b-mac-installer-distribution-key-macos-app-store-lane-only)) and `XLESS_DEVID_KEY_FILE` (Developer ID, the DMG). Only the second ship, the one that signs and uploads, has the first two.
- **Bundle ID and app record.** `macos.bundleID` (else the overlay's `bundleID`) needs an app record of its own for macOS in App Store Connect ([bootstrap.md](bootstrap.md#5-app-record)).

One overlay serves both platforms: `--platform` picks the block. The privacy manifest is iOS-only; `testflight` applies to iOS and to the macOS App-Store lane.

## Known gaps

From the milestone's non-goals and what was left out:

- iOS builds are release, arm64, device only. No simulator or debug builds, no x86_64 iOS.
- No Android, Windows or Linux packaging.
- The macOS App-Store lane ([above](#macos-app-store-testflight)) is not tested against a real App Store Connect upload ([research](research/mas-pkg.md)): the package is checked by Apple's `pkgutil` and `xar`, not by App Store Connect. The app's icon is the `.icns` of `macos.icon` (no macOS asset catalog).
- **iOS 27 requires the UIKit scene life cycle.** An app built with the iOS 27 SDK that does not adopt UIScene is stopped by UIKit at launch on iOS 27 ("UIScene life cycle is required for apps built with this SDK"). The images default to Xcode 27.0, so a plain Cargo app has to adopt UIScene itself: winit 0.30 does not, so `samples/HelloCargo` installs from TestFlight but is stopped at launch on iOS 27 (it launches on iOS 26 and earlier), while an app with its own scene delegate works. Earlier iOS versions launch such an app as before; an app whose release pipeline uses an older Xcode is not affected (pin it with `xcode:`). The same note for React Native is in [react-native.md](react-native.md#known-gaps).
- A plain Cargo app embeds no frameworks of its own and has no app extensions. The overlay has no launch storyboard key: use `UILaunchScreen` in the Info.plist.
- No `cargo-bundle` or `cargo-xcode` compatibility. The overlay is the contract.
- The DMG has a default layout: the app and an `/Applications` link on a plain volume, with no background image, window size, icon positions or volume icon.
- No external TestFlight groups and no App Store submission.
- `xless inspect --config` does not support cargo overlays.
- Versions are read by a line-based reader. It expects `name` and `version` as plain `key = "value"` lines (or the workspace forms above) in `[package]`; a manifest that states them any other way is reported as having none or not found. Set `version:` in the overlay then.
- A plist placeholder is replaced in string values only; keys, numbers and data are left alone.
- Native (non-docker) cargo builds are untested, and `make test-cargo-linux` has not yet been run anywhere (see below).

## Linux parity test

From a source checkout, `make test-cargo-linux` builds `samples/HelloCargo` for iOS and for universal macOS through `finalize` in the `xless-tauri` image (no credentials, no signing, explicit build numbers) and checks the finalized apps: thin arm64 Mach-O on iOS at minimum OS 17.0, an `x86_64` then `arm64` universal executable on macOS, the bundle IDs, build numbers and icons, `Assets.car`, and no `@PLACEHOLDER@` left in either Info.plist. There is no Mac reference for a plain Cargo app, so the checks are the bundle's contract, not a comparison with an Xcode build. `scripts/test-cargo-linux.sh --platform ios|macos|all` runs one platform.

- **A normal git checkout.** The repository is mounted read-only and must be an ordinary checkout, not a `git worktree`: `GIT_SHA` is `git rev-parse HEAD` of the mounted source, and a worktree's `.git` file points outside the mount.
- **The sample committed.** The work copy is the tracked files, so a sample that is edited but not committed is built as it was committed.
- Variables: `ARCH` (`arm64` or `amd64`), `XLESS_IMAGE`, `DOCKER_CONTEXT`.

## Troubleshooting

Errors read `[stage] cause — fix`. Exit codes: config 10, prepare 19, build 12, assets 13, finalize 14, sign 15, package 16, upload 17.

| Exit | Stage and message | What to do |
|---|---|---|
| 10 | `[config] overlay … is invalid`, `unknown key '…'` | The overlay does not match [the reference](#overlay-reference); the message names the key. |
| 10 | `[config] no package named '…' in the git-tracked Cargo.toml files` | `package:` is misspelt, or its `Cargo.toml` is not committed. Or set `version:` in the overlay. |
| 10 | `[config] … inherits its version from the workspace, but … has no [workspace.package] version` | Add `[workspace.package]` with `version = "…"` to the workspace manifest, or set `version:`. |
| 10 | `[config] input '…': rev '…' is not a full 40-character lowercase hex commit` | Pin the exact commit (`git rev-parse HEAD`); branches, tags and short hashes are refused. |
| 10 | `[config] input '…': git '…' must be an https:// URL` | Host the input over https; ssh and http are not supported. |
| 10 | `[config] ios.assets is missing` | iOS needs an asset catalog for the App Store's icon; set `ios.assets`. |
| 10 | `[config] … may not name an input` | `assets` and `entitlements` are read from the work copy: commit them in the repository. |
| 10 | `[config] … leaves its root with '..'`, `must be a relative path` | Overlay paths are relative to the source root and stay inside it. Only a path input's `path:` may point elsewhere. |
| 10 | `[config] build: dated needs App Store Connect credentials` | Set them, or pass `XLESS_BUILD_NUMBER=<version>.<YYYYMMDDNN>`. |
| 19 | `input '…': … is not a directory` | Create the directory or fix the input's `path:`. |
| 19 | `input '…' (… at …): cannot clone` | Check the git URL, that the commit exists there, and that the repository is public: git cannot ask for a password. |
| 19 | `is not inside a git repository`, `the work copy … was synced from …` | As for Tauri ([tauri.md](tauri.md#troubleshooting)). |
| 12 | `Info.plist placeholders without a value: …` | The Info.plist template has `@NAME@` placeholders that are neither built in (`VERSION`, `SHORT_VERSION`, `BUILD_NUMBER`, `GIT_SHA`) nor under `plistVars:`. Define them. |
| 12 | `plistVars … refers to …, which is not a built-in value` | A `plistVars` value may use the built-ins only, not another `plistVars` name. |
| 12 | `cannot read the git commit of …` | `GIT_SHA` needs a git checkout with at least one commit. |
| 12 | `… resources[…].from '…' matches nothing` / `does not exist` | Check the pattern and the path, and that the input is the revision that has these files. |
| 12 | `[build]` with a cargo error | Cargo's own output is shown. `--locked` fails when `Cargo.lock` is out of date: commit it. A crate that needs a Mac-only tool is a known risk for C and C++ build scripts. |
| 14 | `no PrivacyInfo.xcprivacy in the bundle` | Set `privacyManifest:` in the overlay. |
| 14, 15, 16, 17 | | As for any xless project: [troubleshooting.md](troubleshooting.md). |

If the exit code is 2, the problem is in `xless run --docker`'s own arguments or configuration (a missing secret variable, overlay, source or input directory, or a mount that holds a secret).
