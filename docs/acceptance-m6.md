# Milestone 6 acceptance — plain Cargo apps

Scope: `type: cargo` overlays ([cargo.md](cargo.md)). Unlike the earlier records, this is a **checklist for the
maintainer** to run on their Linux box: it needs an Apple Developer account, a device and a Mac, which the builder of
the milestone did not have. The Linux tests that the builder could run are `swift test` and
`bash Tests/shell/testflight.test.sh` (overlay parsing and every refusal, plist templates, inputs and the secret-file
checks, the script's three steps in a dry run). Fill in the result column as you go.

Before you start: the images from `xless setup --docker` ([README](../README.md#build-in-docker-instead)), the one-time Apple setup
from [bootstrap.md](bootstrap.md) (API key, Apple Distribution key, Developer ID Application key), the secrets file
from [signing-and-testflight.md](signing-and-testflight.md#one-command-testflight), and a release of xless that
includes milestone 6 (the release follows the nightly run after the merge).

| # | Criterion | Result |
|---|---|---|
| 1 | `make test-cargo-linux` passes | |
| 2 | HelloCargo ships to TestFlight and installs on a device | |
| 3 | The HelloCargo DMG opens with no Gatekeeper warning | |
| 4 | LightCraft ships from its overlay to TestFlight and as a DMG, runs on the iPad and a Mac, and shows CJK text | |

## 1. `make test-cargo-linux`

**It has not yet been run anywhere.** No images were available while the milestone was built, so the script
`scripts/test-cargo-linux.sh`, which builds `samples/HelloCargo` for iOS and universal macOS through `finalize` and
checks the bundles ([cargo.md](cargo.md#linux-parity-test)), is untested. Expect to fix it before it passes.

- [ ] From an ordinary git checkout of xless, **not a `git worktree`** (`GIT_SHA` reads `git rev-parse HEAD` of the
  mounted source, and a worktree's `.git` file points outside the mount), with `samples/HelloCargo` committed (the work
  copy is the tracked files): `make test-cargo-linux`.
- [ ] Every `ok` line prints for iOS and macOS, there is no `FAIL` line and the exit code is 0.
- [ ] A second run is faster than the first (the `xless-rustup` and `xless-cargo` volumes and the work copy are reused).

## 2. HelloCargo on TestFlight

Use a bundle ID of your own and a test app record ([cargo.md](cargo.md#creating-the-app-store-connect-app-record)), so
that nothing is uploaded to a real app. Copy `samples/HelloCargo/xless.overlay.example.yml` out of the repository,
into its own folder, and set `bundleID`, `macos.bundleID`, `teamID`, `source` (the sample's directory, committed) and
`testflight.groups`.

- [ ] `xless docker --config <overlay>` runs the three steps and ends with the build `VALID` and delivered to the
  group. Nothing in step 2 (the build) had a secret.
- [ ] The build number is `1.0.0.<YYYYMMDDNN>`, above every build already in App Store Connect; a second run the same
  day is `…NN+1`.
- [ ] The build reaches the TestFlight group with no processing warning (export compliance and privacy manifest
  included).
- [ ] The app installs from TestFlight on an iPhone or iPad.
- [ ] On a device running **iOS 26 or earlier** it also opens and shows its window. On iOS 27 skip this check and note
  that you did: HelloCargo is built with the iOS 27 SDK (the images default to Xcode 27.0), and its winit 0.30 shell
  does not adopt the UIScene life cycle, so UIKit stops it at launch ([cargo.md](cargo.md#known-gaps)). Launching on
  iOS 27 is proven by item 4, whose shell adopts UIScene.

## 3. HelloCargo as a DMG

- [ ] `xless docker --config <overlay> --platform macos` (or `make dmg CONFIG=<overlay>`) ends with the path of
  `HelloCargo_1.0.0_universal.dmg`, after notarization is `Accepted` and the ticket is stapled.
- [ ] Copy the DMG to a Mac **through a download** (a browser or `curl`, so that it is quarantined), open it and drag
  the app to `/Applications`. Gatekeeper shows no warning, on first open of the DMG and of the app.
- [ ] `spctl --assess --type open --context context:primary-signature -v <dmg>` and
  `spctl --assess --type execute -v /Applications/HelloCargo.app` accept both as `Notarized Developer ID`;
  `lipo -archs` of the executable prints `x86_64 arm64`.
- [ ] The app opens on Apple Silicon (and on an Intel Mac, if you have one) and shows its window. Finder's Get Info
  shows the version `1.0.0` and the `GIT_SHA` of the sample's commit filled in (from `macos/Info.plist.in`).

## 4. LightCraft

LightCraft is the first real user and the acceptance app of this milestone. Its overlay is
`deploy/xless/lightcraft.overlay.yml` in its fork, written for the second plan (the Gitea deployment pipeline), and
it needs nothing in the app's code beyond that file. xless itself names nothing of LightCraft.

- [ ] `xless docker --config deploy/xless/lightcraft.overlay.yml` (iOS) delivers a build to TestFlight, from the
  overlay alone: no change to the application repository. The craft-fonts input (a pinned git revision) is cloned to
  `~/.cache/xless/inputs/` and `CRAFT_FONTS_DIR` reaches `build.rs`; the secrets never reach that build.
- [ ] `xless docker --config deploy/xless/lightcraft.overlay.yml --platform macos` produces a notarized, stapled DMG.
- [ ] The TestFlight build installs and runs on the iPad.
- [ ] The DMG installs and runs on a Mac with no Gatekeeper warning.
- [ ] **CJK text renders on both** (Chinese and Japanese strings, not empty boxes): the proof that the fonts reached
  the build. The licences of the embedded font families are in the macOS app's `Contents/Resources/Licenses/`.
- [ ] A merge to the fork's `main` runs the whole pipeline unattended, as designed in the second plan.

## Record

Fill this in when the checklist is done: the date, the machine (OS, architecture, Docker and image versions), the
Xcode used, the xless version, the four results above, and every failure with its fix. Then replace the "has not yet
been run" paragraph of item 1 with the actual run, and link the record from [README.md](README.md#acceptance-records).
