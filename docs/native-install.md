# The native install

On a Mac there is nothing to install: xless builds with your Xcode ([below](#on-a-mac)).

On Linux, `xless setup --xcode <Xcode.xip>` installs what xless builds with straight onto the machine, and `xless run`
builds with it. This is the default; the Docker images (`--docker`, [README](../README.md#build-in-docker-instead))
are the alternative. This page says what the native install puts where, what it needs, and what it does not cover.

## What it builds

`xless.yml` projects (Swift packages), for iOS and macOS, through every stage up to TestFlight. React Native, Tauri and
plain Cargo apps (`--config <overlay.yml>`) need much more than the native install has (Node and CocoaPods, rustup's
Apple targets, Swift Build, the Xcode tool shims), so `xless run` refuses them without `--docker`.

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
  (10 GB) under the native home. An environment variable of the same name overrides each figure.
- The `.xip` only until the SDK is exported. After that, `xless setup` with no `--xcode` installs from the export in
  `~/.cache/xless/sdk/`, and `--sdk <dir>` names one kept elsewhere
  ([troubleshooting.md](troubleshooting.md#without-the-xip)).

## What it installs, and where

| What | Where |
|---|---|
| xtool and rcodesign, at the versions pinned in `versions.env`, each checked against its sha256 | `~/.local/share/xless-native/tools/`, linked from `…/bin/` |
| The open-source Swift toolchain of the Xcode's Swift (Ruling R10: Swift 6.4.2 for Xcode 27.2, 6.4.0 for Xcode 27.1 and 27.0, 6.3.3 for 26.6, 6.3.2 for 26.5, 6.3.1 for 26.4.1, 6.3.0 for 26.4, 6.2.4 for 26.3, 6.2.3 for 26.2, 6.2.1 for 26.1.1 and 26.1, 6.2.0 for 26.0.1), checked against its sha256 | `~/.local/share/xless-native/toolchains/swift-<version>/` |
| The toolchain record (which Swift compiles app code, and the clang flags it needs) | `~/.local/share/xless-native/swift-toolchain.json` |
| The Darwin SDK exported from the `.xip` by that xtool | `~/.cache/xless/sdk/xcode<version>-<build>/<arch>/` (shared with `--docker`) |
| The SDK, installed for xtool and SwiftPM | `$XDG_CONFIG_HOME/swiftpm/swift-sdks/` if set, else `~/.swiftpm/swift-sdks/` |
| Its toolchain metadata | `$XLESS_TOOLCHAIN_META`, else `$XDG_CONFIG_HOME/xless/toolchain-meta.json` (default `~/.config/xless/`) |

The native home is `$XLESS_NATIVE_HOME` when set, else `$XDG_DATA_HOME/xless-native`, else
`~/.local/share/xless-native`. It is apart from `~/.local/share/xless` (the release's files, which the installer
replaces on every upgrade), so upgrading xless keeps the native install.

xless puts the native toolchain and tools first on its own `PATH` when it starts, so they win over any other `swift`
(swiftly's, your distribution's) for everything it runs, and nothing is added to your shell's startup files.

The Swift toolchain is fitted to the SDK the way the images fit theirs (`scripts/native-toolchain.sh`, with the same
files as `docker/Dockerfile`): its `clang` and `clang++` become a small driver that adds, for Darwin targets only,
the `TARGET_OS_*` definitions Apple's clang has and the open-source one lacks, and the SDK's toolsets get the same
flags. For Xcode 26.2 (Swift 6.2.3) the SDK also uses that toolchain's clang headers with the Xcode's runtime
libraries. This changes only xless's own copy of Swift.

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

An Xcode that Apple did not sign, or that other users of the Mac can write to, is refused
([security.md](security.md#with-an-installed-xcode)). The Command Line Tools alone have no iOS SDK, so they are not enough.

**Which tools.** The compiler, linker and SDKs are that Xcode's. Each other tool is Xcode's when xless knows how to use it,
else xless's own, which is the same as on Linux:

| For | Used | |
|---|---|---|
| Compiling | Xcode's `swift` (SwiftPM), without xcodebuild | always |
| Asset catalogs, launch storyboards | Xcode's `actool` and `ibtool` | `XLESS_TOOLS=xless` uses xless's own, as Linux does; `XLESS_TOOLS=xcode` fails where Xcode's is missing; `XLESS_TOOLS=actool=xless` chooses for one |
| Signing, notarizing, `.ipa`, `.pkg`, disk images, uploading | rcodesign and xless's own | always ([why](security.md#with-an-installed-xcode)) |

rcodesign (about 9 MB, pinned by SHA-256) is fetched once, by the first command that signs, into
`~/.local/share/xless-native/tools` (or under `XLESS_NATIVE_HOME`). `xless clean --native` removes it.

**What it builds.** Swift packages (`xless.yml`), for iOS devices, the iOS simulator and macOS. React Native, Tauri and Cargo
apps build in the images, on a Mac too (`--docker`), except for the React Native simulator builds that
[react-native.md](react-native.md) describes. A pre-built or dynamic library that the app loads is put in its `Frameworks`;
where an app's lowest system needs Swift libraries that Apple ships with Xcode for older systems, the build stops and says to
raise `minimumOS`. A simulator build has no entitlements.

Build products are in the project's `.xless/` (`xcode-pkg-*`, `xcode-build-*`, and `build/` as on Linux). They are deleted with
it.

## One Xcode at a time

(Linux.) The native install holds one Xcode's SDK and Swift. `xless setup` with another Xcode replaces them; with the same Xcode
it does nothing (`--reexport` exports the SDK again). A project that pins another Xcode with `xcode:` is refused at
`build` with the setup command that fixes it. To keep several Xcodes side by side, use the images
(`xless setup --docker`), which are tagged per Xcode.

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

## Removing it

`xless clean --native` removes the native home, the installed SDK and its metadata ([uninstall.md](uninstall.md)).
