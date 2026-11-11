# xless documentation

Start with the [README](../README.md): what xless is, what you need, the install line, `xless setup`, and a first
build. The pages below go further.

## Using xless

- [pipeline.md](pipeline.md): how a build runs, the images, the stages (`build` → `assets` → `finalize` → `sign` →
  `package` → `upload`) and their exit codes.
- [xless-yml.md](xless-yml.md): the `xless.yml` reference, for Swift package apps.
- [signing-and-testflight.md](signing-and-testflight.md): secrets, build numbers, `xless run` up to TestFlight, the
  notarized DMG, and running in CI.
- [bootstrap.md](bootstrap.md): the one-time Apple setup (API key, certificates, bundle ID, app record).
- [react-native.md](react-native.md): React Native / Expo iOS apps, with app extensions and simulator builds.
- [tauri.md](tauri.md): Tauri v2 apps, for iOS and macOS.
- [cargo.md](cargo.md): plain Cargo apps (a Rust binary with its own event loop), for iOS and macOS.
- [troubleshooting.md](troubleshooting.md): install, setup, build and App Store Connect errors, and known gaps.

## Installing and images

- [apple-requirements.md](apple-requirements.md): everything xless needs from Apple, how to get it on Linux, and the
  audit behind that list.
- [xcode-download.md](xcode-download.md): `xless xcode download`, one terminal sign-in to Apple for any number of Xcode
  `.xip`s, and what happens to your Apple ID and password.
- [images.md](images.md): the Docker images (`--docker`), and how to build each one by hand.
- [native-install.md](native-install.md): the native install `xless setup` makes (the default): what goes where, and its limits.
- [uninstall.md](uninstall.md): `xless clean`, freeing disk space after an upgrade, and uninstalling.

## Working on xless

- [CONTRIBUTING.md](../CONTRIBUTING.md): branches, Conventional Commit titles, the pull request checks, and how
  versions are computed.
- [maintainers.md](maintainers.md): the Mac tools, the parity tests, measuring a new Xcode, private registries, releases
  and the repository settings.
- [examples/example-ios.yml](examples/example-ios.yml): an example GitHub Actions workflow for an app repository.

## Research notes

Measurements and decisions behind the code, in [research/](research/):

- [App Store Connect build uploads](research/asc-build-uploads.md) and [TestFlight delivery](research/asc-testflight.md)
- [Why there is no Mac App Store `.pkg`](research/mas-pkg.md)
- [Parity known gaps](research/parity-known-gaps.md) between Xcode builds and xless builds
- [Asset and storyboard tools by Xcode version](research/xcode-tools-by-version.md)
- [ibtool's invocation](research/ib-invocation.md) and [the NIB encoding](research/nib-encoding.md)
- [The React Native iOS contract](research/react-native-ios-contract.md) and [the Tauri iOS contract](research/tauri-ios-contract.md)

## Acceptance records

What each milestone checked, and how: [m2a](acceptance-m2a.md), [m2b](acceptance-m2b.md), [m2c](acceptance-m2c.md),
[m3](acceptance-m3.md), [m4](acceptance-m4.md), [m5](acceptance-m5.md) (releases, and setup from a `.xip` on a fresh Linux VM),
[m6](acceptance-m6.md) (plain Cargo apps: a checklist for the maintainer, not yet run).
