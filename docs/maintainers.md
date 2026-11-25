# Maintainers

This page is for people who work on xless itself: the Mac tools that measure Xcode and compare xless's output with
it, the parity tests, images on other machines, and releases. Users never need any of it. How to propose a change is in
[CONTRIBUTING.md](../CONTRIBUTING.md).

The scripts named here run from a source checkout. Those that run Apple's programs are listed in
[apple-requirements.md](apple-requirements.md#maintainers-only-on-a-mac); none of them is part of the user path.

## Tests

- `swift test` runs the unit tests on the Mac (from a shell whose session leader lives, such as a terminal's; elsewhere
  `scripts/ci-session.sh swift test`, or the agent's tests fail); `make test-linux` runs them in Linux (versions.env's `SWIFT_IMAGE`: the
  `swift:<SWIFT_VERSION>-jammy` image, pinned by digest). `swift test --package-path ThirdParty/AssetKit` runs AssetKit's.
- `bash Tests/shell/<name>.test.sh` runs one shell test; CI runs them all, on Linux and (but those with a `SKIP` guard
  for it) on macOS, there with the system's bash 3.2, sed, stat and tar.
- `python3 -I scripts/check-doc-links.py README.md CONTRIBUTING.md docs/*.md` checks the documentation's relative
  links (`Tests/shell/check-doc-links.test.sh` runs it too).

All the Docker commands below use the active Docker context. To use a separate engine (for example a dedicated Colima
VM), set `DOCKER_CONTEXT`. Nothing in the repository hardcodes a context, except that `xless run --docker` and
`scripts/sim-launch.sh` prefer a context named `colima-xless` when one exists.

## Windows

Part of xless is built and tested on Windows, by `windows-tests (x86_64)`: the libraries of the account commands (XlessCore, XlessASC,
XlessAppleID, XlessFIDO, XlessSign, XlessStore, XlessVault). There is no `xless` for Windows.

- The end of `Package.swift` makes the Windows package of the same manifest: which targets, and which of their files are left out
  (`notOnWindows`). `Tests/windows/sources.txt` says it of every file, and `WindowsSourcesTests` (on every system) fails for a file that
  is in neither list: decide for a new file whether Windows can have it.
- `swift build --build-tests -Xmanifest -DXLESS_WINDOWS_TARGETS --scratch-path .build/windows-targets` builds the same targets and files on
  a Mac or on Linux: what it cannot compile, Windows cannot either. It says nothing about the `#if os(Windows)` code.
- The toolchain is `versions.env`'s (`SWIFT_WINDOWS_*`), installed by `scripts/windows-toolchain.ps1` once its SHA-256 and its Authenticode
  signer are the pinned ones. With a new `SWIFT_VERSION`, take the SHA-256 from winget's manifest of that version
  (microsoft/winget-pkgs, `manifests/s/Swift/Toolchain/`), and the signer from the installer itself. Always `--build-system native`.
- What asks Windows for something is C, in `Sources/CXlessWindows`, for Windows 10 1809 and later.

What holds on Windows, and what does not:

- The secret store is `%LOCALAPPDATA%\xless\vault` (the system's answer, not the variable's). Its directory and files are owned by the user
  of the process's token and let nobody else in; whatever else is found there (another owner, an access entry of anybody but the user, the
  system and the administrators, an inherited or missing access list, a link, a junction, a second name, a share, a removable drive, FAT) is
  refused, never repaired. The same for a key that xless writes. The system and the administrators are accepted when something else let
  them in, and never let in by xless: they are root's counterparts.
- The store is replaced in one step and flushed before; Windows has no way to flush a directory, so after a power cut the old store may
  be back. A backup, a shadow copy or a search index may have what is in a file that was written in clear, as on any system.
- A process that read a secret shows no error dialog, has no heap in an error report, and ends at a fault before Windows' error reporting
  sees it; a process for which the first two cannot be had reads none. Best effort beyond that: its own access list denies other processes of
  the user to open its memory, and no DLL is loaded from a share, an extension point or a file of low integrity.
- That is less than on Linux. An administrator can read any process. A program of the same user that opened the process before it read
  a secret, or that started it under a debugger, keeps what it has. `__fastfail` (a corrupted stack or heap) goes to Windows' error reporting
  past the process's own handler: an administrator's `LocalDumps` setting then writes a dump.
- Nothing is kept unlocked, there are no credential helpers, no security keys and no `secrets materialize`.

## Building the images on the Mac

`xless setup --docker` builds the image of a release ([images.md](images.md)). On the Mac, from a checkout:

```sh
make images XCODE=/Applications/Xcode.app            # or XCODE=<Xcode_*.xip>, ARCHS=arm64 for one architecture
make kits                                            # KITS=tauri,react-native, the Dockerfiles of the checkout
```

