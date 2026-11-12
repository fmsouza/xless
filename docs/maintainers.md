# Maintainers

This page is for people who work on xless itself: the Mac tools that measure Xcode and compare xless's output with
it, the parity tests, private registries, and releases. Users never need any of it. How to propose a change is in
[CONTRIBUTING.md](../CONTRIBUTING.md).

The scripts named here run from a source checkout. Those that run Apple's programs are listed in
[apple-requirements.md](apple-requirements.md#maintainers-only-on-a-mac); none of them is part of the user path.

## Tests

- `swift test` runs the unit tests on the Mac; `make test-linux` runs them in Linux (versions.env's `SWIFT_IMAGE`: the
  `swift:<SWIFT_VERSION>-jammy` image, pinned by digest). `swift test --package-path ThirdParty/AssetKit` runs AssetKit's.
- `bash Tests/shell/<name>.test.sh` runs one shell test; CI runs them all.
- `python3 -I scripts/check-doc-links.py README.md CONTRIBUTING.md docs/*.md` checks the documentation's relative
  links (`Tests/shell/check-doc-links.test.sh` runs it too).

All the Docker commands below use the active Docker context. To use a separate engine (for example a dedicated Colima
VM), set `DOCKER_CONTEXT`. Nothing in the repository hardcodes a context, except that `scripts/testflight.sh` and
`scripts/sim-launch.sh` prefer a context named `colima-xless` when one exists.

## Building the images on the Mac

On Linux, `xless setup --docker` builds the images ([images.md](images.md)). On the Mac, from a checkout:

```sh
make images XCODE=/Applications/Xcode.app            # or XCODE=<Xcode_*.xip>, ARCHS=arm64 for one architecture
```

`make images` (`scripts/build-images.sh`) builds the whole chain (`xless-base`, `xless`, `xless-tauri`, `xless-rn`)
from one Xcode, tags it `:local-<arch>-xcode<version>-<build>` and `:local-<arch>-xcode<version>` (plus the plain
`:local-<arch>` tags for `versions.env`'s default Xcode), and keeps the SDK export in `dist/sdk-xcode<version>/`
(git-ignored). A `.xip` is expanded once with Apple's `xip --expand` into `~/.cache/xless/xcode/<name>/`. Unlike
`xless setup`, `xless-base` gets an `xless` compiled from the checkout.

The single targets: `make base-local` (`xless-base`), `make sdk-export` (`xless sdk export`: `xtool sdk build` inside
the per-arch base image with Xcode mounted read-only, into `dist/sdk/`), `make sdk-local`, `make tauri-local`,
`make rn-local`. They take `ARCHS`, `IMAGE_SUFFIX` and `SDK_DIR`; each image is built by `scripts/docker-images.sh`,
the same recipe `xless setup` uses. Every download (the static Swift SDK, xtool, rcodesign, Node, rustup, Ruby, Swift
Build, Hermes) is sha256-pinned in `versions.env`, the single place for versions.

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
| `make test-rn-linux` | Docker | `samples/HelloRN` through `finalize` in `xless-rn`, against the Mac reference in `samples/HelloRN/reference/` ([react-native.md](react-native.md#linux-parity-test)) |
| `make test-tauri-linux` | Docker | `samples/HelloTauri`, iOS (and `--platform macos`), against `samples/HelloTauri/reference/` ([tauri.md](tauri.md#linux-parity-test)) |
| `ARCH=amd64 make test-rn-linux` (`test-tauri-linux`) | Docker | The same in the amd64 images |
| `scripts/arch-compare.sh <app-a> <app-b>` | anywhere | An app built in the arm64 chain against one built in the amd64 chain: byte for byte outside the code signature |
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
   `sdk` image build fails without this file.
4. **The asset and storyboard tools profile:** `scripts/xcode-tools.sh <B>` prints the commands. With
   `DEVELOPER_DIR=<Xcode.app>/Contents/Developer`, run `scripts/assetkit-golden.sh`, `scripts/ib-golden.sh` and
   `scripts/copypng-golden.sh`, compare their outputs with the measured builds
   ([research/xcode-tools-by-version.md](research/xcode-tools-by-version.md)), and add the entry to
   `Sources/XlessCore/XcodeToolsProfile.swift`.
5. **The references and the tests:** `make images XCODE=…`, then `make rn-reference` and `make tauri-reference` with
   that Xcode, `make test-rn-linux` and `make test-tauri-linux` in its images, and `xless setup --xcode <the .xip>` on
   Linux.

## Private registries

Images hold Apple's SDK, so they are never published. If you need them on other machines (a CI runner, a build
server), push them only to a registry that you have checked is private:

```sh
cp registry.env.example registry.env     # set XLESS_REGISTRY; then XLESS_REGISTRY_PRIVATE=true once you have verified it is private
make base-push sdk-export sdk-push
```

- `make base-push` builds and pushes `<registry>/xless-base:v<version>` for arm64 and amd64, with `xless`
  cross-compiled by Swift's static Linux SDK. The base image never contains SDK files.
- `make sdk-push` builds the SDK image on top of it, `<registry>/xless:xcode<version>-<build>-v<version>`, and pushes
  it. Both refuse to push unless `registry.env` sets `XLESS_REGISTRY_PRIVATE=true`; `scripts/check-private-registry.sh`
  also refuses Docker Hub (`docker.io`, `index.docker.io`, `registry-1.docker.io` in any case, and bare names such as
  `myuser`, which Docker would push to Docker Hub).
- On a machine with a native install, `xless sdk install --image <registry>/xless:<tag>` installs the SDK from such
  an image (`docker login <registry>` first; [native-install.md](native-install.md)).
- [examples/example-ios.yml](examples/example-ios.yml) is a GitHub Actions workflow that runs such an image as the job
  container ([signing-and-testflight.md](signing-and-testflight.md#continuous-integration)). It lives in `docs/`, so
  this repository never runs it.

## Releases

Releases are cut by `.github/workflows/release.yml`, at 03:00 UTC every night and by hand (`gh workflow run
release.yml`). It computes the next version from the Conventional Commit titles merged since the last `v*` tag
(`scripts/next-version.sh`; the rules are in [CONTRIBUTING.md](../CONTRIBUTING.md#versions-and-releases)). With no
releasable commit it does nothing. Otherwise it builds both tarballs from that commit (`.github/actions/build-package`:
`scripts/stamp-version.sh`, a static musl build, `scripts/package-release.sh`), then installs them on both architectures
before publishing anything (the `verify` job: `scripts/release-assets.sh` writes `SHA256SUMS` and copies `install.sh`,
and `scripts/verify-release.sh` lays them out like a GitHub release, installs with that `install.sh` from `file://`,
pinned and as the latest, and checks that `xless --version` and `share/xless/VERSION` are the new version). Only then
does it attest the build provenance of the tarballs, `SHA256SUMS` and `install.sh` (`actions/attest-build-provenance`,
signed through GitHub's OIDC token with Sigstore and stored on GitHub; only the `publish` job gets `id-token: write` and
`attestations: write`), tag `v<version>` and publish a GitHub release with those assets and notes from
`scripts/release-notes.sh`. `gh attestation verify <asset> -R fmsouza/xless` checks one
([README](../README.md#install)). The source tree stays at version `0.0.0-dev`; only the release build stamps one.

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
pushes and deletion. It is idempotent: run it again after changing a required check.

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
