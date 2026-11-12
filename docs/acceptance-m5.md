# Milestone 5 acceptance (2026-10-19) — releases, and setup from a `.xip` on Linux

Scope: xless installable from GitHub releases, with the image chain built on the user's machine from the Xcode `.xip`
Apple distributes (`install.sh` → `xless setup --xcode <Xcode.xip>` → `xless docker <project>`). Acceptance ran on a
fresh Linux VM with a locally built `0.1.0` release served from a `file://` directory laid out like a GitHub release
(`XLESS_RELEASE_BASE`). The published `v0.1.0` comes after this record. Nothing was pushed to a registry or delivered
to Apple.

| Criterion | Result |
|---|---|
| 1. PR checks run and pass; a bad title is blocked; squash merging only | PASS — see below |
| 2. A docs-only nightly releases nothing; a manual run produces `v0.1.0` | PARTLY — the release plan is checked; `v0.1.0` is pending the release |
| 3. The README's install line on fresh Ubuntu 24.04 (arm64 and x86_64) installs `0.1.0`; a tampered tarball is refused | PASS from a local `file://` release; the published `v0.1.0` is pending the release |
| 4. `xless setup` builds the chain from each `.xip` with no Mac; HelloRN and HelloTauri match the Mac references; an unsupported `.xip` is refused | PASS within this scope: chains for Xcode 27.0 (arm64, and amd64 under Rosetta) and 26.2 (arm64). HelloRN matches on arm64 for 27.0 and 26.2 and on amd64 for 27.0; HelloTauri on arm64 for 27.0 only; HelloShip built on all three chains. 27.1 is refused. See the known gaps |
| 5. No Apple binary runs on the user path | PASS — see below |
| 6. The README, followed verbatim by a reader who has not seen the repository, reaches a built app | PASS — its findings are fixed |
| 7. A privacy scan of the repository and every release asset is clean | PASS — see below |

## The test machine

- An Ubuntu 24.04 arm64 VM (Colima, `vz`, 8 vCPUs, 12 GiB of memory), fresh for this run: a 19 GB root disk (18 GB
  free, which holds `~/.cache`) and a separate 147 GB disk for Docker's data root. Docker Engine 29.5 with buildx; the
  user is in the `docker` group. Nothing else was installed.
- `linux/amd64` containers run through Rosetta (`/proc/sys/fs/binfmt_misc/rosetta`). Colima did not switch Rosetta on
  from its own flag; it had to be set in the VM's Lima configuration (`vmOpts.vz.rosetta`, as in milestone 4).
- The `.xip`s and the release directory were mounted read-only from the maintainer's Mac.

## Identifying the downloads (criterion 4)

Each candidate download was exported once with `xtool sdk build` on the maintainer's Mac (in `xless-base`) and the
`toolchain-meta.json` built from the export (`xless sdk meta --from-xtoolsdk`) was compared with the reference measured
from that Xcode: identical means the same SDK and platform builds. The macOS SDK (`libSystem.B.tbd`, `libswiftCore.tbd`)
and the toolchain's Swift macOS runtime were also checked for x86_64 slices (the `.tbd` targets and the archives' fat
headers, read as files).

| Download | Xcode | Metadata | x86_64 slices | Recorded |
|---|---|---|---|---|
| `Xcode_27.xip` | 27.0 (27A266a) | identical | yes | yes |
| `Xcode_26.2_Universal.xip` | 26.2 (17C52) | identical | yes | yes |
| `Xcode_26.2_Apple_silicon.xip` | 26.2 (17C52) | identical | yes | yes |
| `Xcode_27.1.xip` | 27.1 (27A9275) | identical | yes | yes |
| `Xcode_27.2.xip` | 27.2 (27B52) | identical | yes | yes |
| `Xcode_26.0.1_Universal.xip` | 26.0.1 (17A400) | identical | yes | yes |
| `Xcode_26.1_Universal.xip` | 26.1 (17B55) | identical | yes | yes |
| `Xcode_26.1.1_Universal.xip` | 26.1.1 (17B100) | identical | yes | yes |
| `Xcode_26.3_Universal.xip` | 26.3 (17C529) | identical | yes | yes |
| `Xcode_26.4_Universal.xip` | 26.4 (17E192) | identical | yes | yes |
| `Xcode_26.4.1_Universal.xip` | 26.4.1 (17E202) | identical | yes | yes |
| `Xcode_26.5_Universal.xip` | 26.5 (17F42) | identical | yes | yes |

