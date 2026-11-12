# What xless needs from Apple

xless contains no Apple software. To build an app it needs one thing from Apple, the Xcode download, and only the SDK
files inside it. To sign and upload an app it also needs an Apple developer account. Nothing from Apple runs on your
Linux machine: Apple's programs are macOS programs, and xless uses open-source replacements for every one of them.

## How to get Xcode on Linux

1. Sign in at <https://developer.apple.com/download/all/> with an Apple ID. A free Apple ID is enough; you accept
   Apple's Xcode licence when you download.
2. Download the `.xip` of a supported Xcode. Where Apple offers both, take the "Universal" file rather than the
   "Apple silicon" one: xless is checked against the Universal download.

   | Xcode | Build | File |
   |---|---|---|
   | 27.1 | 27A9275 | `Xcode_27.1.xip` |
   | 27.0 | 27A266a | `Xcode_27.xip` |
   | 26.2 | 17C52 | `Xcode_26.2_Universal.xip` |

3. Give it to xless as it is: `xless setup --xcode ~/Downloads/Xcode_27.xip`. Do not unpack it.

`xless xcode download 27.0 26.2` does steps 1 and 2 from the terminal, for as many versions as you name, in one sign-in
that nothing is kept of ([xcode-download.md](xcode-download.md)).

