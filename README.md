# xless

xless is one command-line tool for the whole life of an Apple app: it sets up the account and the app, manages the App Store
listing, builds and signs, sends builds to TestFlight, releases to the App Store, and does all of that in scripts. It builds
Swift packages, Tauri and plain Cargo apps for iOS and macOS, and React Native (Expo) apps for iOS: with the Xcode that is installed
on a Mac, or on Linux with no Mac. The account half also runs on Windows.

## What it does

| | | |
|---|---|---|
| **Set up the account and the app** | API keys, bundle IDs and capabilities, certificates, profiles, devices, push keys, users, the app record | `xless provision apply` makes what a project lacks ([account](docs/account.md)) |
| **Configure the listing** | the texts in every language, screenshots, App Privacy, age rating, price, in-app purchases, as files in your repository | `xless store pull`, `xless store push` ([listing](docs/appstore-manifest.md)) |
| **Build and sign** | an `.ipa`, a notarized macOS app, a Mac App Store package | `xless run <project-dir>` ([build](docs/build.md), [sign and ship](docs/signing-and-testflight.md)) |
| **TestFlight** | upload, groups, internal and external testers, beta review | `xless testflight …` ([testers](docs/testflight.md)) |
| **Release** | a check of what App Review asks for, the submission, phased releases | `xless release submit` ([release](docs/release.md)) |
| **Automate** | several apps, checks, JSON output, runs that nobody answers, CI | `xless session -- ./script.sh` ([automate](docs/automate.md), [CI](docs/ci.md)) |

Your keys go into an encrypted store on your own machine. [What xless keeps and sends](docs/security.md), to which host, and what that
protects from whom.

### Where it runs

| | Linux | macOS 14 or later | Windows 10, 11 | WSL 2 |
|---|---|---|---|---|
| Account, listing, TestFlight, release | yes | yes | yes | yes |
| Build Swift packages, sign and ship | yes | yes, with your Xcode | no | as Linux |
| Build React Native, Tauri, Cargo apps | in Docker | in Docker | no | as Linux |

The [whole table](docs/systems.md), with what was tried, what is not there and what is planned.

## Install

On Linux (x86_64, arm64) and macOS 14 or later (Intel, Apple silicon), and inside WSL 2 (read [what a build can reach
there](docs/security.md#in-wsl) before you build):

```sh
curl -fsSL https://github.com/fmsouza/xless/releases/latest/download/install.sh | sh
```

On Windows 10 (1809 or later) or 11, in a PowerShell that is not "as administrator", for the
[account commands](docs/native-install.md#windows):

```powershell
irm https://github.com/fmsouza/xless/releases/latest/download/install.ps1 | iex
```

The installers check the download against the release's checksums, and need no `sudo` and no administrator. Run the line again to
upgrade. Then check with `xless --version`; if `xless` is not found, or to pick a version, another place, or
[check a download](docs/install.md#check-a-download) yourself with `gh attestation verify`: [install](docs/install.md). To remove
it: [uninstall](docs/uninstall.md).

## A first app

You need an Apple Developer Program membership ([before you start](docs/account.md#before-you-start)). This is the short form;
[get started](docs/get-started.md) explains each step, and has the paths for an app that exists already, for building only, for the
account only, and for CI.

```sh
xless secrets init                       # the encrypted store for your keys
xless auth login --keep                  # your Apple ID, once; lists your teams (on Windows without --keep)
xless team use ABCDE12345                # your team ID, from that list
xless auth api-key create --role ADMIN   # the key goes straight into the store

cd MyApp                                 # a project with an xless.yml and an appstore/ directory
xless provision plan                     # what the account lacks for it
xless provision apply --company-name "Example Ltd"   # makes it (--company-name for the team's first app)

xless run .                              # builds, signs, uploads, delivers to TestFlight
xless store push                         # the listing
xless release submit --release manual    # to App Review
xless release publish                    # once approved, when you choose
```

`xless run` needs Apple's SDK: on a Mac, Xcode, opened once; on Linux, `xless setup` once, below.

<a id="what-you-need"></a>
<a id="on-a-mac"></a>
<a id="build-the-sample-app"></a>
## Build

To build only, with no Apple account: `xless run <project-dir> --build-number 1 --to finalize`. It ends with an unsigned app.

- **On a Mac**, with Xcode installed and opened once, nothing else is set up ([build: on a Mac](docs/build.md#on-a-mac)).
- **On Linux**, <a id="set-up"></a>`xless setup --xcode ~/Downloads/Xcode_27.xip`, once per Xcode version
  ([build: on Linux](docs/build.md#on-linux): what it needs and installs).
- <a id="build-in-docker-instead"></a>**In Docker**, on either: `xless setup --docker --xcode …` once, then
  `xless run --docker …`. React Native, Tauri and Cargo apps build there ([build: in Docker](docs/build.md#in-docker)).
- **In WSL 2**, as on Linux, but read [what a build can reach there](docs/security.md#in-wsl) first.
- <a id="get-xcode"></a>**The Xcode download** that Linux and Docker need: [the versions, and how to get one](docs/xcode-versions.md).

<a id="next"></a>
## Documentation

- [Get started](docs/get-started.md): five paths, each to the end
- [Your Apple account, by task](docs/account.md), and the [reference of every account command](docs/apple-account.md)
- [The App Store listing as files](docs/appstore-manifest.md)
- [Build an app](docs/build.md); [React Native and Expo](docs/react-native.md), [Tauri](docs/tauri.md), [Cargo](docs/cargo.md)
- [Sign it and upload it](docs/signing-and-testflight.md), [testers](docs/testflight.md), [release](docs/release.md)
- [Automate](docs/automate.md) and [CI](docs/ci.md)
- [What xless keeps and sends](docs/security.md): the encrypted secret store, the Apple ID session, and which host gets what
- [Troubleshooting](docs/troubleshooting.md)
- [All documentation](docs/README.md), including how xless works and [how to contribute](CONTRIBUTING.md)

## Apple software

xless contains and distributes no Apple software: no Xcode, no SDKs, no Apple tools. You obtain Xcode from Apple
yourself and are responsible for complying with its license terms. The SDK you export, and the images that contain it,
stay on your machine and are not meant to be published.

xless is not made or supported by Apple.

## Licence

xless is released under the [MIT licence](LICENSE). Each release also carries the licence notices of the third-party
code built into the `xless` binary, in `share/xless/licenses/`.
