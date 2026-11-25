# xless documentation

The [README](../README.md) says what xless is and how to install it. These are the pages by task.

## Get started

- [get-started.md](get-started.md): five paths, each to the end: nothing yet, an app on App Store Connect, only building, only the
  account, CI.
- [install.md](install.md): upgrades, versions, checking a download.
- [systems.md](systems.md): what works on Linux, macOS, Windows and WSL 2, what does not, and what is planned.
- [troubleshooting.md](troubleshooting.md): install, setup, build and App Store Connect errors, and known gaps.
- [uninstall.md](uninstall.md): `xless clean`, freeing disk space after an upgrade, and uninstalling.

## Set up the account and the app

- [account.md](account.md): what you need first, and by task: a device, a certificate, push keys, cleaning up.
- [bootstrap.md](bootstrap.md): the setup one step at a time instead of `xless provision`, and the same in a browser.

## The listing and the App Store

- [appstore-manifest.md](appstore-manifest.md): the App Store listing as an `appstore/` directory, `xless store pull`,
  `xless store validate` and `xless store push`.
- [testflight.md](testflight.md): invite internal and external testers.
- [release.md](release.md): the submission to App Review, and the release.

## Build

- [build.md](build.md): build an app on a Mac, on Linux, in Docker and in WSL 2.
- [xcode-versions.md](xcode-versions.md): the supported Xcode versions, and how to download one;
  [xcode-download.md](xcode-download.md): `xless xcode download`, and what happens to your Apple ID and password.
- [react-native.md](react-native.md): React Native / Expo iOS apps, with app extensions and simulator builds.
- [tauri.md](tauri.md): Tauri v2 apps, for iOS and macOS.
- [cargo.md](cargo.md): plain Cargo apps (a Rust binary with its own event loop), for iOS and macOS.
- [native-install.md](native-install.md): without Docker: what goes where on Linux, what is used on a Mac, what there is on Windows.
- [images.md](images.md): the Docker image (`--docker`), the kits for Tauri, Cargo and React Native apps, an image of your own, and
  how to build it by hand.

## Sign and ship

- [signing-and-testflight.md](signing-and-testflight.md): secrets, build numbers, `xless run` up to TestFlight, the
  notarized DMG, the Mac App Store package, and what `sign` changes on the account.

## Automate and CI

- [automate.md](automate.md): runs without questions, exit codes, several apps, checking a configuration, pulling and pushing
  listings.
- [ci.md](ci.md): the secrets of a job, the flags, the runner; [examples/example-ios.yml](examples/example-ios.yml) is an example
  GitHub Actions workflow for an app repository.

## Security

- [security.md](security.md): the threat model and what xless guarantees: the secret store's format, what
  `xless unlock` and `--keep` hold and who may use it, process hardening, what goes to which Apple host, the web-session commands, and
  how to wipe everything.
- [secrets.md](secrets.md): `xless secrets`, the encrypted store for Apple keys on your own machine, how the
  pipeline reads it, and typing its passphrase once: keeping it unlocked (`xless unlock`, `xless lock`), one unlock for a
  script (`xless session`).
- [apple-requirements.md](apple-requirements.md): everything xless needs from Apple, and the audit behind that list.

## Reference

- [apple-account.md](apple-account.md): every Apple account command, the shared options, the Apple ID web session, their JSON output,
  rate limits and `[account]` errors (exit code 20).
- [xless-yml.md](xless-yml.md): the `xless.yml` of a Swift package app.
- The overlays: [Tauri](tauri.md), [Cargo](cargo.md), [React Native](react-native.md#overlay-reference).
- [pipeline.md](pipeline.md): how a build runs, the stages (`build` → `assets` → `finalize` → `sign` →
  `package` → `upload`) and their exit codes.

## Working on xless

- [CONTRIBUTING.md](../CONTRIBUTING.md): branches, Conventional Commit titles, the pull request checks, and how
  versions are computed.
- [maintainers.md](maintainers.md): the Mac tools, the parity tests, measuring a new Xcode, images on other machines, releases
  and the repository settings.

### Research notes

Measurements and decisions behind the code, in [research/](research/):

- [App Store Connect build uploads](research/asc-build-uploads.md) and [TestFlight delivery](research/asc-testflight.md)
- [What the App Store Connect API covers](research/asc-account-coverage.md), and the web endpoints xless uses for the rest
- [The Mac App Store `.pkg` from Linux](research/mas-pkg.md)
- [Parity known gaps](research/parity-known-gaps.md) between Xcode builds and xless builds
- [Asset and storyboard tools by Xcode version](research/xcode-tools-by-version.md)
- [ibtool's invocation](research/ib-invocation.md) and [the NIB encoding](research/nib-encoding.md)
- [The React Native iOS contract](research/react-native-ios-contract.md) and [the Tauri iOS contract](research/tauri-ios-contract.md)
- [What M7 has not verified against a real Apple account](research/m7-live-checklist.md), and where #105 checks it

### Acceptance records

What each milestone checked, and how: [m2a](acceptance-m2a.md), [m2b](acceptance-m2b.md), [m2c](acceptance-m2c.md),
[m3](acceptance-m3.md), [m4](acceptance-m4.md), [m5](acceptance-m5.md) (releases, and setup from a `.xip` on a fresh Linux VM),
[m6](acceptance-m6.md) (plain Cargo apps: a checklist for the maintainer, not yet run),
[m7](acceptance-m7.md) (an Apple account from the terminal: a guided, recorded run of `scripts/acceptance-m7.sh`, up to
the App Review submission).