`make images` (`scripts/build-images.sh`) builds `xless:local-<arch>-xcode<version>` from one Xcode and keeps the SDK
export in `dist/sdk-xcode<version>/` (git-ignored). A `.xip` is expanded once with Apple's `xip --expand` into
`~/.cache/xless/xcode/<name>/`. Unlike `xless setup`, the image gets an `xless` compiled from the checkout.

`make sdk-export` is the export alone (`xless sdk export`: `xtool sdk build` in `xless:local-<arch>-setup`, with Xcode
mounted read-only, into `dist/sdk/`). The images are built by `scripts/docker-images.sh`, the same recipe `xless setup`
uses, and the kits by `xless setup --docker --with`, so a kit of the checkout has the labels a run looks for. Every
download of the image (the static Swift SDK, xtool, rcodesign, Swift Build) is sha256-pinned in `versions.env`; those of
the kits (Node, rustup, Ruby, Bundler, Hermes) in `docker/tauri/Dockerfile` and `docker/react-native/Dockerfile`, which
are complete by themselves so that a person can start from a copy.

The Docker VM must be able to see Xcode. Colima: `colima start --mount /Applications:r --mount $HOME:w`. Docker
Desktop does not share `/Applications`; make an APFS clone under your home directory (cheap, copy-on-write) and point
`XCODE` at it:

```sh
mkdir -p ~/.cache/xless && cp -cR /Applications/Xcode.app ~/.cache/xless/Xcode.app
make images XCODE=$HOME/.cache/xless/Xcode.app
```

The amd64 images build and run on an arm64 Mac only with Rosetta in the Docker VM: check that
`/proc/sys/fs/binfmt_misc/rosetta` is registered in the VM. Under QEMU's user-mode emulation gcc and Swift crash at
random. Milestone 4 verified amd64 this way, not yet on a native x86_64 host ([acceptance-m4.md](acceptance-m4.md)).

## Parity tests

They compare what xless builds with what Xcode builds from the same sources.

