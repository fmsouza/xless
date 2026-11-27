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
- `python3 -I scripts/check-doc-links.py --index docs/README.md README.md CONTRIBUTING.md docs/*.md docs/research/*.md` checks the
  documentation's relative links, and that every page is reached from docs/README.md (`Tests/shell/check-doc-links.test.sh` runs it too).

All the Docker commands below use the active Docker context. To use a separate engine (for example a dedicated Colima
VM), set `DOCKER_CONTEXT`. Nothing in the repository hardcodes a context, except that `xless run --docker` and
`scripts/sim-launch.sh` prefer a context named `colima-xless` when one exists.

## Windows

The account commands build and run on Windows, x64 ([what is there](native-install.md#windows), [what holds](security.md#windows)). There is no
build there, so most of the package is left out.

- The end of `Package.swift` makes the Windows package of the same manifest: which targets, and which of their files are left out
  (`notOnWindows`). `Tests/windows/sources.txt` says it of every file, and `WindowsSourcesTests` (on every system) fails for a file that
  is in neither list: decide for a new file whether Windows can have it. A command that Windows does not have is in
  `Sources/xless/CommandsNotHere.swift`, with what it says instead.
- `swift build --build-tests -Xmanifest -DXLESS_WINDOWS_TARGETS --scratch-path .build/windows-targets` builds the same targets and files on
  a Mac or on Linux: what it cannot compile, Windows cannot either. It says nothing about the `#if os(Windows)` code.
- The toolchain is `versions.env`'s (`SWIFT_WINDOWS_*`), installed by `scripts/windows-toolchain.ps1` once its SHA-256 and its Authenticode
  signer are the pinned ones. With a new `SWIFT_VERSION`, take the SHA-256 from winget's manifest of that version
  (microsoft/winget-pkgs, `manifests/s/Swift/Toolchain/`), and the signer from the installer itself. Always `--build-system native`, on
  `windows-2022`: the C++ headers of `windows-2025`'s Visual Studio refuse that Swift's clang. arm64 has no package of its own: 6.4's
  optimiser miscompiles async code there, and the x64 one runs under emulation.
- What asks Windows for something is C, in `Sources/CXlessWindows`, for Windows 10 1809 and later. Requests go through WinHTTP, not URLSession:
  its uploads stall once they exceed about 64 KB there (swift-corelibs-foundation #5532).
- Nothing starts a program there: `scripts/windows-package.py` refuses an `xless.exe` that imports what could.
- `Tests/windows/*.ps1` are the tests that need a machine to throw away: they set who writes crash dumps, trust an authority, install xless and
  make a secret store, all for the user who runs them. Only CI runs them.

### The Windows zip

`xless-<version>-windows-x86_64.zip`: `bin\xless.exe` with the DLLs of the Swift runtime that it needs, `LICENSE` and
`share\xless\{VERSION,licenses\}`. `package-release.sh --os windows` makes it (in Git Bash, with Python) and `scripts/windows-package.py` checks
it, there and again on every system that handles it: the names, no links, the licences by sha256, each program's and library's imports (the
zip's own, or a list of what every Windows has in System32, or the Visual C++ runtime), its architecture and its ASLR and NX flags, and that
`xless.exe` can start no program.

- **No library from anywhere else:** Windows' load flags are those of the program or library that has them, and say nothing of what that one
  needs in turn. So each has them (0xA00, `xless.exe`'s directory and System32): `xless.exe` from the linker (`/DEPENDENTLOADFLAG`), the
  runtime's DLLs, which the toolchain has without, from `windows-package.py harden`, which sets that one field of their load configuration
  (they are not signed; one that is is refused). `licenses/windows-swift-runtime-CHANGES.txt` is the notice of it that the zip has.
  Microsoft's runtime has none and needs `vcruntime140_1.dll` too, so `xless.exe` needs it itself, first. `Tests/windows/installed.test.ps1`
  takes libraries away and puts others in the current directory and on `PATH`.
- **Nothing of Microsoft's is in it:** not the Visual C++ runtime (`vcruntime140*.dll`, `msvcp140.dll`: a person installs it, and `install.ps1`
  refuses without), not the UCRT (Windows' own), nothing of the SDK, no `.lib`, no `.pdb` (`-debug-info-format none`).
- **The Swift runtime is dynamic:** the static one crashes there (swift #94100, #91442, #91520).
- **Not signed:** there is no certificate in CI. `SHA256SUMS`, which `install.ps1` always checks, and the attestation vouch for it.
- `scripts/install.ps1` is for Windows PowerShell 5.1 and PowerShell 7, plain ASCII, and one function called by its last line, so that a
  download that was cut runs nothing. `Tests/windows/install.test.ps1` is its test.
- **No winget or Scoop manifest** yet: both need a published URL and its hash, and winget a maintainer's account.

## Building the images on the Mac

`xless setup --docker` builds the image of a release and prepares the Xcode packs ([images.md](images.md)). On the Mac,
from a checkout:

```sh
make images                                          # ARCHS=arm64 for one architecture; no Xcode
make kits                                            # KITS=tauri,react-native, the Dockerfiles of the checkout
XLESS_SHARE="$PWD" swift run xless setup --docker --xcode ~/Downloads/Xcode_26.2_Universal.xip   # the pack, by this checkout's recipe
```

`make images` (`scripts/build-images.sh`) builds `xless:<commit>[-dirty]-<arch>` with an `xless` compiled from the
checkout, by `scripts/docker-images.sh`, the same recipe `xless setup` uses. It takes no Xcode: an Xcode is a pack.
`make kits` builds the kits by `xless setup --docker --with`, so a kit of the checkout has the labels a run looks for.
With `XLESS_SHARE` naming the checkout, `xless setup --docker` prepares packs with the checkout's files, in the image of
the checkout, and their recipe hashes are the checkout's ([below](#xcode-packs)).

`make sdk-export` is the SDK export alone (`xless sdk export`: `xtool sdk build` in the xless image, with the Xcode
mounted read-only, into `dist/sdk/`, git-ignored); `xless setup --docker --sdk dist/sdk` prepares a pack from it.

Every download of the image (Swift's static Linux SDK, xtool, rcodesign, the Swift toolchains' pins, Swift Build's
sources) is sha256-pinned in `versions.env`; those of the kits (Node, rustup, Ruby, Bundler, Hermes) in
`docker/tauri/Dockerfile` and `docker/react-native/Dockerfile`, which are complete by themselves so that a person can
start from a copy. The image fetches no Swift toolchain of an Xcode and compiles no Swift Build: that happens when a
pack is prepared.

The Docker VM must be able to see the Xcode that `make sdk-export` exports. Colima: `colima start --mount /Applications:r
--mount $HOME:w`. Docker Desktop does not share `/Applications`; make an APFS clone under your home directory (cheap,
copy-on-write) and point `XCODE` at it:

```sh
mkdir -p ~/.cache/xless && cp -cR /Applications/Xcode.app ~/.cache/xless/Xcode.app
make sdk-export XCODE=$HOME/.cache/xless/Xcode.app
```

(`xless setup --docker --xcode <.xip>` needs none of that for a `.xip` under your home directory, which the VM sees.)

The amd64 images and packs build and run on an arm64 Mac only with Rosetta in the Docker VM: check that
`/proc/sys/fs/binfmt_misc/rosetta` is registered in the VM. Under QEMU's user-mode emulation gcc and Swift crash at
random. Milestone 4 verified amd64 this way, not yet on a native x86_64 host ([acceptance-m4.md](acceptance-m4.md)).

## Xcode packs

A pack's `pack.json` holds a **recipe hash** for each part, which `PackRecipe` computes from the share directory and
`versions.env` and nothing else (not xless's version):

| Part | Made from (the hash's inputs) |
|---|---|
| `sdk` | `scripts/fit-toolchain.sh`; `docker/toolchain/clang-driver`, `target-os-check`, `record-flags.py`, `target-os/derived.txt` and `target-os/<build>.txt`; the Swift toolchain's URL and sha256 for the architecture; whether that toolchain is the image's own Swift; every `versions.env` entry ending in `_<build>`; `XTOOL_VERSION`; the Xcode build |
| `swift-build` | `SWB_TAG` and every `SWB_*` pin; the toolchain's sha256; the distribution of `SWIFT_IMAGE` (`jammy`); `scripts/pack-swift-build.sh` |

Both start with `PackRecipe.format`, the pack format number. A pack whose hash is not the one this xless computes is
stale: a run prepares the part again from the SDK export, or stops (exit 2) and names `xless setup`. So:

- **A change to `scripts/fit-toolchain.sh`, `scripts/pack-swift-build.sh`, anything under `docker/toolchain/`, or a pin
  among those inputs makes the packs stale, by design**: every machine prepares that part again once, about a minute and
  a half for `sdk` and four minutes for `swift-build`. Change them when the packs must change, and say so in the commit.
  A comment counts: it changes the file's bytes.
- **Raise `PackRecipe.format`** when the Swift code that prepares a pack (`PackPlan`, `PackStore`, the setup) changes what
  it produces, the layout or a file's content, without a change to any of those files. Then every pack is prepared
  again. Nothing finds such a change for you: the files above are hashed, the Swift code is not.
- A change to `docker/Dockerfile`, the kits or the rest of xless prepares nothing again.

`make test-image` checks the xless image of this checkout and its kits (`Tests/shell/image-contents.test.sh`): no file,
label or build argument of an Xcode in any layer, and what each must hold. Then it uses the `tauri` kit's image directly
with a pack volume read-only (`Tests/shell/image-direct.test.sh`): an overlay builds from the pack, nothing can write
the pack, and without a pack a build exits 2. It needs the image, the `tauri` kit and a pack volume of the pinned Xcode
(`XLESS_XCODE_PIN`, else `versions.env`'s `XCODE_VERSION`), and fails when one is missing; `ARCHS="arm64 amd64"` checks
each.

## Parity tests

They compare what xless builds with what Xcode builds from the same sources.

| Command | Where | What it checks |
|---|---|---|
| `make test-rn-linux` | Docker | `samples/HelloRN` through `finalize` in the React Native kit, against the Mac reference in `samples/HelloRN/reference/` ([react-native.md](react-native.md#linux-parity-test)) |
| `make test-tauri-linux` | Docker | `samples/HelloTauri`, iOS (and `--platform macos`), against `samples/HelloTauri/reference/` ([tauri.md](tauri.md#linux-parity-test)) |
| `ARCH=amd64 make test-rn-linux` (`test-tauri-linux`) | Docker | The same in the amd64 images |
| `scripts/arch-compare.sh <app-a> <app-b>` | anywhere | An app built in the arm64 image against one built in the amd64 image: byte for byte outside the code signature |
| `scripts/pack-parity.sh <baseline dir> <candidate dir>` | anywhere | Products built with an Xcode baked into the image against the same built with the Xcode's pack: byte for byte outside the code signature, but for the paths the pack moved, each listed ([acceptance-xcode-packs.md](acceptance-xcode-packs.md)) |
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
   that release, space separated, so that `xless setup` recognises it). Add its row to [xcode-versions.md](xcode-versions.md#the-versions).
2. **The Swift toolchain** (Ruling R10): `XCODE_SWIFT_<B>`, the open-source Swift release with the same major.minor as
   Apple's and the highest patch not above it; for a release other than `SWIFT_VERSION`, its
   `SWIFT_TOOLCHAIN_<x_y_z>_*` download pins. `scripts/xcode-swift.sh <B>` checks the entry and prints what is missing.
3. **The `TARGET_OS_*` macros:** `scripts/target-os-macros.sh <Xcode.app> > docker/toolchain/target-os/<B>.txt`.
   Preparing a pack of that Xcode fails without this file, which is part of the pack's `sdk` recipe.
4. **The asset and storyboard tools profile:** `scripts/xcode-tools.sh <B>` prints the commands. With
   `DEVELOPER_DIR=<Xcode.app>/Contents/Developer`, run `scripts/assetkit-golden.sh`, `scripts/ib-golden.sh` and
   `scripts/copypng-golden.sh`, compare their outputs with the measured builds
   ([research/xcode-tools-by-version.md](research/xcode-tools-by-version.md)), and add the entry to
   `Sources/XlessCore/XcodeToolsProfile.swift`.
5. **The references and the tests:** the pack of that Xcode (`XLESS_SHARE="$PWD" swift run xless setup --docker --xcode
   <the .xip>`; no image is built for an Xcode), then `make rn-reference` and `make tauri-reference` with that Xcode,
   `make kits` when the kits are not there, `XLESS_XCODE_PIN=<version> make test-rn-linux` and `make test-tauri-linux`
   with its pack, and `xless setup --xcode <the .xip>` on Linux.

## Images on other machines

What may travel, and what never does:

| | Holds Apple's | May go to another machine | May go to a registry, a CI cache or an artifact |
|---|---|---|---|
| The xless image and its kits | nothing | yes | yes (xless has no command, make target or workflow that pushes one) |
| The SDK export (`~/.cache/xless/sdk/xcode<V>-<B>`) | the SDK | yes, to a machine of yours, as you may copy the Xcode it comes from | never |
| An Xcode pack (a `xless-xcode-…` volume, a store's directory) | the SDK | no: prepare it there | never |

On another machine (a CI runner, a build server), copy the SDK export of one you set up and prepare the pack there:

```sh
xless setup --docker --sdk <the copied directory>     # the image and the pack; without --docker the native install
```

A pack is not copied: it is prepared from the export in a few minutes, by that machine's xless, which then knows it
current.

- [examples/example-ios.yml](examples/example-ios.yml) and [examples/example-ios-image.yml](examples/example-ios-image.yml)
  are GitHub Actions workflows for such a runner of your own ([ci.md](ci.md#the-runner)). They live in `docs/`, so this
  repository never runs them.
- `scripts/check-private-registry.sh` says whether `registry.env` (from `registry.env.example`) names a registry that has
  been checked to be private, refuses Docker Hub (`docker.io`, `index.docker.io`, `registry-1.docker.io` in any case, and
  bare names such as `myuser`, which Docker takes for Docker Hub's), and pushes nothing. It is for whoever keeps images of
  an older xless, which held Apple's SDK, in a registry of their own.

## Releases

Releases are cut by `.github/workflows/release.yml`, at 03:00 UTC every night and by hand (`gh workflow run
release.yml`). It computes the next version from the Conventional Commit titles merged since the last `v*` tag
(`scripts/next-version.sh`; the rules are in [CONTRIBUTING.md](../CONTRIBUTING.md#versions-and-releases)). With no
releasable commit it does nothing. Otherwise it builds the four tarballs, `xless-<version>-<linux|macos>-<x86_64|arm64>`, and
[the Windows zip](#the-windows-zip)
from that commit (`.github/actions/build-package`: `scripts/stamp-version.sh`, a static musl build,
[a macOS one](#the-macos-tarballs) or a Windows one, `scripts/package-release.sh`), then installs them on all systems and architectures
before publishing anything (the `verify` jobs: `scripts/release-assets.sh` refuses unless all five are there and
`scripts/check-package.sh` accepts each, writes `SHA256SUMS` and copies `install.sh` and `install.ps1`,
and `scripts/verify-release.sh`, on Windows `verify-release.ps1`, lays them out like a GitHub release, installs with that installer from
`file://`, pinned and as the latest, and checks that `xless --version` and `share/xless/VERSION` are the new version). Only then
does it attest the build provenance of the packages, `SHA256SUMS` and both installers (`actions/attest-build-provenance`,
signed through GitHub's OIDC token with Sigstore and stored on GitHub; only the `publish` job gets `id-token: write` and
`attestations: write`), tag `v<version>` and publish a GitHub release with those assets and notes from
`scripts/release-notes.sh`. `gh attestation verify <asset> -R fmsouza/xless` checks one
([README](../README.md#install)). What is verified and published is what the build jobs made: an artifact is the whole run's, and any job may
replace it, so each build job gives its package's sha256 as an output of the job, and the `verify` and `publish` jobs download the five
packages by name and refuse one with another sum (`scripts/package-sums.sh`, `.github/actions/release-packages`). The two legs of one
matrix share their outputs, so between those two the sums decide nothing. The source tree stays at version `0.0.0-dev`; only the release build stamps one.

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
