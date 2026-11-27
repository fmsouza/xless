# The native install

On a Mac there is nothing to install: xless builds with your Xcode ([below](#on-a-mac)). On Windows there are the account
commands only ([below](#windows)).

On Linux, `xless setup --xcode <Xcode.xip>` installs what xless builds with straight onto the machine, and `xless run`
builds with it. This is the default; the Docker images (`--docker`, [build.md](build.md#in-docker))
are the alternative. This page says what the native install puts where, what it needs, and what it does not cover.

## What it builds

`xless.yml` projects (Swift packages), for iOS and macOS, through every stage up to TestFlight. React Native, Tauri and
plain Cargo apps (`--config <overlay.yml>`) need more than the native install has. On Linux `xless run` builds one
without `--docker` only where what it needs is installed: an Xcode pack and rustup (Cargo), and Node (Tauri); Swift
Build, the Xcode tool shims, Node, Ruby, Bundler and `hermesc` (React Native). A native setup on a bare host prepares no
Swift Build part, so React Native builds there with `--docker` only. Elsewhere the run names what is missing and stops
(exit 2). A container of a kit's image has it all ([images.md](images.md#using-the-image-directly)).
[On a Mac](#tauri-cargo-and-react-native-apps-on-a-mac) they build natively.

## What it needs

- Linux, x86_64 or arm64. Debian and Ubuntu are tested; swift.org's Ubuntu 22.04 toolchain is the one installed.
- The commands `curl`, `tar`, `gzip`, `unzip`, `zip`, `git` and `python3`, and the libraries Swift's toolchain links
  against. `xless setup` checks the commands before anything else, and runs the new `swiftc` once right after
  unpacking it, so a missing library is named then rather than in the middle of a build. On Debian or Ubuntu:

  ```sh
  sudo apt-get install -y curl ca-certificates tar gzip zip unzip git python3 cpio binutils libc6-dev libcurl4-openssl-dev libedit2 libgcc-11-dev libncurses6 libpython3-dev libsqlite3-0 libstdc++-11-dev libxml2-dev libz3-dev pkg-config tzdata zlib1g-dev
  ```

  (On a release newer than Ubuntu 22.04, use its versions of `libgcc-*-dev` and `libstdc++-*-dev`.)
- Free space: `XLESS_SETUP_CACHE_GB` (17 GB) under the cache while the SDK is exported, and `XLESS_SETUP_NATIVE_GB`
  (10 GB) under the store of Xcode packs while a pack is prepared. An environment variable of the same name overrides
  each figure.
- The `.xip` only until the SDK is exported. After that, `xless setup` with no `--xcode` prepares the pack from the export in
  `~/.cache/xless/sdk/`, and `--sdk <dir>` names one kept elsewhere
  ([troubleshooting.md](troubleshooting.md#without-the-xip)).

## What it installs, and where

| What | Where |
|---|---|
| xtool and rcodesign, at the versions pinned in `versions.env`, each checked against its sha256 | `~/.local/share/xless-native/tools/`, linked from `…/bin/` |
| The Darwin SDK exported from the `.xip` by that xtool | `~/.cache/xless/sdk/xcode<version>-<build>/<arch>/` (shared with `--docker`) |
| The Xcode pack, one per Xcode (several side by side): the open-source Swift toolchain of the Xcode's Swift (Ruling R10; [which one](xcode-versions.md#the-versions)), checked against its sha256, in `toolchain/`; the SDK installed for xtool and SwiftPM in `config/`; its `toolchain-meta.json`; the toolchain record `swift-toolchain.json`; and `pack.json` | `$XLESS_XCODES/<version>-<build>-<arch>/`, default `~/.local/share/xless-native/xcodes/` (on a case-sensitive file system) |

The native home is `$XLESS_NATIVE_HOME` when set, else `$XDG_DATA_HOME/xless-native`, else
`~/.local/share/xless-native`. It is apart from `~/.local/share/xless` (the release's files, which the installer
replaces on every upgrade), so upgrading xless keeps the native install.

xless puts the native toolchain and tools first on its own `PATH` when it starts, so they win over any other `swift`
(swiftly's, your distribution's) for everything it runs, and nothing is added to your shell's startup files.

The Swift toolchain is fitted to the SDK when the pack is prepared, as in a pack of `--docker`
(`scripts/fit-toolchain.sh`, with the files in `docker/toolchain/`): its `clang` and `clang++` become a small driver that adds, for Darwin targets only,
the `TARGET_OS_*` definitions Apple's clang has and the open-source one lacks, and the SDK's toolsets get the same
flags. For Xcode 26.2 (Swift 6.2.3) the SDK also uses that toolchain's clang headers with the Xcode's runtime
libraries. This changes only the pack's copy of Swift. A native setup prepares no Swift Build part: only a pack prepared in the
image has one ([What it builds](#what-it-builds)).

## On a Mac

With Xcode installed, and opened once (it asks for its license and adds what it needs), `xless run` builds and ships an
`xless.yml` project with nothing else set up: no Xcode download, no SDK, no Docker.

```sh
xless setup      # optional: says which Xcode it is, and whether anything is missing; downloads nothing
xless run <project-dir> --build-number 1 --to finalize
xless run <project-dir> --destination simulator        # for the simulator, signed ad hoc
```

**Which Xcode.** In this order: `DEVELOPER_DIR`, the one that `xcode-select` names, then the others in `/Applications` and
`~/Applications` (`Xcode*.app`), the newest first. A project that pins one with `xcode: "27.2"` gets the first of them of that
version; when there is none, the build says which there are. `DEVELOPER_DIR` is never passed over: where it does not fit the
pin, the build stops. One line at the start says which Xcode is used and from where:

```text
xless: Xcode 27.2 (27B52) at /Applications/Xcode.app (xcode-select); actool and ibtool: Xcode's
```

An Xcode is refused when its app, or a program in it that the build starts, is not signed by Apple, or when other users of the Mac
can write to those programs ([security.md](security.md#with-an-installed-xcode) says what that covers and what not). The Command Line Tools alone have no iOS SDK, so they are not enough.

**Which tools.** The compiler, linker and SDKs are that Xcode's. Each other tool is Xcode's when xless knows how to use it,
else xless's own, which is the same as on Linux:

| For | Used | |
|---|---|---|
| Compiling | Xcode's `swift` (SwiftPM), without xcodebuild | always |
| Asset catalogs, launch storyboards | Xcode's `actool` and `ibtool` | `XLESS_TOOLS=xless` uses xless's own, as Linux does; `XLESS_TOOLS=xcode` fails where Xcode's is missing; `XLESS_TOOLS=actool=xless` chooses for one |
| Signing, notarizing, `.ipa`, `.pkg`, disk images, uploading | rcodesign and xless's own | always ([why](security.md#with-an-installed-xcode)) |

rcodesign (about 9 MB, pinned by SHA-256) is fetched once, by the first command that signs, into
`~/.local/share/xless-native/tools` (or under `XLESS_NATIVE_HOME`, an absolute path). `xless clean --native` removes it.

**What it builds.** Swift packages (`xless.yml`), for iOS devices, the iOS simulator and macOS, and
[Tauri, Cargo and React Native apps](#tauri-cargo-and-react-native-apps-on-a-mac). A framework that the app loads is put in its `Frameworks`, and on macOS a
dynamic library (`lib….dylib`) too; on iOS, where the App Store takes no loose one, `finalize` stops, so make that library
product static there. Where an app's lowest system needs Swift libraries that Apple ships with Xcode for older systems, the build stops and says to
raise `minimumOS`. A simulator build has no entitlements.

Package versions are those of the project's `Package.resolved`, where the manifests allow them. Without one, the newest that the
manifest allows are taken. The build ends with a note on each package that the file does not hold: commit that file.

Build products are in the project's `.xless/` (`xcode-pkg-*`, `xcode-build-*`, and `build/` as on Linux). They are deleted with
it. SwiftPM keeps its own caches and settings as it does without xless: `~/Library/Caches/org.swift.swiftpm` and `~/.swiftpm`
(`~/Library/org.swift.swiftpm`), which it finds by the user, not by `HOME`.

### Tauri, Cargo and React Native apps on a Mac

```sh
xless run --config ~/ci/my-app.overlay.yml --build-number 1.0.0.2026101601 --to finalize
```

The overlay is the one that the images build. What they have of other languages is yours here, found on `PATH`:

| App | Needs, beside Xcode |
|---|---|
| Cargo | [rustup](https://rustup.rs). Targets that the app needs and you lack are added to your toolchain (`rustup target add`). |
| Tauri | rustup, Node and the package manager of the lockfile. An iOS app also has `llvm-tools` added to the toolchain. |
| React Native | Node and the package manager of the lockfile, Ruby with Bundler 2.7.2. The gems, CocoaPods among them, are installed for the builds only. |

The build runs in a sandbox that keeps the app's build code from your files and xless's secrets; a line at the start says what it
opens. It does not keep it from the environment of your other programs, nor from turning your launch agents off and reading the
variables in their files.
[security.md](security.md#an-overlays-build-on-a-mac) says what that covers and what not. What the app's build needs beyond its
checkout goes into `XLESS_BUILD_READ`:

```sh
XLESS_BUILD_READ=~/projects/shared-package xless run --config ~/ci/my-app.overlay.yml
```

- **Your settings of the tools are not there**: `~/.npmrc`, `~/.cargo/config.toml`, `~/.gitconfig`, ssh keys. What the build needs of
  them belongs into the app's repository (`.npmrc`, `.cargo/config.toml`) or the overlay's `env:`. Packages from private registries or
  over ssh cannot be fetched, as in the images.
- **The first build fetches everything once more**, into `~/.cache/xless/build-home`, a home directory that only builds have.
- React Native is built by `xcodebuild`. Its log is in the work copy, and the error names it.
- Asset catalogs and storyboards are compiled by xless, as on Linux: Xcode's `actool` and `ibtool` do not work in the sandbox, so
  `XLESS_TOOLS=xcode` is refused.
- Debug symbols, signing, packaging and uploading are as in the images. Disk images are made by macOS's `hdiutil`.
- The work copy is `~/.cache/xless/work/<overlay name>`, the one that `--docker` uses for Tauri and Cargo apps (React Native's is in a
  volume there). Going from one to the other installs the JavaScript packages again.

## Several Xcodes

(Linux.) Each Xcode gets a pack of its own in the store, and `xless setup` with another Xcode adds its pack beside the
others; with the same Xcode it does nothing when the pack is current (`--reexport` exports the SDK again). A project
pins one with `xcode:`; without a pin a build uses the newest. A pack is prepared beside its place and put there whole,
so a failed setup leaves the pack that was there, and a second setup of the same pack waits for the first. An Xcode
installed natively by an xless of before the packs is not used: setup says so and prepares the pack, and `xless clean
--old` removes the old install.

Every command finds the pack the same way: `XLESS_XCODE=<pack directory>` names one and wins; else the store
(`XLESS_XCODES`, default `~/.local/share/xless-native/xcodes`), by the pin or the newest. A missing pack, or one that
this xless prepares in another way (after an upgrade that changed how), stops a build with exit code 2 and the `xless
setup` that prepares it ([images.md](images.md#where-the-packs-are) has the rest).

The store must be on a case-sensitive file system: the SDK has headers whose names differ only in case, and setup
refuses another before it writes anything. One store may serve both a native xless and `--docker` (`XLESS_XCODES` set
for both). Then do not run a native `xless setup` while an `xless run --docker` builds: a native setup does not look for
the containers that use a pack, so nothing keeps it from replacing one under them.

## Running it

```sh
xless run <project-dir> --build-number 1 --to finalize
```

Leave out `--to finalize` to sign and upload too
([signing-and-testflight.md](signing-and-testflight.md)). `xless ship --platform ios` in the project directory runs the
stages directly.

## From a source checkout

`scripts/install-native.sh [--prefix <dir>]` builds `xless` from the checkout and installs it into `<prefix>/bin`
(default `/usr/local`; it installs Swift through swiftly first if needed, and uses `sudo`). A source build finds its
data files (`versions.env`, the scripts) only through `XLESS_SHARE`, so run setup as
`XLESS_SHARE=<the checkout> xless setup --xcode <Xcode.xip>`. A source build is version `0.0.0-dev`, as is a checkout's
`versions.env`, so it refuses a release's share directory (`~/.local/share/xless`) and the other way round
([troubleshooting.md](troubleshooting.md#installing)).

## Windows

On Windows xless has its account commands, natively: `auth`, `team`, `secrets`, `devices`, `bundle-ids`, `merchant-ids`, `certs`,
`profiles`, `app-groups`, `icloud-containers`, `keys`, `apps`, `store`, `builds`, `users`, `testflight`, `release`, `iap`,
`subscriptions`, `sandbox-testers`, `reviews`, `reports`, `webhooks`, `provision` and `api` ([apple-account.md](apple-account.md)).
**Builds do not run there:** install xless inside [WSL2](https://learn.microsoft.com/windows/wsl/install) (`wsl --install`), with the
line for Linux, and build in it, or build on a Mac or Linux. The commands that build say so.

```powershell
irm https://github.com/fmsouza/xless/releases/latest/download/install.ps1 | iex
```

It needs Windows 10 1809 or later (or Windows 11, or Server 2019 and later), x64, and Windows PowerShell 5.1 or PowerShell 7. On ARM64 the
x64 program runs under Windows 11's emulation.

- **Where.** `%LOCALAPPDATA%\Programs\xless`, which only you, the system and the administrators may open, and the `bin` directory in it on
  your own `PATH`. Your secret store and settings are elsewhere (`%LOCALAPPDATA%\xless`).
- **What it checks.** The zip against the release's `SHA256SUMS`, always, over HTTPS only; nothing is replaced before that. The zip's
  and the installer's provenance can be checked with [`gh attestation verify`](../README.md#install).
- **What it does not do.** It needs no administrator and refuses an elevated terminal, whose user may be another one (a machine without
  another kind, such as a CI runner, sets `XLESS_ALLOW_ELEVATED=1`). It changes no execution policy, and installs nothing else.
- **The Visual C++ runtime** of Microsoft is the one thing xless needs that Windows may not have. Without it the installer
  installs nothing and says so: `winget install Microsoft.VCRedist.2015+.x64`, then the line again. (On ARM64 it cannot tell, and only says it.)
- **Upgrade:** run the line again (an xless that runs meanwhile goes on). **A given release:** `$env:XLESS_VERSION = 'x.y.z'` first.
- **Remove it:** `$env:XLESS_UNINSTALL = '1'`, then the line. It takes away the program and its `PATH` entry, and keeps your secret store
  and settings.

The program carries no signature (Authenticode): what vouches for it are the checksum and the attestation. A zip that a browser downloaded
is marked, and SmartScreen asks about what is unpacked from it; the install line leaves no mark.

Use it in a console: Windows Terminal, the console of PowerShell or `cmd`, or a terminal that uses Windows' pseudoconsole (Git Bash's
newer ones do; with an old one, `winpty xless …`). PowerShell ISE has no console, and xless asks nothing there.

What is not there, and what each command says instead: builds (`setup`, `run`, `ship`, …: inside WSL2, or on a Mac or Linux), keeping a secret store or a
sign-in unlocked (`unlock`, `session`, `--remember`, `--keep`, `--across-reboots`: every command asks; in CI, set the variables), credential
helpers, `secrets materialize` and `secrets import-env`, security keys (use a code), and the overlay of a Tauri, Cargo or React Native
project (`--config`: give `--app` or `--bundle-id`). What holds there of xless's security, and what does not:
[security.md](security.md#windows).

In Git Bash, MSYS turns an argument such as `/v1/apps` into a Windows path: `MSYS_NO_PATHCONV=1 xless api GET /v1/apps`.

## Removing it

`xless clean --native` removes the native home with the packs of its store, and the SDK and metadata that an older xless
installed; it asks first ([uninstall.md](uninstall.md#xless-clean)). A store elsewhere (`XLESS_XCODES`) is removed by
`xless clean --packs`.