xless identifies the file by its SHA-256 (recorded in `versions.env` for each download it has been checked against),
so renaming it changes nothing, and refuses any other file with the list of supported versions. An already unpacked
`Xcode.app` is accepted too, identified by its `Contents/version.plist`. The `.xip` is unpacked by
[xtool](https://github.com/xtool-org/xtool), which is open source, inside the `xless-base` image; Apple's `xip` tool
is not used.

## From `Xcode.xip`

`xless setup` runs `xtool sdk build` on the `.xip`, which writes a Darwin SDK bundle (`darwin.xtoolsdk`, about 3 GB)
into `~/.cache/xless/sdk/xcode<version>-<build>/<arch>/`; xtool unpacks the `.xip` there first, so that directory
peaks at about 15 GB. That bundle, and the metadata read from it, is all xless takes from the download. A native setup installs it for
Swift under your home directory ([native-install.md](native-install.md)); with `--docker` it goes into the `xless`
image and from there into the images built on it.

| File or tree (inside the Xcode bundle) | Used by | Why there is no open replacement |
|---|---|---|
| The `.xip` file itself (only its SHA-256 and xtool's read of it) | `XcodeSource` (identification), `NativeSetupPlan` (read by the native xtool), `SetupPlan` (mounted read-only into the xtool container) | It is the only legal source of the SDK: Apple's licence does not allow redistributing it. |
| `iPhoneOS.platform/Developer/SDKs/iPhoneOS.sdk`: headers, `.tbd` link stubs, module maps, Swift module interfaces | every iOS build: SwiftPM through xtool (`xless build`), Swift Build (React Native), cargo and Swift (Tauri) | These files define Apple's iOS APIs. The open-source Swift toolchains do not include any Apple platform SDK. |
| `MacOSX.platform/Developer/SDKs/MacOSX.sdk` | macOS builds (SwiftPM `xless.yml` apps, the Tauri DMG) | The same, for macOS. |
| `iPhoneSimulator.platform/Developer/SDKs/iPhoneSimulator.sdk` | React Native simulator builds (`--destination simulator`) | The same, for the iOS Simulator. |
| The default toolchain's `usr/lib/swift` and `usr/lib/swift_static`: Swift's shims, C++ interoperability overlays, compatibility and back-deployment libraries for Apple platforms | Swift compiles and links for iOS and macOS (`docker/Dockerfile.sdk` keeps them as the SDK bundle's Swift resource directory) | They belong to the SDK: its Swift module interfaces are built against these files, so both must come from the same Xcode. |
| The default toolchain's `usr/lib/clang/<version>/lib/darwin/libclang_rt.*.a`: compiler runtime libraries for Apple targets | every link for iOS and macOS (for example `@available` checks call into it) | Open-source LLVM releases for Linux do not ship the Darwin builds of compiler-rt. |
| Each SDK's `SDKSettings.json` and `System/Library/CoreServices/SystemVersion.plist`, and each platform's `Info.plist` | `ToolchainMetaCollector` writes `toolchain-meta.json` from them; `finalize` stamps them into the app's Info.plist (`DTSDKName`, `DTSDKBuild`, `DTPlatformVersion`, `DTPlatformBuild`, `DTXcode`, `DTXcodeBuild`) and every binary's `LC_BUILD_VERSION` | App Store Connect checks that an app names the SDK and Xcode it was built with. The values describe Apple's SDK, so they can only come from it. |
| `Contents/version.plist` (an `Xcode.app` only) | `XcodeSource` identifies an unpacked `Xcode.app` by its build | A `.xip` is identified by its hash instead. |

What xless does **not** take from Xcode: any program. The Xcode version, its Swift version and the
`BuildMachineOSBuild` value it stamps come from a table in `versions.env`, measured once per Xcode release; the asset
and storyboard compilers (`actool`, `ibtool`, `copypng`), `xcrun`, `xcodebuild`, `PlistBuddy`, `lipo`, `otool`,
`strip`, `ditto` and `codesign` are replaced by xless's own code, by LLVM's tools or by rcodesign; the compilers are
the open-source Swift and LLVM releases.

## From your Apple account

Only for signing and uploading. Building up to `finalize` needs none of this.

| What | Needed for | Where to get it |
|---|---|---|
| An Apple ID | downloading Xcode | <https://appleid.apple.com>, free |
| Apple Developer Program membership | everything below | <https://developer.apple.com/programs/>, paid yearly |
| App Store Connect API key (`.p8`, Admin role), with its key ID and issuer ID | `sign`, `upload`, macOS notarization, `xless sign bootstrap` | App Store Connect, Users and Access, Integrations ([bootstrap.md](bootstrap.md#1-app-store-connect-api-key)) |
| Apple Distribution certificate and its private key | iOS `sign` | `xless sign bootstrap --type distribution`, on Linux ([bootstrap.md](bootstrap.md#2-apple-distribution-key-ios)) |
| Developer ID Application certificate and its private key | macOS `sign` | `xless sign bootstrap --type developer-id` ([bootstrap.md](bootstrap.md#3-developer-id-application-key-macos-only)) |
| A registered bundle ID | `sign`, the app record | developer.apple.com, or the first `xless ship` ([bootstrap.md](bootstrap.md#4-bundle-id-before-the-app-record)) |
| An App Store Connect app record | `upload` | App Store Connect, by hand: the API cannot create it ([bootstrap.md](bootstrap.md#5-app-record)) |
| Provisioning profiles | `sign` | Created by `xless sign` through the API; nothing to do |
| TestFlight testers | delivery to a group | App Store Connect users, added to the group once in the web UI ([signing-and-testflight.md](signing-and-testflight.md#one-command-testflight)) |

All of it is done in a web browser or with xless itself; none of it needs a Mac.

## Maintainers only (on a Mac)

These run Apple's own programs, black-box, to measure what xless must reproduce or to compare its output with
Xcode's. None of them is part of installing xless or building an app. [maintainers.md](maintainers.md) describes when
to run them.

| Script or command | What it runs from Apple | What for |
|---|---|---|
| `scripts/ib-golden.sh` | `ibtool` (through `xcrun`), `xcodebuild -version` | The storyboard compiler's golden outputs (`Tests/IBCorpus/golden/<build>/`) |
| `scripts/assetkit-golden.sh` | `actool`, `assetutil --info` | The asset catalog fields AssetKit must match (`Parity.expected.<build>.json`) |
| `scripts/copypng-golden.sh` | `copypng`, `xcodebuild -version` | The PNG cases the `copypng` replacement must match |
| `scripts/target-os-macros.sh` | Xcode's `clang -dM -E` on an empty input | The `TARGET_OS_*` macros of each Xcode (`docker/toolchain/target-os/<build>.txt`) |
| `scripts/rn-reference.sh` (`make rn-reference`) | `xcodebuild`, CocoaPods with Xcode | The React Native reference app `make test-rn-linux` compares with |
| `scripts/tauri-ios-reference.sh` (`make tauri-reference`) | `tauri ios build` / `tauri build` with Xcode, `lipo`, `hdiutil`, `codesign` | The Tauri reference apps `make test-tauri-linux` compares with |
| `scripts/sim-launch.sh` (`make sim-launch`) | `simctl`, `codesign --verify` | Launching a simulator build on the Mac's iOS Simulator |
| `scripts/ib-parity.sh` (`make ib-parity`) | `ibtool`, `xcodebuild`, `simctl` | Golden drift, and a pixel comparison of a launch screen compiled both ways |
| `scripts/parity.sh` (`make parity`) | `xcodebuild`, `assetutil` | HelloShip built by Xcode against the same app built by xless |
| `scripts/build-images.sh` (`make images`) | `xip --expand` for a `.xip`; then `xless sdk export` | The Mac way to build the images, from before `xless setup` |
| `xless sdk export`, `xless sdk meta --xcode <Xcode.app>` | the Xcode's `swift --version` | Reading an installed `Xcode.app` on the Mac (`xless setup` uses the version table instead) |
| `xless tauri report` / `xless tauri compare` built for macOS (so `make test-rn-linux`, `make test-tauri-linux` and `scripts/arch-compare.sh` on a Mac host) | `assetutil --info` | Comparing asset catalogs; the Linux build of xless never calls it and skips that comparison |
| `scripts/ib-corpus/known-fonts.sh`, `scripts/ib-corpus/differential.py` | `swiftc` and `simctl`; `ibtool` | The font name list and random-storyboard checks of the storyboard compiler |

## The audit

Every place in the shipped code that names an Xcode location or an Apple tool was found with this search, run from the
repository root on the Swift sources (xless and the vendored AssetKit) and on everything a release ships (the
installer, the scripts in `share/xless/scripts`, and `docker/`):

```sh
git grep -n -E 'Contents/Developer|xcrun|xcodebuild|sw_vers|PlistBuddy|xip |\.app/' -- \
  Sources ThirdParty/AssetKit/Sources scripts/install.sh scripts/docker-images.sh scripts/xcode-swift.sh \
  scripts/testflight.sh docker
```

Run on 2026-10-19 (at the commit that added this document): 90 hits in 32 files. Each one falls in one of four
classes:

- **SDK**: reads a file listed under [From `Xcode.xip`](#from-xcodexip); nothing is executed.
- **Replacement**: xless's own open-source stand-in for an Apple tool, named after it so that build scripts find it
  (`xcrun`, `xcodebuild`, `PlistBuddy`, `lipo`, `otool`). It runs no Apple program.
- **Text**: a comment, a help or error message, or a name; nothing is read or run.
- **Maintainer**: a Mac-only path from the [table above](#maintainers-only-on-a-mac).

| File | Lines | Class |
|---|---|---|
| `Sources/XlessCore/EntitlementRewrites.swift` | 11 | Text |
| `Sources/XlessCore/KnownXcodes.swift` | 10 | Text |
| `Sources/XlessCore/PlistBuddyShim.swift` | 3, 6, 7, 9, 13, 61, 189 | Replacement |
| `Sources/XlessCore/StagePolicy.swift` | 30 | Text (tells you to install a simulator app with `xcrun simctl` on a Mac) |
| `Sources/XlessCore/SwiftToolchain.swift` | 8, 11 | Text |
| `Sources/XlessCore/XcodeToolsProfile.swift` | 13 | Text |
| `Sources/XlessCore/XcrunShim.swift` | 3, 4, 15, 23, 25, 26, 36, 37, 38, 42 | Replacement |
| `Sources/XlessPackage/IPAInfo.swift` | 10 | Text |
| `Sources/XlessReactNative/Overlay.swift` | 199 | Text |
| `Sources/XlessReactNative/ReactNativeBuilder.swift` | 40, 452 | Text |
| `Sources/XlessReactNative/SimulatorBuild.swift` | 17 | Text |
| `Sources/XlessSDK/SetupPlan.swift` | 41 | SDK (the `.xip` is mounted read-only for xtool) |
| `Sources/XlessSDK/SetupPlan.swift` | 63 | Text |
| `Sources/XlessSDK/ToolchainMetaCollector.swift` | 8 | Text |
| `Sources/XlessSDK/ToolchainMetaCollector.swift` | 19 | Maintainer (`xless sdk export` / `sdk meta --xcode`: an installed `Xcode.app`'s platform files) |
| `Sources/XlessSDK/ToolchainMetaCollector.swift` | 65 | Maintainer (the Xcode's `swift --version`, for `xless sdk export` / `sdk meta --xcode`; `xless setup` reads the table) |
| `Sources/XlessSDK/XcodeSource.swift` | 16, 47, 50 | Text |
| `Sources/XlessTauri/AssetCatalogReport.swift` | 4, 41 | Text |
| `Sources/XlessTauri/AssetCatalogReport.swift` | 23, 32 | Maintainer (`assetutil`, in the macOS build of xless only) |
| `Sources/XlessTauri/BundleReport.swift` | 51 | Text |
| `Sources/XlessXcode/PIFWriter.swift` | 5 | Text |
| `Sources/XlessXcode/SwiftBuildEnvironment.swift` | 7, 95 | Text |
| `Sources/XlessXcode/SwiftBuildOutput.swift` | 41, 44, 58, 66, 67 | Text (build-log messages it recognises) |
| `Sources/XlessXcode/XcodeProject.swift` | 583 | Text |
| `Sources/XlessXcode/XcodebuildShim.swift` | 4, 6, 7, 40, 99, 161, 166, 167, 171, 172 | Replacement |
| `Sources/xless/Commands/SDKCommands.swift` | 34 | Text |
| `Sources/xless/Commands/SDKCommands.swift` | 100 | Maintainer (`xless sdk export`, built on macOS only: checks that Docker sees the `Xcode.app`) |
| `Sources/xless/Commands/SetupCommand.swift` | 6, 11, 21, 77 | Text |
| `Sources/xless/Commands/ShimCommands.swift` | 13, 35, 37, 154, 231, 232, 236 | Replacement |
| `Sources/xless/Commands/TauriCommands.swift` | 33, 48, 59 | Maintainer (`xless tauri compare --assets-only`) |
| `ThirdParty/AssetKit/Sources/AssetKit/CAR/KeyFormat.swift` | 6 | Text |
| `docker/Dockerfile.rn` | 127, 128, 129 | Text |
| `docker/Dockerfile.rn` | 136, 140, 142, 144 | Replacement (installs the `PlistBuddy` stand-in and checks the stand-ins answer) |
| `docker/Dockerfile.tauri` | 51 | Replacement (the image build asks the `xcrun` stand-in for the SDK path) |
| `docker/shims/rn/lipo`, `docker/shims/rn/otool` | 2 | Replacement |
| `docker/shims/rn/xcodebuild` | 2 | Text |
| `docker/shims/rn/xcodebuild` | 10 | Replacement |
| `docker/shims/xcrun` | 2 | Replacement |

No hit outside these classes: the user path (install, `xless setup`, `xless run`, every build stage, signing,
packaging and upload) runs no Apple program. Line numbers drift as the code changes; run the search again to check.