The twelve SHA-256s are in `versions.env` (`XCODE_XIP_SHA256_<build>`). Exports on the Mac took 171 to 234 s each, and
the export directory peaked at 11.5 to 14.9 GB.

## Runs in the VM

Disk columns are the growth of the root disk (`~/.cache`) and of Docker's data root during the run, in decimal GB
(10^9 bytes, as `xless setup`'s check counts): the peak, then what stayed. They were sampled every 10 s with `df`. The first chain was built by the README reader (criterion 6); the others followed in this order.

| Run | Exit | Time | Cache peak / kept | Docker peak / kept |
|---|---|---|---|---|
| `xless setup --xcode Xcode_27.xip` (arm64, the README run, fresh machine) | 0 | 12 min 15 s | — / 3.5 GB | — / 31 GB |
| `xless docker ~/HelloShip --build-number 1 --to finalize` (Xcode 27.0) | 0 | ~6 s | — | — |
| `xless setup --xcode Xcode_27.1.xip` | 11, the supported list | 2 s | 0 | 0 |
| `xless setup --xcode /etc/hostname` | 11, the supported list | 0 s | 0 | 0 |
| HelloRN, `xless docker --config samples/HelloRN/xless.overlay.yml … --to finalize` (Xcode 27.0) | 0 | 2 min 16 s | 0 | 3.3 / 3.1 GB |
| HelloRN, `scripts/test-rn-linux.sh` (Xcode 27.0) | 0 | 3 min 3 s | 0 | 2.9 GB |
| HelloTauri, `xless docker --config samples/HelloTauri/xless.overlay.example.yml … --to finalize` (Xcode 27.0) | 0 | 3 min 11 s | 1.4 GB | 2.1 GB |
| HelloTauri, `scripts/test-tauri-linux.sh` (Xcode 27.0) | 0 | 2 min 26 s | 0 | 1.3 GB |
| `xless setup --xcode Xcode_26.2_Universal.xip` (arm64; `xless-base` layers cached) | 0 | 13 min 8 s | 14.5 / 3.3 GB | 27.2 / 27.8 GB |
| HelloShip pinned to `xcode: "26.2"` (the README's 26.2 step) | 0 | 6 s | 0 | 0 |
| HelloRN, `xless docker --config samples/HelloRN/xless.overlay-26.2.yml …` (Xcode 26.2) | 0 | 1 min 44 s | 0 | 2.2 GB |
| HelloRN, `scripts/test-rn-linux.sh` with the 26.2 overlay and the 26.2 Mac reference | 0 | 2 min 37 s | 0 | 2.7 GB |
| `xless setup --xcode Xcode_27.xip --arch amd64` (`XLESS_BIN_AMD64` = the local x86_64 `0.1.0` binary; Rosetta) | 0 | 21 min 4 s | 13.1 / 3.6 GB | 22.9 / 22.9 GB |
| HelloShip in the amd64 images (Xcode 27.0) | 0 | 1 min 1 s | 0 | 7.2 GB (first run of the amd64 image) |
| `scripts/arch-compare.sh`, HelloShip arm64 against amd64 | 0, identical | — | — | — |
| HelloRN, `ARCH=amd64 scripts/test-rn-linux.sh` (Xcode 27.0) | 0 | 7 min 57 s | 0 | 3.8 GB |
| `scripts/arch-compare.sh`, HelloRN arm64 against amd64 (build-stage app and finalized app) | 0, identical (47 files each) | — | — | — |
| Final code: install over the previous `0.1.0`, then `xless setup --xcode Xcode_27.xip` (arm64; export again, images rebuilt around the new `xless`) | 0 | 9 min 43 s | 12.7 / 3.6 GB | 21.0 / 21.4 GB |
| Final code: HelloShip, fresh copy (Xcode 27.0), then `scripts/arch-compare.sh` against the README run's app | 0, identical | 6 s | 0 | 0 |

Between the 26.2 runs and the amd64 runs, the 26.2 images were removed (`docker rmi`, `docker builder prune`,
`fstrim`), as a user with one disk would.

Step times of the setups, on the 8-core arm64 VM with a fast network:

| Step | 27.0 arm64 (final code) | 26.2 arm64 | 27.0 amd64 under Rosetta |
|---|---|---|---|
| `xless-base` | 19 s | 1 s (cached) | 2 min 28 s |
| SDK export | 57 s | 1 min 36 s | 54 s |
| `xless` (SDK, Swift toolchain) | 2 min 34 s | 4 min 44 s | 1 min 56 s |
| `xless-tauri` | 25 s | 37 s | 51 s |
| `xless-rn` | 5 min 21 s | 6 min 2 s | 14 min 50 s |

`xless setup` now prints these as its estimates and says that they depend on the CPU and the network.

## Parity with the Mac references (criterion 4)

- HelloRN, Xcode 27.0, arm64 and amd64: `scripts/test-rn-linux.sh` in the VM: all four runs (fresh prepare with
  network, again offline, the simulator build, the device build after it) match `samples/HelloRN/reference`, app and
  extension, with no allowed gaps. The simulator app is an arm64 `iphonesimulator` app, signed ad hoc.
- HelloRN, Xcode 26.2, arm64: the same four runs match the milestone 4 reference recorded with Xcode 26.2 on the Mac.
- HelloTauri, Xcode 27.0, arm64: `scripts/test-tauri-linux.sh` matches `samples/HelloTauri/reference` apart from the
  known gaps in its `allowed-gaps.txt`.
- The asset catalog comparison (`xcrun assetutil`) and the simulator launch need a Mac and were skipped in the VM;
  milestone 4 ran them on the Mac for the same image recipes.
- Host architecture: HelloShip and HelloRN built in the amd64 images are byte-identical to the arm64 builds outside
  the code signature (`scripts/arch-compare.sh`).

## The README reader (criterion 6)

A fresh reader with only the README, a shell in the VM and the `.xip` path installed xless, ran `xless setup` with
Xcode 27.0 and built HelloShip. Its findings, and what changed:

- The disk check asked for 120 GB in both the cache and Docker's data root, and refused a machine that had room: the
  run kept about 3.5 GB of cache and 31 GB of Docker data. The check now asks, per architecture, for
  `XLESS_SETUP_CACHE_GB` (17) under the cache, only when the SDK is exported, and `XLESS_SETUP_DOCKER_GB` (40) under
  Docker's data root. The figures are the largest measured peaks (14.9 GB of cache, 31 GB of Docker data), plus about
  2 GB and 9 GB. The stock 19 GB root disk of this VM had 18 GB free, so the README's path still passes the check. The refusal names the
  directory, the free and the needed GB, and the variable that overrides it; `--dry-run` prints the check. README and
  [troubleshooting.md](troubleshooting.md#the-disk-check) say the same.
- The step estimates were several times too long (75 minutes in all, against 12). They are now the measured times,
  and the README gives a range.
- The installer said that `~/.local/bin` was not on `PATH`, but a new login shell already had it (Ubuntu's `~/.profile`
  adds it once it exists). The message now says "in this shell", and that a new terminal may already have it.
- The README now mentions `--dry-run`, that the sample builds in under a minute, that `/work` in the output is the
  project directory, and that each image has several tags.

## No Apple binary runs (criterion 5)

The VM's kernel can run Linux ELF programs (natively and, for x86_64, through Rosetta) and nothing else: its
`binfmt_misc` handlers are `python3.12` and `rosetta`, with no Mach-O loader. No step of the user path can therefore
execute a program from Xcode. `xtool sdk build` unpacks the `.xip` itself, without Apple's `xip` tool; `actool`,
`ibtool` and the other tools the builds call are xless's own Linux implementations. The `.xip` is read only through
that export ([apple-requirements.md](apple-requirements.md)).

## Install (criterion 3)

- arm64: the README's install line (`curl -fsSL …/install.sh | sh`, with `XLESS_RELEASE_BASE` pointing at the
  `file://` release) installed `0.1.0` in the VM, and `xless --version` printed `0.1.0`. Running it again upgraded in
  place.
- x86_64: every PR runs the `package (x86_64)` job on GitHub's Ubuntu 24.04 x86_64 runner: it installs the job's own
  tarball with `install.sh` from a `file://` release, checks `xless --version`, and checks that
  `xless setup --xcode /etc/hostname` exits 11 with the supported list. The local `0.1.0` x86_64 binary printed `0.1.0`
  in an `ubuntu:24.04` amd64 container.
- A tampered tarball is refused before anything is installed (`Tests/shell/install.test.sh`, also under `dash`).
- The published `v0.1.0` (GitHub's download URLs, both architectures) is checked after the release.

## PR checks and releases (criteria 1 and 2)

- Every PR of the milestone ran the checks that existed at the time and merged green; since the release tarballs
  landed there are six required checks (`title`, `shellcheck`, and `linux-tests` and `package` for x86_64 and arm64). A throwaway PR with a non-Conventional title failed the `title` check and could
  not be merged. The repository allows squash merging only.
- The release workflow, run by hand without a first version on a `main` with no tag, planned no release and skipped
  the build and publish jobs. The nightly schedule had not run yet at the time of writing. `v0.1.0` is cut by the
  release workflow after this record.

## Privacy scan (criterion 7)

- Every tracked file at the branch head (3,848 files, binary files included) against the maintainer's local list of
  private identifiers and home paths: no hit. No tracked file is Apple SDK material (`.tbd`, `SDKSettings`,
  `.swiftinterface`, `.swiftmodule`, SDK directories, `.xip`, `.car`).
- Both release tarballs, extracted (160 files): no private identifier and no home path. The only matches of the
  list's patterns: one pattern matched a common English word inside ICU's unit-name data in the binaries; a false
  positive. No Apple SDK file is in either tarball.
- A first local build compiled its build directory's absolute path into the binary (BoringSSL's assertion paths). The
  scanned tarballs were therefore built from a clone at a neutral path, as CI builds them.

## Known gaps

- amd64 was verified under Rosetta on an Apple-silicon Mac, not on a native x86_64 host. On x86_64 hardware, only the
  install and `xless --version` ran (GitHub's runner); no `xless setup` from a `.xip` has run on a native x86_64 host.
- Xcode 26.2 was set up on arm64 only.
- HelloTauri was built and compared on arm64 with Xcode 27.0 only: not on amd64, and not with Xcode 26.2 (its
  reference was recorded with Xcode 27.0).
- No image chain was built from the Apple-silicon 26.2 download. It is accepted by its checksum after the metadata
  and x86_64-slice checks above.
- The asset catalog comparison and the simulator launch need a Mac and did not run in the VM.
- Colima's own Rosetta flag did not take effect on the VM used here; the Lima configuration had to be edited.
- Re-running `xless setup` after an upgrade rebuilds the images around the new `xless`; the previous images stay on
  disk until `docker image prune` ([troubleshooting.md](troubleshooting.md#xless-setup)).

Everything else: [react-native.md](react-native.md#known-gaps).
