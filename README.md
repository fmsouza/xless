# xless

xless builds iOS and macOS apps on Linux, with no Mac. It compiles a Swift package, a React Native (Expo) app, a
Tauri app or a plain Cargo app against Apple's SDK, and can then sign it, package it and upload it to TestFlight. By
default it installs everything it needs straight onto your Linux machine, from the Xcode download Apple gives you. The
alternative is a set of Docker images that you build once on your own machine: add `--docker` to the commands. React
Native, Tauri and plain Cargo apps build in the images only.

## What you need

- A Linux machine, x86_64 or arm64. Debian and Ubuntu are what xless is tested on.
- A few system packages: `curl`, `tar`, `zip`, `unzip`, `git`, `python3` and the libraries of Swift's Linux toolchain.
  `xless setup` checks for the commands and prints the `apt-get install` line that adds whatever is missing. It never
  runs `sudo` itself.
- Free disk space, per Xcode version: about 17 GB in your home directory's cache (`~/.cache`) while the SDK is taken
  out of the `.xip` (about 3.5 GB of it stays), and about 10 GB for the native install (`~/.local/share/xless-native`
  and the installed SDK), plus a few GB for each app's build caches. `xless setup` checks both before it starts.
- Xcode 27.0 or 26.2 from Apple, as the `.xip` file Apple distributes. xless takes Apple's SDK out of it; it never runs
  a program from it. See [Get Xcode](#get-xcode).
- Only for `--docker`: [Docker Engine](https://docs.docker.com/engine/install/) with the buildx plugin, usable without
  `sudo` (your user is in the `docker` group), and about 40 GB where Docker keeps its data ([Build in Docker
  instead](#build-in-docker-instead)).

You do not need a Mac, and you do not need to unpack the `.xip`.

### Get Xcode

1. Open <https://developer.apple.com/download/all/> and sign in with your Apple ID. A free Apple ID is enough.
2. Search for the Xcode version and download its `.xip`. Where Apple offers a "Universal" and an "Apple silicon"
   file, take the Universal one (for 26.2, xless also accepts the Apple silicon file).

   | Xcode | File to download |
   |---|---|
   | 27.0 (build 27A266a) | `Xcode_27.xip` |
   | 26.2 (build 17C52) | `Xcode_26.2_Universal.xip` |

3. Keep the file where your browser saved it. The commands below assume `~/Downloads`.

xless recognises the file by its content, not by its name, and refuses any other Xcode version
([what to do then](docs/troubleshooting.md#xless-setup)).
[docs/apple-requirements.md](docs/apple-requirements.md) lists everything xless uses from Apple, and why.

## Install

```sh
curl -fsSL https://github.com/fmsouza/xless/releases/latest/download/install.sh | sh
```

This puts `xless` in `~/.local/bin` and its support files in `~/.local/share/xless`, after checking the download
against the release's checksums. It needs no `sudo`. If it says that `~/.local/bin` is not on `PATH` in this shell,
open a new terminal (many Linux systems add `~/.local/bin` at login once it exists) or run the `export` line it
prints. If a new terminal still cannot find `xless`, add that line to your shell's startup file. Then check:

```sh
xless --version
```

Each release asset also carries a signed build provenance attestation: proof that the release workflow of
`fmsouza/xless` built it, from which commit. To check a download yourself with the [GitHub CLI](https://cli.github.com/)
(signed in with `gh auth login`):

```sh
gh attestation verify xless-<version>-linux-<arch>.tar.gz -R fmsouza/xless
```

`SHA256SUMS` and `install.sh` are attested too. The installer itself checks the checksum only; it does not need `gh`.

## Set up

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

You do this once per Xcode version. The native install holds one Xcode at a time: for Xcode 26.2 run
`xless setup --xcode ~/Downloads/Xcode_26.2_Universal.xip`, which replaces 27.0's SDK and Swift (the exported SDKs stay
in the cache, so switching back is quick). Running it again with the same Xcode does nothing.

## Build the sample app

The install includes a small iOS app, HelloShip. Copy it and build it:

```sh
cp -r ~/.local/share/xless/samples/HelloShip ~/HelloShip
xless run ~/HelloShip --build-number 1 --to finalize
```

If you set up Xcode 26.2 only, run this between the two commands, so that the sample uses that Xcode:

```sh
echo 'xcode: "26.2"' >> ~/HelloShip/xless.yml
```

The first build resolves the sample's Swift packages; later ones take under a minute. The build ends with `stopped
after finalize (--to), nothing delivered`. The finished app is `~/HelloShip/.xless/build/ios/final/HelloShip.app`: an
unsigned iOS app for arm64 devices. No Apple account is needed for this step.

## Build in Docker instead

The same builds can run in Docker images instead, which carry everything xless needs, including what React Native,
Tauri and plain Cargo apps need. Build the images once per Xcode version:

```sh
xless setup --docker --xcode ~/Downloads/Xcode_27.xip
```

This builds four Docker images on your machine: `xless-base`, `xless` (with Apple's SDK), `xless-tauri` (Tauri and
plain Cargo apps) and `xless-rn`. It first checks Docker and your free disk space, then prints each step with a rough
time. The whole run took about 13 minutes on an 8-core machine with a fast network; it can take an hour on a slow one.
`--dry-run` shows the plan, and `--arch amd64` (or `arm64`, or both) builds for another architecture.

`docker images` then lists each image under several tags that name the same image: `:local-<arch>-xcode<version>`,
`:local-<arch>-xcode<version>-<build>` and, for Xcode 27.0, `:local-<arch>`. The images never leave your machine: they
contain Apple's SDK, so do not push them to a public registry.

Then add `--docker` to `xless run`:

```sh
xless run --docker ~/HelloShip --build-number 1 --to finalize
```

Paths in the output that start with `/work` are inside the build container, where `/work` is your project directory.
The build runs as root inside the container, so the files it creates in `~/HelloShip` (`.xless`, `.build`, `.bsp`,
`xtool` and `xtool.yml`) belong to root: remove that copy with `sudo rm -rf ~/HelloShip`. `xless docker …` is the
same as `xless run --docker …`.

## Next

- [Sign the app and upload it to TestFlight](docs/signing-and-testflight.md): you need an Apple Developer Program
  membership for this.
- [React Native and Expo apps](docs/react-native.md)
- [Tauri v2 apps](docs/tauri.md), for iOS and macOS
- [Plain Cargo apps](docs/cargo.md) (winit, egui…), for iOS and macOS
- [The native install in detail](docs/native-install.md): what it installs where, and its limits
- [Troubleshooting](docs/troubleshooting.md)
- [Uninstall xless and free its disk space](docs/uninstall.md): `xless clean`
- [All documentation](docs/README.md), including how xless works and how to contribute

## Apple software

xless contains and distributes no Apple software: no Xcode, no SDKs, no Apple tools. You obtain Xcode from Apple
yourself and are responsible for complying with its license terms. The SDK you export, and the images that contain it,
stay on your machine and are not meant to be published.

## Licence

xless is released under the [MIT licence](LICENSE). Each release also carries the licence notices of the third-party
code built into the `xless` binary, in `share/xless/licenses/`.
