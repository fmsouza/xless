# Build an app

A build needs no Apple account: it ends with an unsigned app. With the account set up, the same command goes on to sign and
ship it ([signing-and-testflight.md](signing-and-testflight.md)). [Install xless](../README.md#install) first.

| You have | Read |
|---|---|
| A Swift package app, on a Mac | [On a Mac](#on-a-mac) |
| A Swift package app, on Linux | [On Linux](#on-linux) |
| A React Native, Expo, Tauri or Cargo app | [On a Mac](#overlays-on-a-mac), or [in Docker](#in-docker); then [react-native.md](react-native.md), [tauri.md](tauri.md) or [cargo.md](cargo.md) |
| Windows | [WSL 2](#in-wsl-2), or a Mac or a Linux machine: builds do not run on Windows itself |

A Swift package app is a package with an `xless.yml` beside its `Package.swift`: [xless-yml.md](xless-yml.md) is the reference.
What works on which system: [systems.md](systems.md).

A build runs the project's code (its package manifests, plugins and macros, the scripts of its JavaScript or Rust packages):
[what that code can reach](security.md#the-build-and-your-secrets).

## On a Mac

Install Xcode and open it once. Nothing else is set up:

```sh
xless run <project-dir> --build-number 1 --to finalize     # an app for a device
xless run <project-dir> --destination simulator            # for the simulator, signed ad hoc
```

`xless setup` there only checks what it finds. Which Xcode is used, which tools of it, and what a build covers:
[native-install.md](native-install.md#on-a-mac). To try it with a small iOS app, [build the sample](#the-sample-app).

### Overlays on a Mac

A React Native, Tauri or Cargo app builds from its overlay, with the Mac's own rustup, Node, Ruby and Xcode.

The app's build code (npm scripts, `build.rs`, gems, pods, plugins, build phases) runs in a sandbox, always; signing, packaging and
uploading come after it, outside, with the secrets. One line at the start says what the sandbox opens. **It is not a container.**
Read what it keeps away and what not in [security.md](security.md) ("An overlay's build on a Mac") before you build code that you do
not trust. Then:

```sh
xless run --config <overlay.yml> --build-number <n> --to finalize
```

What the build needs beyond the app's checkout goes into `XLESS_BUILD_READ`, absolute paths with `:` between them. The app's code can
read all that is in them: name nothing with a secret in it. What each kind of app needs on the Mac is in [native-install.md](native-install.md#on-a-mac). [In Docker](#in-docker) stays, with `--docker`.

## On Linux

### What you need

- x86_64 or arm64. Debian and Ubuntu are what xless is tested on.
- A few system packages: `curl`, `tar`, `zip`, `unzip`, `git`, `python3` and the libraries of Swift's Linux toolchain.
  `xless setup` checks for the commands and prints the `apt-get install` line that adds whatever is missing
  ([the whole list](native-install.md#what-it-needs)). It never runs `sudo` itself.
- Free disk space, per Xcode version: about 17 GB in your home directory's cache (`~/.cache`) while the SDK is taken
  out of the `.xip` (about 3.5 GB of it stays), and about 10 GB for the native install (`~/.local/share/xless-native`
  and the installed SDK), plus a few GB for each app's build caches. `xless setup` checks both before it starts.
- An Xcode download from Apple, the `.xip` file: [which versions, and how to get it](xcode-versions.md). You do not need a
  Mac, and you do not unpack it.

### Set up, once per Xcode version

```sh
xless setup --xcode ~/Downloads/Xcode_27.xip
```

This installs, under `~/.local/share/xless-native`, the tools xless builds with: [xtool](https://github.com/xtool-org/xtool),
[rcodesign](https://github.com/indygreg/apple-platform-rs) and the open-source Swift toolchain that matches the Swift of
that Xcode (swift.org's, about a 1.1 GB download). Each download is checked against a checksum pinned in xless. It
then takes Apple's SDK out of the `.xip` and installs it for Swift. It needs no Docker and no `sudo`, leaves any Swift
you already have alone, and does not touch your shell's startup files: xless finds its own tools. It first checks the
commands it needs and your free disk space, then prints each step. When it finishes it prints the next command to run.
To see the plan and the disk space it asks for without running anything, add `--dry-run`.

The native install holds one Xcode at a time: for Xcode 26.2 run
`xless setup --xcode ~/Downloads/Xcode_26.2_Universal.xip`, which replaces 27.0's SDK and Swift (the exported SDKs stay
in the cache, so switching back is quick). Running it again with the same Xcode does nothing. What it puts where:
[native-install.md](native-install.md).

### Build

```sh
xless run <project-dir> --build-number 1 --to finalize
```

## The sample app

The install includes a small iOS app, HelloShip. Copy it and build it:

```sh
cp -r ~/.local/share/xless/samples/HelloShip ~/HelloShip
xless run ~/HelloShip --build-number 1 --to finalize
```

The first build resolves the sample's Swift packages; later ones take under a minute. The build ends with `stopped
after finalize (--to), nothing delivered`. The finished app is `~/HelloShip/.xless/build/ios/final/HelloShip.app`: an
unsigned iOS app for arm64 devices.

## In Docker

The same builds can run in a Docker image on your machine, on Linux or on a Mac. Swift package apps can; on Linux, React Native,
Expo, Tauri and Cargo apps build in the images only. You need [Docker Engine](https://docs.docker.com/engine/install/) with the
buildx plugin, usable without `sudo` (your user is in the `docker` group), about 40 GB where Docker keeps its data, and an
[Xcode download](xcode-versions.md). Build the image once per Xcode version:

```sh
xless setup --docker --xcode ~/Downloads/Xcode_27.xip
```

This builds one Docker image on your machine, `xless:local-<arch>-xcode<version>`, with Apple's SDK. It first checks
Docker and your free disk space, then prints each step with a rough time: most of it is unpacking the `.xip`.
`--dry-run` shows the plan, and `--arch amd64` (or `arm64`, or both) builds for another architecture.

**The images never leave your machine:** they contain Apple's SDK, so never push them to a registry.

Then add `--docker` to `xless run`:

```sh
xless run --docker ~/HelloShip --build-number 1 --to finalize
```

- A Tauri, plain Cargo, React Native or Expo app needs other toolchains too (Rust, Node, Ruby, Hermes). `xless run` adds
  them in a small image on top the first time such an app needs it, and says so; `xless setup --docker --with
  tauri,react-native` does it ahead of time ([images.md](images.md)).
- A project that pins an Xcode (`xcode: "26.2"`) runs in that one's image, another in the newest Xcode's there is an image of.
- Once the SDK is exported, the `.xip` is no longer needed: to build the image again (on a machine that lost it,
  say), run `xless setup --docker` with no `--xcode`. It reuses the SDK export in `~/.cache/xless/sdk/`, or the one you
  name with `--sdk <dir>` ([troubleshooting.md](troubleshooting.md#without-the-xip)). The same works without
  `--docker` for the native install on Linux.
- Paths in the output that start with `/work` are inside the build container, where `/work` is your project directory.
- On Linux the build runs as root inside the container, so the files it creates in the project (`.xless`, `.build`, `.bsp`,
  `xtool` and `xtool.yml`) belong to root: remove a copy of the sample with `sudo rm -rf ~/HelloShip`.
- `xless docker …` is the same as `xless run --docker …`.

## In WSL 2

A WSL 2 distribution builds as Linux does. **First read [In WSL](security.md#in-wsl):** on a distribution as it is
installed, a build can reach Windows, and be root in the distribution, whatever xless does; for code that you do not trust,
make [a distribution for builds](security.md#a-distribution-for-builds). None of this was tried in WSL itself: it is written
from WSL's source and documentation. The limits of a build there: [troubleshooting.md](troubleshooting.md#in-wsl).

To start such a build from Windows itself is planned ([#200](https://github.com/fmsouza/xless/issues/200)).

## Next

- [How a build runs](pipeline.md): the stages and their exit codes.
- [Sign the app and upload it to TestFlight](signing-and-testflight.md).
- [Free the disk space](uninstall.md): `xless clean`.
