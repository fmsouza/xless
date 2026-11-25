# xless documentation

Start with the [README](../README.md): what xless is, what you need, the install line, `xless setup`, and a first
build. The pages below go further.

## Using xless

- [pipeline.md](pipeline.md): how a build runs, the images, the stages (`build` → `assets` → `finalize` → `sign` →
  `package` → `upload`) and their exit codes.
- [xless-yml.md](xless-yml.md): the `xless.yml` reference, for Swift package apps.
- [signing-and-testflight.md](signing-and-testflight.md): secrets, build numbers, `xless run` up to TestFlight, the
  notarized DMG, and running in CI.
- [account.md](account.md): your Apple account from the terminal, by task: the first app from zero with
  `xless provision`, adding a device, rotating a certificate, inviting a tester, releasing.
- [secrets.md](secrets.md): `xless secrets`, the encrypted store for Apple keys on your own machine, how the
  pipeline reads it, and typing its passphrase once: keeping it unlocked (`xless unlock`, `xless lock`), one unlock for a
  script (`xless session`).
- [security.md](security.md): the threat model and what xless guarantees: the secret store's format, what
  `xless unlock` and `--keep` hold and who may use it, process hardening, what goes to which Apple host, the web-session commands, and how to wipe everything.
- [apple-account.md](apple-account.md): the reference of every Apple account command (`xless auth`, `team`,
  `devices`, `bundle-ids`, `merchant-ids`, `certs`, `profiles`, `app-groups`, `icloud-containers`, `keys`, `apps`,
  `store`, `builds`, `users`, `testflight`, `release`, `provision`, `api`, and the shared `--team`, `--json`, `--yes`,
  `--verbose`, `--no-input`), the Apple ID web session, their JSON output, rate limits and `[account]` errors (exit
  code 20).
- [appstore-manifest.md](appstore-manifest.md): the App Store listing as an `appstore/` directory, `xless store pull`,
  `xless store validate` and `xless store push`.
- [bootstrap.md](bootstrap.md): the one-time Apple setup from the terminal (API key, `xless provision`, or bundle ID,
  certificates and app record one at a time), and the same in a browser.
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
- [What the App Store Connect API covers](research/asc-account-coverage.md), and the web endpoints xless uses for the rest
- [The Mac App Store `.pkg` from Linux](research/mas-pkg.md)
- [Parity known gaps](research/parity-known-gaps.md) between Xcode builds and xless builds
- [Asset and storyboard tools by Xcode version](research/xcode-tools-by-version.md)
- [ibtool's invocation](research/ib-invocation.md) and [the NIB encoding](research/nib-encoding.md)
- [The React Native iOS contract](research/react-native-ios-contract.md) and [the Tauri iOS contract](research/tauri-ios-contract.md)
- [What M7 has not verified against a real Apple account](research/m7-live-checklist.md), and where #105 checks it

## Acceptance records

What each milestone checked, and how: [m2a](acceptance-m2a.md), [m2b](acceptance-m2b.md), [m2c](acceptance-m2c.md),
[m3](acceptance-m3.md), [m4](acceptance-m4.md), [m5](acceptance-m5.md) (releases, and setup from a `.xip` on a fresh Linux VM),
[m6](acceptance-m6.md) (plain Cargo apps: a checklist for the maintainer, not yet run),
[m7](acceptance-m7.md) (an Apple account from the terminal: a guided, recorded run of `scripts/acceptance-m7.sh`, up to
the App Review submission).
