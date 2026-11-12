# Milestone 4 acceptance (2026-10-18) — toolchain ready for CD (local)

Scope: the toolchain only. Registry publication, CD workflows, upload from CD, TestFlight and any app-specific acceptance are out of scope for this milestone and belong to later deployment plans. Nothing was pushed to a registry or delivered to Apple. Acceptance is local: test suites, Linux builds of the samples on both host architectures with both Xcode pins, and simulator launches.

| Criterion | Result |
|---|---|
| G1. The asset and storyboard tools follow the Xcode pin | PASS — see below |
| G2. Every chain predefines Apple's `TARGET_OS_*` set, checked strictly | PASS — see below |
| G3. amd64 is a first-class host | PASS under Rosetta on an Apple-silicon Mac — see below and the known gaps |

## G1. Tools follow the pin

- `actool`, `ibtool`, `copypng` and the `assets` stage take their output formats from the image's Xcode build (`/opt/xless/toolchain-meta.json`) through a tools profile. Profiles exist for Xcode 26.2 (17C52), 27.0 (27A266a) and 27.1 (27A9275), measured black-box ([research/xcode-tools-by-version.md](research/xcode-tools-by-version.md)); the per-build golden files are byte-identical.
- Match against an Xcode 26.2 reference: `samples/HelloRN/xless.overlay-26.2.yml` (pinned to Xcode 26.2) built in the Xcode 26.2 image matches a reference recorded from `xcodebuild` of Xcode 26.2 on a Mac, app and extension, with no allowed gaps beyond the documented app-icon one, asset catalogs rendition by rendition (`scripts/test-rn-linux.sh`, both runs: fresh and offline).
- Refusal of an unprofiled build: `make images` and `scripts/rn-reference.sh` refuse an Xcode with no profile (`scripts/xcode-tools.sh`), and an image whose Xcode build has no profile is refused by the `actool` and `ibtool` shims with exit 70 and a fix naming `make images`; they never fall back to another Xcode's output. Covered by `Tests/shell/xcode-tools.test.sh` and the Swift tests.

## G2. Strict TARGET_OS check on both chains

- The default (Xcode 27.0) chain bridges Apple's five Apple-only macros (`TARGET_OS_ARROW`, `BRIDGE`, `IOSMAC`, `KERNELKIT`, `XR`) with the same Darwin-only clang driver as a pinned chain. `target-os-check` has no allow-list: every chain is checked against its Xcode's own table at image build time.
- The fixture's Linux triples include `x86_64-unknown-linux-gnu`, so a Linux compile on an amd64 host (build scripts, `cc`) gets exactly the open-source driver's predefines (`Tests/shell/clang-driver.test.sh`).
- The check passed in the image builds of Tasks 1, 4 and 5.

## G3. amd64 chains

- Chains for both Xcodes (27.0 and 26.2) exist for linux/arm64 and linux/amd64 (`xless-base`, `xless`, `xless-tauri`, `xless-rn`).
- Linux tests on both architectures and both Xcodes, with images built from cf8c0ff (no image input changed afterwards):

| Run | arm64 | amd64 |
|---|---|---|
| `scripts/test-rn-linux.sh`, default overlay (Xcode 27.0), both runs, asset catalogs, simulator build | PASS | PASS |
| `scripts/test-rn-linux.sh`, `xless.overlay-26.2.yml` (Xcode 26.2) against the 26.2 Mac reference | PASS | PASS (one retry: the first attempt's CocoaPods artifact download from a public mirror dropped the connection; the re-run passed) |
| `scripts/test-tauri-linux.sh`, Xcode 27.0 image | PASS | PASS |
| `scripts/test-tauri-linux.sh`, Xcode 26.2 image | see note | see note |

Note: the Tauri sample's reference was recorded with Xcode 27.0. Built in the Xcode 26.2 image, the app differs from it in exactly the four entries that identify the SDK (`DTPlatformVersion`, `DTSDKName`, and the two Swift runtime libraries the 26.2 SDK links differently), identically on arm64 and amd64. This is the expected effect of the pin, not a defect; no Xcode 26.2 Tauri reference was recorded.

- Host-architecture comparison: `scripts/arch-compare.sh` on HelloRN, the build stage's app and the finalized app, for each Xcode: the `xless tauri report` summaries are identical and 0 files differ in 47 outside `_CodeSignature/` and the Mach-O code-signature blob. Two causes of earlier differences were fixed in the images, not tolerated: Swift's per-process dictionary seed (`SWIFT_DETERMINISTIC_HASHING=1`) and uninitialised bytes `llvm-strip` leaves in dropped indirect-symbol entries (normalised by the strip shim).
- Simulator launch: each HelloRN simulator build (Xcode 27.0 and 26.2, from the arm64 and the amd64 chain) was installed and launched on an iOS Simulator by `scripts/sim-launch.sh` and was still running after 10 s.

## Suites on the branch head

`swift test`, `swift test --package-path ThirdParty/AssetKit`, `make test-linux` and every `Tests/shell/*.test.sh` pass.

## Known gaps

- amd64 was verified under Rosetta on an Apple-silicon Mac, not on a native x86_64 host (deployment work is a later plan). The Docker VM must run amd64 through Rosetta; with Colima that needs the `vz` VM type with Rosetta enabled, which on some Colima and Lima releases has to be set in the VM's Lima configuration (`vmOpts.vz.rosetta`, with `enabled: true` and `binfmt: true`). Under QEMU user-mode emulation gcc and Swift crashed at random.
- Tools profiles exist for Xcode 26.2 (17C52), 27.0 (27A266a) and 27.1 (27A9275) only; any other build is refused until it is measured (27.1 was added after this milestone).
- The Tauri sample has a reference for Xcode 27.0 only.

Everything else: [react-native.md](react-native.md#known-gaps).
