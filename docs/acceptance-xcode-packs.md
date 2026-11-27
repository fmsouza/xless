# Xcode packs acceptance (2026-11-27) — what the packs build, against the baked images

Scope: the samples built with an Xcode pack (the generic xless image, with the Xcode's SDK, Swift toolchain and Swift
Build in a pack mounted read-only at `/xcodes/<version>-<build>-<arch>`) against the same samples built in the images
that had the Xcode baked in (`xless:local-<arch>-xcode<version>`, the SDK at
`/opt/xless/config/swiftpm/swift-sdks/darwin.artifactbundle`, the Xcode's Swift at `/opt/xless/toolchains/swift-<v>` or,
when it is the image's own, at `/usr`, Swift Build at `/opt/swift-build`). The baked images were built from commit
49ad396, the last with an Xcode in the image; the packs and the generic image from fc15c64. The goal: the products are
byte for byte the same, or differ only where they record one of the moved paths, each listed. Also measured: sizes,
the image and pack build times, a run's start-up, and what happens to a work copy when its pack is prepared again.
Nothing was pushed or delivered.

| Criterion | Result |
|---|---|
| The samples built with packs are those the baked images built (Xcode 27.0 and 26.2, arm64) | PARTLY — 5 of 8 pairs identical, 1 path only, 2 differ for one cause: the 27.0 pack's own copy of Swift. See below |
| Run to run, a sample builds byte for byte the same (the noise floor) | PASS — nothing to mask |
| amd64 | NOT RUN — the commands are below |
| A new xless over existing packs prepares nothing | PASS — both packs, prepared by an earlier xless, were found current |
| Sizes and times are measured | Below |
| Outputs kept in a work copy follow a pack prepared again | FAIL for Cargo (and the Rust part of Tauri) — see [Stale outputs](#stale-outputs-after-a-pack-is-prepared-again) |

## The machine

- An Apple M3 Max Mac (14 cores, 36 GB), macOS 27.2.1, with Docker 29.5.2 in a Colima 0.10.3 VM (`vz`, arm64): 4 CPUs,
  8 GiB of memory, a 100 GiB disk. The VM ran other containers of the user throughout.
- The two SDK exports (`~/.cache/xless/sdk/xcode27.0-27A266a`, `xcode26.2-17C52`), made earlier from the `.xip`s: no
  `.xip` was expanded for this record. The baked images were built from them with the baseline's own
  `scripts/docker-images.sh image --arch arm64 --xcode <V> --xcode-build <B> --sdk-dir <export>`, its kits with the
  `docker build` lines its `xless setup --docker --with tauri,react-native --dry-run` prints.
- The packs: the volumes `xless-xcode-27.0-27A266a-arm64` and `xless-xcode-26.2-17C52-arm64`, already there.

## How the pairs were built

Each sample was built the way its test script builds it, in a container of the image (the kit for Cargo, Tauri and
React Native), and its products copied out of the container:

| Sample | As | Products compared |
|---|---|---|
| HelloShip (Swift) | `scripts/parity.sh`'s xless part: a copy of the sample with its macOS line on, `xless build`, `assets`, `finalize` for iOS and macOS in `/work` | `ios/HelloShip.app`, `macos/HelloShip.app` (universal) |
| HelloCargo | `scripts/test-cargo-linux.sh`: `xless ship --to finalize`, iOS and macOS | both finalized apps |
| HelloTauri | `scripts/test-tauri-linux.sh`: `xless ship --to finalize`, iOS and `--platform macos` | both finalized apps |
| HelloRN | `scripts/test-rn-linux.sh`'s first run: a fresh work copy, `xless ship --to finalize`, iOS (`xless.overlay-26.2.yml` for 26.2) | the build stage's app and the finalized app |

What a build may pick up from where and when it runs was made the same on both sides first:

- the build number: `XLESS_BUILD_NUMBER` as the scripts set it (`1.0.0.2026010101`, `1.0.0.202601010000` on macOS,
  `1.0.0.2026101601` for HelloRN; HelloShip's `xless.yml` says `build: 1`);
- the sources and `GIT_SHA` (HelloCargo's macOS `Info.plist` records the commit): one clone at fc15c64 mounted
  read-only as `/repo` on both sides, in place of each side's own checkout;
- the work copy: a new, empty work volume for every build, at the same path in the container (`/cache/work/<overlay>`,
  `/work`); the Rust toolchains and the cargo registry, and the React Native caches (corepack, bundler, CocoaPods), one
  set of volumes for both sides.

The image each build ran in is in the first lines of its log (the image's ID, and `XLESS_IMAGE_ID`, `XLESS_XCODE` and the
`SDK:` and `compiler:` lines inside the container): every baseline build ran in a baked image of 49ad396 with no pack
(Swift from `/usr` for 27.0, from `/opt/xless/toolchains/swift-6.2.3` for 26.2), every candidate build in the generic
image of fc15c64 with the pin's pack (Swift from `/xcodes/<pack>/toolchain`).

## The noise floor

Built twice on the baseline alone, in fresh work volumes, each pair is byte for byte identical, the code signatures
included: HelloShip, HelloCargo, HelloTauri and HelloRN with Xcode 27.0, HelloShip with Xcode 26.2. Nothing differs from
run to run once the inputs above are the same, so nothing is masked as run-to-run. The image's identity
(`XLESS_IMAGE_ID`, which differs between the two sides) is in no product: the identical pairs below show it.

## Results

`scripts/pack-parity.sh <baseline> <candidate>` on each pair (arm64):

| Sample | Xcode 27.0 | Xcode 26.2 |
|---|---|---|
| HelloShip | **differs**: the iOS executable is path only; the macOS executable differs (below) | **path only**: the macOS executable, 37 paths of the SDK in each slice's symbol table |
| HelloCargo | identical (11 files) | identical (11 files) |
| HelloTauri | **differs**: the iOS executable's debug map names another build directory (below) | identical (16 files) |
| HelloRN | identical (94 files) | identical (94 files) |

Every "identical" pair is identical byte for byte, the code signatures included.

### Path only

- **HelloShip, Xcode 26.2, `macos/HelloShip.app/Contents/MacOS/HelloShip`**, in both slices (arm64 and x86_64): 37
  paths in the symbol table's string table, the stabs the linker writes for the debugger, each naming a prebuilt module
  of the SDK, e.g.
  `/opt/xless/config/swiftpm/swift-sdks/darwin.artifactbundle/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/macosx/prebuilt-modules/26.2/AppKit.swiftmodule/arm64e-apple-macos.swiftmodule`
  against the same under `/xcodes/26.2-17C52-arm64/config/swiftpm/swift-sdks/darwin.artifactbundle`. The string table
  is 512 bytes longer, so `LC_SYMTAB`'s `strsize` and `__LINKEDIT`'s size grow with it, and `LC_UUID`, which ld64.lld
  computes from the file's bytes, differs; every other byte is in place and the same. Checked with the tools as well:
  `otool -l` of the two differs only in `strsize`, `__LINKEDIT`'s `vmsize` and `filesize`, and the UUID, and
  `nm -ap` of the two is identical once the SDK's old and new prefix are replaced. The iOS app of the pair is
  identical.

### Differs, and why

Both 27.0 differences have one cause, and it is not the SDK or Swift Build of the pack:

- In the baked 27.0 image, Xcode 27.0's Swift (6.4.0) was the image's own Swift, at `/usr`. The 27.0 pack holds its
  own copy of the same release, at `/xcodes/27.0-27A266a-arm64/toolchain` (its `pack.json` says `"mode": "own"`).
- xless takes any Swift outside `/usr/bin` for another Swift than the image's (`SwiftToolchain.isEngine`) and builds
  differently with it: a macOS Swift app through that toolchain's SwiftPM (`--swift-sdk <arch>-apple-macosx --arch`, not
  `--triple`), and Tauri's Swift packages in a build directory named after it (`.build-swift-6.4`).
- Built with the pack but with `XLESS_SWIFT_TOOLCHAIN` naming a record of the image's own Swift (root `/`, the pack's
  clang flags), HelloShip (iOS and macOS) and HelloTauri are byte for byte the baseline's. The SDK and Swift Build of
  the pack change nothing.

What differs:

- **HelloShip, `ios/HelloShip.app/HelloShip`** (path only on its own): one `LC_RPATH`, the toolchain's back-deployment
  libraries, `/usr/lib/swift-6.2/iphoneos` against `/xcodes/27.0-27A266a-arm64/toolchain/usr/lib/swift-6.2/iphoneos`.
  The load commands are 40 bytes longer and fit in the header's padding; `LC_UUID` differs; every other byte is the same.
- **HelloShip, `macos/HelloShip.app/Contents/MacOS/HelloShip`**: the same rpath moves (`/usr/lib/swift-6.2/macosx`), and
  another rpath changes: **`@loader_path` becomes `$ORIGIN`**, a Linux (ELF) token that dyld does not expand. The load
  commands grow by 32 bytes in each slice, and this link has no header padding to take them: every section moves by
  0x20 (`__text` at 0xed8 against 0xef8 in the arm64 slice), so the code is not byte-identical. A macOS app that loads
  a library from beside its executable through `@rpath` would not find it.
- **HelloTauri, `ios/HelloTauri.app/HelloTauri`**: 12 entries of the debug map (11 `N_OSO`, 1 `N_SO`) name
  `…/.xless/swift/Aggregate/.build-swift-6.4/…` where the baseline has `…/.build/…`; the string table is 120 bytes
  longer and the UUID differs. No moved path is involved, so nothing is masked. The macOS app of the pair is identical.

With Xcode 26.2 the baked image already used another Swift (6.2.3 at `/opt/xless/toolchains/swift-6.2.3`), so both
sides take the same path and the products agree.

## How the comparison masks

`scripts/pack-parity.sh` compares every file of the two trees. Left out, as `scripts/arch-compare.sh` does (the code
is shared, `scripts/code-signature-mask.py`): the bundles' `_CodeSignature/` directories, and in a Mach-O image its
code-signature blob, `LC_CODE_SIGNATURE`'s offset and size and `__LINKEDIT`'s sizes; a universal file slice by slice.
A file that still differs is "path only" only when its differences are the moved paths:

- the paths: the SDK (`/opt/xless/config/swiftpm/swift-sdks/darwin.artifactbundle` → `/xcodes/<pack>/config/swiftpm/swift-sdks/darwin.artifactbundle`),
  Swift (`/opt/xless/toolchains/swift-<v>` → `/xcodes/<pack>/toolchain`; when the baked image's Swift was its own,
  the empty prefix of its per-platform libraries `/usr/lib/swift[-<v>]/<platform>`, which no Apple OS has, at the start
  of a path) and Swift Build (`/opt/swift-build` → `/xcodes/<pack>/swift-build`), each a whole path component, the old
  only in the baseline, the new only in the candidate, the n-th of each the same directory, all of one pack;
- the proof, by the first that applies: the same length (each replaced by a placeholder of its length, the two files
  are equal); substituted (the baseline with each old path replaced by the new one is the candidate, byte for byte);
  Mach-O (each occurrence is in a load command that holds a path or in the symbol table's string table, and the two
  are equal once the paths are replaced in those strings, `sizeofcmds`, those commands' sizes and padding,
  `strsize` and each symbol's offset into the string table are left out, the header's padding is all zero, and
  `LC_UUID` is left out and listed);
- anything else, including paths of different lengths whose surroundings moved, is a difference: the tool says whether
  the printable strings are the same once the paths are replaced, and where the first section starts in each, as
  evidence for a person, not as a pass.

Each masked occurrence is printed with its offset in both files and where it is (`load command LC_RPATH`,
`string table`, a section), and each differing `LC_UUID` with both values. Of the products here, two files were
masked: the 26.2 macOS HelloShip executable (37 string-table occurrences per slice, and the UUID) and the 27.0 iOS
HelloShip executable (one `LC_RPATH`, and the UUID).

## Stale outputs after a pack is prepared again

Cargo and Tauri keep their build outputs in the work copy (`target/`, `.xless/`), and nothing in their fingerprint
names the pack; React Native's does. The run:

1. HelloCargo built for Xcode 26.2 with the pack, its work volume kept: `target/*/release/hello-cargo` written at 13:53.
2. The pack's `sdk` part marked as made by another recipe (its hash in `pack.json` replaced), then
   `xless setup --docker --sdk ~/.cache/xless/sdk/xcode26.2-17C52`: "is not current (its sdk part was prepared by another
   recipe …)", the part prepared again and the pack put in place at the same path, in 2 min 43 s. The SDK's files are
   new files (`iPhoneOS.sdk/usr/lib/libSystem.tbd`: another inode, a new mtime).
3. HelloCargo built again in the same work volume: cargo compiled and linked nothing (`Finished … in 0.34s` for each
   target); the three executables kept their inodes and their 13:53 mtimes, and were bundled again as they were.
4. A clean build in a new work volume: identical to the build of step 3, since the recipe, and so the SDK's content,
   had not changed.

So the executables of a Cargo app (and the Rust part of a Tauri app) linked against a pack survive that pack being
prepared again: cargo tracks its sources, flags and declared environment variables, and the SDK's path is the same.
Had the recipe changed the SDK or the toolchain, the next build would have shipped executables linked against the old
ones. Swift Build, which tracks the headers and modules a compile read, was not tried. Until the fingerprint names
the pack's recipe, a clean work copy after `xless setup` prepared a pack again is the safe course.

## Sizes

Decimal GB. Images as `docker images` shows them (the Swift image they start from, 5.6 GB, is shared); the packs and
exports as `du`.

| What | Size |
|---|---|
| The image (fc15c64) / with the `tauri` kit / with the `react-native` kit | 6.52 / 6.83 / 7.28 GB |
| Baked image, Xcode 27.0 / with `tauri` / with `react-native` | 11.0 / 11.3 / 11.8 GB |
| Baked image, Xcode 26.2 / with `tauri` / with `react-native` | 12.8 / 13.1 / 13.5 GB |
| Pack 27.0-27A266a-arm64: `config/` (the SDK), `toolchain/`, `swift-build/` | 7.3 GB: 3.6, 3.7, 0.05 |
| Pack 26.2-17C52-arm64: `config/`, `toolchain/`, `swift-build/` | 6.7 GB: 3.3, 3.3, 0.10 |
| SDK export, Xcode 27.0 / 26.2 | 3.5 / 3.2 GB |

## Times

On the machine above, each once:

| What | Time |
|---|---|
| The image, from an empty build cache (the Swift image already on the machine), `xless setup --docker --sdk <27.0 export> --with tauri,react-native` | 3 min 53 s |
| The `tauri` kit / the `react-native` kit (it compiles Ruby and `hermesc`) | 18 s / 2 min 30 s |
| That whole setup (both packs current: nothing prepared) | 6 min 42 s |
| The pack's `sdk` part prepared again from the 26.2 export: the Swift 6.2.3 download and unpacking, the SDK, the fit | 2 min 43 s: 1 min 53 s, 39 s, 7 s |
| A whole pack from the export, with Swift Build compiled (about 4 min of it): measured before this record, not again | about 5 min 40 s |
| Baked images, for comparison: 27.0 (partly next to other builds) / 26.2 (stages cached from 27.0) | 9 min 18 s / 7 min 4 s |
| A run's start-up: `xless run --docker <HelloShip> --build-number 1 --to build`, from the command to the first line of the build step's container, with the pack / with the baked image | 0.82, 0.44, 0.44 s / 0.48, 0.36, 0.40 s |

The start-up is the same: the pack is a volume mount. One of the three baseline runs then crashed in SwiftPM
(`Signal 11` in libdispatch's event loop, `xless exited with code 12`); the next run passed. That is the baked image's
own Swift, unchanged by the packs.

## Not run

- **amd64.** Under emulation here; it needs an x86_64 host with Docker and SDK exports that hold `amd64/darwin.xtoolsdk`.
  There, with `A=amd64`, the exports in `$SDK27` and `$SDK26`, and this repository checked out:

  ```sh
  git worktree add ../xless-baked 49ad396
  for x in "27.0 27A266a $SDK27" "26.2 17C52 $SDK26"; do set -- $x
    (cd ../xless-baked && scripts/docker-images.sh image --arch $A --xcode $1 --xcode-build $2 --sdk-dir $3)
    (cd ../xless-baked && swift build --product xless && XLESS_SHARE=$PWD .build/debug/xless setup --docker --sdk $3 \
       --with tauri,react-native --arch $A --dry-run)   # prints the two kits' docker build lines: run them
    swift build --product xless && XLESS_SHARE=$PWD .build/debug/xless setup --docker --sdk $3 --with tauri,react-native --arch $A
  done
  ```

  Then build each sample on both sides as in [How the pairs were built](#how-the-pairs-were-built): the baked side in
  `xless:local-$A-xcode<V>[-tauri|-react-native]` with no pack, the pack side in `xless:<commit>-$A[-tauri|-react-native]`
  with `--mount type=volume,src=xless-xcode-<V>-<B>-$A,dst=/xcodes,readonly -e XLESS_XCODE=/xcodes/<V>-<B>-$A`; both with
  one clone mounted as `/repo`, a new work volume each, the build numbers above; copy the products out and run
  `scripts/pack-parity.sh <baked> <pack>` for each of the eight pairs.
- The Mac half of `scripts/parity.sh` (HelloShip built by Xcode) and the test scripts' comparisons with the Mac
  references: they compare with Xcode, not the two images with each other.

## Known limits

- A native `xless setup` on a Linux host can replace a pack in a directory store (`XLESS_XCODES`) while an
  `xless run --docker` build is reading it: the guard against replacing a pack that containers use covers setups run
  through Docker only.
- Rootless Docker and a directory store of packs are covered by unit tests, not exercised for real.
- The 27.0 pack's copy of Swift changes the macOS SwiftPM build (the `$ORIGIN` rpath) and the build directory of
  Tauri's Swift packages, as above.
- Cargo's and Tauri's outputs in a work copy are not rebuilt when the pack they were linked against is prepared again,
  as above.