| Command | Where | What it checks |
|---|---|---|
| `make test-rn-linux` | Docker | `samples/HelloRN` through `finalize` in the React Native kit, against the Mac reference in `samples/HelloRN/reference/` ([react-native.md](react-native.md#linux-parity-test)) |
| `make test-tauri-linux` | Docker | `samples/HelloTauri`, iOS (and `--platform macos`), against `samples/HelloTauri/reference/` ([tauri.md](tauri.md#linux-parity-test)) |
| `ARCH=amd64 make test-rn-linux` (`test-tauri-linux`) | Docker | The same in the amd64 images |
| `scripts/arch-compare.sh <app-a> <app-b>` | anywhere | An app built in the arm64 image against one built in the amd64 image: byte for byte outside the code signature |
| `make parity` | Mac | HelloShip built by Xcode against the xless build: Info.plist keys, `LC_BUILD_VERSION`, files, `Assets.car` ([research/parity-known-gaps.md](research/parity-known-gaps.md)) |
| `make ib-parity` | Mac | The storyboard compiler: golden drift, and a simulator screenshot of a launch screen compiled both ways |
| `make rn-reference`, `make tauri-reference APP=… OUT=…` | Mac | Record the references the Linux tests compare with |
| `make sim-launch APP=…` | Mac | Install and launch a simulator build ([react-native.md](react-native.md#simulator-builds)) |

## Measuring a new Xcode

xless accepts only the Xcode releases it has measured. Adding one takes, on a Mac with that Xcode, all black-box:

1. **The supported-Xcode table** in `versions.env`, keyed by the Xcode build `<B>`: add `<B>` to `XCODE_RELEASES`,
   and set `XCODE_SHORT_<B>` (the marketing version), `XCODE_APPLE_SWIFT_<B>` (what the Xcode's default toolchain's
   `swift --version` reports), `XCODE_BUILD_MACHINE_OS_<B>` (the `BuildMachineOSBuild` that Xcode stamps into the
   apps it builds, from a reference build) and `XCODE_XIP_SHA256_<B>` (the `shasum -a 256` of each `.xip` download of
   that release, space separated, so that `xless setup` recognises it).
2. **The Swift toolchain** (Ruling R10): `XCODE_SWIFT_<B>`, the open-source Swift release with the same major.minor as
   Apple's and the highest patch not above it; for a release other than `SWIFT_VERSION`, its
   `SWIFT_TOOLCHAIN_<x_y_z>_*` download pins. `scripts/xcode-swift.sh <B>` checks the entry and prints what is missing.
3. **The `TARGET_OS_*` macros:** `scripts/target-os-macros.sh <Xcode.app> > docker/toolchain/target-os/<B>.txt`. The
   image build fails without this file.
4. **The asset and storyboard tools profile:** `scripts/xcode-tools.sh <B>` prints the commands. With
   `DEVELOPER_DIR=<Xcode.app>/Contents/Developer`, run `scripts/assetkit-golden.sh`, `scripts/ib-golden.sh` and
   `scripts/copypng-golden.sh`, compare their outputs with the measured builds
   ([research/xcode-tools-by-version.md](research/xcode-tools-by-version.md)), and add the entry to
   `Sources/XlessCore/XcodeToolsProfile.swift`.
5. **The references and the tests:** `make images XCODE=…`, then `make rn-reference` and `make tauri-reference` with
   that Xcode, `make kits`, `make test-rn-linux` and `make test-tauri-linux` in its images, and `xless setup --xcode <the .xip>` on
   Linux.

## Images on other machines

Images hold Apple's SDK, so they stay on the machine that built them: xless has no command, make target or workflow that
pushes one, and none is ever pushed by hand either, also not to a registry that is private today. On another machine (a CI
runner, a build server), copy the SDK export of one you set up (`~/.cache/xless/sdk/xcode<V>-<B>`, as you may copy the Xcode
it comes from) and build the image there:

```sh
xless setup --docker --sdk <the copied directory>     # the image; without --docker the native install
```

- [examples/example-ios.yml](examples/example-ios.yml) is a GitHub Actions workflow for such a runner of your own
  ([signing-and-testflight.md](signing-and-testflight.md#continuous-integration)). It lives in `docs/`, so this repository
  never runs it.
- `scripts/check-private-registry.sh` is for whoever already keeps such images in a registry of their own, from before: it says
  whether `registry.env` (from `registry.env.example`) names one that has been checked to be private, refuses Docker Hub
  (`docker.io`, `index.docker.io`, `registry-1.docker.io` in any case, and bare names such as `myuser`, which Docker takes for
  Docker Hub's), and pushes nothing.

## Releases

Releases are cut by `.github/workflows/release.yml`, at 03:00 UTC every night and by hand (`gh workflow run
release.yml`). It computes the next version from the Conventional Commit titles merged since the last `v*` tag
(`scripts/next-version.sh`; the rules are in [CONTRIBUTING.md](../CONTRIBUTING.md#versions-and-releases)). With no
releasable commit it does nothing. Otherwise it builds the four tarballs, `xless-<version>-<linux|macos>-<x86_64|arm64>`,
from that commit (`.github/actions/build-package`: `scripts/stamp-version.sh`, a static musl build or
[a macOS one](#the-macos-tarballs), `scripts/package-release.sh`), then installs them on both systems and architectures
before publishing anything (the `verify` job: `scripts/release-assets.sh` refuses unless all four are there and
`scripts/check-package.sh` accepts each, writes `SHA256SUMS` and copies `install.sh`,
and `scripts/verify-release.sh` lays them out like a GitHub release, installs with that `install.sh` from `file://`,
pinned and as the latest, and checks that `xless --version` and `share/xless/VERSION` are the new version). Only then
does it attest the build provenance of the tarballs, `SHA256SUMS` and `install.sh` (`actions/attest-build-provenance`,
signed through GitHub's OIDC token with Sigstore and stored on GitHub; only the `publish` job gets `id-token: write` and
`attestations: write`), tag `v<version>` and publish a GitHub release with those assets and notes from
`scripts/release-notes.sh`. `gh attestation verify <asset> -R fmsouza/xless` checks one
([README](../README.md#install)). The source tree stays at version `0.0.0-dev`; only the release build stamps one.

### The macOS tarballs

Built on GitHub's `xcode-27` runner (arm64, macOS 27; the only label with the Swift 6.4 that `Package.swift` and Linux
use, and named in `.github/actionlint.yaml` because actionlint does not know it), the x86_64 one with `swift build --arch
x86_64`. They are for macOS 14.0 and later and run in CI on macOS 15 (arm64 and Intel) and 27 (arm64); GitHub offers no
macOS 14 runner any more. `swift test` runs on arm64 only, since no Intel runner has that Swift: there the installed
program is run, with the shell tests of the agent and the prompts.

- **Each is signed ad hoc**, by `package-release.sh` (`codesign --sign -`, with the hardened runtime and `restrict`), whatever the
  linker did: the agent tells xless by its signature, and for x86_64 the linker makes none by itself. `check-macos-binary.sh`
  refuses a program without it, when it is packaged and again when it was installed. A build from source has the linker's
  (`-adhoc_codesign` in `Package.swift`); the `package` jobs check that too, for both architectures.
- **Nothing of Apple's is in them.** The Swift runtime and everything else is the system's. The build passes
  `-runtime-compatibility-version none`, so the compiler adds none of its `libswiftCompatibility*` archives, which only
  systems before macOS 14 need. `package-release.sh` runs the checks, and makes no package when one fails:
  - `scripts/check-link-map.sh` reads the linker's map (`-Xlinker -map`, `XLESS_LINK_MAP`): every object must be one that the build
    compiled, the system's libraries are there by name only (`.tbd`), and no archive, library file or object of the toolchain
    or of a package is. It lists what may be in a map, with the reason. It takes the paths and the symbols of the build
    directory as they are: it keeps out what the toolchain adds, not somebody who can write there.
  - `scripts/check-macos-binary.sh` refuses a binary that needs a library outside `/usr/lib` and `/System/Library`, has a run
    path of its own (`package-release.sh` takes out the Xcode's), is for another macOS or architecture, or has the section of
    a compatibility archive. The release's `verify` jobs run it again on the installed program.
  - `scripts/check-package.sh` compares the tarball with the checkout, on every system that handles it: the names, the owner, the
    modes, no extended attributes; every file but `bin/xless`, `VERSION`, the `XLESS_VERSION` line and the packages' own licences
    byte for byte or by sha256; those licences by name and as text; and `bin/xless` as a program of that system and architecture.

  Nothing of the build is cached or uploaded but the tarball.
- **Signed ad hoc**, with the hardened runtime and `restrict`, by `package-release.sh`. There is no Developer ID in CI and
  the program is not notarized: it needs no secret, and needs none of the two, because `curl` and `tar` set no quarantine
  mark, so Gatekeeper never asks. It names nobody: what vouches for a download are `SHA256SUMS`, which `install.sh` always
  checks, and the attestation ([what the flags protect](security.md#linux-and-macos)).
- **Reproducible as far as the Linux ones are:** sorted names, fixed owner and modes, no AppleDouble files; the binary is
  what that Xcode's compiler makes.
- **No Homebrew formula:** a tap is another repository, with a token here to write to it. `install.sh` is the installer;
  a tap would be a follow-up.

**The first release.** While there is no `v*` tag the nightly releases nothing. The first one is cut by hand, once:

```sh
gh workflow run release.yml --ref main -f first_version=0.1.0
```

### The nightly may be switched off

GitHub disables the scheduled workflows of a public repository after 60 days without activity in it, and the nightly
would then stop without a word: whatever is merged after a quiet spell would never be released. Two things cover it:

- `.github/workflows/nightly-state.yml` runs on every push to `main` (`scripts/nightly-state.sh`). When GitHub has
  disabled `release.yml` for inactivity (state `disabled_inactivity`), it enables it again and leaves a warning on the
  run; the next nightly then releases what was merged. A `release.yml` disabled by hand (`disabled_manually`) is left
  alone, with a warning.
- To check or fix it yourself:

  ```sh
  gh api 'repos/fmsouza/xless/actions/workflows/release.yml' --jq .state    # active when the nightly runs
  gh workflow enable release.yml
  gh workflow run release.yml --ref main                                    # release now instead of tonight
  ```

## Repository settings

`scripts/github-settings.sh [owner/repo]` applies the settings the workflow relies on, with `gh api` (it needs a token
with admin rights on the repository; CI never runs it): squash merges only, with the PR title and body as the commit;
merged branches deleted; and a ruleset on `main` that requires a pull request, the six checks (`title`,
`linux-tests (x86_64)`, `linux-tests (arm64)`, `package (x86_64)`, `package (arm64)`, `shellcheck`), and blocks force
pushes and deletion. It is idempotent: run it again after changing a required check. The five macOS checks of
[CONTRIBUTING.md](../CONTRIBUTING.md#checks-on-every-pull-request) are not in it: add them once they have run for a while.

It also applies a **`release tags`** ruleset on `refs/tags/v*`, the tags `scripts/next-version.sh` counts from: nobody
can move (update or force-push) or delete one. Creating one can't be restricted: the release workflow creates each tag
with its `GITHUB_TOKEN`, and in a repository owned by a personal account a ruleset cannot let GitHub Actions bypass a
rule. Instead, the release's `plan` job runs `scripts/release-tag-check.sh` on the latest `v*` tag and refuses to
release when that tag has no GitHub release, i.e. when it was pushed by hand. To remove such a tag, disable the ruleset
(Settings → Rules → Rulesets, or `gh api -X PUT repos/fmsouza/xless/rulesets/<id> -f enforcement=disabled`), run
`git push origin :refs/tags/<tag>`, and enable it again.

## Private notes

The maintainer's design notes and acceptance logs (`docs/superpowers/`, `docs/acceptance/`) are git-ignored and stay on
the maintainer's machine. Public acceptance records are the `docs/acceptance-m*.md` files.
