# What works on which system

xless is one program for the whole life of an app. The **account** half (keys, certificates, profiles, the listing, TestFlight,
the release) is the same on every system. The **build** half needs Apple's SDK: the Xcode that is installed on a Mac, or what
`xless setup` takes out of an [Xcode download](xcode-versions.md) on Linux.

| | Linux | macOS | Windows | WSL 2 |
|---|---|---|---|---|
| Versions | x86_64, arm64; Debian and Ubuntu are tested | 14 or later; Intel, Apple silicon | 10 (1809 or later), 11, Server 2019 or later; x64, on ARM64 under Windows 11's emulation | as Linux |
| Account commands | yes | yes | yes ([but](#windows)) | yes |
| Sign in with a USB security key | yes | yes, not tried with a real key ([#199](https://github.com/fmsouza/xless/issues/199)) | no: use a code | as Linux |
| Keep the store or a sign-in unlocked (`unlock`, `session`, `--keep`) | yes | yes | no: each command asks | yes |
| Download Xcode (`xless xcode download`) | yes | yes | no | yes |
| Swift package apps, for iOS and macOS | yes, after `xless setup` | yes, with the installed Xcode | no | yes, as Linux ([read first](security.md#in-wsl)) |
| The same for the iOS simulator | no | yes | no | no |
| Tauri and Cargo apps, for iOS and macOS | in Docker | in Docker | no | as Linux |
| React Native and Expo apps, for iOS and its simulator | in Docker | in Docker | no | as Linux |
| Sign, notarize, package, upload | yes | yes | no | yes |
| Checked on each pull request | the tests, on x86_64 and arm64 | the tests; a sample built, and signed with a throw-away certificate | the account commands and their tests | the Linux tests with the kernel taken for WSL's; nothing in WSL itself |

Docker in this table is [the images](images.md) you build on your own machine; they hold Apple's SDK and never leave it. A
simulator app that Docker built is launched on a Mac ([react-native.md](react-native.md#simulator-builds)).

## Linux

Everything, natively for Swift packages and in Docker for the rest. A session or an unlock is held in an agent in memory (Linux
5.3 or later), else in the kernel's keyring where that works ([secrets.md](secrets.md#staying-unlocked)).

A whole run against a real Apple account, for a new app, from the first API key to a TestFlight build on a device and a submission
to App Review, was made on Linux arm64 on 2026-11-24: [acceptance-m7.md](acceptance-m7.md). The approval, the release to the App Store
and the two last checks of that list were not part of it ([#181](https://github.com/fmsouza/xless/issues/181)).

## macOS

Swift packages build with the Xcode that is installed, for devices, the simulator and macOS, with no SDK export and no Docker.
Signing, notarizing, packaging and uploading are xless's own, as on Linux. Details and limits:
[native-install.md](native-install.md#on-a-mac).

- CI builds and signs a sample there. An upload to App Store Connect from a Mac has not been recorded.
- With a security key: tested with a simulated key only ([#199](https://github.com/fmsouza/xless/issues/199)).

## Windows

The account commands, natively. Not there: builds and what belongs to them (`setup`, `run`, `ship` and its stages, `xcode`, `clean`),
keeping anything unlocked, credential helpers, `secrets materialize` and `import-env`, security keys, and reading a project's overlay
(`--config`). Each says so and what to do instead: [native-install.md](native-install.md#windows). What holds of xless's security
there: [security.md](security.md#windows).

Planned: builds started from Windows that run in WSL 2 ([#200](https://github.com/fmsouza/xless/issues/200)).

## WSL 2

As Linux, with the program for Linux. It was not tried in WSL itself; it follows WSL's source and Microsoft's documentation.
**On a WSL distribution as it is installed, a build can reach Windows, and be root in the distribution, whatever xless does**:
[In WSL](security.md#in-wsl) says what to turn off, and [a distribution for builds](security.md#a-distribution-for-builds) how. WSL 1
builds nothing.

A run asks the passphrase after the build, not before it, and holds nothing meanwhile; with `--no-input` and a locked store it is
refused. Symptoms and limits: [troubleshooting.md](troubleshooting.md#in-wsl).

## What is not here

- Builds of a plain Xcode project (`.xcodeproj`): a Swift app is a Swift package with an [`xless.yml`](xless-yml.md).
- Builds for Apple Watch, Apple TV and Apple Vision, and for Android.
